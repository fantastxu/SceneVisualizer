//
//  WristSettingsTriggerView.swift
//  SceneVisualizer
//
//  Created by Adam Gastineau on 5/25/24.
//

import SwiftUI

struct WristSettingsTriggerView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @Binding var realityKitModel: RealityKitModel
    
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
                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                    realityKitModel.arModel?.saveMeshAnchorGeometriesToFile();
                }
            } label: {
                Text("Save Meshs")
            }
            //.frame(width: 200, height: 100)
        }

    }
}

#Preview {
    WristSettingsTriggerView(realityKitModel: .constant(RealityKitModel()))
}
