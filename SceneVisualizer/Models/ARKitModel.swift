//
//  ARKitModel.swift
//  SceneVisualizer
//
//  Created by Adam Gastineau on 5/24/24.
//

import RealityKit
import ARKit
// Extension to handle NaN values in SIMD3<Float>
extension SIMD3 where Scalar == Float {
    func sanitized() -> SIMD3<Float> {
        return SIMD3<Float>(
            x.isNaN ? 0.0 : x,
            y.isNaN ? 0.0 : y,
            z.isNaN ? 0.0 : z
        )
    }
}

@MainActor
struct MeshAnchorGeometryData: Encodable {
    let vertices: [SIMD3<Float>]
    let normals: [SIMD3<Float>]?
    let faces: [UInt32]
    let originFromAnchorTransform: simd_float4x4

    init(from geometry: MeshAnchor.Geometry, transform: simd_float4x4) {
        self.vertices = geometry.vertices.asSIMD3(ofType: Float.self)
        // Check if normals are available; otherwise, set to nil
        self.normals = geometry.normals.count > 0 ? geometry.normals.asSIMD3(ofType: Float.self).map { $0.sanitized() } : nil
        self.faces = (0..<geometry.faces.count * 3).map {
            geometry.faces.buffer.contents()
                .advanced(by: $0 * geometry.faces.bytesPerIndex)
                .assumingMemoryBound(to: UInt32.self).pointee
        }
        self.originFromAnchorTransform = transform
    }
    enum CodingKeys: String, CodingKey {
        case vertices
        case normals
        case faces
        case originFromAnchorTransform
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vertices, forKey: .vertices)
        if let normals = normals {
            try container.encode(normals, forKey: .normals)
        }
        
        // Convert faces to a 2D array where each sub-array contains 3 indices
        let groupedFaces = stride(from: 0, to: faces.count, by: 3).map {
            Array(faces[$0..<min($0 + 3, faces.count)])
        }
        try container.encode(groupedFaces, forKey: .faces)
        
        // 自定义编码 simd_float4x4
        let transformArray = [
            originFromAnchorTransform.columns.0,
            originFromAnchorTransform.columns.1,
            originFromAnchorTransform.columns.2,
            originFromAnchorTransform.columns.3
        ]
        try container.encode(transformArray, forKey: .originFromAnchorTransform)
    }    
}

struct CameraData{
    public var timeStamp : String
    public var transfom : simd_float4x4?
    public var pixelBuffer : CVPixelBuffer
    public var extrinsics : simd_float4x4
    public var intrinsics : simd_float3x3
    
    init(timeInterval: TimeInterval, transform: simd_float4x4?,
         extrinsics: simd_float4x4, intrinsics: simd_float3x3,
         pixelBuffer: CVPixelBuffer)
    {
        self.timeStamp = String(format: "%.9f", timeInterval)
        self.transfom = transform
        self.extrinsics = extrinsics
        self.intrinsics = intrinsics
        self.pixelBuffer = pixelBuffer
    }
    
    func Save()
    {
        
    }
}

@available(visionOS 2.0, *)
@Observable final class ARKitModel {
    private let arSession = ARKitSession()
    private let sceneReconstructionProvider = SceneReconstructionProvider(modes: [.classification])
    private let worldTrackingProvider = WorldTrackingProvider()
    private let cameraFrameProvider = CameraFrameProvider()
    
    private var cameraDataCache : [CameraData] = []
    
    private var isSaving = false  // Flag to indicate when file saving is in progress
    private let queue = DispatchQueue(label: "com.innopeak.SceneVisualizer.meshUpdateQueue", attributes: .concurrent)
    private let formats = CameraVideoFormat.supportedVideoFormats(for: .main, cameraPositions:[.left])
    private var pixelBuffer: CVPixelBuffer? = nil
    
    private var lastTimeStamp : TimeInterval = -1.0
    private var currentURL : URL? = nil
    public var fps : Float = 10 {didSet{}}
    
    public var folderName : String = "" {didSet{
        //create new folder for new data saving
        if folderName.isEmpty {
            //stop recording
            self.lastTimeStamp = -1.0
        }
        else {
            //start recording camera pose and camera rgb frames.
            //create sub-folder first
            currentURL = getDocumentsDirectory().appendingPathComponent(folderName)
            do {
                try FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true, attributes: nil)
                print("data save directory created at \(currentURL.path)")
            } catch {
                print("Error creating data directory: \(error)")
            }
            
            //set timestamp
            self.lastTimeStamp = Date().timeIntervalSince1970
        }
    }}
    
    private let cameraDataQueue = DispatchQueue(label: "com.innopeak.SceneVisualizer.cameraDataQueue")



    let entity = Entity()

    private var activeShaderMaterial: Material?
    private var meshEntities: [UUID: OccludedEntityPair] = [:]
    private var meshAnchorGeometries: [UUID: MeshAnchorGeometryData] = [:]

    private var material: Material {
        get {
            if var material = self.activeShaderMaterial as? ShaderGraphMaterial {
                // Enable displaying wireframe
                material.triangleFillMode = .lines

                return material
            } else {
                var material = SimpleMaterial(color: .red.withAlphaComponent(0.7), isMetallic: false)
                material.triangleFillMode = .lines

                return material
            }
        }
    }

    private var cachedSettings: RealityKitModel?


    func start3DMesh(_ model: RealityKitModel) async {
        guard SceneReconstructionProvider.isSupported else {
            print("SceneReconstructionProvider not supported.")
            return
        }
        
        do {
            self.activeShaderMaterial = try await ShaderGraphMaterial(named: "/Root/ProximityMaterial", from: "Materials")
        } catch {
            print(error)
        }

        do {

            self.updateProximityMaterialProperties(model)

            //get 3d mesh
            for await update in self.sceneReconstructionProvider.anchorUpdates {
                if Task.isCancelled {
                    print("Quit ARKit task")
                    return
                }

//                print("Anchor update: \(update)")
                await processMeshAnchorUpdate(update)
            }
            
        }
    }
    
    func startCameraData(_ model: RealityKitModel) async {
        
        await arSession.queryAuthorization(for: [.cameraAccess])

        do {
            guard let cameraFrameUpdates =
                cameraFrameProvider.cameraFrameUpdates(for: formats[0]) else {
                return
            }
            //get RGB buffer
            for await cameraFrame in cameraFrameUpdates{
                guard let mainCameraSample = cameraFrame.sample(for: .left) else {
                     continue
                 }
                 
                if(self.lastTimeStamp >= 0.0 && mainCameraSample.parameters.captureTimestamp - self.lastTimeStamp > Double(1 / self.fps))
                {
                    let newdata = CameraData(timeInterval: mainCameraSample.parameters.captureTimestamp,
                                             transform: getDevicePose(timeStamp: mainCameraSample.parameters.captureTimestamp),
                                             extrinsics: mainCameraSample.parameters.extrinsics,
                                             intrinsics: mainCameraSample.parameters.intrinsics,
                                             pixelBuffer: mainCameraSample.pixelBuffer)
                    
                    cameraDataQueue.async {
                        self.cameraDataCache.append(newdata)
                    }
                }
                
            }
        }
    }
    
    func start(_ model: RealityKitModel) async {

        do {
            try await self.arSession.run([self.sceneReconstructionProvider, self.worldTrackingProvider, self.cameraFrameProvider])
            print("Started ARKit")
            
            Task{
                await start3DMesh(model)
            }
            
            Task{
                await startCameraData(model)
            }


        } catch {
            print("ARKit error \(error)")
        }
    }

    func updateProximityMaterialProperties(_ model: RealityKitModel) {
        guard var material = self.activeShaderMaterial as? ShaderGraphMaterial, material.name == "ProximityMaterial" else {
            print("Incorrect material")
            return
        }

        self.cachedSettings = model

        do {
            if model.wireframe {
                material.triangleFillMode = .lines
            }

            try material.setParameter(name: "Ripple", value: .bool(model.ripple))

            try material.setParameter(name: "UseCustomColor", value: .bool(model.enableMeshColor))
            try material.setParameter(name: "CustomColor", value: .color(model.meshColor.resolve(in: .init()).cgColor))
        } catch {
            print(error)
        }

        for pair in self.meshEntities.values {
            pair.primaryEntity.model?.materials = [material]
        }
    }

    @MainActor
    private func processMeshAnchorUpdate(_ update: AnchorUpdate<MeshAnchor>) async {

        guard !self.isSaving else { return }
        
        let meshAnchor = update.anchor

        // Used for collision only, so not used here
//        guard let shape = try? await ShapeResource.generateStaticMesh(from: meshAnchor) else { return }

        let transform = Transform(matrix: meshAnchor.originFromAnchorTransform)

        switch update.event {
        case .added:
            let (primaryMesh, occlusionMesh) = try! self.generateMeshes(from: meshAnchor.geometry)

            let primaryEntity = ModelEntity(mesh: primaryMesh, materials: [self.material])
            // SimpleMaterial is provided as for some reason the occlusion doesn't work without it
            let occlusionEntity = ModelEntity(mesh: occlusionMesh, materials: [OcclusionMaterial(), SimpleMaterial(color: .blue, isMetallic: false)])

            primaryEntity.transform = transform

            // Interaction and collision
//            primaryEntity.collision = CollisionComponent(shapes: [shape], isStatic: true)
//            primaryEntity.components.set(InputTargetComponent())
//            primaryEntity.physicsBody = PhysicsBodyComponent(mode: .static)

            occlusionEntity.transform = transform

            self.meshEntities[meshAnchor.id] = OccludedEntityPair(primaryEntity: primaryEntity, occlusionEntity: occlusionEntity)
            self.entity.addChild(primaryEntity)
            self.entity.addChild(occlusionEntity)

            if let cachedSettings = self.cachedSettings {
                self.updateProximityMaterialProperties(cachedSettings)
            }

            self.meshAnchorGeometries[meshAnchor.id] = MeshAnchorGeometryData(from: meshAnchor.geometry, transform: meshAnchor.originFromAnchorTransform)

        case .updated:
            guard let pair = self.meshEntities[meshAnchor.id] else {
                return
            }

            pair.primaryEntity.transform = transform
            pair.occlusionEntity.transform = transform

            let (primaryMesh, occlusionMesh) = try! self.generateMeshes(from: meshAnchor.geometry)

            pair.primaryEntity.model?.mesh = primaryMesh
            pair.occlusionEntity.model?.mesh = occlusionMesh

            // Collision
//            pair.primaryEntity.collision?.shapes = [shape]

            self.meshAnchorGeometries[meshAnchor.id] = MeshAnchorGeometryData(from: meshAnchor.geometry, transform: meshAnchor.originFromAnchorTransform)

        case .removed:
            if let pair = self.meshEntities[meshAnchor.id] {
                pair.primaryEntity.removeFromParent()
                pair.occlusionEntity.removeFromParent()
            }

            self.meshEntities.removeValue(forKey: meshAnchor.id)
            self.meshAnchorGeometries.removeValue(forKey: meshAnchor.id)
        }

    }

    @MainActor
    private func generateMeshes(from geometry: MeshAnchor.Geometry) throws -> (MeshResource, MeshResource) {
        let primaryMesh = try generateMesh(from: geometry)
        let occlusionMesh = try generateMesh(from: geometry, with: { vertex, normal in -0.01 * normal + vertex } )

        return (primaryMesh, occlusionMesh)
    }

    // Data extraction derived from https://github.com/XRealityZone/what-vision-os-can-do/blob/3a731b5645f1c509689637e66ee96693b2fa2da7/WhatVisionOSCanDo/ShowCase/WorldScening/WorldSceningTrackingModel.swift
    @MainActor
    private func generateMesh(from geometry: MeshAnchor.Geometry, with vertexTransform: ((_ vertex: SIMD3<Float>, _ normal: SIMD3<Float>) -> SIMD3<Float>)? = nil) throws -> MeshResource {
        var desc = MeshDescriptor()
        let vertices = geometry.vertices.asSIMD3(ofType: Float.self)
        let normalValues = geometry.normals.asSIMD3(ofType: Float.self)

        let modifiedVertices = if let vertexTransform = vertexTransform {
            zip(vertices, normalValues).map { vertex, normal in
                vertexTransform(vertex, normal)
            }
        } else {
            vertices
        }

        desc.positions = .init(modifiedVertices)
        desc.normals = .init(normalValues)
        desc.primitives = .polygons(
            (0..<geometry.faces.count).map { _ in UInt8(3) },
            (0..<geometry.faces.count * 3).map {
                geometry.faces.buffer.contents()
                    .advanced(by: $0 * geometry.faces.bytesPerIndex)
                    .assumingMemoryBound(to: UInt32.self).pointee
            }
        )

        return try MeshResource.generate(from: [desc])
    }
    
    @MainActor
    func saveMeshAnchorGeometriesToFile(completion: @escaping()->Void) {
        guard !self.isSaving else { return }
        self.isSaving = true  // Set flag to true before saving
        DispatchQueue.global(qos: .background).async {
            
            let timestamp = Int(Date().timeIntervalSince1970)
            let mainFolderURL = self.getCurrentTimeDirectory()
            let fileURL = mainFolderURL.appendingPathComponent("meshAnchorGeometries_\(timestamp).json")
            
            // Ensure the directory exists
            if !FileManager.default.fileExists(atPath: mainFolderURL.path) {
                do {
                    try FileManager.default.createDirectory(at: mainFolderURL, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("Failed to create directory: \(error.localizedDescription)")
                    self.isSaving = false  // Reset flag on error
                    completion()
                    return
                }
            }

            do {
                // Convert the dictionary to use String keys
                let stringKeyedDictionary = self.meshAnchorGeometries.reduce(into: [String: MeshAnchorGeometryData]()) { (result, keyValue) in
                    let (key, value) = keyValue
                    result[key.uuidString] = value
                }
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // Adds indentation and sorts keys for readability
                
                let data = try encoder.encode(stringKeyedDictionary)
                try data.write(to: fileURL)
                DispatchQueue.main.async {
                    print("Mesh anchor geometries saved to \(fileURL)")
                    self.isSaving = false  // Reset flag after saving
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    print("Failed to save mesh anchor geometries: \(error)")
                    self.isSaving = false  // Reset flag on error
                    completion()
                }
            }
        }
    }
    
    func getDevicePose(timeStamp:TimeInterval) -> simd_float4x4?
    {
        guard let pose = worldTrackingProvider.queryDeviceAnchor(atTimestamp: timeStamp) else {
            return nil
        }
        
        return pose.originFromAnchorTransform
        
    }
    
    // Helper function to convert matrix to string
    private func matrixToArray(_ matrix: simd_float4x4) -> String {
        // 将矩阵的元素格式化为字符串
        var matrixString = ""
        for row in 0..<4 {
            for col in 0..<4 {
                matrixString += "\(matrix[row, col])"
                if col < 3 {
                    matrixString += ", "
                }
            }
            matrixString += "\n"
        }
        
        return matrixString
    }
    
    private func matrixToArray(_ matrix: simd_float3x3) -> String {
        // 将矩阵的元素格式化为字符串
        var matrixString = ""
        for row in 0..<3 {
            for col in 0..<3 {
                matrixString += "\(matrix[row, col])"
                if col < 2 {
                    matrixString += ", "
                }
            }
            matrixString += "\n"
        }
        
        return matrixString
    }
    
    // Convert CVPixelBuffer to Data
    private func pixelBufferToData(pixelBuffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags.readOnly)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let dataSize = CVPixelBufferGetDataSize(pixelBuffer)
        let data = Data(bytes: baseAddress!, count: dataSize)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags.readOnly)
        return data
    }
    
    // Helper function to get documents directory
    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    private func getCurrentTimeDirectory() -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let mainFolderName = dateFormatter.string(from: Date())
        return getDocumentsDirectory().appendingPathComponent(mainFolderName)
    }
    
    
}

private struct OccludedEntityPair {
    let primaryEntity: ModelEntity
    let occlusionEntity: ModelEntity
}


