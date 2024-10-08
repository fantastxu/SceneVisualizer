//
//  WristSettingsTriggerView.swift
//  SceneVisualizer
//
//  Created by Adam Gastineau on 5/25/24.
//

import SwiftUI

@available(visionOS 2.0, *)
struct WristSettingsTriggerView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @Binding var realityKitModel: RealityKitModel
    @State private var isSaving = false
    
    var body: some View {
        VStack(spacing:10) {
            Button {
                // Kill existing settings window, if it exists
                self.dismissWindow(id: "main")

                // After short delay, open a new settings window where the user is looking
                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                    self.openWindow(id: "main")
                }
            } label: {
                Text("Show Settings")
            }
            //.frame(width: 200, height: 100)
            
            Button {
                isSaving = true
                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                    realityKitModel.arModel?.saveMeshAnchorGeometriesToFile(){
                        isSaving = false
                    };
                }
            } label: {
                Text("Save Meshs")
            }
            .disabled(isSaving)
            //.frame(width: 200, height: 100)
        }

    }
}

#Preview {
    if #available(visionOS 2.0, *) {
        WristSettingsTriggerView(realityKitModel: .constant(RealityKitModel()))
    } else {
        // Fallback on earlier versions
    }
}
