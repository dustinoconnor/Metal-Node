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
        MetalPreviewView(
            configuration: store.previewConfiguration(forRenderNodeID: renderNodeID),
            isRunning: store.isGraphRunning,
            videoRecorder: store.previewVideoRecorder(forRenderNodeID: renderNodeID),
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
