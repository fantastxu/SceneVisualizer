//
//  ARKitModel.swift
//  SceneVisualizer
//
//  Created by Adam Gastineau on 5/24/24.
//

import RealityKit
import ARKit

@MainActor
struct MeshAnchorGeometryData: Encodable {
    let vertices: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let faces: [UInt32]
    let originFromAnchorTransform: simd_float4x4

    init(from geometry: MeshAnchor.Geometry, transform: simd_float4x4) {
        self.vertices = geometry.vertices.asSIMD3(ofType: Float.self)
        self.normals = geometry.normals.asSIMD3(ofType: Float.self)
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
        try container.encode(normals, forKey: .normals)
        try container.encode(faces, forKey: .faces)
        
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

@Observable final class ARKitModel {
    private let arSession = ARKitSession()
    private let sceneReconstructionProvider = SceneReconstructionProvider(modes: [.classification])

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

    func start(_ model: RealityKitModel) async {
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
            try await self.arSession.run([self.sceneReconstructionProvider])
            print("Started ARKit")

            self.updateProximityMaterialProperties(model)

            for await update in self.sceneReconstructionProvider.anchorUpdates {
                if Task.isCancelled {
                    print("Quit ARKit task")
                    return
                }

//                print("Anchor update: \(update)")
                await processMeshAnchorUpdate(update)
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

    func saveMeshAnchorGeometriesToFile() {
        DispatchQueue.global(qos: .background).async {
            let fileManager = FileManager.default
            let urls = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
            guard let documentDirectory = urls.first else { return }

            let timestamp = Int(Date().timeIntervalSince1970)
            let fileURL = documentDirectory.appendingPathComponent("meshAnchorGeometries_\(timestamp).json")

            do {
                let data = try JSONEncoder().encode(self.meshAnchorGeometries)
                try data.write(to: fileURL)
                DispatchQueue.main.async {
                    print("Mesh anchor geometries saved to \(fileURL)")
                }
            } catch {
                DispatchQueue.main.async {
                    print("Failed to save mesh anchor geometries: \(error)")
                }
            }
        }
    }    
}

private struct OccludedEntityPair {
    let primaryEntity: ModelEntity
    let occlusionEntity: ModelEntity
}


