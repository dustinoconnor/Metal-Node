//
//  PreviewWindowView.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import SwiftUI

struct PreviewWindowView: View {
    @EnvironmentObject private var store: GraphStore
    let renderNodeID: GraphNode.ID

    var body: some View {
        let renderTitle = store.node(withID: renderNodeID)?.title ?? "Render Window"
        MetalPreviewView(
            configuration: store.previewConfiguration(forRenderNodeID: renderNodeID),
            isRunning: store.isGraphRunning,
            preferredFramesPerSecond: store.preferredPreviewWindowFramesPerSecond(for: renderNodeID),
            videoRecorder: store.previewVideoRecorder(forRenderNodeID: renderNodeID),
            syphonServerName: "Metal Composer - \(renderTitle)",
            onMouseChange: store.updateMousePosition,
            onMouseButtonChange: store.updateMouseButtons,
            onModifierFlagsChange: store.updatePreviewModifierFlags,
            onScrollChange: store.updateScrollDelta
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .ignoresSafeArea()
        .frame(minWidth: 256, minHeight: 256)
        .background(Color.black)
    }
}
