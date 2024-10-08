//
//  SettingsView.swift
//  SceneVisualizer
//
//  Created by Adam Gastineau on 5/25/24.
//

import SwiftUI

@available(visionOS 2.0, *)
struct SettingsView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss

    let id: String?

    @Binding var realityKitModel: RealityKitModel
    
    var body: some View {
        NavigationStack {
            VStack {
                Button {
                    self.changeImmersiveState(!self.realityKitModel.immersiveSpaceIsShown)
                    
                    if self.realityKitModel.immersiveSpaceIsShown
                    {
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
                        let mainFolderName = dateFormatter.string(from: Date())
                        
                        self.realityKitModel.arModel?.folderName = mainFolderName
                    }
                    else{
                        self.realityKitModel.arModel?.folderName = ""
                    }
                } label: {
                    Text(self.realityKitModel.immersiveSpaceIsShown ? "Leave Space" : "Enter Space")
                        .padding()
                }
                .padding(.bottom, 24)

                Form {
                    Section("Display") {
                        Toggle(isOn: Binding(get: { self.realityKitModel.ripple }, set: { value in
                            self.realityKitModel.ripple = value
                        })) {
                            Text("Ripple")
                            Text("Periodically shift the vertices of the generated mesh")
                        }

                        Toggle(isOn: Binding(get: { self.realityKitModel.wireframe }, set: { value in
                            self.realityKitModel.wireframe = value
                        })) {
                            Text("Display Polygons")
                            Text("Show the individual polygons rendered as a set of lines")
                        }
                    }

                    Section("Color") {
                        Toggle(isOn: Binding(get: { self.realityKitModel.enableMeshColor }, set: { value in
                            self.realityKitModel.enableMeshColor = value
                        })) {
                            Text("Display Custom Color")
                            Text("Use \"Custom Color\" to color the room rendering")
                        }

                        ColorPicker(selection: Binding(get: { self.realityKitModel.meshColor }, set: { value in
                            self.realityKitModel.meshColor = value

                            // Enable custom color automatically if this changes
                            self.realityKitModel.enableMeshColor = true
                        }), label: {
                            Text("Custom Color")
                        })
                    }

                    Section {
                        Toggle(isOn: Binding(get: { self.realityKitModel.settingsOnRight }, set: { value in
                            self.realityKitModel.settingsOnRight = value
                        })) {
                            Text("Settings on Right Wrist")
                            Text("Lift your right wrist to open settings. Left wrist by default")
                        }
                    } header: {
                        Text("Environment")
                    } footer: {
                        Text("In the virtual space, you can look at your wrist to summon the settings window.")
                    }
                }

                Spacer()
                Section(header: Text("FPS")) {
                    Slider(value: Binding(
                        get: {
                            Double(realityKitModel.arModel!.fps)
                        },
                        set: { newValue in
                            realityKitModel.arModel!.fps = Float(newValue)
                        }
                    ), in: 5...30, step: 5)
                    .disabled(self.realityKitModel.immersiveSpaceIsShown) // Disable when immersive space is shown
                    Text("FPS: \(realityKitModel.arModel!.fps)")
                }
            }
            .padding()
            .navigationTitle("SceneVisualizer")
        }
    }

    func changeImmersiveState(_ state: Bool) {
        Task {
            if state {
                switch await self.openImmersiveSpace(id: "ImmersiveSpace") {
                case .opened:
                    self.realityKitModel.immersiveSpaceIsShown = true
                case .error, .userCancelled:
                    fallthrough
                @unknown default:
                    self.realityKitModel.immersiveSpaceIsShown = false
                }
            } else if self.realityKitModel.immersiveSpaceIsShown {
                await self.dismissImmersiveSpace()
                self.realityKitModel.immersiveSpaceIsShown = false
            }
        }
    }
}

#Preview {
    if #available(visionOS 2.0, *) {
        SettingsView(id: "main", realityKitModel: .constant(RealityKitModel()))
            .frame(width: 600, height: 780)
    } else {
        // Fallback on earlier versions
    }
}
