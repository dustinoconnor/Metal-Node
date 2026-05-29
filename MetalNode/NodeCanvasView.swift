//
//  NodeCanvasView.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import AppKit
import ImagePlayground
import SwiftUI
import UniformTypeIdentifiers

private enum GraphCanvasLayout {
    static let standardNodeWidth: CGFloat = 250
    static let compactNodeWidth: CGFloat = 176
    static let utilityNodeWidth: CGFloat = 144
    static let headerHeight: CGFloat = 104
    static let compactHeaderHeight: CGFloat = 70
    static let portSpacing: CGFloat = 26
    static let cardPadding: CGFloat = 16
    static let portRadius: CGFloat = 8
    static let gridSpacing: CGFloat = 36

    static func usesUtilityLayout(for node: GraphNode) -> Bool {
        switch node.kind {
        case .uniform, .scalarVariable, .stringVariable, .colorVariable, .scalarArrayVariable, .stringArrayVariable, .colorArrayVariable, .imageArrayVariable:
            return true
        default:
            return false
        }
    }

    static func nodeWidth(for node: GraphNode) -> CGFloat {
        switch node.kind {
        case .uniform, .scalarVariable, .stringVariable, .colorVariable, .scalarArrayVariable, .stringArrayVariable, .colorArrayVariable, .imageArrayVariable:
            return utilityNodeWidth
        case .scalarArrayIndex, .stringArrayIndex, .colorArrayIndex, .imageArrayIndex, .arrayCount, .random, .pulse, .counter, .toggle, .delay, .timer, .rectHit, .screenSize, .gridLayout:
            return compactNodeWidth
        default:
            return standardNodeWidth
        }
    }

    static func nodeHeight(for node: GraphNode) -> CGFloat {
        let inputCount = max(visibleInputPorts(for: node).count, 1)
        let outputCount = max(node.outputPorts.count, 1)
        let portRows = max(inputCount, outputCount)
        // Leave bottom breathing room so the last port row is fully inside the card.
        return headerHeight(for: node) + CGFloat(portRows) * portSpacing
    }

    static func headerHeight(for node: GraphNode) -> CGFloat {
        usesUtilityLayout(for: node) ? compactHeaderHeight : headerHeight
    }

    static func visibleInputPorts(for node: GraphNode) -> [GraphPort] {
        guard case .math = node.kind else { return node.inputPorts }
        let unaryOperations: Set<MathOperation> = [.sine, .cosine, .round, .floor, .ceil]
        guard
            let store = GraphStore.currentForLayoutMetrics,
            unaryOperations.contains(store.settings(forMathNodeID: node.id).operation)
        else {
            return node.inputPorts
        }
        return node.inputPorts.filter { $0.name != "B" }
    }
}

private struct PortCenterPreferenceKey: PreferenceKey {
    static var defaultValue: [GraphPort.ID: CGPoint] = [:]

    static func reduce(value: inout [GraphPort.ID: CGPoint], nextValue: () -> [GraphPort.ID: CGPoint]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PortRowCenterPreferenceKey: PreferenceKey {
    static var defaultValue: [GraphPort.ID: CGFloat] = [:]

    static func reduce(value: inout [GraphPort.ID: CGFloat], nextValue: () -> [GraphPort.ID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CanvasFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ConnectionCreateMenuState: Identifiable {
    let id = UUID()
    let outputPortID: GraphPort.ID?
    let inputPortID: GraphPort.ID?
    let location: CGPoint
    let options: [ConnectionCreateNodeOption]
}

private struct ConnectionCreateNodeOption: Identifiable {
    let kind: ConnectionCreateNodeKind
    let title: String
    let subtitle: String

    var id: String { kind.rawValue }
}

private enum ConnectionCreateNodeKind: String {
    case renderWindow
    case layers
    case mix
    case feedback
    case transform
    case blur
    case bloom
    case underwater
    case metalFragment
    case monitor
    case trackball
    case math
    case mapRange
    case interpolator
    case scalarSmooth
    case pointSplit
    case point3Split
    case point4Split
    case colorSplit
    case scene3DRender
    case scene3DMaterial
    case scene3DLight
    case scene3DTransform
    case scene3DTile
    case scene3DPrimitive
    case scene3DText
    case scene3DModel
    case oscGet4
    case oscGetArray
}

private extension String {
    var normalizedPortSignalName: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct NodeCanvasView: View {
    private let canvasSize = CGSize(width: 8000, height: 5200)
    private let canvasCenterAnchorID = "canvas:center"

    @ObservedObject var store: GraphStore
    let document: ShaderDocument
    let selectedNodeID: GraphNode.ID?
    let onSelect: (GraphNode.ID) -> Void

    @State private var draggedOutputPortID: GraphPort.ID?
    @State private var draggedInputPortID: GraphPort.ID?
    @State private var dragLocation: CGPoint?
    @State private var highlightedInputPortID: GraphPort.ID?
    @State private var draggedNodeOrigin: CGPoint?
    @State private var draggedNodeID: GraphNode.ID?
    @State private var portCenters: [GraphPort.ID: CGPoint] = [:]
    @State private var hoveredConnectionID: GraphConnection.ID?
    @State private var selectedConnectionID: GraphConnection.ID?
    @State private var selectedNodeIDs = Set<GraphNode.ID>()
    @State private var multiDraggedNodeOrigins: [GraphNode.ID: CGPoint] = [:]
    @State private var marqueeStartPoint: CGPoint?
    @State private var marqueeCurrentPoint: CGPoint?
    @State private var marqueeBaseSelection = Set<GraphNode.ID>()
    @State private var zoom: CGFloat = 1.0
    @State private var hasCenteredInitialViewport = false
    @State private var viewportSize: CGSize = .zero
    @State private var canvasFrameInViewport: CGRect = .zero
    @State private var canvasScrollView: NSScrollView?
    @State private var isSpacePanMode = false
    @State private var canvasPanStartBoundsOrigin: CGPoint?
    @State private var connectionCreateMenu: ConnectionCreateMenuState?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { viewportGeometry in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        canvasContent
                        connectionCreateMenuOverlay
                    }
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom, alignment: .topLeading)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: CanvasFramePreferenceKey.self,
                                value: geometry.frame(in: .named("scrollViewport"))
                            )
                        }
                    )
                    .coordinateSpace(name: "canvas")
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                handleCanvasTap(at: value.location)
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named("canvas"))
                            .onChanged { value in
                                updateMarqueeSelection(with: value)
                            }
                            .onEnded { _ in
                                finishMarqueeSelection()
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHoveredConnection(at: location)
                        case .ended:
                            hoveredConnectionID = nil
                        }
                    }
                    .onPreferenceChange(PortCenterPreferenceKey.self) { centers in
                        portCenters = centers.mapValues { point in
                            CGPoint(x: point.x / zoom, y: point.y / zoom)
                        }
                    }
                    .onPreferenceChange(CanvasFramePreferenceKey.self) { frame in
                        canvasFrameInViewport = frame
                    }
                    .dropDestination(for: String.self) { items, location in
                        handleDrop(items: items, at: location)
                    }
                    .overlay {
                        GraphFileDropOverlay { urls, location in
                            handleDroppedFileURLs(urls, at: location)
                        }
                    }
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                zoom = clampedZoom(value.magnification * zoom)
                            }
                    )
                    .background(
                        ScrollViewAccessor(
                            onResolve: { scrollView in
                                canvasScrollView = scrollView
                                if hasCenteredInitialViewport == false {
                                    hasCenteredInitialViewport = true
                                    restoreCanvasViewport()
                                }
                            },
                            onScroll: { scrollView in
                                canvasScrollView = scrollView
                                Task { @MainActor in
                                    store.updateCanvasViewportCenter(
                                        currentViewportCenter(in: scrollView),
                                        markDirty: false
                                    )
                                }
                            }
                        )
                    )
                    .onAppear {
                        viewportSize = viewportGeometry.size
                    }
                    .onChange(of: viewportGeometry.size) { _, newValue in
                        viewportSize = newValue
                    }
                    .onChange(of: store.focusSelectionRequestID) { _, _ in
                        focusSelection()
                    }
                    .onChange(of: store.canvasViewportRestoreRequestID) { _, _ in
                        restoreCanvasViewport()
                    }
                    .onChange(of: store.canvasZoomInRequestID) { _, _ in
                        zoom = clampedZoom(zoom * 1.1)
                    }
                    .onChange(of: store.canvasZoomOutRequestID) { _, _ in
                        zoom = clampedZoom(zoom / 1.1)
                    }
                }
                .coordinateSpace(name: "scrollViewport")
            }

            CanvasZoomControls(
                zoomLabel: Int(zoom * 100),
                zoomIn: { zoom = clampedZoom(zoom * 1.1) },
                zoomOut: { zoom = clampedZoom(zoom / 1.1) },
                reset: { zoom = 1.0 },
                canCreateMacro: selectedNodeIDs.count >= 1,
                createMacro: createMacro
            )
            .padding(20)

            if let editingMacro = store.editingMacroNodeID,
               let macroNode = store.node(withID: editingMacro) {
                MacroEditingOverlay(
                    title: macroNode.title,
                    exitMacro: {
                        store.exitMacroEditor()
                        if let selectedMacroID = store.selectedNodeID {
                            selectedNodeIDs = [selectedMacroID]
                            onSelect(selectedMacroID)
                        }
                    }
                )
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let editingIterator = store.editingIteratorNodeID,
               let iteratorNode = store.node(withID: editingIterator) {
                MacroEditingOverlay(
                    title: iteratorNode.title,
                    exitMacro: {
                        store.exitIteratorEditor()
                        if let selectedIteratorID = store.selectedNodeID {
                            selectedNodeIDs = [selectedIteratorID]
                            onSelect(selectedIteratorID)
                        }
                    }
                )
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    guard isSpacePanMode else { return }
                    updateCanvasPan(withGlobal: value)
                }
                .onEnded { _ in
                    guard isSpacePanMode else { return }
                    finishCanvasPan()
                }
        )
        .background(
            store.canvasBackgroundColor.opacity(store.canvasBackgroundOpacity)
        )
        .background(
            CanvasKeyboardMonitor(
                onSpaceChanged: { isPressed in
                    handleSpacePanModeChanged(isPressed)
                },
                onEscape: {
                    guard connectionCreateMenu != nil else { return false }
                    connectionCreateMenu = nil
                    return true
                }
            )
        )
        .focusable()
        .onDeleteCommand(perform: deleteSelection)
        .onDisappear {
            handleSpacePanModeChanged(false)
        }
        .onAppear {
            if let selectedNodeID {
                selectedNodeIDs = [selectedNodeID]
                store.selectedNodeIDs = selectedNodeIDs
            }
        }
        .onChange(of: selectedNodeID) { _, newValue in
            if store.selectedNodeIDs.count > 1 {
                selectedNodeIDs = store.selectedNodeIDs
                return
            }
            guard let newValue else {
                if selectedConnectionID == nil {
                    selectedNodeIDs.removeAll()
                    store.selectedNodeIDs = selectedNodeIDs
                }
                return
            }
            if selectedNodeIDs.contains(newValue) == false {
                selectedNodeIDs = [newValue]
            }
            store.selectedNodeIDs = selectedNodeIDs
        }
        .onChange(of: selectedNodeIDs) { _, newValue in
            store.selectedNodeIDs = newValue
        }
        .onChange(of: store.selectedNodeIDs) { _, newValue in
            guard newValue != selectedNodeIDs else { return }
            selectedNodeIDs = newValue
        }
        .onAppear {
            GraphStore.currentForLayoutMetrics = store
        }
    }

    @ViewBuilder
    private var connectionCreateMenuOverlay: some View {
        if let menu = connectionCreateMenu {
            let offset = connectionCreateMenuOffset(for: menu.location)
            ConnectionCreateNodeMenu(
                options: menu.options,
                onSelect: { option in
                    createConnectedNode(option)
                },
                onCancel: {
                    connectionCreateMenu = nil
                }
            )
            .offset(x: offset.x, y: offset.y)
            .zIndex(1000)
        }
    }

    private var canvasContent: some View {
        let visibleConnections = document.connections.filter { store.isConnectionVisibleOnCanvas($0) }
        let visibleNodes = document.nodes.filter { store.isNodeVisibleOnCanvas($0.id) }

        return ZStack(alignment: .topLeading) {
            GridBackdrop(
                backgroundColor: store.canvasBackgroundColor,
                backgroundOpacity: store.canvasBackgroundOpacity,
                size: canvasSize
            )

            Color.clear
                .frame(width: 1, height: 1)
                .position(x: canvasSize.width / 2, y: canvasSize.height / 2)
                .id(canvasCenterAnchorID)
            Canvas { context, _ in
                for connection in visibleConnections {
                    guard
                        let start = portCenters[connection.fromPortID],
                        let end = portCenters[connection.toPortID],
                        let outputPort = store.port(withID: connection.fromPortID),
                        let inputPort = store.port(withID: connection.toPortID)
                    else {
                        continue
                    }

                    let isSelected = selectedConnectionID == connection.id
                    let isHovered = hoveredConnectionID == connection.id
                    let isNodeRelated = selectedNodeID == outputPort.nodeID || selectedNodeID == inputPort.nodeID
                    let lineWidth: CGFloat = isSelected ? 5 : (isHovered || isNodeRelated ? 4 : 3)
                    let gradientColors: [Color]
                    if isSelected {
                        gradientColors = [.white.opacity(0.98), .yellow.opacity(0.95)]
                    } else if isHovered {
                        gradientColors = [.white.opacity(0.92), .cyan.opacity(0.96)]
                    } else if isNodeRelated {
                        gradientColors = [.green.opacity(0.95), .yellow.opacity(0.9)]
                    } else {
                        gradientColors = [.orange.opacity(0.8), .cyan.opacity(0.8)]
                    }

                    if isSelected || isHovered {
                        context.stroke(
                            cablePath(from: start, to: end),
                            with: .color(.white.opacity(isSelected ? 0.5 : 0.28)),
                            style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round)
                        )
                    }

                    context.stroke(
                        cablePath(from: start, to: end),
                        with: .linearGradient(
                            Gradient(colors: gradientColors),
                            startPoint: start,
                            endPoint: end
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                }

                if
                    let draggedOutputPortID,
                    let dragLocation,
                    let start = portCenters[draggedOutputPortID]
                {
                    context.stroke(
                        cablePath(from: start, to: dragLocation),
                        with: .color(.white.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8, 6])
                    )
                }

                if
                    let draggedInputPortID,
                    let dragLocation,
                    let end = portCenters[draggedInputPortID]
                {
                    context.stroke(
                        cablePath(from: dragLocation, to: end),
                        with: .color(.white.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [8, 6])
                    )
                }
            }

            ForEach(visibleNodes) { node in
                NodeCardView(
                    store: store,
                    node: node,
                    isSelected: selectedNodeIDs.contains(node.id),
                    isSpacePanMode: isSpacePanMode,
                    highlightedInputPortID: highlightedInputPortID,
                    onSelect: { handleNodeSelect(node.id) },
                    onDelete: {
                        store.removeNode(node.id)
                    },
                    onOpenEditor: {
                        store.openCodeEditorWindow()
                    },
                    onOpenMacro: {
                        store.enterMacroEditor(for: node.id)
                        selectedNodeIDs.removeAll()
                    },
                    onOpenIterator: {
                        store.enterIteratorEditor(for: node.id)
                        selectedNodeIDs.removeAll()
                    },
                    onNodeMoved: { value in
                        moveNode(node.id, with: value)
                    },
                    onNodeMoveEnded: {
                        draggedNodeOrigin = nil
                        draggedNodeID = nil
                        multiDraggedNodeOrigins.removeAll()
                    },
                    onInputDragStart: startInputPortDrag(_:),
                    onOutputDragStart: startPortDrag(_:),
                    onOutputDragChange: updatePortDrag(_:),
                    onOutputDragEnd: finishPortDrag,
                    onInputHoverChanged: handleInputHover(portID:isHovering:),
                    showsInlineInspector: false
                )
                .frame(
                    width: GraphCanvasLayout.nodeWidth(for: node),
                    height: GraphCanvasLayout.nodeHeight(for: node),
                    alignment: .topLeading
                )
                .offset(x: node.position.x, y: node.position.y)
                .id(node.id)
            }

            if let marqueeRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(
                        Rectangle()
                            .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
                    )
                    .frame(width: marqueeRect.width, height: marqueeRect.height)
                    .offset(x: marqueeRect.minX, y: marqueeRect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func connectionMidpoint(from start: CGPoint, to end: CGPoint) -> CGPoint {
        CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
    }

    private func startPortDrag(_ portID: GraphPort.ID) {
        selectedConnectionID = nil
        connectionCreateMenu = nil
        draggedOutputPortID = portID
        draggedInputPortID = nil
        dragLocation = portCenters[portID]
    }

    private func startInputPortDrag(_ portID: GraphPort.ID) {
        connectionCreateMenu = nil
        draggedInputPortID = portID
        dragLocation = portCenters[portID]
        guard let connection = document.connections.first(where: { $0.toPortID == portID }) else { return }
        let duplicatesConnection = NSEvent.modifierFlags.contains(.option)
        selectedConnectionID = connection.id
        draggedOutputPortID = connection.fromPortID
        draggedInputPortID = nil
        dragLocation = portCenters[portID] ?? portCenters[connection.fromPortID]
        if !duplicatesConnection {
            store.disconnectConnection(connection.id)
        }
    }

    private func updatePortDrag(_ value: DragGesture.Value) {
        let scrollAdjustment = autoScrollCanvasForPortDrag(atScaledLocation: value.location)
        let effectiveScaledLocation = CGPoint(
            x: value.location.x + scrollAdjustment.x,
            y: value.location.y + scrollAdjustment.y
        )
        let location = CGPoint(
            x: effectiveScaledLocation.x / zoom,
            y: effectiveScaledLocation.y / zoom
        )
        dragLocation = location
        if draggedInputPortID == nil {
            highlightedInputPortID = nearestCompatibleInputPort(to: location, for: draggedOutputPortID)
        }
    }

    private func finishPortDrag() {
        if let draggedInputPortID {
            finishInputPortDrag(draggedInputPortID)
            return
        }

        guard let draggedOutputPortID else {
            dragLocation = nil
            highlightedInputPortID = nil
            return
        }

        let targetPortID = highlightedInputPortID ?? dragLocation.flatMap {
            nearestCompatibleInputPort(to: $0, for: draggedOutputPortID)
        }

        guard let targetPortID else {
            if
                let dropLocation = dragLocation,
                let outputPort = store.port(withID: draggedOutputPortID)
            {
                let options = connectionCreateOptions(for: outputPort)
                if options.isEmpty == false {
                    connectionCreateMenu = ConnectionCreateMenuState(
                        outputPortID: draggedOutputPortID,
                        inputPortID: nil,
                        location: dropLocation,
                        options: options
                    )
                }
            }
            self.draggedOutputPortID = nil
            draggedInputPortID = nil
            dragLocation = nil
            highlightedInputPortID = nil
            return
        }

        store.connectPorts(from: draggedOutputPortID, to: targetPortID)
        selectedConnectionID = document.connections.first(where: { $0.fromPortID == draggedOutputPortID && $0.toPortID == targetPortID })?.id
        self.draggedOutputPortID = nil
        draggedInputPortID = nil
        dragLocation = nil
        highlightedInputPortID = nil
    }

    private func finishInputPortDrag(_ inputPortID: GraphPort.ID) {
        defer {
            draggedInputPortID = nil
            draggedOutputPortID = nil
            dragLocation = nil
            highlightedInputPortID = nil
        }

        guard let inputPort = store.port(withID: inputPortID) else { return }

        if let sourcePortID = dragLocation.flatMap({ nearestCompatibleOutputPort(to: $0, for: inputPortID) }) {
            store.connectPorts(from: sourcePortID, to: inputPortID)
            selectedConnectionID = document.connections.first(where: { $0.fromPortID == sourcePortID && $0.toPortID == inputPortID })?.id
            return
        }

        guard let dropLocation = dragLocation else { return }
        let options = connectionCreateOptions(forInput: inputPort)
        guard options.isEmpty == false else { return }
        connectionCreateMenu = ConnectionCreateMenuState(
            outputPortID: nil,
            inputPortID: inputPortID,
            location: dropLocation,
            options: options
        )
    }

    private func handleInputHover(portID: GraphPort.ID, isHovering: Bool) {
        guard draggedOutputPortID != nil else {
            if !isHovering {
                highlightedInputPortID = nil
            }
            return
        }
        highlightedInputPortID = isHovering ? portID : (highlightedInputPortID == portID ? nil : highlightedInputPortID)
    }

    private func cablePath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        let delta = max((end.x - start.x) * 0.45, 70)
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + delta, y: start.y),
            control2: CGPoint(x: end.x - delta, y: end.y)
        )
        return path
    }

    private func nearestCompatibleInputPort(
        to location: CGPoint,
        for outputPortID: GraphPort.ID?
    ) -> GraphPort.ID? {
        guard
            let outputPortID,
            let outputPort = store.port(withID: outputPortID)
        else {
            return nil
        }

        let maxDistance: CGFloat = 24
        var bestMatch: (id: GraphPort.ID, distance: CGFloat)?

        for node in document.nodes {
            for inputPort in node.inputPorts where store.portsAreCompatible(outputPort, inputPort) {
                guard let center = portCenters[inputPort.id] else { continue }
                let distance = hypot(center.x - location.x, center.y - location.y)
                guard distance <= maxDistance else { continue }

                if let currentBest = bestMatch {
                    if distance < currentBest.distance {
                        bestMatch = (inputPort.id, distance)
                    }
                } else {
                    bestMatch = (inputPort.id, distance)
                }
            }
        }

        return bestMatch?.id
    }

    private func nearestCompatibleOutputPort(
        to location: CGPoint,
        for inputPortID: GraphPort.ID?
    ) -> GraphPort.ID? {
        guard
            let inputPortID,
            let inputPort = store.port(withID: inputPortID)
        else {
            return nil
        }

        let maxDistance: CGFloat = 24
        var bestMatch: (id: GraphPort.ID, distance: CGFloat)?

        for node in document.nodes {
            for outputPort in node.outputPorts where store.portsAreCompatible(outputPort, inputPort) {
                guard let center = portCenters[outputPort.id] else { continue }
                let distance = hypot(center.x - location.x, center.y - location.y)
                guard distance <= maxDistance else { continue }

                if let currentBest = bestMatch {
                    if distance < currentBest.distance {
                        bestMatch = (outputPort.id, distance)
                    }
                } else {
                    bestMatch = (outputPort.id, distance)
                }
            }
        }

        return bestMatch?.id
    }

    private func autoScrollCanvasForPortDrag(atScaledLocation location: CGPoint) -> CGPoint {
        guard let scrollView = canvasScrollView else { return .zero }

        let visibleBounds = scrollView.contentView.bounds
        let contentSize = CGSize(width: canvasSize.width * zoom, height: canvasSize.height * zoom)
        let edgeThreshold: CGFloat = 96
        let maximumStep: CGFloat = 28

        func scrollDelta(for coordinate: CGFloat, minEdge: CGFloat, maxEdge: CGFloat) -> CGFloat {
            if coordinate < minEdge + edgeThreshold {
                let proximity = min(1, ((minEdge + edgeThreshold) - coordinate) / edgeThreshold)
                return -maximumStep * proximity
            }
            if coordinate > maxEdge - edgeThreshold {
                let proximity = min(1, (coordinate - (maxEdge - edgeThreshold)) / edgeThreshold)
                return maximumStep * proximity
            }
            return 0
        }

        let proposedDelta = CGPoint(
            x: scrollDelta(for: location.x, minEdge: visibleBounds.minX, maxEdge: visibleBounds.maxX),
            y: scrollDelta(for: location.y, minEdge: visibleBounds.minY, maxEdge: visibleBounds.maxY)
        )

        guard proposedDelta != .zero else { return .zero }

        let maxOriginX = max(0, contentSize.width - visibleBounds.width)
        let maxOriginY = max(0, contentSize.height - visibleBounds.height)
        let currentOrigin = visibleBounds.origin
        let targetOrigin = CGPoint(
            x: min(max(currentOrigin.x + proposedDelta.x, 0), maxOriginX),
            y: min(max(currentOrigin.y + proposedDelta.y, 0), maxOriginY)
        )

        let appliedDelta = CGPoint(
            x: targetOrigin.x - currentOrigin.x,
            y: targetOrigin.y - currentOrigin.y
        )

        guard appliedDelta != .zero else { return .zero }

        scrollView.contentView.setBoundsOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        Task { @MainActor in
            store.updateCanvasViewportCenter(
                currentViewportCenter(in: scrollView),
                markDirty: false
            )
        }

        return appliedDelta
    }

    private func connectionCreateMenuOffset(for location: CGPoint) -> CGPoint {
        return CGPoint(
            x: min(max(location.x, 12), max(12, canvasSize.width - connectionCreateMenuSize.width - 12)),
            y: min(max(location.y, 12), max(12, canvasSize.height - connectionCreateMenuSize.height - 12))
        )
    }

    private var connectionCreateMenuSize: CGSize {
        CGSize(width: 286, height: 360)
    }

    private func connectionCreateMenuFrame(for location: CGPoint) -> CGRect {
        CGRect(origin: connectionCreateMenuOffset(for: location), size: connectionCreateMenuSize)
    }

    private func connectionCreateOptions(for outputPort: GraphPort) -> [ConnectionCreateNodeOption] {
        func option(_ kind: ConnectionCreateNodeKind, _ title: String, _ subtitle: String) -> ConnectionCreateNodeOption {
            ConnectionCreateNodeOption(kind: kind, title: title, subtitle: subtitle)
        }

        switch outputPort.kind {
        case .fragmentShader:
            return [
                option(.renderWindow, "Render Window", "Display this shader in a preview window"),
                option(.layers, "Layers", "Composite this shader with more layers"),
                option(.mix, "Mix", "Blend this shader with another shader"),
                option(.feedback, "Feedback", "Use this shader in a feedback loop"),
                option(.transform, "2D Transform", "Move, scale, or rotate this shader"),
                option(.metalFragment, "Metal Fragment", "Feed this shader into a custom effect"),
                option(.blur, "Blur", "Apply a Core Image blur"),
                option(.bloom, "Bloom", "Add glow highlights"),
                option(.underwater, "Underwater", "Apply wavy underwater distortion")
            ]
        case .scene3DSignal:
            return [
                option(.scene3DRender, "3D Render", "Render this scene to a shader"),
                option(.scene3DTransform, "3D Transform", "Move, rotate, or scale this scene"),
                option(.scene3DTile, "3D Tile", "Repeat this scene in an animated field")
            ]
        case .lightSignal:
            return [
                option(.scene3DPrimitive, "3D Primitive", "Create geometry that uses this light"),
                option(.scene3DText, "3D Text", "Create text that uses this light"),
                option(.scene3DModel, "3D Model", "Create a model loader that uses this light")
            ]
        case .materialSignal:
            return [
                option(.scene3DPrimitive, "3D Primitive", "Create geometry using this material"),
                option(.scene3DText, "3D Text", "Create text using this material"),
                option(.scene3DModel, "3D Model", "Create a model loader using this material")
            ]
        case .scalarSignal, .audio, .time, .uniform:
            return [
                option(.monitor, "Monitor", "Inspect this value"),
                option(.math, "Math", "Process this value"),
                option(.mapRange, "Map Range", "Remap this value to another range"),
                option(.interpolator, "Interpolator", "Use this value as a control input"),
                option(.scalarSmooth, "Scalar Smooth", "Smooth sudden value changes")
            ]
        case .pointSignal:
            return [
                option(.pointSplit, "Point Split", "Break this point into X and Y"),
                option(.monitor, "Monitor", "Inspect this point")
            ]
        case .point3Signal:
            return [
                option(.point3Split, "Point3 Split", "Break this point into X, Y, and Z"),
                option(.monitor, "Monitor", "Inspect this point")
            ]
        case .point4Signal:
            return [
                option(.point4Split, "Point4 Split", "Break this point into four channels"),
                option(.monitor, "Monitor", "Inspect this point")
            ]
        case .colorSignal:
            return [
                option(.colorSplit, "Color Split", "Break this color into channels"),
                option(.monitor, "Monitor", "Inspect this color")
            ]
        case .stringSignal:
            return [
                option(.monitor, "Monitor", "Inspect this text")
            ]
        case .oscPacketSignal:
            return [
                option(.oscGet4, "OSC Get 4", "Extract up to four values"),
                option(.oscGetArray, "OSC Get Array", "Extract a float array")
            ]
        default:
            return []
        }
    }

    private func connectionCreateOptions(forInput inputPort: GraphPort) -> [ConnectionCreateNodeOption] {
        func option(_ kind: ConnectionCreateNodeKind, _ title: String, _ subtitle: String) -> ConnectionCreateNodeOption {
            ConnectionCreateNodeOption(kind: kind, title: title, subtitle: subtitle)
        }

        switch inputPort.kind {
        case .fragmentShader:
            return [
                option(.metalFragment, "Metal Fragment", "Create a shader source upstream"),
                option(.layers, "Layers", "Composite shaders before this input"),
                option(.mix, "Mix", "Blend two shaders before this input"),
                option(.feedback, "Feedback", "Create a feedback texture source"),
                option(.scene3DRender, "3D Render", "Render a 3D scene into this shader input")
            ]
        case .scene3DSignal:
            return [
                option(.scene3DModel, "3D Model", "Load a model into this scene input"),
                option(.scene3DPrimitive, "3D Primitive", "Create primitive geometry upstream"),
                option(.scene3DText, "3D Text", "Create text geometry upstream"),
                option(.scene3DTransform, "3D Transform", "Transform another scene upstream"),
                option(.scene3DTile, "3D Tile", "Tile another scene upstream")
            ]
        case .materialSignal:
            return [
                option(.scene3DMaterial, "3D Material", "Create a material for this model")
            ]
        case .lightSignal:
            return [
                option(.scene3DLight, "3D Light", "Create a light for this scene node")
            ]
        case .scalarSignal(let signal):
            var options: [ConnectionCreateNodeOption] = []
            if trackballFriendlyScalarNames.contains(signal) || trackballFriendlyScalarNames.contains(inputPort.name.normalizedPortSignalName) {
                options.append(option(.trackball, "Trackball", "Drive rotation, pan, or distance interactively"))
            }
            options.append(contentsOf: [
                option(.interpolator, "Interpolator", "Drive this input over time"),
                option(.math, "Math", "Create a computed scalar upstream"),
                option(.mapRange, "Map Range", "Remap another scalar upstream"),
                option(.scalarSmooth, "Scalar Smooth", "Smooth a scalar before this input")
            ])
            return options
        case .stringSignal:
            return [
                option(.monitor, "Monitor", "Inspect this text")
            ]
        case .pointSignal:
            return [
                option(.pointSplit, "Point Split", "Use or inspect a point upstream")
            ]
        case .point3Signal:
            return [
                option(.point3Split, "Point3 Split", "Use or inspect a 3D point upstream")
            ]
        case .point4Signal:
            return [
                option(.point4Split, "Point4 Split", "Use or inspect a 4D point upstream")
            ]
        case .colorSignal:
            return [
                option(.colorSplit, "Color Split", "Use or inspect a color upstream")
            ]
        default:
            return []
        }
    }

    private var trackballFriendlyScalarNames: Set<String> {
        [
            "orbit",
            "pitch",
            "rotationx",
            "rotationy",
            "panx",
            "pany",
            "distance",
            "cameradistance"
        ]
    }

    private func createConnectedNode(_ option: ConnectionCreateNodeOption) {
        guard let menu = connectionCreateMenu else { return }
        connectionCreateMenu = nil

        let initialNodeIDs = Set(store.document.nodes.map(\.id))
        addNode(forConnectionOption: option.kind, at: menu.location)
        guard let newNodeID = Set(store.document.nodes.map(\.id)).subtracting(initialNodeIDs).first,
              let newNode = store.node(withID: newNodeID)
        else { return }

        store.attachNodeToActiveContainerIfNeeded(newNodeID)

        if
            let outputPortID = menu.outputPortID,
            let outputPort = store.port(withID: outputPortID),
            let inputPort = preferredCompatibleInput(on: newNode, from: outputPort)
        {
            store.connectPorts(from: outputPortID, to: inputPort.id)
            selectedConnectionID = store.document.connections.first(where: { $0.fromPortID == outputPortID && $0.toPortID == inputPort.id })?.id
        } else if
            let inputPortID = menu.inputPortID,
            let inputPort = store.port(withID: inputPortID),
            let outputPort = preferredCompatibleOutput(on: newNode, to: inputPort)
        {
            store.connectPorts(from: outputPort.id, to: inputPortID)
            selectedConnectionID = store.document.connections.first(where: { $0.fromPortID == outputPort.id && $0.toPortID == inputPortID })?.id
        }

        selectedNodeIDs = [newNodeID]
        onSelect(newNodeID)
    }

    private func addNode(forConnectionOption option: ConnectionCreateNodeKind, at location: CGPoint) {
        switch option {
        case .renderWindow:
            store.addRenderNode(at: location)
        case .layers:
            store.addLayersNode(at: location)
        case .mix:
            store.addMixNode(at: location)
        case .feedback:
            store.addFeedbackNode(at: location)
        case .transform:
            store.addTransformNode(at: location)
        case .blur:
            store.addBlurNode(at: location)
        case .bloom:
            store.addBloomNode(at: location)
        case .underwater:
            store.addUnderwaterNode(at: location)
        case .metalFragment:
            store.addMetalFragmentNode(at: location)
        case .monitor:
            store.addMonitorNode(at: location)
        case .trackball:
            store.addTrackballNode(at: location)
        case .math:
            store.addMathNode(at: location)
        case .mapRange:
            store.addMapRangeNode(at: location)
        case .interpolator:
            store.addInterpolatorNode(at: location)
        case .scalarSmooth:
            store.addScalarSmoothNode(at: location)
        case .pointSplit:
            store.addPointSplitNode(at: location)
        case .point3Split:
            store.addPoint3SplitNode(at: location)
        case .point4Split:
            store.addPoint4SplitNode(at: location)
        case .colorSplit:
            store.addColorSplitNode(at: location)
        case .scene3DRender:
            store.addScene3DRenderNode(at: location)
        case .scene3DMaterial:
            store.addScene3DMaterialNode(at: location)
        case .scene3DLight:
            store.addScene3DLightNode(at: location)
        case .scene3DTransform:
            store.addScene3DTransformNode(at: location)
        case .scene3DTile:
            store.addScene3DTileNode(at: location)
        case .scene3DPrimitive:
            store.addScene3DPrimitiveNode(at: location)
        case .scene3DText:
            store.addScene3DTextNode(at: location)
        case .scene3DModel:
            store.addScene3DModelNode(at: location)
        case .oscGet4:
            store.addOSCGet4Node(at: location)
        case .oscGetArray:
            store.addOSCGetArrayNode(at: location)
        }
    }

    private func preferredCompatibleInput(on node: GraphNode, from outputPort: GraphPort) -> GraphPort? {
        if let exactMatch = node.inputPorts.first(where: { $0.kind == outputPort.kind }) {
            return exactMatch
        }
        return node.inputPorts.first(where: { store.portsAreCompatible(outputPort, $0) })
    }

    private func preferredCompatibleOutput(on node: GraphNode, to inputPort: GraphPort) -> GraphPort? {
        if let exactMatch = node.outputPorts.first(where: { $0.kind == inputPort.kind }) {
            return exactMatch
        }
        return node.outputPorts.first(where: { store.portsAreCompatible($0, inputPort) })
    }

    private func handleDrop(items: [String], at location: CGPoint) -> Bool {
        guard let item = items.first else { return false }
        let dropPoint = adjustedDropPoint(for: location)
        let initialNodeIDs = Set(document.nodes.map(\.id))

        func finalizeDrop() -> Bool {
            let newNodeIDs = Set(store.document.nodes.map(\.id)).subtracting(initialNodeIDs)
            if let newNodeID = newNodeIDs.first {
                store.attachNodeToActiveContainerIfNeeded(newNodeID)
            }
            return true
        }

        if item.hasPrefix("customFragmentPreset:") {
            let rawID = String(item.dropFirst("customFragmentPreset:".count))
            guard let presetID = UUID(uuidString: rawID) else { return false }
            store.addCustomFragmentPresetNode(presetID, at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:time" {
            store.addTimeNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:mouse" {
            store.addMouseNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:pointSplit" {
            store.addPointSplitNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:pointCombine" {
            store.addPointCombineNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:point3Split" {
            store.addPoint3SplitNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:point3Combine" {
            store.addPoint3CombineNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:point4Split" {
            store.addPoint4SplitNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:point4Combine" {
            store.addPoint4CombineNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:pointInterpolate" {
            store.addPointInterpolatorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:point3Interpolate" {
            store.addPoint3InterpolatorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:point4Interpolate" {
            store.addPoint4InterpolatorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:pointScale" {
            store.addPointScaleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:point3Scale" {
            store.addPoint3ScaleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:point4Scale" {
            store.addPoint4ScaleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:colorSplit" {
            store.addColorSplitNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scroll" {
            store.addScrollNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:handTracker" {
            store.addHandTrackerNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:pinch" {
            store.addPinchNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scrollGesture" {
            store.addScrollGestureNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:zoomGesture" {
            store.addZoomGestureNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:trackball" {
            store.addTrackballNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:depthEstimate" {
            store.addDepthEstimateNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:math" {
            store.addMathNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:expression" {
            store.addExpressionNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:clamp" {
            store.addClampNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:mapRange" {
            store.addMapRangeNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:logic" {
            store.addLogicNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:compare" {
            store.addCompareNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:random" {
            store.addRandomNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:pulse" {
            store.addPulseNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:fireOnLoad" {
            store.addFireOnLoadNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:counter" {
            store.addCounterNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:toggle" {
            store.addToggleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:delay" {
            store.addDelayNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:timer" {
            store.addTimerNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:string" {
            store.addStringNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:stringFormat" {
            store.addStringFormatNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:stringCompare" {
            store.addStringCompareNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:stringSplit" {
            store.addStringSplitNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:color" {
            store.addColorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:hslColor" {
            store.addHSLColorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scalarArray" {
            store.addScalarArrayNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:stringArray" {
            store.addStringArrayNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:colorArray" {
            store.addColorArrayNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:imageArray" {
            store.addImageArrayNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scalarArrayIndex" {
            store.addScalarArrayIndexNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:stringArrayIndex" {
            store.addStringArrayIndexNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:colorArrayIndex" {
            store.addColorArrayIndexNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:imageArrayIndex" {
            store.addImageArrayIndexNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:arrayCount" {
            store.addArrayCountNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:textImage" {
            store.addTextImageNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:audio" {
            store.addAudioNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:beatDetect" {
            store.addBeatDetectNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:slider" {
            store.addSliderNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:sliderStyle" {
            store.addSliderStyleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:button" {
            store.addButtonNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:buttonStyle" {
            store.addButtonStyleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:polar" {
            store.addPolarNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:hitZone" {
            store.addHitZoneNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:rectHit" {
            store.addRectHitNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:screenSize" {
            store.addScreenSizeNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:screenBounds" {
            store.addScreenBoundsNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:renderBounds" {
            store.addRenderBoundsNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:renderWindow" {
            store.addRenderWindowNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:keyboard" {
            store.addKeyboardNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:gridLayout" {
            store.addGridLayoutNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scalarMultiplexor" {
            store.addScalarMultiplexorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:stringMultiplexor" {
            store.addStringMultiplexorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:colorMultiplexor" {
            store.addColorMultiplexorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:imageMultiplexor" {
            store.addImageMultiplexorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:midiOut" {
            store.addMIDIOutNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:iterator" {
            store.addIteratorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:iteratorVariables" {
            store.addIteratorVariablesNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:midiCC" {
            store.addMIDICCNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:midiCCInput" {
            store.addMIDIInputCCNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:midiNoteInput" {
            store.addMIDIInputNoteNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:oscReceive" {
            store.addOSCReceiveNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:oscSend" {
            store.addOSCSendNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:oscGet4" {
            store.addOSCGet4Node(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:oscGetArray" {
            store.addOSCGetArrayNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:oscMake4" {
            store.addOSCMake4Node(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:oscMakeArray" {
            store.addOSCMakeArrayNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:oscBundle" {
            store.addOSCBundleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:note" {
            store.addNoteNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:transform" {
            store.addTransformNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DTransform" {
            store.addScene3DTransformNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DTile" {
            store.addScene3DTileNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DRender" {
            store.addScene3DRenderNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:billboard" {
            store.addBillboardNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:line" {
            store.addLineNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:select" {
            store.addSelectNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scalarSwitch" {
            store.addScalarSwitchNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:stringSwitch" {
            store.addStringSwitchNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:colorSwitch" {
            store.addColorSwitchNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:clear" {
            store.addClearNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:circle" {
            store.addCircleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:image" {
            store.openImagePicker(at: dropPoint)
            return true
        }

        if item == "core:webView" {
            store.addWebViewNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:aiImage" {
            store.addAIImageNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:videoPlayer" {
            store.openVideoPlayerPicker(at: dropPoint)
            return true
        }

        if item == "core:video" {
            store.addVideoNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:coreImage" {
            store.addCoreImageNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:blur" {
            store.addBlurNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:bloom" {
            store.addBloomNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:hueRotate" {
            store.addHueRotateNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:posterize" {
            store.addPosterizeNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:levels" {
            store.addLevelsNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:glow" {
            store.addGlowNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:underwater" {
            store.addUnderwaterNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:feedback" {
            store.addFeedbackNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scale" {
            store.addScaleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:interpolator" {
            store.addInterpolatorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:hold" {
            store.addHoldNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scalarSmooth" {
            store.addScalarSmoothNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:trail" {
            store.addTrailNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:monitor" {
            store.addMonitorNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:mix" {
            store.addMixNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:transition" {
            store.addTransitionNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:layers" {
            store.addLayersNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:plasma" {
            store.addPlasmaFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:lavaLamp" {
            store.addLavaLampFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:organicMotion" {
            store.addOrganicMotionFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:colorDiffusionFlow" {
            store.addColorDiffusionFlowFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:nebula" {
            store.addNebulaFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:liquidChrome" {
            store.addLiquidChromeFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:liquidFlux" {
            store.addLiquidFluxFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:prismRings" {
            store.addPrismRingsFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:turntableSpectrum" {
            store.addTurntableSpectrumFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:hologramScan" {
            store.addHologramScanFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:hologramVideo" {
            store.addHologramVideoFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:badTVGlitch" {
            store.addBadTVGlitchFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:heatDistortion" {
            store.addHeatDistortionFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:liquidGlass" {
            store.addLiquidGlassFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:chromaticAberration" {
            store.addChromaticAberrationFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:aurora" {
            store.addAuroraFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:digitalRain" {
            store.addDigitalRainFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:plasmaVortex" {
            store.addPlasmaVortexFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:cyberTunnel" {
            store.addCyberTunnelFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:rgbOffsetSplit" {
            store.addRGBOffsetSplitFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:edgeDetection" {
            store.addEdgeDetectionFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:liquidNoiseWipe" {
            store.addLiquidNoiseWipeFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:mercuryMelt" {
            store.addMercuryMeltFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:glitchDisplacement" {
            store.addGlitchDisplacementFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:datamosh" {
            store.addDatamoshFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:temporalGhostTrails" {
            store.addTemporalGhostTrailsFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:frameMelt" {
            store.addFrameMeltFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:reactionDiffusion" {
            store.addReactionDiffusionFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:prismSplit" {
            store.addPrismSplitFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:ghostFrameEcho" {
            store.addGhostFrameEchoFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:pixelSortBands" {
            store.addPixelSortBandsFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:phyllotaxisPetalSpiral" {
            store.addPhyllotaxisPetalSpiralFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:fbmNoiseHeightMap" {
            store.addFBMNoiseHeightMapFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DMaterial" {
            store.addScene3DMaterialNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DLight" {
            store.addScene3DLightNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DPrimitive" {
            store.addScene3DPrimitiveNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DText" {
            store.addScene3DTextNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DModel" {
            store.addScene3DModelNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DGaussianSplat" {
            store.addScene3DGaussianSplatNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DParticle" {
            store.addScene3DParticleNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DFishSchool" {
            store.addScene3DFishSchoolNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:scene3DDustHaze" {
            store.addScene3DDustHazeNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:fragment" {
            store.addMetalFragmentNode(at: dropPoint)
            return finalizeDrop()
        }

        if item == "core:render" {
            store.addRenderNode(at: dropPoint)
            return finalizeDrop()
        }

        guard item.hasPrefix("uniform:") else { return false }
        let rawID = String(item.dropFirst("uniform:".count))
        guard let uniformID = UUID(uuidString: rawID) else { return false }
        store.addUniformNode(uniformID, at: dropPoint)
        return finalizeDrop()
    }

    private func handleDroppedFileURLs(_ urls: [URL], at location: CGPoint) -> Bool {
        guard urls.isEmpty == false else { return false }
        let dropPoint = adjustedDropPoint(for: location)

        for url in urls {
            importDroppedImage(from: url, at: dropPoint)
        }

        return true
    }

    private func importDroppedImage(from url: URL, at dropPoint: CGPoint) {
        let supportedExtensions = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")

        try? FileManager.default.removeItem(at: tempURL)

        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
        } catch {
            return
        }

        Task { @MainActor in
            store.addImageNode(fromFileURL: tempURL, displayFilename: url.lastPathComponent, at: dropPoint)
        }
    }

    private func adjustedDropPoint(for location: CGPoint) -> CGPoint {
        return CGPoint(
            x: max(24, (location.x / zoom) - (GraphCanvasLayout.standardNodeWidth * 0.5)),
            y: max(24, (location.y / zoom) - 70)
        )
    }

    private func moveNode(_ nodeID: GraphNode.ID, with value: DragGesture.Value) {
        guard !isSpacePanMode else { return }

        if draggedNodeOrigin == nil {
            let isOptionDrag = NSEvent.modifierFlags.contains(.option)
            if isOptionDrag,
               let duplicatedNodeID = store.duplicateNode(nodeID),
               let duplicatedNode = store.document.nodes.first(where: { $0.id == duplicatedNodeID }) {
                draggedNodeID = duplicatedNodeID
                draggedNodeOrigin = duplicatedNode.position
                selectedNodeIDs = [duplicatedNodeID]
            } else if let node = document.nodes.first(where: { $0.id == nodeID }) {
                draggedNodeID = nodeID
                draggedNodeOrigin = node.position
                if selectedNodeIDs.contains(nodeID), selectedNodeIDs.count > 1 {
                    multiDraggedNodeOrigins = Dictionary(uniqueKeysWithValues: document.nodes.compactMap { existingNode in
                        guard selectedNodeIDs.contains(existingNode.id) else { return nil }
                        return (existingNode.id, existingNode.position)
                    })
                } else {
                    multiDraggedNodeOrigins = [nodeID: node.position]
                }
            }
        }

        guard let origin = draggedNodeOrigin else { return }
        let activeNodeID = draggedNodeID ?? nodeID
        let translatedPosition = CGPoint(
            x: max(24, origin.x + (value.translation.width / zoom)),
            y: max(24, origin.y + (value.translation.height / zoom))
        )

        if selectedNodeIDs.contains(activeNodeID), multiDraggedNodeOrigins.count > 1 {
            for (selectedID, selectedOrigin) in multiDraggedNodeOrigins {
                store.moveNode(
                    selectedID,
                    to: targetCanvasPosition(CGPoint(
                        x: max(24, selectedOrigin.x + (value.translation.width / zoom)),
                        y: max(24, selectedOrigin.y + (value.translation.height / zoom))
                    ))
                )
            }
        } else {
            store.moveNode(activeNodeID, to: targetCanvasPosition(translatedPosition))
        }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.5), 2.25)
    }

    private var marqueeRect: CGRect? {
        guard let marqueeStartPoint, let marqueeCurrentPoint else { return nil }
        return CGRect(
            x: min(marqueeStartPoint.x, marqueeCurrentPoint.x),
            y: min(marqueeStartPoint.y, marqueeCurrentPoint.y),
            width: abs(marqueeCurrentPoint.x - marqueeStartPoint.x),
            height: abs(marqueeCurrentPoint.y - marqueeStartPoint.y)
        )
    }

    private func handleCanvasTap(at location: CGPoint) {
        guard !isSpacePanMode else { return }
        let canvasPoint = CGPoint(x: location.x / zoom, y: location.y / zoom)
        guard marqueeStartPoint == nil else { return }
        if let menu = connectionCreateMenu {
            guard connectionCreateMenuFrame(for: menu.location).contains(canvasPoint) == false else {
                return
            }
            connectionCreateMenu = nil
            return
        }
        if document.nodes.filter({ store.isNodeVisibleOnCanvas($0.id) }).contains(where: { nodeContainsPoint($0, point: canvasPoint) }) {
            return
        }
        selectedConnectionID = nearestConnection(to: canvasPoint)
        if selectedConnectionID == nil {
            selectedNodeIDs.removeAll()
        }
    }

    private func updateHoveredConnection(at location: CGPoint) {
        guard marqueeStartPoint == nil else {
            hoveredConnectionID = nil
            return
        }
        let canvasPoint = CGPoint(x: location.x / zoom, y: location.y / zoom)
        if document.nodes.filter({ store.isNodeVisibleOnCanvas($0.id) }).contains(where: { nodeContainsPoint($0, point: canvasPoint) }) {
            hoveredConnectionID = nil
            return
        }
        hoveredConnectionID = nearestConnection(to: canvasPoint)
    }

    private func nodeContainsPoint(_ node: GraphNode, point: CGPoint) -> Bool {
        nodeFrame(for: node).contains(point)
    }

    private func nearestConnection(to point: CGPoint) -> GraphConnection.ID? {
        let maxDistance: CGFloat = 14
        var bestMatch: (id: GraphConnection.ID, distance: CGFloat)?

        for connection in document.connections where store.isConnectionVisibleOnCanvas(connection) {
            guard
                let start = portCenters[connection.fromPortID],
                let end = portCenters[connection.toPortID]
            else {
                continue
            }

            let distance = distanceFromPoint(point, toCableFrom: start, to: end)
            guard distance <= maxDistance else { continue }

            if let currentBest = bestMatch {
                if distance < currentBest.distance {
                    bestMatch = (connection.id, distance)
                }
            } else {
                bestMatch = (connection.id, distance)
            }
        }

        return bestMatch?.id
    }

    private func distanceFromPoint(_ point: CGPoint, toCableFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let samples = 24
        var shortestDistance = CGFloat.greatestFiniteMagnitude
        var previousPoint = start

        for sample in 1...samples {
            let t = CGFloat(sample) / CGFloat(samples)
            let currentPoint = cubicPoint(from: start, to: end, t: t)
            shortestDistance = min(shortestDistance, distanceFromPoint(point, toSegmentFrom: previousPoint, to: currentPoint))
            previousPoint = currentPoint
        }

        return shortestDistance
    }

    private func cubicPoint(from start: CGPoint, to end: CGPoint, t: CGFloat) -> CGPoint {
        let delta = max((end.x - start.x) * 0.45, 70)
        let control1 = CGPoint(x: start.x + delta, y: start.y)
        let control2 = CGPoint(x: end.x - delta, y: end.y)
        let mt = 1 - t
        let x = mt * mt * mt * start.x
            + 3 * mt * mt * t * control1.x
            + 3 * mt * t * t * control2.x
            + t * t * t * end.x
        let y = mt * mt * mt * start.y
            + 3 * mt * mt * t * control1.y
            + 3 * mt * t * t * control2.y
            + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }

    private func distanceFromPoint(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if dx == 0, dy == 0 {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func deleteSelection() {
        if let selectedConnectionID {
            store.disconnectConnection(selectedConnectionID)
            self.selectedConnectionID = nil
            return
        }

        let deletableNodeIDs = selectedNodeIDs.filter { store.canDeleteNode($0) }
        if deletableNodeIDs.isEmpty == false {
            let nodeIDsToDelete = Array(deletableNodeIDs)
            selectedNodeIDs.subtract(deletableNodeIDs)
            store.selectedNodeIDs.subtract(deletableNodeIDs)
            if let activeSelectedNodeID = selectedNodeID, deletableNodeIDs.contains(activeSelectedNodeID) {
                store.selectedNodeID = nil
                store.inspectorFocusTarget = .nodeLibrary
            }
            DispatchQueue.main.async {
                for nodeID in nodeIDsToDelete {
                    store.removeNode(nodeID)
                }
            }
            return
        }

        guard
            let selectedNodeID,
            store.canDeleteNode(selectedNodeID)
        else {
            return
        }

        store.removeNode(selectedNodeID)
        selectedNodeIDs.remove(selectedNodeID)
    }

    private func handleNodeSelect(_ nodeID: GraphNode.ID) {
        finishMarqueeSelection()
        selectedConnectionID = nil
        let isShiftSelecting = NSEvent.modifierFlags.contains(.shift)
        if isShiftSelecting {
            if selectedNodeIDs.contains(nodeID) {
                selectedNodeIDs.remove(nodeID)
                if selectedNodeID == nodeID {
                    onSelect(selectedNodeIDs.first ?? nodeID)
                }
            } else {
                selectedNodeIDs.insert(nodeID)
                onSelect(nodeID)
            }
            return
        }

        selectedNodeIDs = [nodeID]
        onSelect(nodeID)
    }

    private func createMacro() {
        store.createMacroFromSelection()
        if let macroID = store.selectedNodeID {
            selectedNodeIDs = [macroID]
            onSelect(macroID)
        }
    }

    private func focusSelection() {
        let selectedIDs = store.selectedNodeIDs.isEmpty ? selectedNodeIDs : store.selectedNodeIDs
        let visibleNodes = document.nodes.filter { selectedIDs.contains($0.id) && store.isNodeVisibleOnCanvas($0.id) }
        if visibleNodes.isEmpty == false {
            let minX = visibleNodes.map(\.position.x).min() ?? 0
            let minY = visibleNodes.map(\.position.y).min() ?? 0
            let maxX = visibleNodes.map { $0.position.x + GraphCanvasLayout.nodeWidth(for: $0) }.max() ?? minX
            let maxY = visibleNodes.map { $0.position.y + GraphCanvasLayout.nodeHeight(for: $0) }.max() ?? minY
            centerCanvas(on: CGPoint(x: (minX + maxX) * 0.5, y: (minY + maxY) * 0.5))
            return
        }

        centerCanvas()
    }

    private func updateMarqueeSelection(with value: DragGesture.Value) {
        guard !isSpacePanMode else { return }
        guard draggedOutputPortID == nil, draggedNodeOrigin == nil else { return }

        let startPoint = CGPoint(x: value.startLocation.x / zoom, y: value.startLocation.y / zoom)
        let currentPoint = CGPoint(x: value.location.x / zoom, y: value.location.y / zoom)

        if marqueeStartPoint == nil {
            guard document.nodes.filter({ store.isNodeVisibleOnCanvas($0.id) }).contains(where: { nodeContainsPoint($0, point: startPoint) }) == false else {
                return
            }
            marqueeStartPoint = startPoint
            marqueeBaseSelection = NSEvent.modifierFlags.contains(.shift) ? selectedNodeIDs : []
            selectedConnectionID = nil
        }

        marqueeCurrentPoint = currentPoint

        guard let marqueeRect else { return }
        let intersectingNodeIDs = Set(
            document.nodes
                .filter { store.isNodeVisibleOnCanvas($0.id) }
                .filter { nodeFrame(for: $0).intersects(marqueeRect) }
                .map(\.id)
        )
        selectedNodeIDs = marqueeBaseSelection.union(intersectingNodeIDs)
        if let firstSelectedID = selectedNodeIDs.first {
            onSelect(firstSelectedID)
        }
    }

    private func finishMarqueeSelection() {
        marqueeStartPoint = nil
        marqueeCurrentPoint = nil
        marqueeBaseSelection.removeAll()
    }

    private func centerCanvas() {
        centerCanvas(on: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    private func restoreCanvasViewport() {
        if let preferredCenter = store.requestedCanvasViewportCenter(),
           isReasonableViewportCenter(preferredCenter) {
            centerCanvas(on: preferredCenter)
            return
        }
        if let contentCenter = graphContentCenter() {
            centerCanvas(on: contentCenter)
            return
        }
        centerCanvas()
    }

    private func centerCanvas(on canvasPoint: CGPoint) {
        guard let scrollView = canvasScrollView else { return }
        let visibleSize = scrollView.contentView.bounds.size
        let contentSize = CGSize(width: canvasSize.width * zoom, height: canvasSize.height * zoom)
        let targetOrigin = CGPoint(
            x: max(0, min(canvasPoint.x * zoom - (visibleSize.width * 0.5), max(0, contentSize.width - visibleSize.width))),
            y: max(0, min(canvasPoint.y * zoom - (visibleSize.height * 0.5), max(0, contentSize.height - visibleSize.height)))
        )
        scrollView.contentView.setBoundsOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        Task { @MainActor in
            store.updateCanvasViewportCenter(
                currentViewportCenter(in: scrollView),
                markDirty: false
            )
        }
    }

    private func handleSpacePanModeChanged(_ isEnabled: Bool) {
        let textEditingActive = (NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder) is NSTextView
        guard !textEditingActive || !isEnabled else { return }

        isSpacePanMode = isEnabled
        if !isEnabled {
            canvasPanStartBoundsOrigin = nil
        }
        updateCanvasCursor()
    }

    private func updateCanvasPan(withGlobal value: DragGesture.Value) {
        guard let scrollView = canvasScrollView else { return }
        if canvasPanStartBoundsOrigin == nil {
            canvasPanStartBoundsOrigin = CGPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: scrollView.contentView.bounds.origin.y
            )
            NSCursor.closedHand.set()
        }
        guard let panStart = canvasPanStartBoundsOrigin else { return }

        let contentSize = CGSize(width: canvasSize.width * zoom, height: canvasSize.height * zoom)
        let visibleSize = scrollView.contentView.bounds.size
        let targetOrigin = CGPoint(
            x: max(0, min(panStart.x - value.translation.width, max(0, contentSize.width - visibleSize.width))),
            y: max(0, min(panStart.y - value.translation.height, max(0, contentSize.height - visibleSize.height)))
        )
        scrollView.contentView.setBoundsOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        Task { @MainActor in
            store.updateCanvasViewportCenter(
                currentViewportCenter(in: scrollView),
                markDirty: true
            )
        }
    }

    private func finishCanvasPan() {
        canvasPanStartBoundsOrigin = nil
        updateCanvasCursor()
    }

    private func updateCanvasCursor() {
        if canvasPanStartBoundsOrigin != nil {
            NSCursor.closedHand.set()
        } else if isSpacePanMode {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func currentViewportCenter() -> CGPoint {
        guard viewportSize != .zero else {
            return CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        }

        return CGPoint(
            x: (viewportSize.width * 0.5 - canvasFrameInViewport.minX) / max(zoom, 0.001),
            y: (viewportSize.height * 0.5 - canvasFrameInViewport.minY) / max(zoom, 0.001)
        )
    }

    private func currentViewportCenter(in scrollView: NSScrollView) -> CGPoint {
        let visibleOrigin = scrollView.contentView.bounds.origin
        let visibleSize = scrollView.contentView.bounds.size
        return CGPoint(
            x: (visibleOrigin.x + visibleSize.width * 0.5) / max(zoom, 0.001),
            y: (visibleOrigin.y + visibleSize.height * 0.5) / max(zoom, 0.001)
        )
    }

    private func graphContentCenter() -> CGPoint? {
        guard let bounds = graphContentBounds() else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func graphContentBounds() -> CGRect? {
        let visibleNodes = document.nodes.filter { store.isNodeVisibleOnCanvas($0.id) }
        guard visibleNodes.isEmpty == false else { return nil }

        let minX = visibleNodes.map(\.position.x).min() ?? 0
        let minY = visibleNodes.map(\.position.y).min() ?? 0
        let maxX = visibleNodes.map { $0.position.x + GraphCanvasLayout.nodeWidth(for: $0) }.max() ?? minX
        let maxY = visibleNodes.map { $0.position.y + GraphCanvasLayout.nodeHeight(for: $0) }.max() ?? minY

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func isReasonableViewportCenter(_ center: CGPoint) -> Bool {
        guard let bounds = graphContentBounds() else { return true }

        let paddingX = max(bounds.width * 0.75, viewportSize.width / max(zoom, 0.001), 240)
        let paddingY = max(bounds.height * 0.75, viewportSize.height / max(zoom, 0.001), 240)
        let expandedBounds = bounds.insetBy(dx: -paddingX, dy: -paddingY)
        return expandedBounds.contains(center)
    }

    private func targetCanvasPosition(_ point: CGPoint) -> CGPoint {
        guard store.snapToGridEnabled else {
            return CGPoint(x: max(24, point.x), y: max(24, point.y))
        }
        return snappedCanvasPosition(point)
    }

    private func snappedCanvasPosition(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(24, (point.x / GraphCanvasLayout.gridSpacing).rounded() * GraphCanvasLayout.gridSpacing),
            y: max(24, (point.y / GraphCanvasLayout.gridSpacing).rounded() * GraphCanvasLayout.gridSpacing)
        )
    }

    private func nodeFrame(for node: GraphNode) -> CGRect {
        CGRect(
            origin: node.position,
            size: CGSize(width: GraphCanvasLayout.nodeWidth(for: node), height: GraphCanvasLayout.nodeHeight(for: node))
        )
    }
}

private struct ScrollViewAccessor: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void
    let onScroll: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onResolve = onResolve
        view.onScroll = onScroll
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView {
                view.attach(to: scrollView)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let observerView = nsView as? ObserverView else { return }
        observerView.onResolve = onResolve
        observerView.onScroll = onScroll
        DispatchQueue.main.async {
            if let scrollView = observerView.enclosingScrollView {
                observerView.attach(to: scrollView)
            }
        }
    }

    final class ObserverView: NSView {
        var onResolve: ((NSScrollView) -> Void)?
        var onScroll: ((NSScrollView) -> Void)?
        private weak var observedScrollView: NSScrollView?

        deinit {
            detach()
        }

        func attach(to scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else {
                onResolve?(scrollView)
                return
            }
            detach()
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            onResolve?(scrollView)
            onScroll?(scrollView)
        }

        private func detach() {
            if let observedScrollView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedScrollView.contentView
                )
            }
            observedScrollView = nil
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let scrollView = observedScrollView else { return }
            onScroll?(scrollView)
        }
    }
}

private struct ConnectionCreateNodeMenu: View {
    let options: [ConnectionCreateNodeOption]
    let onSelect: (ConnectionCreateNodeOption) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Node")
                        .font(.headline)
                    Text("Connect cable to...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(options) { option in
                        Button {
                            onSelect(option)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: iconName(for: option.kind))
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 22)
                                    .foregroundStyle(.cyan)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(option.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 276)
        }
        .padding(12)
        .frame(width: 286, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 18, y: 10)
    }

    private func iconName(for kind: ConnectionCreateNodeKind) -> String {
        switch kind {
        case .renderWindow:
            return "display"
        case .layers:
            return "square.3.layers.3d"
        case .mix, .feedback, .transform, .blur, .bloom, .underwater, .metalFragment:
            return "sparkles"
        case .scene3DRender, .scene3DMaterial, .scene3DLight, .scene3DTransform, .scene3DTile, .scene3DPrimitive, .scene3DText, .scene3DModel:
            return "cube"
        case .monitor:
            return "waveform.path.ecg"
        case .trackball:
            return "rotate.3d"
        case .math, .mapRange, .interpolator, .scalarSmooth:
            return "function"
        case .pointSplit, .point3Split, .point4Split:
            return "point.3.connected.trianglepath.dotted"
        case .colorSplit:
            return "eyedropper"
        case .oscGet4, .oscGetArray:
            return "network"
        }
    }
}

private struct CanvasKeyboardMonitor: NSViewRepresentable {
    let onSpaceChanged: (Bool) -> Void
    let onEscape: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onSpaceChanged: onSpaceChanged, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSpaceChanged = onSpaceChanged
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onSpaceChanged: (Bool) -> Void
        var onEscape: () -> Bool
        private var keyDownMonitor: Any?
        private var keyUpMonitor: Any?

        init(onSpaceChanged: @escaping (Bool) -> Void, onEscape: @escaping () -> Bool) {
            self.onSpaceChanged = onSpaceChanged
            self.onEscape = onEscape
        }

        func start() {
            guard keyDownMonitor == nil, keyUpMonitor == nil else { return }
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {
                    return self?.onEscape() == true ? nil : event
                }
                guard event.keyCode == 49 else { return event }
                let textEditingActive = (NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder) is NSTextView
                guard !textEditingActive else { return event }
                self?.onSpaceChanged(true)
                return nil
            }
            keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard event.keyCode == 49 else { return event }
                let textEditingActive = (NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder) is NSTextView
                guard !textEditingActive else { return event }
                self?.onSpaceChanged(false)
                return nil
            }
        }

        func stop() {
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
                self.keyDownMonitor = nil
            }
            if let keyUpMonitor {
                NSEvent.removeMonitor(keyUpMonitor)
                self.keyUpMonitor = nil
            }
        }

        deinit {
            stop()
        }
    }
}

private struct InlinePortTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let isFocused: Bool
    let font: NSFont
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onCommit: () -> Void
    let onAdvance: () -> Void
    let onRetreat: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = InlinePortNSTextField(frame: .zero)
        textField.isEditable = true
        textField.isSelectable = true
        textField.isEnabled = true
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.backgroundColor = .controlBackgroundColor
        textField.delegate = context.coordinator
        textField.commandDelegate = context.coordinator
        textField.font = font
        textField.placeholderString = placeholder
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        nsView.font = font

        if isFocused, context.coordinator.didRequestFocus == false {
            context.coordinator.didRequestFocus = true
            DispatchQueue.main.async {
                guard nsView.window != nil else { return }
                nsView.window?.makeFirstResponder(nsView)
                nsView.selectText(nil)
                nsView.currentEditor()?.selectedRange = NSRange(location: 0, length: nsView.stringValue.count)
            }
        } else if !isFocused {
            context.coordinator.didRequestFocus = false
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, InlinePortNSTextFieldDelegate {
        var parent: InlinePortTextField
        var didRequestFocus = false

        init(parent: InlinePortTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocus()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onBlur()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                parent.onAdvance()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onRetreat()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            default:
                return false
            }
        }

        func inlineTextFieldDidCommit() {
            parent.onCommit()
        }

        func inlineTextFieldAdvance() {
            parent.onAdvance()
        }

        func inlineTextFieldRetreat() {
            parent.onRetreat()
        }
    }
}

private protocol InlinePortNSTextFieldDelegate: AnyObject {
    func inlineTextFieldDidCommit()
    func inlineTextFieldAdvance()
    func inlineTextFieldRetreat()
}

private final class InlinePortNSTextField: NSTextField {
    weak var commandDelegate: InlinePortNSTextFieldDelegate?

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        if let movement = notification.userInfo?["NSTextMovement"] as? Int,
           movement == NSReturnTextMovement {
            commandDelegate?.inlineTextFieldDidCommit()
        }
    }

}

private struct GraphFileDropOverlay: NSViewRepresentable {
    let onDrop: ([URL], CGPoint) -> Bool

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.onDrop = onDrop
    }

    final class DropView: NSView {
        var onDrop: (([URL], CGPoint) -> Bool)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerForDraggedTypes([.fileURL])
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            return droppedURLs(from: sender).isEmpty ? [] : .copy
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            droppedURLs(from: sender).isEmpty == false
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = droppedURLs(from: sender)
            guard urls.isEmpty == false else { return false }
            if enclosingScrollView != nil {
                let viewportPoint = convert(sender.draggingLocation, from: nil)
                return onDrop?(urls, viewportPoint) ?? false
            }

            let point = convert(sender.draggingLocation, from: nil)
            let flippedPoint = CGPoint(x: point.x, y: bounds.height - point.y)
            return onDrop?(urls, flippedPoint) ?? false
        }

        private func droppedURLs(from sender: NSDraggingInfo) -> [URL] {
            let classes: [AnyClass] = [NSURL.self]
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            return (sender.draggingPasteboard.readObjects(forClasses: classes, options: options) as? [URL]) ?? []
        }
    }
}

private struct GridBackdrop: View {
    let backgroundColor: Color
    let backgroundOpacity: Double
    let size: CGSize

    var body: some View {
        ZStack {
            backgroundColor.opacity(backgroundOpacity)

            Canvas { context, _ in
                let spacing = GraphCanvasLayout.gridSpacing
                for x in stride(from: 0, through: size.width, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
                }

                for y in stride(from: 0, through: size.height, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
                }
            }
        }
    }
}

private struct CanvasZoomControls: View {
    let zoomLabel: Int
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let reset: () -> Void
    let canCreateMacro: Bool
    let createMacro: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Macro", action: createMacro)
                .disabled(!canCreateMacro)
            Button("-", action: zoomOut)
            Text("\(zoomLabel)%")
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 44)
            Button("+", action: zoomIn)
            Button("Reset", action: reset)
        }
        .padding(10)
        .background(.black.opacity(0.45))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.12))
        }
    }
}

private struct MacroEditingOverlay: View {
    let title: String
    let exitMacro: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Editing \(title)")
                .font(.headline)
                .foregroundStyle(.white)

            Button("Exit Macro") {
                exitMacro()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }
}

private struct NodeCardView: View {
    private let nodeCoordinateSpace = "node-card"

    @ObservedObject var store: GraphStore
    let node: GraphNode
    let isSelected: Bool
    let isSpacePanMode: Bool
    let highlightedInputPortID: GraphPort.ID?
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onOpenEditor: () -> Void
    let onOpenMacro: () -> Void
    let onOpenIterator: () -> Void
    let onNodeMoved: (DragGesture.Value) -> Void
    let onNodeMoveEnded: () -> Void
    let onInputDragStart: (GraphPort.ID) -> Void
    let onOutputDragStart: (GraphPort.ID) -> Void
    let onOutputDragChange: (DragGesture.Value) -> Void
    let onOutputDragEnd: () -> Void
    let onInputHoverChanged: (GraphPort.ID, Bool) -> Void
    let showsInlineInspector: Bool
    @State private var portRowCenters: [GraphPort.ID: CGFloat] = [:]
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var editingInputPortID: GraphPort.ID?
    @State private var inputValueDraft = ""
    @State private var editingMacroPortID: GraphPort.ID?
    @State private var macroPortNameDraft = ""
    @FocusState private var isTitleFieldFocused: Bool
    @FocusState private var focusedInputPortID: GraphPort.ID?
    @FocusState private var focusedMacroPortID: GraphPort.ID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                titleView

                if !GraphCanvasLayout.usesUtilityLayout(for: node) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                headerActions

                portRows

                if case .monitor = node.kind {
                    Divider()
                        .overlay(.white.opacity(0.12))
                    CompactMonitorReadout(store: store, nodeID: node.id)
                }

                if case .note = node.kind {
                    Divider()
                        .overlay(.white.opacity(0.12))
                    CompactNoteReadout(store: store, nodeID: node.id)
                }

                if case .renderOutput = node.kind {
                    Divider()
                        .overlay(.white.opacity(0.12))
                    CompactRenderNodePreview(store: store, renderNodeID: node.id)
                }

                if showsInlineInspector {
                    Divider()
                        .overlay(.white.opacity(0.12))
                    NodeInspectorControls(store: store, node: node)
                }
            }
            .padding(GraphCanvasLayout.cardPadding)
            .frame(width: GraphCanvasLayout.nodeWidth(for: node), alignment: .leading)
            .focusSection()
            .background(background)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(accent)
                    .frame(width: 6)
                    .padding(.vertical, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(isSelected ? .white.opacity(0.65) : .white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: accent.opacity(isSelected ? 0.45 : 0.25), radius: isSelected ? 28 : 18, y: 8)
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.18), value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture(perform: onSelect)
            .onTapGesture(count: 2) {
                onSelect()
                guard !isEditingTitle else { return }
                switch node.kind {
                case .metalFragment:
                    onOpenEditor()
                case .macro:
                    onOpenMacro()
                case .iterator:
                    onOpenIterator()
                default:
                    break
                }
            }
            .gesture(isEditingTitle || isSpacePanMode ? nil : DragGesture(coordinateSpace: .named("canvas"))
                .onChanged(onNodeMoved)
                .onEnded { _ in
                    onNodeMoveEnded()
                })

            portOverlay
        }
        .coordinateSpace(name: nodeCoordinateSpace)
        .onPreferenceChange(PortRowCenterPreferenceKey.self) { portRowCenters = $0 }
        .onAppear {
            titleDraft = node.title
        }
        .onChange(of: node.title) { _, newValue in
            if !isEditingTitle {
                titleDraft = newValue
            }
        }
        .onChange(of: isTitleFieldFocused) { _, isFocused in
            if isEditingTitle && !isFocused {
                commitTitleEdit()
            }
        }
            .onChange(of: focusedInputPortID) { _, focusedPortID in
                if let editingInputPortID, focusedPortID != editingInputPortID {
                    commitInputValueEditIfNeeded(for: editingInputPortID)
                }
            }
        .onChange(of: focusedMacroPortID) { _, focusedPortID in
            if let editingMacroPortID, focusedPortID != editingMacroPortID {
                commitMacroPortEditIfNeeded(for: editingMacroPortID)
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("Node Name", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .focused($isTitleFieldFocused)
                .onSubmit {
                    commitTitleEdit()
                }
                .onAppear {
                    DispatchQueue.main.async {
                        isTitleFieldFocused = true
                    }
                }
        } else {
            Text(node.title)
                .font(.headline)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onSelect()
                    titleDraft = node.title
                    isEditingTitle = true
                }
        }
    }

    private func commitTitleEdit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.renameNode(node.id, to: trimmed)
        } else {
            titleDraft = node.title
        }
        isEditingTitle = false
        isTitleFieldFocused = false
    }

    private func beginInputValueEdit(for inputPortID: GraphPort.ID) {
        if let uniform = store.editableFloatUniform(forInputPortID: inputPortID),
           case .float(let currentValue) = uniform.defaultValue {
            editingInputPortID = inputPortID
            inputValueDraft = String(format: "%.2f", currentValue)
            focusedInputPortID = inputPortID
            return
        }

        if let currentValue = store.editableScalarFallbackValue(forInputPortID: inputPortID) {
            editingInputPortID = inputPortID
            inputValueDraft = String(format: "%.2f", currentValue)
            focusedInputPortID = inputPortID
            return
        }

        if let currentValue = store.editableStringFallbackValue(forInputPortID: inputPortID) {
            editingInputPortID = inputPortID
            inputValueDraft = currentValue
            focusedInputPortID = inputPortID
            return
        }

        if store.editableColorFallbackValue(forInputPortID: inputPortID) != nil {
            editingInputPortID = inputPortID
            focusedInputPortID = nil
            return
        }

        if store.editableBoolUniform(forInputPortID: inputPortID) != nil {
            editingInputPortID = inputPortID
            focusedInputPortID = nil
        }
    }

    private func commitInputValueEditIfNeeded(for inputPortID: GraphPort.ID) {
        if let uniform = store.editableFloatUniform(forInputPortID: inputPortID),
           case .float(let currentValue) = uniform.defaultValue {
            commitInputValueEdit(for: inputPortID, fallbackValue: currentValue)
            return
        }

        if let currentValue = store.editableScalarFallbackValue(forInputPortID: inputPortID) {
            commitInputValueEdit(for: inputPortID, fallbackValue: currentValue)
            return
        }

        if let currentValue = store.editableStringFallbackValue(forInputPortID: inputPortID) {
            store.updateStringFallbackValue(forInputPortID: inputPortID, value: inputValueDraft.isEmpty ? currentValue : inputValueDraft)
            editingInputPortID = nil
            focusedInputPortID = nil
            inputValueDraft = ""
            return
        }

        if store.editableColorFallbackValue(forInputPortID: inputPortID) != nil {
            editingInputPortID = nil
            focusedInputPortID = nil
            inputValueDraft = ""
            return
        }

        if store.editableBoolUniform(forInputPortID: inputPortID) != nil {
            editingInputPortID = nil
            focusedInputPortID = nil
            inputValueDraft = ""
            return
        }

        editingInputPortID = nil
        inputValueDraft = ""
    }

    private func commitInputValueEdit(for inputPortID: GraphPort.ID, fallbackValue: Double) {
        if let editingInputPortID, editingInputPortID != inputPortID {
            return
        }
        let parsedValue = Double(inputValueDraft) ?? fallbackValue
        if store.editableFloatUniform(forInputPortID: inputPortID) != nil {
            store.updateFloatUniform(forInputPortID: inputPortID, value: parsedValue)
        } else {
            store.updateScalarFallbackValue(forInputPortID: inputPortID, value: parsedValue)
        }
        editingInputPortID = nil
        focusedInputPortID = nil
        inputValueDraft = ""
    }

    private func commitStringInputValueEdit(for inputPortID: GraphPort.ID, fallbackValue: String) {
        if let editingInputPortID, editingInputPortID != inputPortID {
            return
        }
        store.updateStringFallbackValue(forInputPortID: inputPortID, value: inputValueDraft.isEmpty ? fallbackValue : inputValueDraft)
        editingInputPortID = nil
        focusedInputPortID = nil
        inputValueDraft = ""
    }

    private func prepareForDeletion() {
        if let editingInputPortID {
            commitInputValueEditIfNeeded(for: editingInputPortID)
        }
        if let editingMacroPortID {
            commitMacroPortEditIfNeeded(for: editingMacroPortID)
        }
        if isEditingTitle {
            commitTitleEdit()
        }
        focusedInputPortID = nil
        focusedMacroPortID = nil
        isTitleFieldFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func editableInlinePortIDs() -> [GraphPort.ID] {
        visibleInputPorts.compactMap { port in
            if store.editableFloatUniform(forInputPortID: port.id) != nil { return port.id }
            if store.editableScalarFallbackValue(forInputPortID: port.id) != nil { return port.id }
            if store.editableStringFallbackValue(forInputPortID: port.id) != nil { return port.id }
            if store.editableColorFallbackValue(forInputPortID: port.id) != nil { return port.id }
            if store.editableBoolUniform(forInputPortID: port.id) != nil { return port.id }
            return nil
        }
    }

    private func advanceInlineEdit(from inputPortID: GraphPort.ID, reverse: Bool = false) {
        let editablePortIDs = editableInlinePortIDs()
        guard let currentIndex = editablePortIDs.firstIndex(of: inputPortID) else {
            commitInputValueEditIfNeeded(for: inputPortID)
            return
        }

        let nextIndex = reverse ? currentIndex - 1 : currentIndex + 1
        commitInputValueEditIfNeeded(for: inputPortID)

        guard editablePortIDs.indices.contains(nextIndex) else { return }
        beginInputValueEdit(for: editablePortIDs[nextIndex])
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 8) {
            if case .metalFragment = node.kind {
                Button("Code") {
                    onOpenEditor()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green.opacity(0.85))
            }

            Spacer()

            switch node.kind {
            case .uniform, .time, .mouse, .keyboard, .pointSplit, .pointCombine, .point3Split, .point3Combine, .point4Split, .point4Combine, .pointInterpolate, .point3Interpolate, .point4Interpolate, .pointScale, .point3Scale, .point4Scale, .colorSplit, .scroll, .handTracker, .pinch, .scrollGesture, .zoomGesture, .trackball, .depthEstimate, .math, .expression, .clamp, .mapRange, .logic, .compare, .random, .pulse, .fireOnLoad, .counter, .toggle, .delay, .timer, .scalarVariable, .stringVariable, .colorVariable, .scalarArrayVariable, .stringArrayVariable, .colorArrayVariable, .imageArrayVariable, .string, .stringFormat, .stringCompare, .stringSplit, .color, .hslColor, .scalarArray, .stringArray, .colorArray, .imageArray, .scalarArrayIndex, .stringArrayIndex, .colorArrayIndex, .imageArrayIndex, .arrayCount, .textImage, .audio, .beatDetect, .slider, .sliderStyle, .button, .buttonStyle, .polar, .hitZone, .rectHit, .screenSize, .screenBounds, .renderBounds, .renderWindow, .gridLayout, .scalarMultiplexor, .stringMultiplexor, .colorMultiplexor, .imageMultiplexor, .macro, .iterator, .iteratorVariables, .midiOut, .midiCC, .midiCCInput, .midiNoteInput, .oscInput, .oscOutput, .oscReceive, .oscSend, .oscGet4, .oscGetArray, .oscMake4, .oscMakeArray, .oscBundle, .note, .transform, .billboard, .line, .scene3DTransform, .scene3DTile, .scene3DRender, .scene3DLight, .scene3DMaterial, .scene3DPrimitive, .scene3DText, .scene3DModel, .scene3DGaussianSplat, .scene3DParticle, .select, .scalarSwitch, .stringSwitch, .colorSwitch, .circle, .clear, .image, .webView, .aiImage, .videoPlayer, .video, .coreImage, .blur, .bloom, .hueRotate, .posterize, .levels, .glow, .underwater, .feedback, .reactionDiffusion, .transition, .scale, .interpolator, .hold, .scalarSmooth, .trail, .monitor, .layers:
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.85))
            case .mix:
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.85))
            case .metalFragment:
                if !store.canDeleteNode(node.id) {
                    EmptyView()
                } else {
                    Button(role: .destructive) {
                        prepareForDeletion()
                        DispatchQueue.main.async {
                            onDelete()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.85))
                }
            case .renderOutput:
                if !store.canDeleteNode(node.id) {
                    EmptyView()
                } else {
                    Button(role: .destructive) {
                        prepareForDeletion()
                        DispatchQueue.main.async {
                            onDelete()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var portRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(portLabels.enumerated()), id: \.offset) { index, row in
                let visibleInputs = visibleInputPorts
                let inputPort = visibleInputs.indices.contains(index) ? visibleInputs[index] : nil
                let outputPort = node.outputPorts.indices.contains(index) ? node.outputPorts[index] : nil
                HStack {
                    inputLabel(for: inputPort, fallbackName: row.input)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    outputLabel(for: outputPort, fallbackName: row.output)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let inputPort, case .macro = node.kind {
                        beginMacroPortEdit(for: inputPort)
                    } else if let inputPort, case .iterator = node.kind {
                        beginMacroPortEdit(for: inputPort)
                    } else if let inputPort {
                        beginInputValueEdit(for: inputPort.id)
                    } else if let outputPort, case .macro = node.kind {
                        beginMacroPortEdit(for: outputPort)
                    } else if let outputPort, case .iterator = node.kind {
                        beginMacroPortEdit(for: outputPort)
                    }
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PortRowCenterPreferenceKey.self,
                            value: rowCenterPreferences(
                                for: row,
                                midY: proxy.frame(in: .named(nodeCoordinateSpace)).midY
                            )
                        )
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func inputLabel(for inputPort: GraphPort?, fallbackName: String) -> some View {
        if let inputPort {
            if editingMacroPortID == inputPort.id, case .macro = node.kind {
                TextField("Port Name", text: $macroPortNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .frame(width: 112)
                    .focused($focusedMacroPortID, equals: inputPort.id)
                    .onSubmit {
                        commitMacroPortEdit(for: inputPort)
                    }
                    .onAppear {
                        if macroPortNameDraft.isEmpty {
                            macroPortNameDraft = inputPort.name
                        }
                        DispatchQueue.main.async {
                            focusedMacroPortID = inputPort.id
                        }
                    }
            } else if editingMacroPortID == inputPort.id, case .iterator = node.kind {
                TextField("Port Name", text: $macroPortNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .frame(width: 112)
                    .focused($focusedMacroPortID, equals: inputPort.id)
                    .onSubmit {
                        commitMacroPortEdit(for: inputPort)
                    }
                    .onAppear {
                        if macroPortNameDraft.isEmpty {
                            macroPortNameDraft = inputPort.name
                        }
                        DispatchQueue.main.async {
                            focusedMacroPortID = inputPort.id
                        }
                    }
            } else if editingInputPortID == inputPort.id,
                      let fallbackValue = store.editableFloatUniform(forInputPortID: inputPort.id).flatMap({ uniform -> Double? in
                          guard case .float(let currentValue) = uniform.defaultValue else { return nil }
                          return currentValue
                      }) ?? store.editableScalarFallbackValue(forInputPortID: inputPort.id) {
                InlinePortTextField(
                    placeholder: inputPort.name,
                    text: $inputValueDraft,
                    isFocused: focusedInputPortID == inputPort.id,
                    font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular),
                    onFocus: {
                        focusedInputPortID = inputPort.id
                    },
                    onBlur: {
                        commitInputValueEdit(for: inputPort.id, fallbackValue: fallbackValue)
                    },
                    onCommit: {
                        commitInputValueEdit(for: inputPort.id, fallbackValue: fallbackValue)
                    },
                    onAdvance: {
                        advanceInlineEdit(from: inputPort.id)
                    },
                    onRetreat: {
                        advanceInlineEdit(from: inputPort.id, reverse: true)
                    }
                )
                    .frame(width: 84)
                    .onAppear {
                        if inputValueDraft.isEmpty {
                            inputValueDraft = String(format: "%.2f", fallbackValue)
                        }
                        DispatchQueue.main.async {
                            focusedInputPortID = inputPort.id
                        }
                    }
            } else if editingInputPortID == inputPort.id,
                      let fallbackValue = store.editableStringFallbackValue(forInputPortID: inputPort.id) {
                InlinePortTextField(
                    placeholder: inputPort.name,
                    text: $inputValueDraft,
                    isFocused: focusedInputPortID == inputPort.id,
                    font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize),
                    onFocus: {
                        focusedInputPortID = inputPort.id
                    },
                    onBlur: {
                        commitStringInputValueEdit(for: inputPort.id, fallbackValue: fallbackValue)
                    },
                    onCommit: {
                        commitStringInputValueEdit(for: inputPort.id, fallbackValue: fallbackValue)
                    },
                    onAdvance: {
                        advanceInlineEdit(from: inputPort.id)
                    },
                    onRetreat: {
                        advanceInlineEdit(from: inputPort.id, reverse: true)
                    }
                )
                    .frame(width: 120)
                    .onAppear {
                        if inputValueDraft.isEmpty {
                            inputValueDraft = fallbackValue
                        }
                        DispatchQueue.main.async {
                            focusedInputPortID = inputPort.id
                        }
                    }
            } else if editingInputPortID == inputPort.id,
                      let fallbackValue = store.editableColorFallbackValue(forInputPortID: inputPort.id) {
                HStack(spacing: 6) {
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: {
                                Color(
                                    .displayP3,
                                    red: fallbackValue.red,
                                    green: fallbackValue.green,
                                    blue: fallbackValue.blue,
                                    opacity: fallbackValue.alpha
                                )
                            },
                            set: { newColor in
                                let converted = rgbaComponents(from: newColor)
                                store.updateColorFallbackValue(
                                    forInputPortID: inputPort.id,
                                    value: ArrayColorValue(
                                        red: converted.red,
                                        green: converted.green,
                                        blue: converted.blue,
                                        alpha: converted.alpha
                                    )
                                )
                            }
                        ),
                        supportsOpacity: true
                    )
                    .labelsHidden()
                    .frame(width: 30, height: 22)

                    Button {
                        editingInputPortID = nil
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.82))
                }
            } else if editingInputPortID == inputPort.id,
                      let uniform = store.editableBoolUniform(forInputPortID: inputPort.id),
                      case .bool(let currentValue) = uniform.defaultValue {
                HStack(spacing: 6) {
                    Button {
                        store.updateBoolUniform(forInputPortID: inputPort.id, value: !currentValue)
                    } label: {
                        Text(currentValue ? "On" : "Off")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(currentValue ? Color.green.opacity(0.8) : Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        editingInputPortID = nil
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.82))
                }
            } else {
                HStack(spacing: 6) {
                    if let colorValue = store.editableColorFallbackValue(forInputPortID: inputPort.id) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(.displayP3, red: colorValue.red, green: colorValue.green, blue: colorValue.blue, opacity: colorValue.alpha))
                            .frame(width: 12, height: 12)
                    }
                    if let uniform = store.editableBoolUniform(forInputPortID: inputPort.id),
                       case .bool(let boolValue) = uniform.defaultValue {
                        Image(systemName: boolValue ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundStyle(boolValue ? .green : .white.opacity(0.5))
                    }
                    Text(fallbackName)
                        .font(.caption2)
                }
                    .foregroundStyle((store.editableFloatUniform(forInputPortID: inputPort.id) == nil && store.editableScalarFallbackValue(forInputPortID: inputPort.id) == nil && store.editableStringFallbackValue(forInputPortID: inputPort.id) == nil && store.editableColorFallbackValue(forInputPortID: inputPort.id) == nil && store.editableBoolUniform(forInputPortID: inputPort.id) == nil) ? .white.opacity(0.6) : .white.opacity(0.82))
                    .contextMenu {
                        if case .macro = node.kind {
                            Button("Unpublish Port") {
                                store.updateMacroInputPort(inputPort.id, on: node.id, isPublished: false)
                            }
                        } else if case .iterator = node.kind {
                            Button("Unpublish Port") {
                                store.updateIteratorInputPort(inputPort.id, on: node.id, isPublished: false)
                            }
                        } else if store.editingMacroNodeID != nil, store.isPortPublishedOnEditingContainer(inputPort) {
                            Button("Unpublish from Macro") {
                                if let macroNodeID = store.editingMacroNodeID {
                                    store.updateMacroInputPortForInternalPort(inputPort.id, on: macroNodeID, isPublished: false)
                                }
                            }
                        } else if store.editingIteratorNodeID != nil, store.isPortPublishedOnEditingContainer(inputPort) {
                            Button("Unpublish from Iterator") {
                                if let iteratorNodeID = store.editingIteratorNodeID {
                                    store.updateIteratorInputPortForInternalPort(inputPort.id, on: iteratorNodeID, isPublished: false)
                                }
                            }
                        } else if store.editingMacroNodeID != nil, store.canPublishPort(inputPort) {
                            Button("Publish to Macro") {
                                store.publishPortFromEditingMacro(inputPort)
                            }
                        } else if store.editingIteratorNodeID != nil, store.canPublishPort(inputPort) {
                            Button("Publish to Iterator") {
                                store.publishPortFromEditingMacro(inputPort)
                            }
                        }
                        if store.canCreateVariableNode(forInputPortID: inputPort.id) {
                            Button("Make Variable Node") {
                                store.makeVariableNode(forInputPortID: inputPort.id)
                            }
                        }
                    }
            }
        } else {
            Text(fallbackName)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private func outputLabel(for outputPort: GraphPort?, fallbackName: String) -> some View {
        if let outputPort {
            if editingMacroPortID == outputPort.id, case .macro = node.kind {
                TextField("Port Name", text: $macroPortNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .frame(width: 112)
                    .focused($focusedMacroPortID, equals: outputPort.id)
                    .onSubmit {
                        commitMacroPortEdit(for: outputPort)
                    }
                    .onAppear {
                        if macroPortNameDraft.isEmpty {
                            macroPortNameDraft = outputPort.name
                        }
                        DispatchQueue.main.async {
                            focusedMacroPortID = outputPort.id
                        }
                    }
            } else if editingMacroPortID == outputPort.id, case .iterator = node.kind {
                TextField("Port Name", text: $macroPortNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .frame(width: 112)
                    .focused($focusedMacroPortID, equals: outputPort.id)
                    .onSubmit {
                        commitMacroPortEdit(for: outputPort)
                    }
                    .onAppear {
                        if macroPortNameDraft.isEmpty {
                            macroPortNameDraft = outputPort.name
                        }
                        DispatchQueue.main.async {
                            focusedMacroPortID = outputPort.id
                        }
                    }
            } else {
                Text(fallbackName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .contextMenu {
                        if case .macro = node.kind {
                            Button("Unpublish Port") {
                                store.updateMacroOutputPort(outputPort.id, on: node.id, isPublished: false)
                            }
                        } else if case .iterator = node.kind {
                            Button("Unpublish Port") {
                                store.updateIteratorOutputPort(outputPort.id, on: node.id, isPublished: false)
                            }
                        } else if store.editingMacroNodeID != nil, store.isPortPublishedOnEditingContainer(outputPort) {
                            Button("Unpublish from Macro") {
                                if let macroNodeID = store.editingMacroNodeID {
                                    store.updateMacroOutputPortForInternalPort(outputPort.id, on: macroNodeID, isPublished: false)
                                }
                            }
                        } else if store.editingIteratorNodeID != nil, store.isPortPublishedOnEditingContainer(outputPort) {
                            Button("Unpublish from Iterator") {
                                if let iteratorNodeID = store.editingIteratorNodeID {
                                    store.updateIteratorOutputPortForInternalPort(outputPort.id, on: iteratorNodeID, isPublished: false)
                                }
                            }
                        } else if store.editingMacroNodeID != nil, store.canPublishPort(outputPort) {
                            Button("Publish to Macro") {
                                store.publishPortFromEditingMacro(outputPort)
                            }
                        } else if store.editingIteratorNodeID != nil, store.canPublishPort(outputPort) {
                            Button("Publish to Iterator") {
                                store.publishPortFromEditingMacro(outputPort)
                            }
                        }
                    }
            }
        } else {
            Text(fallbackName)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func beginMacroPortEdit(for port: GraphPort) {
        switch node.kind {
        case .macro, .iterator:
            break
        default:
            return
        }
        editingMacroPortID = port.id
        macroPortNameDraft = port.name
        focusedMacroPortID = port.id
    }

    private func commitMacroPortEditIfNeeded(for portID: GraphPort.ID) {
        guard let port = node.allPorts.first(where: { $0.id == portID }) else {
            editingMacroPortID = nil
            macroPortNameDraft = ""
            return
        }
        commitMacroPortEdit(for: port)
    }

    private func commitMacroPortEdit(for port: GraphPort) {
        let trimmed = macroPortNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingMacroPortID = nil
            focusedMacroPortID = nil
            macroPortNameDraft = ""
            return
        }
        switch port.direction {
        case .input:
            switch node.kind {
            case .macro:
                store.updateMacroInputPort(port.id, on: node.id, name: trimmed)
            case .iterator:
                store.updateIteratorInputPort(port.id, on: node.id, name: trimmed)
            default:
                break
            }
        case .output:
            switch node.kind {
            case .macro:
                store.updateMacroOutputPort(port.id, on: node.id, name: trimmed)
            case .iterator:
                store.updateIteratorOutputPort(port.id, on: node.id, name: trimmed)
            default:
                break
            }
        }
        editingMacroPortID = nil
        focusedMacroPortID = nil
        macroPortNameDraft = ""
    }

    private var portOverlay: some View {
        ZStack {
            ForEach(visibleInputPorts) { port in
                GraphPortView(
                    port: port,
                    accent: accent,
                    isHighlighted: highlightedInputPortID == port.id,
                    hoverChanged: { onInputHoverChanged(port.id, $0) }
                )
                .onTapGesture(count: 2) {
                    beginInputValueEdit(for: port.id)
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                        .onChanged { value in
                            if value.translation == .zero {
                                onInputDragStart(port.id)
                            }
                            onOutputDragChange(value)
                        }
                        .onEnded { _ in
                            onOutputDragEnd()
                        }
                )
                .position(
                    x: 0,
                    y: portCenterY(for: port, in: visibleInputPorts)
                )
            }

            ForEach(node.outputPorts) { port in
                GraphPortView(
                    port: port,
                    accent: accent,
                    isHighlighted: false,
                    hoverChanged: { _ in }
                )
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                        .onChanged { value in
                            if value.translation == .zero {
                                onOutputDragStart(port.id)
                            }
                            onOutputDragChange(value)
                        }
                        .onEnded { _ in
                            onOutputDragEnd()
                        }
                )
                .position(
                    x: GraphCanvasLayout.nodeWidth(for: node),
                    y: portCenterY(for: port, in: node.outputPorts)
                )
            }
        }
    }

    private var portLabels: [(input: String, output: String)] {
        let inputNames = visibleInputPorts.map(\.name)
        let outputNames = node.outputPorts.map(\.name)
        let rows = max(max(inputNames.count, outputNames.count), 1)
        return (0..<rows).map { index in
            (
                input: inputNames.indices.contains(index) ? inputNames[index] : "",
                output: outputNames.indices.contains(index) ? outputNames[index] : ""
            )
        }
    }

    private var visibleInputPorts: [GraphPort] {
        GraphCanvasLayout.visibleInputPorts(for: node)
    }

    private func index(of port: GraphPort, in ports: [GraphPort]) -> Int {
        ports.firstIndex(where: { $0.id == port.id }) ?? 0
    }

    private func portCenterY(for port: GraphPort, in ports: [GraphPort]) -> CGFloat {
        if let measuredCenter = portRowCenters[port.id] {
            return measuredCenter
        }

        return GraphCanvasLayout.headerHeight(for: node) + CGFloat(index(of: port, in: ports)) * GraphCanvasLayout.portSpacing
    }

    private func rowCenterPreferences(
        for row: (input: String, output: String),
        midY: CGFloat
    ) -> [GraphPort.ID: CGFloat] {
        var preferences: [GraphPort.ID: CGFloat] = [:]

        if let inputPort = visibleInputPorts.first(where: { $0.name == row.input }), !row.input.isEmpty {
            preferences[inputPort.id] = midY
        }

        if let outputPort = node.outputPorts.first(where: { $0.name == row.output }), !row.output.isEmpty {
            preferences[outputPort.id] = midY
        }

        return preferences
    }

    private var subtitle: String {
        switch node.kind {
        case .uniform(let uniform):
            return uniform.kind.label
        case .time:
            return "Animated input"
        case .mouse:
            return "Pointer input"
        case .pointSplit:
            return "Point to scalars"
        case .pointCombine:
            return "Scalars to point"
        case .point3Split:
            return "Point3 to scalars"
        case .point3Combine:
            return "Scalars to point3"
        case .point4Split:
            return "Point4 to scalars"
        case .point4Combine:
            return "Scalars to point4"
        case .pointInterpolate:
            return "Animated point"
        case .point3Interpolate:
            return "Animated point3"
        case .point4Interpolate:
            return "Animated point4"
        case .pointScale:
            return "Scale point"
        case .point3Scale:
            return "Scale point3"
        case .point4Scale:
            return "Scale point4"
        case .colorSplit:
            return "Color to scalars"
        case .scroll:
            return "Trackpad scroll input"
        case .keyboard:
            return "Keyboard input"
        case .handTracker:
            return "Vision hand input"
        case .pinch:
            return "Finger-thumb gesture"
        case .scrollGesture:
            return "Gated motion scroll"
        case .zoomGesture:
            return "Two-point zoom"
        case .trackball:
            return "Mouse orbit control"
        case .depthEstimate:
            return "Inferred hand depth"
        case .math:
            return "Scalar math"
        case .expression:
            return "Scalar formula"
        case .clamp:
            return "Value limiter"
        case .mapRange:
            return "Range remap"
        case .logic:
            return "Boolean gate"
        case .compare:
            return "Threshold compare"
        case .random:
            return "Random scalar"
        case .pulse:
            return "Rising edge gate"
        case .fireOnLoad:
            return "Startup pulse"
        case .counter:
            return "Counter"
        case .toggle:
            return "Toggle"
        case .delay:
            return "Delayed pulse"
        case .timer:
            return "Timed pulse"
        case .scalarVariable:
            return "Scalar variable"
        case .stringVariable:
            return "String variable"
        case .colorVariable:
            return "Color variable"
        case .scalarArrayVariable:
            return "Scalar array variable"
        case .stringArrayVariable:
            return "String array variable"
        case .colorArrayVariable:
            return "Color array variable"
        case .imageArrayVariable:
            return "Image array variable"
        case .string:
            return "String value"
        case .stringFormat:
            return "Template formatter"
        case .stringCompare:
            return "Text compare gate"
        case .stringSplit:
            return "Split text to part"
        case .color:
            return "RGBA color value"
        case .hslColor:
            return "HSLA color value"
        case .scalarArray:
            return "Numeric value list"
        case .stringArray:
            return "Text value list"
        case .colorArray:
            return "Color palette list"
        case .imageArray:
            return "Visual source list"
        case .scalarArrayIndex:
            return "Scalar array lookup"
        case .stringArrayIndex:
            return "String array lookup"
        case .colorArrayIndex:
            return "Color array lookup"
        case .imageArrayIndex:
            return "Source array lookup"
        case .arrayCount:
            return "Array length"
        case .textImage:
            return "Rendered text source"
        case .audio:
            return "System audio input"
        case .beatDetect:
            return "Kick and snare triggers"
        case .slider:
            return "On-screen slider"
        case .sliderStyle:
            return "Slider color theme"
        case .button:
            return "On-screen button"
        case .buttonStyle:
            return "Button color theme"
        case .polar:
            return "Point to angle/radius"
        case .hitZone:
            return "Point to touch gate"
        case .rectHit:
            return "Rectangular point gate"
        case .screenSize:
            return "Main screen metrics"
        case .screenBounds:
            return "Screen edges and bounds"
        case .renderBounds:
            return "Render window bounds"
        case .renderWindow:
            return "Render window control"
        case .gridLayout:
            return "Index to grid position"
        case .scalarMultiplexor:
            return "Indexed scalar selector"
        case .stringMultiplexor:
            return "Indexed string selector"
        case .colorMultiplexor:
            return "Indexed color selector"
        case .imageMultiplexor:
            return "Indexed image selector"
        case .macro:
            return "Wrapped subgraph"
        case .iterator:
            return "Repeat subgraph"
        case .iteratorVariables:
            return "Index, progress, total"
        case .midiOut:
            return "Point-to-note mapper"
        case .midiCC:
            return "Scalar to CC mapper"
        case .midiCCInput:
            return "Incoming controller value"
        case .midiNoteInput:
            return "Incoming note gate"
        case .oscInput:
            return "Incoming OSC message"
        case .oscOutput:
            return "Outgoing OSC sender"
        case .oscReceive:
            return "OSC packet receiver"
        case .oscSend:
            return "OSC packet sender"
        case .oscGet4:
            return "Unpack four OSC values"
        case .oscGetArray:
            return "Unpack OSC float array"
        case .oscMake4:
            return "Build one OSC message"
        case .oscMakeArray:
            return "Build OSC float array"
        case .oscBundle:
            return "Bundle OSC messages"
        case .note:
            return "Graph note + overlay"
        case .transform:
            return "Position XYZ, scale, rotate"
        case .scene3DTransform:
            return "3D scene transform"
        case .scene3DTile:
            return "Infinite 3D tiling"
        case .scene3DRender:
            return "3D scene renderer"
        case .billboard:
            return "Position XYZ, size, tint"
        case .line:
            return "Endpoints, thickness, color"
        case .scene3DLight:
            return "Reusable 3D scene light"
        case .scene3DMaterial:
            return "Reusable 3D material"
        case .scene3DPrimitive:
            return "SceneKit primitive source"
        case .scene3DText:
            return "SceneKit 3D text source"
        case .scene3DModel:
            return "SceneKit model file source"
        case .scene3DGaussianSplat:
            return "PLY Gaussian splat viewer"
        case .scene3DParticle:
            return "SceneKit particle emitter"
        case .select:
            return "Choose source A or B"
        case .scalarSwitch:
            return "Choose scalar A or B"
        case .stringSwitch:
            return "Choose string A or B"
        case .colorSwitch:
            return "Choose color A or B"
        case .circle:
            return "Point marker"
        case .clear:
            return "Solid background"
        case .image:
            return "Embedded image source"
        case .webView:
            return "Interactive web page source"
        case .aiImage:
            return "On-device prompt image source"
        case .videoPlayer:
            return "Movie file source"
        case .video:
            return "Webcam source"
        case .coreImage:
            return "Filter picker"
        case .blur:
            return "Gaussian blur"
        case .bloom:
            return "Bright soft bloom"
        case .hueRotate:
            return "Hue shift"
        case .posterize:
            return "Color bands"
        case .levels:
            return "Black/white levels"
        case .glow:
            return "Luminous halo"
        case .underwater:
            return "Image distortion"
        case .feedback:
            return "Frame echo"
        case .reactionDiffusion:
            return "Reaction simulation"
        case .transition:
            return "Source transition"
        case .scale:
            return "Scalar remap"
        case .interpolator:
            return "Looping value"
        case .hold:
            return "Hold last sample"
        case .scalarSmooth:
            return "Smooth scalar follower"
        case .trail:
            return "Rainbow trail"
        case .layers:
            return "Alpha composite"
        case .monitor:
            return "Scalar readout"
        case .mix:
            return "Blend node"
        case .metalFragment:
            return "Metal fragment"
        case .renderOutput:
            return "Output window"
        }
    }

    private var accent: Color {
        switch node.kind {
        case .uniform:
            return .orange
        case .time:
            return .blue
        case .mouse:
            return .cyan
        case .pointSplit:
            return .cyan
        case .pointCombine:
            return .cyan
        case .point3Split:
            return .cyan
        case .point3Combine:
            return .cyan
        case .point4Split:
            return .cyan
        case .point4Combine:
            return .cyan
        case .pointInterpolate:
            return .blue
        case .point3Interpolate:
            return .blue
        case .point4Interpolate:
            return .blue
        case .pointScale:
            return .blue
        case .point3Scale:
            return .blue
        case .point4Scale:
            return .blue
        case .colorSplit:
            return .pink
        case .scroll:
            return .teal
        case .handTracker:
            return .green
        case .pinch:
            return .mint
        case .scrollGesture:
            return .cyan
        case .zoomGesture:
            return .blue
        case .trackball:
            return .blue
        case .depthEstimate:
            return .teal
        case .keyboard:
            return .blue
        case .math:
            return .orange
        case .expression:
            return .orange
        case .clamp:
            return .yellow
        case .mapRange:
            return .mint
        case .logic:
            return .indigo
        case .compare:
            return .purple
        case .random:
            return .orange
        case .pulse:
            return .indigo
        case .fireOnLoad:
            return .blue
        case .counter:
            return .yellow
        case .toggle:
            return .green
        case .delay:
            return .indigo
        case .timer:
            return .cyan
        case .scalarVariable:
            return .orange
        case .stringVariable:
            return .orange
        case .colorVariable:
            return .pink
        case .scalarArrayVariable:
            return .orange
        case .stringArrayVariable:
            return .orange
        case .colorArrayVariable:
            return .pink
        case .imageArrayVariable:
            return .blue
        case .string:
            return .orange
        case .stringFormat:
            return .orange
        case .stringCompare:
            return .purple
        case .stringSplit:
            return .orange
        case .color:
            return .pink
        case .hslColor:
            return .pink
        case .scalarArray:
            return .orange
        case .stringArray:
            return .orange
        case .colorArray:
            return .pink
        case .imageArray:
            return .blue
        case .scalarArrayIndex:
            return .yellow
        case .stringArrayIndex:
            return .yellow
        case .colorArrayIndex:
            return .yellow
        case .imageArrayIndex:
            return .yellow
        case .arrayCount:
            return .mint
        case .textImage:
            return .yellow
        case .audio:
            return .pink
        case .beatDetect:
            return .pink
        case .slider:
            return .mint
        case .sliderStyle:
            return .teal
        case .button:
            return .blue
        case .buttonStyle:
            return .indigo
        case .polar:
            return .yellow
        case .hitZone:
            return .mint
        case .rectHit:
            return .mint
        case .screenSize:
            return .cyan
        case .screenBounds:
            return .cyan
        case .renderBounds:
            return .cyan
        case .renderWindow:
            return .cyan
        case .gridLayout:
            return .mint
        case .scalarMultiplexor:
            return .yellow
        case .stringMultiplexor:
            return .orange
        case .colorMultiplexor:
            return .pink
        case .imageMultiplexor:
            return .blue
        case .macro:
            return .purple
        case .iterator:
            return .purple
        case .iteratorVariables:
            return .indigo
        case .midiOut:
            return .orange
        case .midiCC:
            return .orange
        case .midiCCInput:
            return .orange
        case .midiNoteInput:
            return .orange
        case .oscInput:
            return .orange
        case .oscOutput:
            return .orange
        case .oscReceive:
            return .orange
        case .oscSend:
            return .orange
        case .oscGet4:
            return .orange
        case .oscGetArray:
            return .orange
        case .oscMake4:
            return .orange
        case .oscMakeArray:
            return .orange
        case .oscBundle:
            return .orange
        case .note:
            return .yellow
        case .transform:
            return .cyan
        case .scene3DTransform:
            return .blue
        case .scene3DTile:
            return .blue
        case .scene3DRender:
            return .blue
        case .billboard:
            return .pink
        case .line:
            return .red
        case .scene3DLight:
            return .blue
        case .scene3DMaterial:
            return .blue
        case .scene3DPrimitive:
            return .blue
        case .scene3DText:
            return .blue
        case .scene3DModel:
            return .blue
        case .scene3DGaussianSplat:
            return .purple
        case .scene3DParticle:
            return .blue
        case .select:
            return .mint
        case .scalarSwitch:
            return .orange
        case .stringSwitch:
            return .teal
        case .colorSwitch:
            return .pink
        case .circle:
            return .red
        case .clear:
            return .gray
        case .image:
            return .yellow
        case .webView:
            return .orange
        case .aiImage:
            return .orange
        case .videoPlayer:
            return .orange
        case .video:
            return .blue
        case .coreImage:
            return .pink
        case .blur:
            return .blue
        case .bloom:
            return .yellow
        case .hueRotate:
            return .pink
        case .posterize:
            return .orange
        case .levels:
            return .indigo
        case .glow:
            return .mint
        case .underwater:
            return .teal
        case .feedback:
            return .indigo
        case .reactionDiffusion:
            return .mint
        case .transition:
            return .purple
        case .scale:
            return .mint
        case .interpolator:
            return .blue
        case .hold:
            return .indigo
        case .scalarSmooth:
            return .mint
        case .trail:
            return .purple
        case .layers:
            return .orange
        case .monitor:
            return .teal
        case .mix:
            return .purple
        case .metalFragment:
            return .green
        case .renderOutput:
            return .cyan
        }
    }

    private var background: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(isSelected ? 0.14 : 0.08),
                Color.white.opacity(isSelected ? 0.08 : 0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct NodeInspectorControls: View {
    @ObservedObject var store: GraphStore
    let node: GraphNode

    var body: some View {
        Group {
            if case .uniform(let uniform) = node.kind {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.displayValue(for: uniform))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    CompactUniformEditor(store: store, uniform: uniform)
                }
            } else if case .mouse = node.kind {
                MouseNodeReadout(store: store)
            } else if case .scroll = node.kind {
                ScrollNodeReadout(store: store)
            } else if case .handTracker = node.kind {
                HandTrackerNodeReadout(store: store, nodeID: node.id)
            } else if case .pinch = node.kind {
                PinchNodeEditor(store: store, nodeID: node.id)
            } else if case .scrollGesture = node.kind {
                ScrollGestureNodeEditor(store: store, nodeID: node.id)
            } else if case .zoomGesture = node.kind {
                ZoomGestureNodeEditor(store: store, nodeID: node.id)
            } else if case .trackball = node.kind {
                TrackballNodeEditor(store: store, nodeID: node.id)
            } else if case .depthEstimate = node.kind {
                DepthEstimateNodeEditor(store: store, nodeID: node.id)
            } else if case .math = node.kind {
                MathNodeEditor(store: store, nodeID: node.id)
            } else if case .expression = node.kind {
                ExpressionNodeEditor(store: store, nodeID: node.id)
            } else if case .clamp = node.kind {
                ClampNodeEditor(store: store, nodeID: node.id)
            } else if case .mapRange = node.kind {
                MapRangeNodeEditor(store: store, nodeID: node.id)
            } else if case .logic = node.kind {
                LogicNodeEditor(store: store, nodeID: node.id)
            } else if case .compare = node.kind {
                CompareNodeEditor(store: store, nodeID: node.id)
            } else if case .random = node.kind {
                RandomNodeEditor(store: store, nodeID: node.id)
            } else if case .pulse = node.kind {
                PulseNodeEditor(store: store, nodeID: node.id)
            } else if case .counter = node.kind {
                CounterNodeEditor(store: store, nodeID: node.id)
            } else if case .toggle = node.kind {
                ToggleNodeEditor(store: store, nodeID: node.id)
            } else if case .delay = node.kind {
                DelayNodeEditor(store: store, nodeID: node.id)
            } else if case .timer = node.kind {
                TimerNodeEditor(store: store, nodeID: node.id)
            } else if case .keyboard = node.kind {
                KeyboardNodeEditor(store: store, nodeID: node.id)
            } else if case .scalarVariable = node.kind {
                ScalarVariableNodeEditor(store: store, nodeID: node.id)
            } else if case .stringVariable = node.kind {
                StringVariableNodeEditor(store: store, nodeID: node.id)
            } else if case .string = node.kind {
                StringNodeEditor(store: store, nodeID: node.id)
            } else if case .stringFormat = node.kind {
                StringFormatNodeEditor(store: store, nodeID: node.id)
            } else if case .stringCompare = node.kind {
                StringCompareNodeEditor(store: store, nodeID: node.id)
            } else if case .stringSplit = node.kind {
                StringSplitNodeEditor(store: store, nodeID: node.id)
            } else if case .color = node.kind {
                ColorNodeEditor(store: store, nodeID: node.id)
            } else if case .hslColor = node.kind {
                HSLColorNodeEditor(store: store, nodeID: node.id)
            } else if case .scalarArray = node.kind {
                ScalarArrayNodeEditor(store: store, nodeID: node.id)
            } else if case .stringArray = node.kind {
                StringArrayNodeEditor(store: store, nodeID: node.id)
            } else if case .colorArray = node.kind {
                ColorArrayNodeEditor(store: store, nodeID: node.id)
            } else if case .imageArray = node.kind {
                ImageArrayNodeEditor(store: store, nodeID: node.id)
            } else if case .scalarArrayIndex = node.kind {
                ScalarArrayIndexNodeEditor(store: store, nodeID: node.id)
            } else if case .stringArrayIndex = node.kind {
                StringArrayIndexNodeEditor(store: store, nodeID: node.id)
            } else if case .colorArrayIndex = node.kind {
                ColorArrayIndexNodeEditor(store: store, nodeID: node.id)
            } else if case .imageArrayIndex = node.kind {
                ImageArrayIndexNodeEditor(store: store, nodeID: node.id)
            } else if case .arrayCount = node.kind {
                ArrayCountNodeEditor(store: store, nodeID: node.id)
            } else if case .textImage = node.kind {
                TextImageNodeEditor(store: store, nodeID: node.id)
            } else if case .audio = node.kind {
                AudioNodeReadout(store: store)
            } else if case .beatDetect = node.kind {
                BeatDetectNodeReadout(store: store, nodeID: node.id)
            } else if case .slider = node.kind {
                SliderNodeEditor(store: store, nodeID: node.id)
            } else if case .sliderStyle = node.kind {
                SliderStyleNodeEditor(store: store, nodeID: node.id)
            } else if case .button = node.kind {
                ButtonNodeEditor(store: store, nodeID: node.id)
            } else if case .buttonStyle = node.kind {
                ButtonStyleNodeEditor(store: store, nodeID: node.id)
            } else if case .polar = node.kind {
                PolarNodeEditor(store: store, nodeID: node.id)
            } else if case .hitZone = node.kind {
                HitZoneNodeEditor(store: store, nodeID: node.id)
            } else if case .rectHit = node.kind {
                RectHitNodeEditor(store: store, nodeID: node.id)
            } else if case .screenSize = node.kind {
                ScreenSizeNodeEditor(store: store)
            } else if case .screenBounds = node.kind {
                ScreenBoundsNodeEditor(store: store, nodeID: node.id)
            } else if case .renderBounds = node.kind {
                RenderBoundsNodeEditor(store: store, nodeID: node.id)
            } else if case .renderWindow = node.kind {
                RenderWindowNodeEditor(store: store, nodeID: node.id)
            } else if case .gridLayout = node.kind {
                GridLayoutNodeEditor(store: store, nodeID: node.id)
            } else if case .scalarMultiplexor = node.kind {
                ScalarMultiplexorNodeEditor(store: store, nodeID: node.id)
            } else if case .stringMultiplexor = node.kind {
                StringMultiplexorNodeEditor(store: store, nodeID: node.id)
            } else if case .colorMultiplexor = node.kind {
                ColorMultiplexorNodeEditor(store: store, nodeID: node.id)
            } else if case .imageMultiplexor = node.kind {
                ImageMultiplexorNodeEditor(store: store, nodeID: node.id)
            } else if case .macro = node.kind {
                MacroNodeEditor(store: store, nodeID: node.id)
            } else if case .iterator = node.kind {
                IteratorNodeEditor(store: store, nodeID: node.id)
            } else if case .iteratorVariables = node.kind {
                IteratorVariablesNodeEditor()
            } else if case .midiOut = node.kind {
                MIDIOutNodeEditor(store: store, nodeID: node.id)
            } else if case .midiCC = node.kind {
                MIDICCNodeEditor(store: store, nodeID: node.id)
            } else if case .midiCCInput = node.kind {
                MIDIInputCCNodeEditor(store: store, nodeID: node.id)
            } else if case .midiNoteInput = node.kind {
                MIDIInputNoteNodeEditor(store: store, nodeID: node.id)
            } else if case .oscInput = node.kind {
                OSCInputNodeEditor(store: store, nodeID: node.id)
            } else if case .oscOutput = node.kind {
                OSCOutputNodeEditor(store: store, nodeID: node.id)
            } else if case .oscReceive = node.kind {
                OSCInputNodeEditor(store: store, nodeID: node.id)
            } else if case .oscSend = node.kind {
                OSCSendNodeEditor(store: store, nodeID: node.id)
            } else if case .oscMake4 = node.kind {
                OSCMessageNodeEditor(store: store, nodeID: node.id)
            } else if case .oscMakeArray = node.kind {
                OSCArrayMessageNodeEditor(store: store, nodeID: node.id)
            } else if case .oscBundle = node.kind {
                OSCBundleNodeEditor(store: store, nodeID: node.id)
            } else if case .note = node.kind {
                NoteNodeEditor(store: store, nodeID: node.id)
            } else if case .transform = node.kind {
                TransformNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DTransform = node.kind {
                Scene3DTransformNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DTile = node.kind {
                Scene3DTileNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DRender = node.kind {
                Scene3DRenderNodeEditor(store: store, nodeID: node.id)
            } else if case .billboard = node.kind {
                BillboardNodeEditor(store: store, nodeID: node.id)
            } else if case .line = node.kind {
                LineNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DLight = node.kind {
                Scene3DLightNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DMaterial = node.kind {
                Scene3DMaterialNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DPrimitive = node.kind {
                Scene3DPrimitiveNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DText = node.kind {
                Scene3DTextNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DModel = node.kind {
                Scene3DModelNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DGaussianSplat = node.kind {
                Scene3DGaussianSplatNodeEditor(store: store, nodeID: node.id)
            } else if case .scene3DParticle = node.kind {
                Scene3DParticleNodeEditor(store: store, nodeID: node.id)
            } else if case .select = node.kind {
                SelectNodeEditor(store: store, nodeID: node.id)
            } else if case .scalarSwitch = node.kind {
                SelectNodeEditor(store: store, nodeID: node.id)
            } else if case .stringSwitch = node.kind {
                SelectNodeEditor(store: store, nodeID: node.id)
            } else if case .colorSwitch = node.kind {
                SelectNodeEditor(store: store, nodeID: node.id)
            } else if case .circle = node.kind {
                CircleNodeEditor(store: store, nodeID: node.id)
            } else if case .clear = node.kind {
                ClearNodeEditor(store: store, nodeID: node.id)
            } else if case .image = node.kind {
                ImageNodeReadout(store: store, nodeID: node.id)
            } else if case .webView = node.kind {
                WebViewNodeEditor(store: store, nodeID: node.id)
            } else if case .aiImage = node.kind {
                AIImageNodeEditor(store: store, nodeID: node.id)
            } else if case .videoPlayer = node.kind {
                VideoPlayerNodeEditor(store: store, nodeID: node.id)
            } else if case .video = node.kind {
                Text("Live webcam source")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
            } else if store.isCoreImageEffectNode(node.id) {
                CoreImageNodeEditor(store: store, nodeID: node.id, kind: node.kind)
            } else if case .underwater = node.kind {
                UnderwaterNodeEditor(store: store, nodeID: node.id)
            } else if case .feedback = node.kind {
                FeedbackNodeEditor(store: store, nodeID: node.id)
            } else if case .reactionDiffusion = node.kind {
                ReactionDiffusionNodeEditor(store: store, nodeID: node.id)
            } else if case .transition = node.kind {
                TransitionNodeEditor(store: store, nodeID: node.id)
            } else if case .scale = node.kind {
                ScaleNodeEditor(store: store, nodeID: node.id)
            } else if case .interpolator = node.kind {
                InterpolatorNodeEditor(store: store, nodeID: node.id)
            } else if case .pointInterpolate = node.kind {
                PointInterpolatorNodeEditor(store: store, nodeID: node.id)
            } else if case .point3Interpolate = node.kind {
                Point3InterpolatorNodeEditor(store: store, nodeID: node.id)
            } else if case .point4Interpolate = node.kind {
                Point4InterpolatorNodeEditor(store: store, nodeID: node.id)
            } else if case .pointScale = node.kind {
                PointScaleNodeEditor(store: store, nodeID: node.id)
            } else if case .point3Scale = node.kind {
                Point3ScaleNodeEditor(store: store, nodeID: node.id)
            } else if case .point4Scale = node.kind {
                Point4ScaleNodeEditor(store: store, nodeID: node.id)
            } else if case .hold = node.kind {
                HoldNodeEditor(store: store, nodeID: node.id)
            } else if case .scalarSmooth = node.kind {
                ScalarSmoothNodeEditor(store: store, nodeID: node.id)
            } else if case .trail = node.kind {
                TrailNodeEditor(store: store, nodeID: node.id)
            } else if case .layers = node.kind {
                LayersNodeEditor(store: store, nodeID: node.id)
            } else if case .metalFragment = node.kind {
                MetalFragmentNodeEditor(store: store, nodeID: node.id)
            } else if case .monitor = node.kind {
                MonitorReadout(store: store, nodeID: node.id)
            } else if case .renderOutput = node.kind {
                RenderNodePreview(store: store, renderNodeID: node.id)
            } else {
                EmptyView()
            }
        }
    }
}

private struct MetalFragmentNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let uniforms = store.fragmentUniforms(for: nodeID)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(store.isCodeEditorVisible ? "Hide Code" : "Edit Fragment") {
                    store.toggleCodeEditorWindow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Make Preset Node") {
                    store.makePresetNodeFromSelectedFragment()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if uniforms.isEmpty == false {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Uniform Controls")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(uniforms) { uniform in
                        UniformControlView(
                            uniform: uniform,
                            currentValueText: store.displayValue(for: uniform),
                            onRangeChange: { minValue, maxValue in
                                store.updateUniformRange(uniform.id, minValue: minValue, maxValue: maxValue)
                            },
                            onChange: { value in
                                store.updateUniform(uniform.id, value: value)
                            }
                        )
                        .padding(12)
                        .background(.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.08))
                        }
                    }
                }
            } else {
                Text("No imported uniforms yet. Add inputs in the fragment metadata comment to make editable ports and controls.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }
}

private struct RenderNodePreview: View {
    @ObservedObject var store: GraphStore
    let renderNodeID: GraphNode.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Open") {
                    store.openPreviewWindow(for: renderNodeID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Hide") {
                    store.hideAuxiliaryWindows()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            MetalPreviewView(
                configuration: store.previewConfiguration(forRenderNodeID: renderNodeID),
                isRunning: store.isGraphRunning,
                onMouseChange: store.updateMousePosition,
                onMouseButtonChange: store.updateMouseButtons,
                onModifierFlagsChange: store.updatePreviewModifierFlags,
                onScrollChange: store.updateScrollDelta
            )
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.1))
            }
        }
    }
}

private struct CompactRenderNodePreview: View {
    @ObservedObject var store: GraphStore
    let renderNodeID: GraphNode.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Open") {
                    store.openPreviewWindow(for: renderNodeID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)

                Button("Hide") {
                    store.hideAuxiliaryWindows()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            MetalPreviewView(
                configuration: store.previewConfiguration(forRenderNodeID: renderNodeID),
                isRunning: store.isGraphRunning,
                onMouseChange: store.updateMousePosition,
                onMouseButtonChange: store.updateMouseButtons,
                onModifierFlagsChange: store.updatePreviewModifierFlags,
                onScrollChange: store.updateScrollDelta
            )
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.1))
            }
        }
    }
}

private struct AudioNodeReadout: View {
    @ObservedObject var store: GraphStore

    var body: some View {
        let spectrum = store.audioSpectrumValues()

        VStack(alignment: .leading, spacing: 8) {
            Text(store.audioStatus)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            ForEach(AudioSignalKind.allCases) { signal in
                HStack(spacing: 8) {
                    Text(signal.label)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 72, alignment: .leading)
                    ProgressView(value: store.audioValue(for: signal))
                        .tint(.pink)
                    Text(String(format: "%.2f", store.audioValue(for: signal)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, alignment: .trailing)
                }
            }

            if spectrum.isEmpty == false {
                HStack {
                    Text("Spectrum")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.78))
                    Spacer()
                    Text("\(store.audioSpectrumBandCount) bands")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }

                AudioSpectrumStrip(values: spectrum)
                    .frame(height: 42)
            }
        }
    }
}

private struct BeatDetectNodeReadout: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forBeatDetectNodeID: nodeID)
        let kick = store.beatDetectValue(for: nodeID, outputName: "Kick") ?? 0
        let snare = store.beatDetectValue(for: nodeID, outputName: "Snare") ?? 0
        let kickLevel = store.beatDetectValue(for: nodeID, outputName: "Kick Level") ?? 0
        let snareLevel = store.beatDetectValue(for: nodeID, outputName: "Snare Level") ?? 0

        VStack(alignment: .leading, spacing: 8) {
            Text("Detects one-frame kick and snare hits from the live audio input. Lower Threshold to catch more hits, or raise Sensitivity to amplify the detector before the threshold.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            LabeledSlider(
                title: "Kick Threshold",
                value: Binding(
                    get: { settings.kickThreshold },
                    set: { newValue in
                        store.updateBeatDetectNodeSettings(nodeID) { $0.kickThreshold = newValue }
                    }
                ),
                range: 0...2
            )

            LabeledSlider(
                title: "Kick Sensitivity",
                value: Binding(
                    get: { settings.kickSensitivity },
                    set: { newValue in
                        store.updateBeatDetectNodeSettings(nodeID) { $0.kickSensitivity = newValue }
                    }
                ),
                range: 0.1...4
            )

            LabeledSlider(
                title: "Snare Threshold",
                value: Binding(
                    get: { settings.snareThreshold },
                    set: { newValue in
                        store.updateBeatDetectNodeSettings(nodeID) { $0.snareThreshold = newValue }
                    }
                ),
                range: 0...2
            )

            LabeledSlider(
                title: "Snare Sensitivity",
                value: Binding(
                    get: { settings.snareSensitivity },
                    set: { newValue in
                        store.updateBeatDetectNodeSettings(nodeID) { $0.snareSensitivity = newValue }
                    }
                ),
                range: 0.1...4
            )

            HStack {
                Text("Kick")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(kick >= 0.5 ? "Hit" : "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(kick >= 0.5 ? .green : .white.opacity(0.85))
            }

            HStack {
                Text("Snare")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(snare >= 0.5 ? "Hit" : "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(snare >= 0.5 ? .orange : .white.opacity(0.85))
            }

            HStack {
                Text("Kick Level")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(String(format: "%.2f", kickLevel))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Snare Level")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(String(format: "%.2f", snareLevel))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct AudioSpectrumStrip: View {
    let values: [Double]

    private var sampledValues: [Double] {
        let targetCount = min(64, max(values.count, 1))
        guard values.count > targetCount else { return values }
        return (0..<targetCount).map { index in
            let start = (index * values.count) / targetCount
            let end = max(start + 1, ((index + 1) * values.count) / targetCount)
            let slice = values[start..<min(end, values.count)]
            return slice.max() ?? 0.0
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let bars = sampledValues
            let count = max(bars.count, 1)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.05))

                Canvas { context, canvasSize in
                    let drawWidth = canvasSize.width / CGFloat(count)
                    let gradient = Gradient(colors: [
                        Color.cyan.opacity(0.9),
                        Color.pink.opacity(0.95)
                    ])

                    for (index, value) in bars.enumerated() {
                        let clamped = max(0.0, min(1.0, value))
                        let height = max(1, canvasSize.height * clamped)
                        let rect = CGRect(
                            x: CGFloat(index) * drawWidth,
                            y: canvasSize.height - height,
                            width: max(1, drawWidth - 1),
                            height: height
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1.5),
                            with: .linearGradient(
                                gradient,
                                startPoint: CGPoint(x: rect.midX, y: rect.maxY),
                                endPoint: CGPoint(x: rect.midX, y: rect.minY)
                            )
                        )
                    }
                }
            }
        }
    }
}

private struct HandTrackerNodeReadout: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forHandTrackerNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text(store.handTrackerStatus)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Text("Uses the shared webcam feed. Layer a Webcam node under Trail to line things up visually.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))

            handRow(title: "Finger 1", point: store.handPoint(isLeftHand: true))
            handRow(title: "Finger 2", point: store.handPoint(isLeftHand: false))
            handRow(title: "Thumb 1", point: store.thumbPoint(isLeftHand: true))
            handRow(title: "Thumb 2", point: store.thumbPoint(isLeftHand: false))

            LabeledSlider(
                title: "Offset X",
                value: Binding(
                    get: { settings.offsetX },
                    set: { newValue in
                        store.updateHandTrackerNodeSettings(nodeID) { $0.offsetX = newValue }
                    }
                ),
                range: -0.5...0.5
            )

            LabeledSlider(
                title: "Offset Y",
                value: Binding(
                    get: { settings.offsetY },
                    set: { newValue in
                        store.updateHandTrackerNodeSettings(nodeID) { $0.offsetY = newValue }
                    }
                ),
                range: -0.5...0.5
            )
        }
    }

    private func handRow(title: String, point: CGPoint?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 34, alignment: .leading)
            ProgressView(value: point?.x ?? 0.0)
                .tint(.green)
                .opacity(point == nil ? 0.3 : 1.0)
            Text(point.map { String(format: "%.2f, %.2f", $0.x, $0.y) } ?? "--")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 82, alignment: .trailing)
        }
    }
}

private struct MouseNodeReadout: View {
    @ObservedObject var store: GraphStore

    var body: some View {
        let mousePosition = store.currentMousePosition
        let leftDown = store.currentMouseLeftButtonDown
        let rightDown = store.currentMouseRightButtonDown

        VStack(alignment: .leading, spacing: 8) {
            Text("Move over a preview to drive this signal.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            HStack(spacing: 8) {
                Text("X")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 16, alignment: .leading)
                ProgressView(value: mousePosition?.x ?? 0.0)
                    .tint(.cyan)
                    .opacity(mousePosition == nil ? 0.3 : 1.0)
                Text(mousePosition.map { String(format: "%.2f", $0.x) } ?? "--")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Y")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 16, alignment: .leading)
                ProgressView(value: mousePosition?.y ?? 0.0)
                    .tint(.cyan)
                    .opacity(mousePosition == nil ? 0.3 : 1.0)
                Text(mousePosition.map { String(format: "%.2f", $0.y) } ?? "--")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("L")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 16, alignment: .leading)
                Capsule()
                    .fill(leftDown ? Color.green : Color.white.opacity(0.14))
                    .frame(height: 8)
                Text(leftDown ? "1" : "0")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("R")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 16, alignment: .leading)
                Capsule()
                    .fill(rightDown ? Color.green : Color.white.opacity(0.14))
                    .frame(height: 8)
                Text(rightDown ? "1" : "0")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

private struct ScrollNodeReadout: View {
    @ObservedObject var store: GraphStore

    var body: some View {
        let scroll = store.currentScrollPosition

        VStack(alignment: .leading, spacing: 8) {
            Text("Two-finger scroll over a preview to drive this signal.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            HStack(spacing: 8) {
                Text("X")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 16, alignment: .leading)
                Text(String(format: "%.3f", scroll.x))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
            }

            HStack(spacing: 8) {
                Text("Y")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 16, alignment: .leading)
                Text(String(format: "%.3f", scroll.y))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }
}

private struct PolarNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forPolarNodeID: nodeID)
        let angle = store.scalarOutputValue(forNodeID: nodeID, outputName: "Angle")
        let degrees = store.scalarOutputValue(forNodeID: nodeID, outputName: "Degrees")
        let normalized = store.scalarOutputValue(forNodeID: nodeID, outputName: "Normalized")
        let radius = store.scalarOutputValue(forNodeID: nodeID, outputName: "Radius")

        VStack(alignment: .leading, spacing: 8) {
            Text("Turns a point into angle, degrees, normalized angle, and radius.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            HStack {
                Text("Deg")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(degrees.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Norm")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(normalized.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Rad")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(angle.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Radius")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(radius.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 8) {
                NumericField(
                    title: "Center X",
                    value: settings.centerX,
                    onSubmit: { newValue in
                        store.updatePolarNodeSettings(nodeID) { $0.centerX = min(max(newValue, 0.0), 1.0) }
                    }
                )
                NumericField(
                    title: "Center Y",
                    value: settings.centerY,
                    onSubmit: { newValue in
                        store.updatePolarNodeSettings(nodeID) { $0.centerY = min(max(newValue, 0.0), 1.0) }
                    }
                )
            }

            NumericField(
                title: "Offset Deg",
                value: settings.angleOffsetDegrees,
                onSubmit: { newValue in
                    store.updatePolarNodeSettings(nodeID) { $0.angleOffsetDegrees = newValue }
                }
            )

            Toggle(
                "Clockwise",
                isOn: Binding(
                    get: { settings.clockwise },
                    set: { newValue in
                        store.updatePolarNodeSettings(nodeID) { $0.clockwise = newValue }
                    }
                )
            )
            .toggleStyle(.switch)
            .font(.caption2)
        }
    }
}

private struct HitZoneNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forHitZoneNodeID: nodeID)
        let inside = store.scalarOutputValue(forNodeID: nodeID, outputName: "Inside")
        let distance = store.scalarOutputValue(forNodeID: nodeID, outputName: "Distance")

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs 1 while the point is inside the ring between Inner and Outer Radius.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            HStack {
                Text("Inside")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(inside.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Distance")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(distance.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 8) {
                NumericField(
                    title: "Center X",
                    value: settings.centerX,
                    onSubmit: { newValue in
                        store.updateHitZoneNodeSettings(nodeID) { $0.centerX = newValue }
                    }
                )
                NumericField(
                    title: "Center Y",
                    value: settings.centerY,
                    onSubmit: { newValue in
                        store.updateHitZoneNodeSettings(nodeID) { $0.centerY = newValue }
                    }
                )
            }

            NumericField(
                title: "Inner Radius",
                value: settings.innerRadius,
                onSubmit: { newValue in
                    store.updateHitZoneNodeSettings(nodeID) { $0.innerRadius = newValue }
                }
            )

            NumericField(
                title: "Outer Radius",
                value: settings.outerRadius,
                onSubmit: { newValue in
                    store.updateHitZoneNodeSettings(nodeID) { $0.outerRadius = newValue }
                }
            )
        }
    }
}

private struct RectHitNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forRectHitNodeID: nodeID)
        let inside = store.scalarOutputValue(forNodeID: nodeID, outputName: "Inside")

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs 1 while the point is inside the rectangular region centered on Center.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            HStack {
                Text("Inside")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(inside.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 8) {
                NumericField(
                    title: "Center X",
                    value: settings.centerX,
                    onSubmit: { newValue in
                        store.updateRectHitNodeSettings(nodeID) { $0.centerX = newValue }
                    }
                )
                NumericField(
                    title: "Center Y",
                    value: settings.centerY,
                    onSubmit: { newValue in
                        store.updateRectHitNodeSettings(nodeID) { $0.centerY = newValue }
                    }
                )
            }

            HStack(spacing: 8) {
                NumericField(
                    title: "Width",
                    value: settings.width,
                    onSubmit: { newValue in
                        store.updateRectHitNodeSettings(nodeID) { $0.width = newValue }
                    }
                )
                NumericField(
                    title: "Height",
                    value: settings.height,
                    onSubmit: { newValue in
                        store.updateRectHitNodeSettings(nodeID) { $0.height = newValue }
                    }
                )
            }
        }
    }
}

private struct ScreenSizeNodeEditor: View {
    @ObservedObject var store: GraphStore

    var body: some View {
        let width = NSScreen.main?.visibleFrame.width ?? 0
        let height = NSScreen.main?.visibleFrame.height ?? 0
        let aspect = height > 0 ? width / height : 1

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs the current main screen width, height, and aspect ratio.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            HStack {
                Text("Width")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(String(format: "%.0f", width))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Height")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(String(format: "%.0f", height))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Aspect")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(String(format: "%.3f", aspect))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ScreenBoundsNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScreenBoundsNodeID: nodeID)
        let left = store.scalarOutputValue(forNodeID: nodeID, outputName: "Left")
        let right = store.scalarOutputValue(forNodeID: nodeID, outputName: "Right")
        let top = store.scalarOutputValue(forNodeID: nodeID, outputName: "Top")
        let bottom = store.scalarOutputValue(forNodeID: nodeID, outputName: "Bottom")

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs screen edges and size in normalized, centered, or pixel space.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Picker("Mode", selection: Binding(
                get: { settings.mode },
                set: { newValue in
                    store.updateScreenBoundsNodeSettings(nodeID) { $0.mode = newValue }
                }
            )) {
                ForEach(ScreenBoundsMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("L/R")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text("\(left.map { String(format: "%.2f", $0) } ?? "--") / \(right.map { String(format: "%.2f", $0) } ?? "--")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("B/T")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text("\(bottom.map { String(format: "%.2f", $0) } ?? "--") / \(top.map { String(format: "%.2f", $0) } ?? "--")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct RenderBoundsNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forRenderBoundsNodeID: nodeID)
        let renders = store.renderOutputNodes()
        let left = store.scalarOutputValue(forNodeID: nodeID, outputName: "Left")
        let right = store.scalarOutputValue(forNodeID: nodeID, outputName: "Right")
        let top = store.scalarOutputValue(forNodeID: nodeID, outputName: "Top")
        let bottom = store.scalarOutputValue(forNodeID: nodeID, outputName: "Bottom")
        let width = store.scalarOutputValue(forNodeID: nodeID, outputName: "Width")
        let height = store.scalarOutputValue(forNodeID: nodeID, outputName: "Height")

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs the current bounds of a specific render window in pixels.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Picker("Render", selection: Binding(
                get: { settings.targetRenderNodeID },
                set: { newValue in
                    store.updateRenderBoundsNodeSettings(nodeID) { $0.targetRenderNodeID = newValue }
                }
            )) {
                Text("Active Render").tag(Optional<GraphNode.ID>.none)
                ForEach(renders, id: \.id) { renderNode in
                    Text(renderNode.title).tag(Optional(renderNode.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("L/R")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text("\(left.map { String(format: "%.1f", $0) } ?? "--") / \(right.map { String(format: "%.1f", $0) } ?? "--")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("B/T")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text("\(bottom.map { String(format: "%.1f", $0) } ?? "--") / \(top.map { String(format: "%.1f", $0) } ?? "--")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Size")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text("\(width.map { String(format: "%.0f", $0) } ?? "--") x \(height.map { String(format: "%.0f", $0) } ?? "--")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct RenderWindowNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forRenderWindowNodeID: nodeID)
        let renders = store.renderOutputNodes()
        let targetID = settings.targetRenderNodeID ?? store.activePreviewRenderNodeID
        let liveSize = targetID.flatMap { store.previewWindowContentSizes[$0] }

        VStack(alignment: .leading, spacing: 8) {
            Text("Controls title, level, fullscreen, position, and pixel size of a specific render window.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Picker("Render", selection: Binding(
                get: { settings.targetRenderNodeID },
                set: { newValue in
                    store.updateRenderWindowNodeSettings(nodeID) { $0.targetRenderNodeID = newValue }
                }
            )) {
                Text("Active Render").tag(Optional<GraphNode.ID>.none)
                ForEach(renders, id: \.id) { renderNode in
                    Text(renderNode.title).tag(Optional(renderNode.id))
                }
            }
            .pickerStyle(.menu)

            TextField("Window Title", text: Binding(
                get: { settings.title },
                set: { newValue in
                    store.updateRenderWindowNodeSettings(nodeID) { $0.title = newValue }
                }
            ))
            .textFieldStyle(.roundedBorder)

            Toggle("Syphon Enabled", isOn: Binding(
                get: { settings.syphonEnabled },
                set: { newValue in
                    store.updateRenderWindowNodeSettings(nodeID) { $0.syphonEnabled = newValue }
                }
            ))
            .toggleStyle(.switch)

            TextField("Syphon Server Name", text: Binding(
                get: { settings.syphonName },
                set: { newValue in
                    store.updateRenderWindowNodeSettings(nodeID) { $0.syphonName = newValue }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .disabled(settings.syphonEnabled == false)

            Picker("Level", selection: Binding(
                get: { settings.levelMode },
                set: { newValue in
                    store.updateRenderWindowNodeSettings(nodeID) { $0.levelMode = newValue }
                }
            )) {
                ForEach(RenderWindowLevelMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Toggle("Fullscreen", isOn: Binding(
                get: { settings.fullscreen >= 0.5 },
                set: { newValue in
                    store.updateRenderWindowNodeSettings(nodeID) { $0.fullscreen = newValue ? 1.0 : 0.0 }
                }
            ))
            .toggleStyle(.switch)

            NumericField(title: "Width", value: settings.width) { newValue in
                store.updateRenderWindowNodeSettings(nodeID) { $0.width = newValue }
            }

            NumericField(title: "Height", value: settings.height) { newValue in
                store.updateRenderWindowNodeSettings(nodeID) { $0.height = newValue }
            }

            NumericField(title: "X", value: settings.x) { newValue in
                store.updateRenderWindowNodeSettings(nodeID) { $0.x = newValue }
            }

            NumericField(title: "Y", value: settings.y) { newValue in
                store.updateRenderWindowNodeSettings(nodeID) { $0.y = newValue }
            }

            NumericField(title: "FPS", value: settings.fps) { newValue in
                store.updateRenderWindowNodeSettings(nodeID) { $0.fps = max(1.0, min(120.0, newValue)) }
            }

            HStack {
                Text("Live")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(liveSize.map { "\(Int($0.width.rounded())) x \(Int($0.height.rounded()))" } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ScalarMultiplexorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let arraySettings = store.settings(forScalarArrayNodeID: nodeID)
        let indexSettings = store.settings(forScalarArrayIndexNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            Text("Selects one scalar input by index.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
            NumericField(title: "Count", value: Double(arraySettings.count)) { newValue in
                store.updateScalarArrayNodeSettings(nodeID) { $0.count = max(1, Int(newValue.rounded())) }
            }
            NumericField(title: "Index", value: indexSettings.index) { newValue in
                store.updateScalarArrayIndexNodeSettings(nodeID) { $0.index = newValue }
            }
            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct StringMultiplexorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let arraySettings = store.settings(forStringArrayNodeID: nodeID)
        let indexSettings = store.settings(forStringArrayIndexNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Selects one string input by index.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
            NumericField(title: "Count", value: Double(arraySettings.count)) { newValue in
                store.updateStringArrayNodeSettings(nodeID) { $0.count = max(1, Int(newValue.rounded())) }
            }
            NumericField(title: "Index", value: indexSettings.index) { newValue in
                store.updateStringArrayIndexNodeSettings(nodeID) { $0.index = newValue }
            }
        }
    }
}

private struct ColorMultiplexorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let arraySettings = store.settings(forColorArrayNodeID: nodeID)
        let indexSettings = store.settings(forColorArrayIndexNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Selects one color input by index.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
            NumericField(title: "Count", value: Double(arraySettings.count)) { newValue in
                store.updateColorArrayNodeSettings(nodeID) { $0.count = max(1, Int(newValue.rounded())) }
            }
            NumericField(title: "Index", value: indexSettings.index) { newValue in
                store.updateColorArrayIndexNodeSettings(nodeID) { $0.index = newValue }
            }
        }
    }
}

private struct ImageMultiplexorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let arraySettings = store.settings(forImageArrayNodeID: nodeID)
        let indexSettings = store.settings(forImageArrayIndexNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Selects one image or fragment input by index.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
            NumericField(title: "Count", value: Double(arraySettings.count)) { newValue in
                store.updateImageArrayNodeSettings(nodeID) { $0.count = max(1, Int(newValue.rounded())) }
            }
            NumericField(title: "Index", value: indexSettings.index) { newValue in
                store.updateImageArrayIndexNodeSettings(nodeID) { $0.index = newValue }
            }
        }
    }
}

private struct GridLayoutNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forGridLayoutNodeID: nodeID)
        let x = store.scalarOutputValue(forNodeID: nodeID, outputName: "X")
        let y = store.scalarOutputValue(forNodeID: nodeID, outputName: "Y")
        let column = store.scalarOutputValue(forNodeID: nodeID, outputName: "Column")
        let row = store.scalarOutputValue(forNodeID: nodeID, outputName: "Row")

        VStack(alignment: .leading, spacing: 8) {
            Text("Turns an item index into grid column, row, and normalized X/Y position.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(title: "Index", value: settings.index) { newValue in
                store.updateGridLayoutNodeSettings(nodeID) { $0.index = newValue }
            }
            NumericField(title: "Columns", value: settings.columns) { newValue in
                store.updateGridLayoutNodeSettings(nodeID) { $0.columns = newValue }
            }
            NumericField(title: "Origin X", value: settings.originX) { newValue in
                store.updateGridLayoutNodeSettings(nodeID) { $0.originX = newValue }
            }
            NumericField(title: "Origin Y", value: settings.originY) { newValue in
                store.updateGridLayoutNodeSettings(nodeID) { $0.originY = newValue }
            }
            NumericField(title: "Spacing X", value: settings.spacingX) { newValue in
                store.updateGridLayoutNodeSettings(nodeID) { $0.spacingX = newValue }
            }
            NumericField(title: "Spacing Y", value: settings.spacingY) { newValue in
                store.updateGridLayoutNodeSettings(nodeID) { $0.spacingY = newValue }
            }

            HStack {
                Text("Column")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(column.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
            HStack {
                Text("Row")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(row.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
            HStack {
                Text("Point")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text("\(x.map { String(format: "%.3f", $0) } ?? "--"), \(y.map { String(format: "%.3f", $0) } ?? "--")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct PinchNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forPinchNodeID: nodeID)
        let distance = store.scalarOutputValue(forNodeID: nodeID, outputName: "Distance")
        let strength = store.scalarOutputValue(forNodeID: nodeID, outputName: "Strength")
        let pinched = store.scalarOutputValue(forNodeID: nodeID, outputName: "Pinched")

        VStack(alignment: .leading, spacing: 8) {
            Text("Measures finger-to-thumb distance. Use Pinched for click and Strength for pressure-like control.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updatePinchNodeSettings(nodeID) { $0.threshold = max(0.005, newValue) }
                    }
                ),
                range: 0.01...0.25
            )

            HStack {
                Text("Distance")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(distance.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Strength")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(strength.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Pinched")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(pinched.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ScrollGestureNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScrollGestureNodeID: nodeID)
        let y = store.scalarOutputValue(forNodeID: nodeID, outputName: "Y")

        VStack(alignment: .leading, spacing: 8) {
            Text("Tracks the midpoint of Point A and Point B. Use a second-hand pair like Finger 2 and Thumb 2 for two-finger-style scroll.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateScrollGestureNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Sensitivity",
                value: Binding(
                    get: { settings.sensitivity },
                    set: { newValue in
                        store.updateScrollGestureNodeSettings(nodeID) { $0.sensitivity = newValue }
                    }
                ),
                range: 0.1...5
            )

            Toggle(
                "Invert Y",
                isOn: Binding(
                    get: { settings.invertY },
                    set: { newValue in
                        store.updateScrollGestureNodeSettings(nodeID) { $0.invertY = newValue }
                    }
                )
            )
            .toggleStyle(.switch)
            .font(.caption2)

            HStack {
                Text("Y")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(y.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ZoomGestureNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forZoomGestureNodeID: nodeID)
        let zoom = store.scalarOutputValue(forNodeID: nodeID, outputName: "Zoom")

        VStack(alignment: .leading, spacing: 8) {
            Text("Measures distance between two points and accumulates zoom like a pinch gesture. Feed it into WebView Zoom.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateZoomGestureNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Sensitivity",
                value: Binding(
                    get: { settings.sensitivity },
                    set: { newValue in
                        store.updateZoomGestureNodeSettings(nodeID) { $0.sensitivity = newValue }
                    }
                ),
                range: 0.1...8
            )

            NumericField(
                title: "Initial Zoom",
                value: settings.initialZoom,
                onSubmit: { newValue in
                    store.updateZoomGestureNodeSettings(nodeID) { $0.initialZoom = newValue }
                }
            )

            HStack(spacing: 8) {
                NumericField(
                    title: "Min Zoom",
                    value: settings.minZoom,
                    onSubmit: { newValue in
                        store.updateZoomGestureNodeSettings(nodeID) { $0.minZoom = newValue }
                    }
                )
                NumericField(
                    title: "Max Zoom",
                    value: settings.maxZoom,
                    onSubmit: { newValue in
                        store.updateZoomGestureNodeSettings(nodeID) { $0.maxZoom = newValue }
                    }
                )
            }

            HStack {
                Text("Zoom")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(zoom.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct TrackballNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forTrackballNodeID: nodeID)
        let orbit = store.scalarOutputValue(forNodeID: nodeID, outputName: "Orbit")
        let pitch = store.scalarOutputValue(forNodeID: nodeID, outputName: "Pitch")
        let panX = store.scalarOutputValue(forNodeID: nodeID, outputName: "Pan X")
        let panY = store.scalarOutputValue(forNodeID: nodeID, outputName: "Pan Y")
        let distance = store.scalarOutputValue(forNodeID: nodeID, outputName: "Distance")
        let rotationX = store.scalarOutputValue(forNodeID: nodeID, outputName: "Rotation X")
        let rotationY = store.scalarOutputValue(forNodeID: nodeID, outputName: "Rotation Y")
        let dragging = store.scalarOutputValue(forNodeID: nodeID, outputName: "Dragging") ?? 0.0

        VStack(alignment: .leading, spacing: 8) {
            Text("Drag over a live preview. Plain drag updates orbit and object rotation. Option-Shift drag pans. Scroll changes distance.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            LabeledSlider(
                title: "Sensitivity",
                value: Binding(
                    get: { settings.sensitivity },
                    set: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.sensitivity = newValue }
                    }
                ),
                range: 0.1...4
            )

            LabeledSlider(
                title: "Pan Sensitivity",
                value: Binding(
                    get: { settings.panSensitivity },
                    set: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.panSensitivity = newValue }
                    }
                ),
                range: 0.1...20
            )

            LabeledSlider(
                title: "Zoom Sensitivity",
                value: Binding(
                    get: { settings.zoomSensitivity },
                    set: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.zoomSensitivity = newValue }
                    }
                ),
                range: 0.05...10
            )

            Toggle(
                "Invert Y",
                isOn: Binding(
                    get: { settings.invertY },
                    set: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.invertY = newValue }
                    }
                )
            )
            .toggleStyle(.switch)
            .font(.caption2)

            HStack(spacing: 8) {
                NumericField(
                    title: "Start Orbit",
                    value: settings.initialOrbit,
                    onSubmit: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.initialOrbit = newValue }
                    }
                )
                NumericField(
                    title: "Start Pitch",
                    value: settings.initialPitch,
                    onSubmit: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.initialPitch = newValue }
                    }
                )
            }

            HStack(spacing: 8) {
                NumericField(
                    title: "Start Distance",
                    value: settings.initialDistance,
                    onSubmit: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.initialDistance = newValue }
                    }
                )
                NumericField(
                    title: "Min Distance",
                    value: settings.minDistance,
                    onSubmit: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.minDistance = newValue }
                    }
                )
                NumericField(
                    title: "Max Distance",
                    value: settings.maxDistance,
                    onSubmit: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.maxDistance = newValue }
                    }
                )
            }

            HStack(spacing: 8) {
                NumericField(
                    title: "Start Pan X",
                    value: settings.initialPanX,
                    onSubmit: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.initialPanX = newValue }
                    }
                )
                NumericField(
                    title: "Start Pan Y",
                    value: settings.initialPanY,
                    onSubmit: { newValue in
                        store.updateTrackballNodeSettings(nodeID) { $0.initialPanY = newValue }
                    }
                )
            }

            HStack {
                Text("Orbit")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(orbit.map { String(format: "%.2f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Pitch")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(pitch.map { String(format: "%.2f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Pan X")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(panX.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Pan Y")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(panY.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Distance")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(distance.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Rotation X")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(rotationX.map { String(format: "%.2f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Rotation Y")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(rotationY.map { String(format: "%.2f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text("Dragging")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(dragging >= 0.5 ? "1" : "0")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(dragging >= 0.5 ? .green : .white.opacity(0.85))
            }
        }
    }
}

private struct DepthEstimateNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forDepthEstimateNodeID: nodeID)
        let depth = store.scalarOutputValue(forNodeID: nodeID, outputName: "Depth") ?? 0.0
        let span = store.scalarOutputValue(forNodeID: nodeID, outputName: "Span") ?? 0.0
        let touching = (store.scalarOutputValue(forNodeID: nodeID, outputName: "Touching") ?? 0.0) >= 0.5

        VStack(alignment: .leading, spacing: 10) {
            Text("Infers near/far depth from finger-to-thumb span. Higher depth means closer unless Invert is on.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))

            LabeledSlider(
                title: "Near Span",
                value: Binding(
                    get: { settings.nearSpan },
                    set: { newValue in
                        store.updateDepthEstimateNodeSettings(nodeID) { $0.nearSpan = newValue }
                    }
                ),
                range: 0.0...1.0
            )

            LabeledSlider(
                title: "Far Span",
                value: Binding(
                    get: { settings.farSpan },
                    set: { newValue in
                        store.updateDepthEstimateNodeSettings(nodeID) { $0.farSpan = newValue }
                    }
                ),
                range: 0.0...1.0
            )

            LabeledSlider(
                title: "Smoothing",
                value: Binding(
                    get: { settings.smoothing },
                    set: { newValue in
                        store.updateDepthEstimateNodeSettings(nodeID) { $0.smoothing = newValue }
                    }
                ),
                range: 0.0...1.0
            )

            LabeledSlider(
                title: "Touch",
                value: Binding(
                    get: { settings.touchThreshold },
                    set: { newValue in
                        store.updateDepthEstimateNodeSettings(nodeID) { $0.touchThreshold = newValue }
                    }
                ),
                range: 0.0...1.0
            )

            Toggle("Invert", isOn: Binding(
                get: { settings.invert },
                set: { newValue in
                    store.updateDepthEstimateNodeSettings(nodeID) { $0.invert = newValue }
                }
            ))
            .toggleStyle(.switch)
            .font(.caption)
            .tint(.teal)

            HStack {
                Text("Depth")
                Spacer()
                Text(String(format: "%.3f", depth))
                    .font(.system(.caption, design: .monospaced))
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))

            HStack {
                Text("Span")
                Spacer()
                Text(String(format: "%.3f", span))
                    .font(.system(.caption, design: .monospaced))
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))

            HStack {
                Text("Touching")
                Spacer()
                Text(touching ? "YES" : "NO")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(touching ? Color.green : Color.white.opacity(0.7))
            }
            .font(.caption)
        }
    }
}

private struct MathNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forMathNodeID: nodeID)
        let result = store.scalarOutputValue(forNodeID: nodeID, outputName: "Result")

        VStack(alignment: .leading, spacing: 8) {
            Text("Applies scalar math to A and B, with unary modes like sin, cos, round, floor, and ceil using only A.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Picker(
                "Mode",
                selection: Binding(
                    get: { settings.operation },
                    set: { newValue in
                        store.updateMathNodeSettings(nodeID) { $0.operation = newValue }
                    }
                )
            ) {
                ForEach(MathOperation.allCases) { operation in
                    Text(operation.label).tag(operation)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("Result")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ExpressionNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    @State private var expressionDraft = ""
    @State private var draftNodeID: GraphNode.ID?

    var body: some View {
        let settings = store.settings(forExpressionNodeID: nodeID)
        let result = store.scalarOutputValue(forNodeID: nodeID, outputName: "Result")
        let variableNames = settings.variables.keys.sorted()

        VStack(alignment: .leading, spacing: 8) {
            Text("Writes a scalar formula with named inputs. Good for circle math, offsets, and quick debug formulas in normalized 0 to 1 space.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            VStack(alignment: .leading, spacing: 4) {
                Text("Expression")
                    .font(.caption.weight(.semibold))

                TextEditor(
                    text: Binding(
                        get: { expressionDraft },
                        set: { newValue in
                            expressionDraft = newValue
                            draftNodeID = nodeID
                            store.updateExpressionNodeSettings(nodeID) { $0.expression = newValue }
                        }
                    )
                )
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 48)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .onAppear {
                if draftNodeID != nodeID {
                    expressionDraft = settings.expression
                    draftNodeID = nodeID
                }
            }
            .onChange(of: nodeID) { _, newNodeID in
                let newSettings = store.settings(forExpressionNodeID: newNodeID)
                expressionDraft = newSettings.expression
                draftNodeID = newNodeID
            }
            .onChange(of: settings.expression) { _, newValue in
                guard draftNodeID == nodeID else { return }
                if expressionDraft != newValue {
                    expressionDraft = newValue
                }
            }

            Text("Functions: sin cos tan abs sqrt min max clamp floor ceil round pow. Constants: pi, tau. Center is usually 0.5, 0.5.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))

            ForEach(variableNames, id: \.self) { name in
                NumericField(title: name, value: settings.variables[name] ?? 0.0) { newValue in
                    store.updateExpressionNodeSettings(nodeID) { $0.variables[name] = newValue }
                }
            }

            HStack {
                Text("Result")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ClampNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forClampNodeID: nodeID)
        let result = store.scalarOutputValue(forNodeID: nodeID, outputName: "Result")

        VStack(alignment: .leading, spacing: 8) {
            Text("Clamps Value between Min and Max.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(
                title: "Min",
                value: settings.minimum,
                onSubmit: { newValue in
                    store.updateClampNodeSettings(nodeID) { $0.minimum = newValue }
                }
            )

            NumericField(
                title: "Max",
                value: settings.maximum,
                onSubmit: { newValue in
                    store.updateClampNodeSettings(nodeID) { $0.maximum = newValue }
                }
            )

            HStack {
                Text("Result")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct MapRangeNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forMapRangeNodeID: nodeID)
        let result = store.scalarOutputValue(forNodeID: nodeID, outputName: "Result")

        VStack(alignment: .leading, spacing: 8) {
            Text("Remaps Value from one range into another.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(
                title: "In Min",
                value: settings.inputMinimum,
                onSubmit: { newValue in
                    store.updateMapRangeNodeSettings(nodeID) { $0.inputMinimum = newValue }
                }
            )

            NumericField(
                title: "In Max",
                value: settings.inputMaximum,
                onSubmit: { newValue in
                    store.updateMapRangeNodeSettings(nodeID) { $0.inputMaximum = newValue }
                }
            )

            NumericField(
                title: "Out Min",
                value: settings.outputMinimum,
                onSubmit: { newValue in
                    store.updateMapRangeNodeSettings(nodeID) { $0.outputMinimum = newValue }
                }
            )

            NumericField(
                title: "Out Max",
                value: settings.outputMaximum,
                onSubmit: { newValue in
                    store.updateMapRangeNodeSettings(nodeID) { $0.outputMaximum = newValue }
                }
            )

            HStack {
                Text("Result")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct LogicNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forLogicNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            Text("Combines scalar inputs as booleans. Values at or above Threshold count as true.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Picker(
                "Mode",
                selection: Binding(
                    get: { settings.operation },
                    set: { newValue in
                        store.updateLogicNodeSettings(nodeID) { $0.operation = newValue }
                    }
                )
            ) {
                ForEach(LogicOperation.allCases) { operation in
                    Text(operation.label).tag(operation)
                }
            }
            .pickerStyle(.segmented)

            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateLogicNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct CompareNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forCompareNodeID: nodeID)
        let result = store.scalarOutputValue(forNodeID: nodeID, outputName: "Result")

        VStack(alignment: .leading, spacing: 8) {
            Text("Compares the incoming scalar against a number and outputs 1 or 0.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Picker(
                "Mode",
                selection: Binding(
                    get: { settings.operation },
                    set: { newValue in
                        store.updateCompareNodeSettings(nodeID) { $0.operation = newValue }
                    }
                )
            ) {
                ForEach(CompareOperation.allCases) { operation in
                    Text(operation.label).tag(operation)
                }
            }
            .pickerStyle(.segmented)

            NumericField(
                title: "Number",
                value: settings.referenceValue,
                onSubmit: { newValue in
                    store.updateCompareNodeSettings(nodeID) { $0.referenceValue = newValue }
                }
            )

            if settings.operation == .equal || settings.operation == .notEqual {
                NumericField(
                    title: "Threshold",
                    value: settings.epsilon,
                    onSubmit: { newValue in
                        store.updateCompareNodeSettings(nodeID) { $0.epsilon = newValue }
                    }
                )
            }

            HStack {
                Text("Result")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct RandomNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forRandomNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            Text("Generates a random scalar continuously at Rate, or while Trigger stays above the threshold.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Toggle(
                "Continuous",
                isOn: Binding(
                    get: { settings.continuous },
                    set: { newValue in
                        store.updateRandomNodeSettings(nodeID) { $0.continuous = newValue }
                    }
                )
            )
            .toggleStyle(.switch)

            NumericField(title: "Min", value: settings.min) { newValue in
                store.updateRandomNodeSettings(nodeID) { $0.min = newValue }
            }

            NumericField(title: "Max", value: settings.max) { newValue in
                store.updateRandomNodeSettings(nodeID) { $0.max = newValue }
            }

            NumericField(title: "Trigger", value: settings.trigger) { newValue in
                store.updateRandomNodeSettings(nodeID) { $0.trigger = newValue }
            }

            NumericField(title: "Rate", value: settings.rate) { newValue in
                store.updateRandomNodeSettings(nodeID) { $0.rate = newValue }
            }

            LabeledSlider(
                title: "Trigger Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateRandomNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct PulseNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forPulseNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs 1 for one frame when Gate crosses above Threshold.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(title: "Gate", value: settings.gate) { newValue in
                store.updatePulseNodeSettings(nodeID) { $0.gate = newValue }
            }

            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updatePulseNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct CounterNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forCounterNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            Text("Counts by Step on each trigger edge, with reset and optional wrap.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Toggle(
                "Wrap",
                isOn: Binding(
                    get: { settings.wrap },
                    set: { newValue in
                        store.updateCounterNodeSettings(nodeID) { $0.wrap = newValue }
                    }
                )
            )
            .toggleStyle(.switch)

            NumericField(title: "Trigger", value: settings.trigger) { newValue in
                store.updateCounterNodeSettings(nodeID) { $0.trigger = newValue }
            }
            NumericField(title: "Reset", value: settings.reset) { newValue in
                store.updateCounterNodeSettings(nodeID) { $0.reset = newValue }
            }
            NumericField(title: "Step", value: settings.step) { newValue in
                store.updateCounterNodeSettings(nodeID) { $0.step = newValue }
            }
            NumericField(title: "Min", value: settings.minimum) { newValue in
                store.updateCounterNodeSettings(nodeID) { $0.minimum = newValue }
            }
            NumericField(title: "Max", value: settings.maximum) { newValue in
                store.updateCounterNodeSettings(nodeID) { $0.maximum = newValue }
            }
            NumericField(title: "Initial", value: settings.initialValue) { newValue in
                store.updateCounterNodeSettings(nodeID) { $0.initialValue = newValue }
            }
            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateCounterNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ToggleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forToggleNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            Text("Flips between 0 and 1 each time Trigger rises.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Toggle(
                "Initial On",
                isOn: Binding(
                    get: { settings.initialOn },
                    set: { newValue in
                        store.updateToggleNodeSettings(nodeID) { $0.initialOn = newValue }
                    }
                )
            )
            .toggleStyle(.switch)

            NumericField(title: "Trigger", value: settings.trigger) { newValue in
                store.updateToggleNodeSettings(nodeID) { $0.trigger = newValue }
            }
            NumericField(title: "Reset", value: settings.reset) { newValue in
                store.updateToggleNodeSettings(nodeID) { $0.reset = newValue }
            }
            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateToggleNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct DelayNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forDelayNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs a one-frame pulse after the delay duration.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(title: "Trigger", value: settings.trigger) { newValue in
                store.updateDelayNodeSettings(nodeID) { $0.trigger = newValue }
            }
            NumericField(title: "Duration", value: settings.duration) { newValue in
                store.updateDelayNodeSettings(nodeID) { $0.duration = newValue }
            }
            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateDelayNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct TimerNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forTimerNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs a repeating pulse every Interval seconds while enabled.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(title: "Enabled", value: settings.enabled) { newValue in
                store.updateTimerNodeSettings(nodeID) { $0.enabled = newValue }
            }
            NumericField(title: "Interval", value: settings.interval) { newValue in
                store.updateTimerNodeSettings(nodeID) { $0.interval = newValue }
            }
            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateTimerNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct KeyboardNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forKeyboardNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Pressed")

        VStack(alignment: .leading, spacing: 8) {
            Text("Outputs 1 while the selected key is held and all enabled modifiers are down.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            Picker(
                "Key",
                selection: Binding(
                    get: { settings.key },
                    set: { newValue in
                        store.updateKeyboardNodeSettings(nodeID) { $0.key = newValue }
                    }
                )
            ) {
                ForEach(KeyboardKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.menu)

            Toggle(
                "Command",
                isOn: Binding(
                    get: { settings.requiresCommand },
                    set: { newValue in
                        store.updateKeyboardNodeSettings(nodeID) { $0.requiresCommand = newValue }
                    }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "Option",
                isOn: Binding(
                    get: { settings.requiresOption },
                    set: { newValue in
                        store.updateKeyboardNodeSettings(nodeID) { $0.requiresOption = newValue }
                    }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "Shift",
                isOn: Binding(
                    get: { settings.requiresShift },
                    set: { newValue in
                        store.updateKeyboardNodeSettings(nodeID) { $0.requiresShift = newValue }
                    }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "Control",
                isOn: Binding(
                    get: { settings.requiresControl },
                    set: { newValue in
                        store.updateKeyboardNodeSettings(nodeID) { $0.requiresControl = newValue }
                    }
                )
            )
            .toggleStyle(.switch)

            HStack {
                Text("Pressed")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(value.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct StringNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forStringNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Constant string output.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            TextField(
                "Text",
                text: Binding(
                    get: { settings.value },
                    set: { newValue in
                        store.updateStringNodeSettings(nodeID) { $0.value = newValue }
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .lineLimit(3...)
        }
    }
}

private struct ScalarVariableNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScalarVariableNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            NumericField(title: "Value", value: settings.value) { newValue in
                store.updateScalarVariableNodeSettings(nodeID) { $0.value = newValue }
            }
            Slider(
                value: Binding(
                    get: { settings.value },
                    set: { newValue in
                        store.updateScalarVariableNodeSettings(nodeID) { $0.value = newValue }
                    }
                ),
                in: -10.0...10.0
            )
            HStack {
                Text("Out")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(String(format: "%.3f", settings.value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
    }
}

private struct StringVariableNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forStringVariableNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Text",
                text: Binding(
                    get: { settings.value },
                    set: { newValue in
                        store.updateStringVariableNodeSettings(nodeID) { $0.value = newValue }
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .lineLimit(2...)
        }
    }
}

private struct StringFormatNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forStringFormatNodeID: nodeID)
        let preview = store.stringOutputValue(forNodeID: nodeID, outputName: "Result") ?? settings.template

        VStack(alignment: .leading, spacing: 8) {
            Text("Use {0}, {1}, {2}, and {3}. Repeating a placeholder reuses the same input.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            TextField(
                "Template",
                text: Binding(
                    get: { settings.template },
                    set: { newValue in
                        store.updateStringFormatNodeSettings(nodeID) { $0.template = newValue }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)

            HStack {
                Text("Preview")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct StringCompareNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forStringCompareNodeID: nodeID)
        let result = store.scalarOutputValue(forNodeID: nodeID, outputName: "Result")

        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "Mode",
                selection: Binding(
                    get: { settings.operation },
                    set: { newValue in
                        store.updateStringCompareNodeSettings(nodeID) { $0.operation = newValue }
                    }
                )
            ) {
                ForEach(StringCompareOperation.allCases) { operation in
                    Text(operation.label).tag(operation)
                }
            }
            .pickerStyle(.menu)

            Toggle(
                "Case Sensitive",
                isOn: Binding(
                    get: { settings.caseSensitive },
                    set: { newValue in
                        store.updateStringCompareNodeSettings(nodeID) { $0.caseSensitive = newValue }
                    }
                )
            )
            .toggleStyle(.switch)
            .font(.caption2)

            HStack {
                Text("Result")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct StringSplitNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forStringSplitNodeID: nodeID)
        let preview = store.stringOutputValue(forNodeID: nodeID, outputName: "Part") ?? ""

        VStack(alignment: .leading, spacing: 8) {
            Text("Splits text and outputs the selected part.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            TextField(
                "Separator",
                text: Binding(
                    get: { settings.separator },
                    set: { newValue in
                        store.updateStringSplitNodeSettings(nodeID) { $0.separator = newValue }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)

            NumericField(
                title: "Index",
                value: settings.index,
                onSubmit: { newValue in
                    store.updateStringSplitNodeSettings(nodeID) { $0.index = max(0.0, newValue.rounded()) }
                }
            )

            HStack {
                Text("Part")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct ColorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forColorNodeID: nodeID)
        let rgba = store.colorOutputValue(forNodeID: nodeID, outputName: "Color") ?? SIMD4<Float>(1, 1, 1, 1)

        VStack(alignment: .leading, spacing: 8) {
            ColorPicker(
                "Color",
                selection: Binding(
                    get: {
                        Color(
                            .displayP3,
                            red: settings.red,
                            green: settings.green,
                            blue: settings.blue,
                            opacity: settings.alpha
                        )
                    },
                    set: { newColor in
                        let converted = rgbaComponents(from: newColor)
                        store.updateColorNodeSettings(nodeID) { updated in
                            updated.red = converted.red
                            updated.green = converted.green
                            updated.blue = converted.blue
                            updated.alpha = converted.alpha
                        }
                    }
                ),
                supportsOpacity: true
            )

            HStack {
                Text("RGBA")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(String(format: "%.2f %.2f %.2f %.2f", rgba.x, rgba.y, rgba.z, rgba.w))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct HSLColorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forHSLColorNodeID: nodeID)
        let rgba = store.colorOutputValue(forNodeID: nodeID, outputName: "Color") ?? SIMD4<Float>(1, 1, 1, 1)

        VStack(alignment: .leading, spacing: 8) {
            NumericField(title: "Hue", value: settings.hue, onSubmit: { newValue in
                store.updateHSLColorNodeSettings(nodeID) { $0.hue = min(max(newValue, 0.0), 1.0) }
            })
            NumericField(title: "Saturation", value: settings.saturation, onSubmit: { newValue in
                store.updateHSLColorNodeSettings(nodeID) { $0.saturation = min(max(newValue, 0.0), 1.0) }
            })
            NumericField(title: "Lightness", value: settings.lightness, onSubmit: { newValue in
                store.updateHSLColorNodeSettings(nodeID) { $0.lightness = min(max(newValue, 0.0), 1.0) }
            })
            NumericField(title: "Alpha", value: settings.alpha, onSubmit: { newValue in
                store.updateHSLColorNodeSettings(nodeID) { $0.alpha = min(max(newValue, 0.0), 1.0) }
            })

            HStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.displayP3, red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z), opacity: Double(rgba.w)))
                    .frame(width: 28, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
                Spacer()
                Text(String(format: "%.2f %.2f %.2f %.2f", rgba.x, rgba.y, rgba.z, rgba.w))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ScalarArrayNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScalarArrayNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Dynamic numeric list.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(title: "Count", value: Double(settings.count), onSubmit: { newValue in
                store.updateScalarArrayNodeSettings(nodeID) { $0.count = max(1, Int(newValue.rounded())) }
            })

            ForEach(Array(settings.values.prefix(settings.count).enumerated()), id: \.offset) { index, value in
                NumericField(title: "Item \(index)", value: value, onSubmit: { newValue in
                    store.updateScalarArrayNodeSettings(nodeID) { settings in
                        if settings.values.indices.contains(index) == false {
                            settings.values += Array(repeating: 0.0, count: index - settings.values.count + 1)
                        }
                        settings.values[index] = newValue
                    }
                })
            }
        }
    }
}

private struct StringArrayNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forStringArrayNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Dynamic text list.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(title: "Count", value: Double(settings.count), onSubmit: { newValue in
                store.updateStringArrayNodeSettings(nodeID) { $0.count = max(1, Int(newValue.rounded())) }
            })

            ForEach(Array(settings.values.prefix(settings.count).enumerated()), id: \.offset) { index, value in
                arrayTextField(title: "Item \(index)", value: value) { newValue in
                    store.updateStringArrayNodeSettings(nodeID) { settings in
                        if settings.values.indices.contains(index) == false {
                            settings.values += Array(repeating: "", count: index - settings.values.count + 1)
                        }
                        settings.values[index] = newValue
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func arrayTextField(title: String, value: String, onChange: @escaping (String) -> Void) -> some View {
        ArrayStringField(title: title, value: value, onChange: onChange)
    }
}

private struct ArrayStringField: View {
    let title: String
    let value: String
    let onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            TextField(title, text: Binding(get: { value }, set: onChange))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }
}

private struct ColorArrayNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forColorArrayNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Dynamic color palette.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(title: "Count", value: Double(settings.count), onSubmit: { newValue in
                store.updateColorArrayNodeSettings(nodeID) { $0.count = max(1, Int(newValue.rounded())) }
            })

            ForEach(Array(settings.values.prefix(settings.count).enumerated()), id: \.offset) { index, value in
                palettePicker(title: "Item \(index)", value: value) { newValue in
                    store.updateColorArrayNodeSettings(nodeID) { settings in
                        if settings.values.indices.contains(index) == false {
                            settings.values += Array(repeating: ArrayColorValue(), count: index - settings.values.count + 1)
                        }
                        settings.values[index] = newValue
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func palettePicker(title: String, value: ArrayColorValue, onChange: @escaping (ArrayColorValue) -> Void) -> some View {
        ColorPicker(
            title,
            selection: Binding(
                get: {
                    Color(
                        .displayP3,
                        red: value.red,
                        green: value.green,
                        blue: value.blue,
                        opacity: value.alpha
                    )
                },
                set: { newColor in
                    let converted = rgbaComponents(from: newColor)
                    onChange(ArrayColorValue(
                        red: converted.red,
                        green: converted.green,
                        blue: converted.blue,
                        alpha: converted.alpha
                    ))
                }
            ),
            supportsOpacity: true
        )
    }
}

private struct ImageArrayNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forImageArrayNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Dynamic visual source list.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            NumericField(title: "Count", value: Double(settings.count), onSubmit: { newValue in
                store.updateImageArrayNodeSettings(nodeID) { $0.count = max(1, Int(newValue.rounded())) }
            })
        }
    }
}

private struct ScalarArrayIndexNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScalarArrayIndexNodeID: nodeID)
        let result = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value")

        VStack(alignment: .leading, spacing: 8) {
            NumericField(
                title: "Index",
                value: settings.index,
                onSubmit: { newValue in
                    store.updateScalarArrayIndexNodeSettings(nodeID) { $0.index = max(0.0, newValue.rounded()) }
                }
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.map { String(format: "%.3f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct StringArrayIndexNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forStringArrayIndexNodeID: nodeID)
        let result = store.stringOutputValue(forNodeID: nodeID, outputName: "Text") ?? ""

        VStack(alignment: .leading, spacing: 8) {
            NumericField(
                title: "Index",
                value: settings.index,
                onSubmit: { newValue in
                    store.updateStringArrayIndexNodeSettings(nodeID) { $0.index = max(0.0, newValue.rounded()) }
                }
            )

            HStack {
                Text("Text")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.isEmpty ? "--" : result)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct ColorArrayIndexNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forColorArrayIndexNodeID: nodeID)
        let rgba = store.colorOutputValue(forNodeID: nodeID, outputName: "Color")

        VStack(alignment: .leading, spacing: 8) {
            NumericField(
                title: "Index",
                value: settings.index,
                onSubmit: { newValue in
                    store.updateColorArrayIndexNodeSettings(nodeID) { $0.index = max(0.0, newValue.rounded()) }
                }
            )

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color(from: rgba))
                    .frame(width: 28, height: 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    }

                Spacer()

                Text(rgba.map { String(format: "%.2f %.2f %.2f %.2f", $0.x, $0.y, $0.z, $0.w) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private func color(from rgba: SIMD4<Float>?) -> Color {
        guard let rgba else { return .clear }
        return Color(
            .displayP3,
            red: Double(rgba.x),
            green: Double(rgba.y),
            blue: Double(rgba.z),
            opacity: Double(rgba.w)
        )
    }
}

private struct ArrayCountNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let result = store.scalarOutputValue(forNodeID: nodeID, outputName: "Count")

        VStack(alignment: .leading, spacing: 8) {
            Text("Counts scalar, string, or color array items.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))

            HStack {
                Text("Count")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(result.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private struct ImageArrayIndexNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forImageArrayIndexNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            NumericField(
                title: "Index",
                value: settings.index,
                onSubmit: { newValue in
                    store.updateImageArrayIndexNodeSettings(nodeID) { $0.index = max(0.0, newValue.rounded()) }
                }
            )

            Text("Outputs one visual source from the connected image array.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
        }
    }
}

private struct TextImageNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    private let availableFonts = NSFontManager.shared.availableFonts.sorted()

    var body: some View {
        let settings = store.settings(forTextImageNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Text",
                text: Binding(
                    get: { settings.text },
                    set: { newValue in
                        store.updateTextImageNodeSettings(nodeID) { $0.text = newValue }
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .lineLimit(3...)

            NumericField(
                title: "Font Size",
                value: settings.fontSize,
                onSubmit: { newValue in
                    store.updateTextImageNodeSettings(nodeID) { $0.fontSize = newValue }
                }
            )

            NumericField(
                title: "X",
                value: settings.x,
                onSubmit: { newValue in
                    store.updateTextImageNodeSettings(nodeID) { $0.x = newValue }
                }
            )

            NumericField(
                title: "Y",
                value: settings.y,
                onSubmit: { newValue in
                    store.updateTextImageNodeSettings(nodeID) { $0.y = newValue }
                }
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Font")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Picker("Font", selection: Binding(
                    get: { settings.fontName },
                    set: { newValue in
                        store.updateTextImageNodeSettings(nodeID) { $0.fontName = newValue }
                    }
                )) {
                    Text("System Default").tag("")
                    ForEach(availableFonts, id: \.self) { fontName in
                        Text(fontName).tag(fontName)
                    }
                }
                .pickerStyle(.menu)

                TextField("Optional exact font name", text: Binding(
                    get: { settings.fontName },
                    set: { newValue in
                        store.updateTextImageNodeSettings(nodeID) { $0.fontName = newValue }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            ColorPicker(
                "Text",
                selection: Binding(
                    get: {
                        Color(red: settings.textRed, green: settings.textGreen, blue: settings.textBlue)
                    },
                    set: { newColor in
                        let nsColor = NSColor(newColor)
                        let components = nsColor.usingColorSpace(.deviceRGB) ?? .white
                        store.updateTextImageNodeSettings(nodeID) { settings in
                            settings.textRed = Double(components.redComponent)
                            settings.textGreen = Double(components.greenComponent)
                            settings.textBlue = Double(components.blueComponent)
                        }
                    }
                ),
                supportsOpacity: false
            )
            .font(.caption2)
        }
    }
}

private struct MacroNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forMacroNodeID: nodeID)
        let publishedInputs = settings.publishedInputs.filter(\.isPublished)
        let publishedOutputs = settings.publishedOutputs.filter(\.isPublished)

        VStack(alignment: .leading, spacing: 8) {
            Text("\(settings.childNodeIDs.count) internal nodes")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text("\(settings.publishedInputs.filter(\.isPublished).count) inputs • \(settings.publishedOutputs.filter(\.isPublished).count) outputs")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
            Text("Double-click a visible macro port to rename it. Right-click a macro port to unpublish it. While editing inside the macro, right-click an internal port to publish it.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))

            if publishedInputs.isEmpty == false {
                PublishedPortsList(
                    title: "Published Inputs",
                    ports: publishedInputs.map { ($0.macroPortID, $0.name) },
                    onUnpublish: { portID in
                        store.updateMacroInputPort(portID, on: nodeID, isPublished: false)
                    }
                )
            }

            if publishedOutputs.isEmpty == false {
                PublishedPortsList(
                    title: "Published Outputs",
                    ports: publishedOutputs.map { ($0.macroPortID, $0.name) },
                    onUnpublish: { portID in
                        store.updateMacroOutputPort(portID, on: nodeID, isPublished: false)
                    }
                )
            }
        }
    }
}

private struct IteratorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forIteratorNodeID: nodeID)
        let publishedInputs = settings.publishedInputs.filter(\.isPublished)
        let publishedOutputs = settings.publishedOutputs.filter(\.isPublished)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Iterations")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                NumericField(title: "", value: settings.iterations, onSubmit: { newValue in
                    store.updateIteratorNodeSettings(nodeID) { $0.iterations = max(1.0, min(128.0, newValue.rounded())) }
                })
                .frame(width: 88)
            }

            Text("\(settings.childNodeIDs.count) internal nodes")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text("\(settings.publishedInputs.filter(\.isPublished).count) inputs • \(settings.publishedOutputs.filter(\.isPublished).count) outputs")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
            Text("Double-click the iterator to edit it. Add Iterator Variables inside and publish the ports you want on the container.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))

            if publishedInputs.isEmpty == false {
                PublishedPortsList(
                    title: "Published Inputs",
                    ports: publishedInputs.map { ($0.macroPortID, $0.name) },
                    onUnpublish: { portID in
                        store.updateIteratorInputPort(portID, on: nodeID, isPublished: false)
                    }
                )
            }

            if publishedOutputs.isEmpty == false {
                PublishedPortsList(
                    title: "Published Outputs",
                    ports: publishedOutputs.map { ($0.macroPortID, $0.name) },
                    onUnpublish: { portID in
                        store.updateIteratorOutputPort(portID, on: nodeID, isPublished: false)
                    }
                )
            }
        }
    }
}

private struct PublishedPortsList: View {
    let title: String
    let ports: [(id: GraphPort.ID, name: String)]
    let onUnpublish: (GraphPort.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))

            ForEach(ports, id: \.id) { port in
                HStack(spacing: 8) {
                    Text(port.name)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Unpublish") {
                        onUnpublish(port.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct IteratorVariablesNodeEditor: View {
    var body: some View {
        Text("Outputs live Index, Progress, and Iterations while the iterator renders each pass.")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MIDIOutNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forMIDIOutNodeID: nodeID)
        let destinations = store.midiDestinationNames()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Note")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(store.currentMIDINoteName(for: nodeID))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Picker("Root", selection: Binding(
                get: { settings.rootNote },
                set: { newValue in
                    store.updateMIDIOutNodeSettings(nodeID) { $0.rootNote = newValue }
                }
            )) {
                ForEach(GraphStore.midiRootNotes, id: \.self) { note in
                    Text(note).tag(note)
                }
            }
            .pickerStyle(.menu)

            Picker("Scale", selection: Binding(
                get: { settings.scale },
                set: { newValue in
                    store.updateMIDIOutNodeSettings(nodeID) { $0.scale = newValue }
                }
            )) {
                ForEach(MIDIScaleMode.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 8) {
                Stepper(
                    "Low \(settings.lowOctave)",
                    value: Binding(
                        get: { settings.lowOctave },
                        set: { newValue in
                            store.updateMIDIOutNodeSettings(nodeID) { $0.lowOctave = newValue }
                        }
                    ),
                    in: 0...9
                )
                Stepper(
                    "High \(settings.highOctave)",
                    value: Binding(
                        get: { settings.highOctave },
                        set: { newValue in
                            store.updateMIDIOutNodeSettings(nodeID) { $0.highOctave = newValue }
                        }
                    ),
                    in: 0...9
                )
            }
            .font(.caption2)

            HStack(spacing: 8) {
                Stepper(
                    "Ch \(settings.channel + 1)",
                    value: Binding(
                        get: { settings.channel },
                        set: { newValue in
                            store.updateMIDIOutNodeSettings(nodeID) { $0.channel = newValue }
                        }
                    ),
                    in: 0...15
                )
                Stepper(
                    "Vel \(settings.velocity)",
                    value: Binding(
                        get: { settings.velocity },
                        set: { newValue in
                            store.updateMIDIOutNodeSettings(nodeID) { $0.velocity = newValue }
                        }
                    ),
                    in: 1...127
                )
            }
            .font(.caption2)

            Picker("Destination", selection: Binding(
                get: { settings.destinationName },
                set: { newValue in
                    store.updateMIDIOutNodeSettings(nodeID) { $0.destinationName = newValue }
                }
            )) {
                if destinations.isEmpty {
                    Text("No MIDI outputs").tag("")
                } else {
                    ForEach(destinations, id: \.self) { destination in
                        Text(destination).tag(destination)
                    }
                }
            }
            .pickerStyle(.menu)
        }
    }
}

private struct MIDICCNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forMIDICCNodeID: nodeID)
        let destinations = store.midiDestinationNames()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CC Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(store.currentMIDICCValue(for: nodeID))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 8) {
                Stepper(
                    "CC \(settings.ccNumber)",
                    value: Binding(
                        get: { settings.ccNumber },
                        set: { newValue in
                            store.updateMIDICCNodeSettings(nodeID) { $0.ccNumber = newValue }
                        }
                    ),
                    in: 0...127
                )
                Stepper(
                    "Ch \(settings.channel + 1)",
                    value: Binding(
                        get: { settings.channel },
                        set: { newValue in
                            store.updateMIDICCNodeSettings(nodeID) { $0.channel = newValue }
                        }
                    ),
                    in: 0...15
                )
            }
            .font(.caption2)

            HStack(spacing: 8) {
                NumericField(
                    title: "Min",
                    value: settings.sourceMin,
                    onSubmit: { newValue in
                        store.updateMIDICCNodeSettings(nodeID) { $0.sourceMin = newValue }
                    }
                )
                NumericField(
                    title: "Max",
                    value: settings.sourceMax,
                    onSubmit: { newValue in
                        store.updateMIDICCNodeSettings(nodeID) { $0.sourceMax = newValue }
                    }
                )
            }

            Text("Input values are mapped from Min...Max to MIDI CC 0...127.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))

            Picker("Destination", selection: Binding(
                get: { settings.destinationName },
                set: { newValue in
                    store.updateMIDICCNodeSettings(nodeID) { $0.destinationName = newValue }
                }
            )) {
                if destinations.isEmpty {
                    Text("No MIDI outputs").tag("")
                } else {
                    ForEach(destinations, id: \.self) { destination in
                        Text(destination).tag(destination)
                    }
                }
            }
            .pickerStyle(.menu)
        }
    }
}

private struct MIDIInputCCNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forMIDIInputCCNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Stepper(
                    "CC \(settings.ccNumber)",
                    value: Binding(
                        get: { settings.ccNumber },
                        set: { newValue in
                            store.updateMIDIInputCCNodeSettings(nodeID) { $0.ccNumber = newValue }
                        }
                    ),
                    in: 0...127
                )
                Stepper(
                    "Ch \(settings.channel + 1)",
                    value: Binding(
                        get: { settings.channel },
                        set: { newValue in
                            store.updateMIDIInputCCNodeSettings(nodeID) { $0.channel = newValue }
                        }
                    ),
                    in: 0...15
                )
                .disabled(settings.listenToAllChannels)
            }
            .font(.caption2)

            Toggle("All Channels", isOn: Binding(
                get: { settings.listenToAllChannels },
                set: { newValue in
                    store.updateMIDIInputCCNodeSettings(nodeID) { $0.listenToAllChannels = newValue }
                }
            ))
            .font(.caption)
        }
    }
}

private struct MIDIInputNoteNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forMIDIInputNoteNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Stepper(
                    "Note \(settings.noteNumber)",
                    value: Binding(
                        get: { settings.noteNumber },
                        set: { newValue in
                            store.updateMIDIInputNoteNodeSettings(nodeID) { $0.noteNumber = newValue }
                        }
                    ),
                    in: 0...127
                )
                .disabled(settings.listenToAllNotes)

                Stepper(
                    "Ch \(settings.channel + 1)",
                    value: Binding(
                        get: { settings.channel },
                        set: { newValue in
                            store.updateMIDIInputNoteNodeSettings(nodeID) { $0.channel = newValue }
                        }
                    ),
                    in: 0...15
                )
                .disabled(settings.listenToAllChannels)
            }
            .font(.caption2)

            Toggle("All Notes", isOn: Binding(
                get: { settings.listenToAllNotes },
                set: { newValue in
                    store.updateMIDIInputNoteNodeSettings(nodeID) { $0.listenToAllNotes = newValue }
                }
            ))
            .font(.caption)

            Toggle("All Channels", isOn: Binding(
                get: { settings.listenToAllChannels },
                set: { newValue in
                    store.updateMIDIInputNoteNodeSettings(nodeID) { $0.listenToAllChannels = newValue }
                }
            ))
            .font(.caption)
        }
    }
}

private struct OSCInputNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forOSCInputNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            NumericField(
                title: "Port",
                value: Double(settings.port),
                onSubmit: { newValue in
                    store.updateOSCInputNodeSettings(nodeID) { $0.port = Int(newValue.rounded()) }
                }
            )

            TextField(
                "Address filter",
                text: Binding(
                    get: { settings.address },
                    set: { newValue in
                        store.updateOSCInputNodeSettings(nodeID) { $0.address = newValue }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            Text("Leave address blank to accept any message on the port.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
        }
    }
}

private struct OSCOutputNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forOSCOutputNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Host",
                text: Binding(
                    get: { settings.host },
                    set: { newValue in
                        store.updateOSCOutputNodeSettings(nodeID) { $0.host = newValue }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            NumericField(
                title: "Port",
                value: Double(settings.port),
                onSubmit: { newValue in
                    store.updateOSCOutputNodeSettings(nodeID) { $0.port = Int(newValue.rounded()) }
                }
            )

            TextField(
                "Address",
                text: Binding(
                    get: { settings.address },
                    set: { newValue in
                        store.updateOSCOutputNodeSettings(nodeID) { $0.address = newValue }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            Text("Wire up Float/Int/Text ports in slot order to send mixed OSC arguments on one address.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OSCSendNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forOSCSendNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Host",
                text: Binding(
                    get: { settings.host },
                    set: { newValue in
                        store.updateOSCSendNodeSettings(nodeID) { $0.host = newValue }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            NumericField(
                title: "Port",
                value: Double(settings.port),
                onSubmit: { newValue in
                    store.updateOSCSendNodeSettings(nodeID) { $0.port = Int(newValue.rounded()) }
                }
            )
        }
    }
}

private struct OSCMessageNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forOSCMessageNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Address",
                text: Binding(
                    get: { settings.address },
                    set: { newValue in
                        store.updateOSCMessageNodeSettings(nodeID) { $0.address = newValue }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            Text("Slot order stays Text, then Int, then Float for each value index.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OSCArrayMessageNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forOSCMessageNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Address",
                text: Binding(
                    get: { settings.address },
                    set: { newValue in
                        store.updateOSCMessageNodeSettings(nodeID) { $0.address = newValue }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            Text("Sends every value from the connected scalar array as one OSC float-array message.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OSCBundleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forOSCBundleNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            NumericField(
                title: "Packet Count",
                value: Double(settings.packetCount),
                onSubmit: { newValue in
                    store.updateOSCBundleNodeSettings(nodeID) { $0.packetCount = Int(newValue.rounded()) }
                }
            )

            Text("Increase packet count when you want to bundle more OSC messages before sending.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ImageNodeReadout: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forImageNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text(settings?.filename ?? "No image loaded")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)

            Text(settings.map { ByteCountFormatter.string(fromByteCount: Int64($0.imageData.count), countStyle: .file) } ?? "")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.62))
        }
    }
}

private struct WebViewNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    @State private var draftURL = ""

    var body: some View {
        let settings = store.settings(forWebViewNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("https://example.com", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        applyURL()
                    }
                Button("Go") {
                    applyURL()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button("Open") {
                    applyURL()
                    store.openWebViewWindow(for: nodeID)
                }
                .buttonStyle(.borderedProminent)

                Button("Refresh") {
                    applyURL()
                    store.refreshWebViewWindow(for: nodeID)
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            WebViewSnapshotPreview(imageData: settings.snapshotData)
                .frame(height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(settings.snapshotData.isEmpty ? "No snapshot yet" : settings.lastSnapshotFilename)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)

            Text(settings.statusText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(2)
        }
        .onAppear {
            if draftURL.isEmpty {
                draftURL = settings.urlString
            }
        }
    }

    private func applyURL() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        draftURL = normalized
        store.updateWebViewNodeSettings(nodeID) {
            $0.urlString = normalized
            $0.statusText = "Loading \(normalized)…"
        }
    }
}

private struct WebViewSnapshotPreview: View {
    let imageData: Data

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.32))

            if
                let nsImage = NSImage(data: imageData),
                imageData.isEmpty == false
            {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Open the browser to interact and capture a preview.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(12)
            }
        }
    }
}

private extension NSImage {
    var pngData: Data? {
        guard
            let tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct AIImageNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    @State private var isPresentingImagePlayground = false

    var body: some View {
        let settings = store.settings(forAIImageNodeID: nodeID)
        let statusText = store.aiImageNodeStatus[nodeID] ?? (settings.imageData.isEmpty ? "No generated image yet" : settings.filename)

        VStack(alignment: .leading, spacing: 8) {
            TextField("Prompt", text: Binding(
                get: { settings.prompt },
                set: { newValue in
                    store.updateAIImageNodeSettings(nodeID) { $0.prompt = newValue }
                }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(3, reservesSpace: true)

            Picker("Style", selection: Binding(
                get: { settings.style },
                set: { newValue in
                    store.updateAIImageNodeSettings(nodeID) { $0.style = newValue }
                }
            )) {
                ForEach(AIImageStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.menu)

            Button("Generate") {
                let trimmedPrompt = settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPrompt.isEmpty else {
                    store.generateAIImage(for: nodeID)
                    return
                }

                if #available(macOS 15.1, *), ImagePlaygroundViewController.isAvailable {
                    store.setAIImageNodeStatus("Opening Image Playground...", for: nodeID)
                    isPresentingImagePlayground = true
                } else {
                    store.generateAIImage(for: nodeID)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange.opacity(0.85))

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(3)
        }
        .modifier(AIImagePlaygroundSheetModifier(
            isPresented: $isPresentingImagePlayground,
            prompt: settings.prompt,
            style: settings.style,
            nodeID: nodeID,
            store: store
        ))
    }
}

private struct AIImagePlaygroundSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let prompt: String
    let style: AIImageStyle
    let nodeID: GraphNode.ID
    @ObservedObject var store: GraphStore

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.1, *) {
            let sheet = content.imagePlaygroundSheet(
                isPresented: $isPresented,
                concepts: promptConcepts,
                onCompletion: { url in
                    store.completeAIImageGeneration(for: nodeID, imageURL: url)
                },
                onCancellation: {
                    store.cancelAIImageGeneration(for: nodeID)
                }
            )

            if #available(macOS 15.4, *) {
                sheet.imagePlaygroundGenerationStyle(imagePlaygroundStyle(for: style))
            } else {
                sheet
            }
        } else {
            content
        }
    }

    @available(macOS 15.1, *)
    private var promptConcepts: [ImagePlaygroundConcept] {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return [] }
        return [ImagePlaygroundConcept.text(trimmedPrompt)]
    }

    @available(macOS 15.4, *)
    private func imagePlaygroundStyle(for style: AIImageStyle) -> ImagePlaygroundStyle {
        switch style {
        case .illustration:
            return .illustration
        case .animation:
            return .animation
        case .sketch:
            return .sketch
        }
    }
}

private struct VideoPlayerNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forVideoPlayerNodeID: nodeID)
        let status = store.videoPlayerNodeStatus[nodeID] ?? "Choose a movie file."

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Open") {
                    store.openVideoPlayerPicker(for: nodeID)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange.opacity(0.85))

                Button(settings.isPlaying ? "Pause" : "Play") {
                    store.updateVideoPlayerNodeSettings(nodeID) { current in
                        current.isPlaying.toggle()
                    }
                }
                .buttonStyle(.bordered)

                Button("Stop") {
                    store.updateVideoPlayerNodeSettings(nodeID) { current in
                        current.isPlaying = false
                        current.seekPosition = 0
                    }
                    store.seekVideoPlayerNode(nodeID, toNormalizedTime: 0)
                }
                .buttonStyle(.bordered)
            }

            Toggle("Loop", isOn: Binding(
                get: { settings.isLooping },
                set: { newValue in
                    store.updateVideoPlayerNodeSettings(nodeID) { $0.isLooping = newValue }
                }
            ))
            .toggleStyle(.switch)

            Toggle("Play", isOn: Binding(
                get: { settings.isPlaying },
                set: { newValue in
                    store.updateVideoPlayerNodeSettings(nodeID) { $0.isPlaying = newValue }
                }
            ))
            .toggleStyle(.switch)

            LabeledSlider(
                title: "Rate",
                value: Binding(
                    get: { settings.rate },
                    set: { newValue in
                        store.updateVideoPlayerNodeSettings(nodeID) { $0.rate = newValue }
                    }
                ),
                range: 0...4
            )

            LabeledSlider(
                title: "Seek",
                value: Binding(
                    get: { settings.seekPosition },
                    set: { newValue in
                        store.updateVideoPlayerNodeSettings(nodeID) { $0.seekPosition = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Volume",
                value: Binding(
                    get: { settings.volume },
                    set: { newValue in
                        store.updateVideoPlayerNodeSettings(nodeID) { $0.volume = newValue }
                    }
                ),
                range: 0...1
            )

            Text(settings.filename)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)

            Text(status)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(2)
        }
    }
}

private struct SliderNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forSliderNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField("Label", text: Binding(
                get: { settings.label },
                set: { newValue in
                    store.updateSliderNodeSettings(nodeID) { $0.label = newValue }
                }
            ))
            .textFieldStyle(.roundedBorder)

            LabeledSlider(
                title: "Min",
                value: Binding(
                    get: { settings.min },
                    set: { newValue in
                        store.updateSliderNodeSettings(nodeID) { $0.min = newValue }
                    }
                ),
                range: -50...50
            )
            LabeledSlider(
                title: "Max",
                value: Binding(
                    get: { settings.max },
                    set: { newValue in
                        store.updateSliderNodeSettings(nodeID) { $0.max = newValue }
                    }
                ),
                range: -50...50
            )
            LabeledSlider(
                title: "Value",
                value: Binding(
                    get: { settings.value },
                    set: { newValue in
                        store.updateSliderNodeSettings(nodeID) { $0.value = newValue }
                    }
                ),
                range: settings.min...max(settings.max, settings.min)
            )

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "X",
                    value: Binding(
                        get: { settings.x },
                        set: { newValue in
                            store.updateSliderNodeSettings(nodeID) { $0.x = newValue }
                        }
                    ),
                    range: 0...1
                )

                LabeledSlider(
                    title: "Y",
                    value: Binding(
                        get: { settings.y },
                        set: { newValue in
                            store.updateSliderNodeSettings(nodeID) { $0.y = newValue }
                        }
                    ),
                    range: 0...1
                )
            }

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "Width",
                    value: Binding(
                        get: { settings.width },
                        set: { newValue in
                            store.updateSliderNodeSettings(nodeID) { $0.width = newValue }
                        }
                    ),
                    range: 0.08...1
                )

                LabeledSlider(
                    title: "Height",
                    value: Binding(
                        get: { settings.height },
                        set: { newValue in
                            store.updateSliderNodeSettings(nodeID) { $0.height = newValue }
                        }
                    ),
                    range: 0.04...0.3
                )
            }

            Text("Connect a Slider Style node to the Style port.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct SliderStyleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    private let availableFonts = NSFontManager.shared.availableFonts.sorted()

    var body: some View {
        let settings = store.settings(forSliderStyleNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            ColorPicker("Track", selection: Binding(
                get: { color(red: settings.trackRed, green: settings.trackGreen, blue: settings.trackBlue, alpha: 1.0) },
                set: { newColor in
                    store.updateSliderStyleNodeSettings(nodeID) { style in
                        apply(newColor, to: &style.trackRed, &style.trackGreen, &style.trackBlue)
                    }
                }
            ), supportsOpacity: false)

            LabeledSlider(
                title: "Track Size",
                value: Binding(
                    get: { settings.trackThickness },
                    set: { newValue in
                        store.updateSliderStyleNodeSettings(nodeID) { style in
                            style.trackThickness = newValue
                        }
                    }
                ),
                range: 0.08...0.9
            )

            ColorPicker("Knob", selection: Binding(
                get: { color(red: settings.knobRed, green: settings.knobGreen, blue: settings.knobBlue, alpha: 1.0) },
                set: { newColor in
                    store.updateSliderStyleNodeSettings(nodeID) { style in
                        apply(newColor, to: &style.knobRed, &style.knobGreen, &style.knobBlue)
                    }
                }
            ), supportsOpacity: false)

            LabeledSlider(
                title: "Knob Size",
                value: Binding(
                    get: { settings.knobScale },
                    set: { newValue in
                        store.updateSliderStyleNodeSettings(nodeID) { style in
                            style.knobScale = newValue
                        }
                    }
                ),
                range: 0.35...2.0
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Knob Symbol")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                TextField("Optional SF Symbol", text: Binding(
                    get: { settings.knobSymbol },
                    set: { newValue in
                        store.updateSliderStyleNodeSettings(nodeID) { style in
                            style.knobSymbol = newValue
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Text("Connect an image source to Knob Image to override the SF Symbol.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))

            ColorPicker("Text", selection: Binding(
                get: { color(red: settings.textRed, green: settings.textGreen, blue: settings.textBlue, alpha: 1.0) },
                set: { newColor in
                    store.updateSliderStyleNodeSettings(nodeID) { style in
                        apply(newColor, to: &style.textRed, &style.textGreen, &style.textBlue)
                    }
                }
            ), supportsOpacity: false)

            LabeledSlider(
                title: "Font Size",
                value: Binding(
                    get: { settings.fontSize },
                    set: { newValue in
                        store.updateSliderStyleNodeSettings(nodeID) { style in
                            style.fontSize = newValue
                        }
                    }
                ),
                range: 0.12...0.4
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Font Weight")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Picker("Font Weight", selection: Binding(
                    get: { settings.fontWeight },
                    set: { newValue in
                        store.updateSliderStyleNodeSettings(nodeID) { style in
                            style.fontWeight = newValue
                        }
                    }
                )) {
                    ForEach(SliderFontWeight.allCases) { weight in
                        Text(weight.label).tag(weight)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Font")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Picker("Font", selection: Binding(
                    get: { settings.fontName },
                    set: { newValue in
                        store.updateSliderStyleNodeSettings(nodeID) { style in
                            style.fontName = newValue
                        }
                    }
                )) {
                    Text("System Default").tag("")
                    ForEach(availableFonts, id: \.self) { fontName in
                        Text(fontName).tag(fontName)
                    }
                }
                .pickerStyle(.menu)

                TextField("Optional exact font name", text: Binding(
                    get: { settings.fontName },
                    set: { newValue in
                        store.updateSliderStyleNodeSettings(nodeID) { style in
                            style.fontName = newValue
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func color(red: Double, green: Double, blue: Double, alpha: Double) -> Color {
        Color(.displayP3, red: red, green: green, blue: blue, opacity: alpha)
    }

    private func apply(_ color: Color, to red: inout Double, _ green: inout Double, _ blue: inout Double, _ alpha: inout Double) {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        red = Double(nsColor.redComponent)
        green = Double(nsColor.greenComponent)
        blue = Double(nsColor.blueComponent)
        alpha = Double(nsColor.alphaComponent)
    }

    private func apply(_ color: Color, to red: inout Double, _ green: inout Double, _ blue: inout Double) {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        red = Double(nsColor.redComponent)
        green = Double(nsColor.greenComponent)
        blue = Double(nsColor.blueComponent)
    }
}

private struct ButtonNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forButtonNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: Binding(
                get: { settings.title },
                set: { newValue in
                    store.updateButtonNodeSettings(nodeID) { $0.title = newValue }
                }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("SF Symbol", text: Binding(
                get: { settings.sfSymbol },
                set: { newValue in
                    store.updateButtonNodeSettings(nodeID) { $0.sfSymbol = newValue }
                }
            ))
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "X",
                    value: Binding(
                        get: { settings.x },
                        set: { newValue in
                            store.updateButtonNodeSettings(nodeID) { $0.x = newValue }
                        }
                    ),
                    range: 0...1
                )

                LabeledSlider(
                    title: "Y",
                    value: Binding(
                        get: { settings.y },
                        set: { newValue in
                            store.updateButtonNodeSettings(nodeID) { $0.y = newValue }
                        }
                    ),
                    range: 0...1
                )
            }

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "Width",
                    value: Binding(
                        get: { settings.width },
                        set: { newValue in
                            store.updateButtonNodeSettings(nodeID) { $0.width = newValue }
                        }
                    ),
                    range: 0.06...0.6
                )

                LabeledSlider(
                    title: "Height",
                    value: Binding(
                        get: { settings.height },
                        set: { newValue in
                            store.updateButtonNodeSettings(nodeID) { $0.height = newValue }
                        }
                    ),
                    range: 0.05...0.3
                )
            }

            Text("Connect a Button Style node to the Style port.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
        }
    }
}

private struct ButtonStyleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forButtonStyleNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            ColorPicker("Fill", selection: Binding(
                get: { color(red: settings.fillRed, green: settings.fillGreen, blue: settings.fillBlue) },
                set: { newColor in
                    store.updateButtonStyleNodeSettings(nodeID) { style in
                        apply(newColor, to: &style.fillRed, &style.fillGreen, &style.fillBlue)
                    }
                }
            ), supportsOpacity: false)

            ColorPicker("Hover", selection: Binding(
                get: { color(red: settings.hoverRed, green: settings.hoverGreen, blue: settings.hoverBlue) },
                set: { newColor in
                    store.updateButtonStyleNodeSettings(nodeID) { style in
                        apply(newColor, to: &style.hoverRed, &style.hoverGreen, &style.hoverBlue)
                    }
                }
            ), supportsOpacity: false)

            ColorPicker("Pressed", selection: Binding(
                get: { color(red: settings.pressedRed, green: settings.pressedGreen, blue: settings.pressedBlue) },
                set: { newColor in
                    store.updateButtonStyleNodeSettings(nodeID) { style in
                        apply(newColor, to: &style.pressedRed, &style.pressedGreen, &style.pressedBlue)
                    }
                }
            ), supportsOpacity: false)

            Text("Connect Image, Hover Image, or Pressed Image to override the default button fill by state.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))

            ColorPicker("Text", selection: Binding(
                get: { color(red: settings.textRed, green: settings.textGreen, blue: settings.textBlue) },
                set: { newColor in
                    store.updateButtonStyleNodeSettings(nodeID) { style in
                        apply(newColor, to: &style.textRed, &style.textGreen, &style.textBlue)
                    }
                }
            ), supportsOpacity: false)
        }
    }

    private func color(red: Double, green: Double, blue: Double) -> Color {
        Color(.displayP3, red: red, green: green, blue: blue, opacity: 1.0)
    }

    private func apply(_ color: Color, to red: inout Double, _ green: inout Double, _ blue: inout Double) {
        #if canImport(AppKit)
        let nsColor = NSColor(color)
        let converted = nsColor.usingColorSpace(.displayP3) ?? nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        red = Double(converted.redComponent)
        green = Double(converted.greenComponent)
        blue = Double(converted.blueComponent)
        #endif
    }
}

private func rgbaComponents(from color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double) {
    let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
    return (
        red: Double(nsColor.redComponent),
        green: Double(nsColor.greenComponent),
        blue: Double(nsColor.blueComponent),
        alpha: Double(nsColor.alphaComponent)
    )
}

private struct SelectNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    private var helpText: String {
        guard let node = store.node(withID: nodeID) else {
            return "Below threshold shows A. At or above threshold shows B."
        }

        switch node.kind {
        case .select:
            return "Below threshold shows Source A. At or above threshold shows Source B."
        case .scalarSwitch, .stringSwitch, .colorSwitch:
            return "Below threshold outputs A. At or above threshold outputs B."
        default:
            return "Below threshold shows A. At or above threshold shows B."
        }
    }

    var body: some View {
        let settings = store.settings(forSelectNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            NumericField(title: "Select", value: settings.selectValue) { newValue in
                store.updateSelectNodeSettings(nodeID) { $0.selectValue = newValue }
            }

            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateSelectNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )

            Text(helpText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
        }
    }
}

private struct ScaleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScaleNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(
                title: "Min",
                value: Binding(
                    get: { settings.min },
                    set: { newValue in
                        store.updateScaleNodeSettings(nodeID) { $0.min = newValue }
                    }
                ),
                range: -10...10
            )
            LabeledSlider(
                title: "Max",
                value: Binding(
                    get: { settings.max },
                    set: { newValue in
                        store.updateScaleNodeSettings(nodeID) { $0.max = newValue }
                    }
                ),
                range: -10...10
            )
            LabeledSlider(
                title: "Scaled Min",
                value: Binding(
                    get: { settings.scaledMin },
                    set: { newValue in
                        store.updateScaleNodeSettings(nodeID) { $0.scaledMin = newValue }
                    }
                ),
                range: -50...50
            )
            LabeledSlider(
                title: "Scaled Max",
                value: Binding(
                    get: { settings.scaledMax },
                    set: { newValue in
                        store.updateScaleNodeSettings(nodeID) { $0.scaledMax = newValue }
                    }
                ),
                range: -720...720
            )
            Text("scaledMin + (value - min) * (scaledMax - scaledMin) / (max - min)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
        }
    }
}

private struct InterpolatorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forInterpolatorNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(
                title: "Start",
                value: Binding(
                    get: { settings.start },
                    set: { newValue in
                        store.updateInterpolatorNodeSettings(nodeID) { $0.start = newValue }
                    }
                ),
                range: -720...720
            )
            LabeledSlider(
                title: "End",
                value: Binding(
                    get: { settings.end },
                    set: { newValue in
                        store.updateInterpolatorNodeSettings(nodeID) { $0.end = newValue }
                    }
                ),
                range: -720...720
            )
            LabeledSlider(
                title: "Duration",
                value: Binding(
                    get: { settings.duration },
                    set: { newValue in
                        store.updateInterpolatorNodeSettings(nodeID) { $0.duration = max(0.05, newValue) }
                    }
                ),
                range: 0.05...120,
                clampsToRange: false
            )
            LabeledSlider(
                title: "Phase",
                value: Binding(
                    get: { settings.phase },
                    set: { newValue in
                        store.updateInterpolatorNodeSettings(nodeID) { $0.phase = newValue }
                    }
                ),
                range: -20...20
            )
            Picker(
                "Curve",
                selection: Binding(
                    get: { settings.easing },
                    set: { newValue in
                        store.updateInterpolatorNodeSettings(nodeID) { $0.easing = newValue }
                    }
                )
            ) {
                ForEach(InterpolatorEasing.allCases) { easing in
                    Text(easing.label).tag(easing)
                }
            }
            .pickerStyle(.menu)

            Toggle(
                "Ping-Pong",
                isOn: Binding(
                    get: { settings.autoreverses },
                    set: { newValue in
                        store.updateInterpolatorNodeSettings(nodeID) { $0.autoreverses = newValue }
                    }
                )
            )
            .toggleStyle(.switch)
            .font(.caption)
        }
    }
}

private struct PointInterpolatorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forPointInterpolatorNodeID: nodeID)
        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: "Start X", value: Binding(get: { settings.startX }, set: { newValue in store.updatePointInterpolatorNodeSettings(nodeID) { $0.startX = newValue } }), range: -2...2)
            LabeledSlider(title: "Start Y", value: Binding(get: { settings.startY }, set: { newValue in store.updatePointInterpolatorNodeSettings(nodeID) { $0.startY = newValue } }), range: -2...2)
            LabeledSlider(title: "End X", value: Binding(get: { settings.endX }, set: { newValue in store.updatePointInterpolatorNodeSettings(nodeID) { $0.endX = newValue } }), range: -2...2)
            LabeledSlider(title: "End Y", value: Binding(get: { settings.endY }, set: { newValue in store.updatePointInterpolatorNodeSettings(nodeID) { $0.endY = newValue } }), range: -2...2)
            LabeledSlider(title: "Duration", value: Binding(get: { settings.duration }, set: { newValue in store.updatePointInterpolatorNodeSettings(nodeID) { $0.duration = max(0.05, newValue) } }), range: 0.05...120, clampsToRange: false)
        }
    }
}

private struct Point3InterpolatorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    var body: some View {
        let settings = store.settings(forPoint3InterpolatorNodeID: nodeID)
        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: "Start X", value: Binding(get: { settings.start.x }, set: { newValue in store.updatePoint3InterpolatorNodeSettings(nodeID) { $0.start.x = newValue } }), range: -2...2)
            LabeledSlider(title: "Start Y", value: Binding(get: { settings.start.y }, set: { newValue in store.updatePoint3InterpolatorNodeSettings(nodeID) { $0.start.y = newValue } }), range: -2...2)
            LabeledSlider(title: "Start Z", value: Binding(get: { settings.start.z }, set: { newValue in store.updatePoint3InterpolatorNodeSettings(nodeID) { $0.start.z = newValue } }), range: -2...2)
            LabeledSlider(title: "End X", value: Binding(get: { settings.end.x }, set: { newValue in store.updatePoint3InterpolatorNodeSettings(nodeID) { $0.end.x = newValue } }), range: -2...2)
            LabeledSlider(title: "End Y", value: Binding(get: { settings.end.y }, set: { newValue in store.updatePoint3InterpolatorNodeSettings(nodeID) { $0.end.y = newValue } }), range: -2...2)
            LabeledSlider(title: "End Z", value: Binding(get: { settings.end.z }, set: { newValue in store.updatePoint3InterpolatorNodeSettings(nodeID) { $0.end.z = newValue } }), range: -2...2)
            LabeledSlider(title: "Duration", value: Binding(get: { settings.duration }, set: { newValue in store.updatePoint3InterpolatorNodeSettings(nodeID) { $0.duration = max(0.05, newValue) } }), range: 0.05...120, clampsToRange: false)
        }
    }
}

private struct Point4InterpolatorNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    var body: some View {
        let settings = store.settings(forPoint4InterpolatorNodeID: nodeID)
        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: "Start X", value: Binding(get: { settings.start.x }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.start.x = newValue } }), range: -2...2)
            LabeledSlider(title: "Start Y", value: Binding(get: { settings.start.y }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.start.y = newValue } }), range: -2...2)
            LabeledSlider(title: "Start Z", value: Binding(get: { settings.start.z }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.start.z = newValue } }), range: -2...2)
            LabeledSlider(title: "Start W", value: Binding(get: { settings.start.w }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.start.w = newValue } }), range: -2...2)
            LabeledSlider(title: "End X", value: Binding(get: { settings.end.x }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.end.x = newValue } }), range: -2...2)
            LabeledSlider(title: "End Y", value: Binding(get: { settings.end.y }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.end.y = newValue } }), range: -2...2)
            LabeledSlider(title: "End Z", value: Binding(get: { settings.end.z }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.end.z = newValue } }), range: -2...2)
            LabeledSlider(title: "End W", value: Binding(get: { settings.end.w }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.end.w = newValue } }), range: -2...2)
            LabeledSlider(title: "Duration", value: Binding(get: { settings.duration }, set: { newValue in store.updatePoint4InterpolatorNodeSettings(nodeID) { $0.duration = max(0.05, newValue) } }), range: 0.05...120, clampsToRange: false)
        }
    }
}

private struct PointScaleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    var body: some View {
        let settings = store.settings(forPointScaleNodeID: nodeID)
        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: "X", value: Binding(get: { settings.x }, set: { newValue in store.updatePointScaleNodeSettings(nodeID) { $0.x = newValue } }), range: -2...2)
            LabeledSlider(title: "Y", value: Binding(get: { settings.y }, set: { newValue in store.updatePointScaleNodeSettings(nodeID) { $0.y = newValue } }), range: -2...2)
            LabeledSlider(title: "Scale", value: Binding(get: { settings.scale }, set: { newValue in store.updatePointScaleNodeSettings(nodeID) { $0.scale = newValue } }), range: -10...10)
        }
    }
}

private struct Point3ScaleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    var body: some View {
        let settings = store.settings(forPoint3ScaleNodeID: nodeID)
        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: "X", value: Binding(get: { settings.value.x }, set: { newValue in store.updatePoint3ScaleNodeSettings(nodeID) { $0.value.x = newValue } }), range: -2...2)
            LabeledSlider(title: "Y", value: Binding(get: { settings.value.y }, set: { newValue in store.updatePoint3ScaleNodeSettings(nodeID) { $0.value.y = newValue } }), range: -2...2)
            LabeledSlider(title: "Z", value: Binding(get: { settings.value.z }, set: { newValue in store.updatePoint3ScaleNodeSettings(nodeID) { $0.value.z = newValue } }), range: -2...2)
            LabeledSlider(title: "Scale", value: Binding(get: { settings.scale }, set: { newValue in store.updatePoint3ScaleNodeSettings(nodeID) { $0.scale = newValue } }), range: -10...10)
        }
    }
}

private struct Point4ScaleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    var body: some View {
        let settings = store.settings(forPoint4ScaleNodeID: nodeID)
        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: "X", value: Binding(get: { settings.value.x }, set: { newValue in store.updatePoint4ScaleNodeSettings(nodeID) { $0.value.x = newValue } }), range: -2...2)
            LabeledSlider(title: "Y", value: Binding(get: { settings.value.y }, set: { newValue in store.updatePoint4ScaleNodeSettings(nodeID) { $0.value.y = newValue } }), range: -2...2)
            LabeledSlider(title: "Z", value: Binding(get: { settings.value.z }, set: { newValue in store.updatePoint4ScaleNodeSettings(nodeID) { $0.value.z = newValue } }), range: -2...2)
            LabeledSlider(title: "W", value: Binding(get: { settings.value.w }, set: { newValue in store.updatePoint4ScaleNodeSettings(nodeID) { $0.value.w = newValue } }), range: -2...2)
            LabeledSlider(title: "Scale", value: Binding(get: { settings.scale }, set: { newValue in store.updatePoint4ScaleNodeSettings(nodeID) { $0.scale = newValue } }), range: -10...10)
        }
    }
}

private struct HoldNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forHoldNodeID: nodeID)
        let heldValue = store.scalarOutputValue(forNodeID: nodeID, outputName: "Held") ?? settings.initialValue

        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(
                title: "Threshold",
                value: Binding(
                    get: { settings.threshold },
                    set: { newValue in
                        store.updateHoldNodeSettings(nodeID) { $0.threshold = newValue }
                    }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "Initial",
                value: Binding(
                    get: { settings.initialValue },
                    set: { newValue in
                        store.updateHoldNodeSettings(nodeID) { $0.initialValue = newValue }
                    }
                ),
                range: -20...20
            )
            HStack {
                Text("Held")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.3f", heldValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

private struct ScalarSmoothNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScalarSmoothNodeID: nodeID)
        let value = store.scalarOutputValue(forNodeID: nodeID, outputName: "Value") ?? settings.initialValue

        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: Binding(
                get: { settings.mode },
                set: { newValue in
                    store.updateScalarSmoothNodeSettings(nodeID) { $0.mode = newValue }
                }
            )) {
                ForEach(ScalarSmoothMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            LabeledSlider(
                title: "Amount",
                value: Binding(
                    get: { settings.amount },
                    set: { newValue in
                        store.updateScalarSmoothNodeSettings(nodeID) { $0.amount = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Inertia",
                value: Binding(
                    get: { settings.inertia },
                    set: { newValue in
                        store.updateScalarSmoothNodeSettings(nodeID) { $0.inertia = newValue }
                    }
                ),
                range: 0...0.99
            )

            LabeledSlider(
                title: "Initial",
                value: Binding(
                    get: { settings.initialValue },
                    set: { newValue in
                        store.updateScalarSmoothNodeSettings(nodeID) { $0.initialValue = newValue }
                    }
                ),
                range: -200...200
            )

            HStack {
                Text("Value")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.3f", value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

private struct UnderwaterNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forUnderwaterNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(
                title: "Scale",
                value: Binding(
                    get: { settings.scale },
                    set: { newValue in
                        store.updateUnderwaterNodeSettings(nodeID) { $0.scale = newValue }
                    }
                ),
                range: 0.25...12
            )
            LabeledSlider(
                title: "Distortion",
                value: Binding(
                    get: { settings.distortion },
                    set: { newValue in
                        store.updateUnderwaterNodeSettings(nodeID) { $0.distortion = newValue }
                    }
                ),
                range: 0...0.25
            )
            HStack(spacing: 8) {
                Text("Octaves")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
                Stepper(
                    value: Binding(
                        get: { settings.octaves },
                        set: { newValue in
                            store.updateUnderwaterNodeSettings(nodeID) { $0.octaves = newValue }
                        }
                    ),
                    in: 1...8
                ) {
                    Text("\(settings.octaves)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .labelsHidden()
            }
            LabeledSlider(
                title: "Lacunarity",
                value: Binding(
                    get: { settings.lacunarity },
                    set: { newValue in
                        store.updateUnderwaterNodeSettings(nodeID) { $0.lacunarity = newValue }
                    }
                ),
                range: 1...4
            )
            LabeledSlider(
                title: "Gain",
                value: Binding(
                    get: { settings.gain },
                    set: { newValue in
                        store.updateUnderwaterNodeSettings(nodeID) { $0.gain = newValue }
                    }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "Amplitude",
                value: Binding(
                    get: { settings.amplitude },
                    set: { newValue in
                        store.updateUnderwaterNodeSettings(nodeID) { $0.amplitude = newValue }
                    }
                ),
                range: 0...1.5
            )
            LabeledSlider(
                title: "Texture Scale",
                value: Binding(
                    get: { settings.textureScale },
                    set: { newValue in
                        store.updateUnderwaterNodeSettings(nodeID) { $0.textureScale = newValue }
                    }
                ),
                range: 0.5...2.5
            )
            LabeledSlider(
                title: "Clamp Margin",
                value: Binding(
                    get: { settings.uvClampMargin },
                    set: { newValue in
                        store.updateUnderwaterNodeSettings(nodeID) { $0.uvClampMargin = newValue }
                    }
                ),
                range: 0...0.05
            )
        }
    }
}

private struct CoreImageNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    let kind: GraphNodeKind

    var body: some View {
        let settings = store.settings(forCoreImageNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            if case .coreImage = kind {
                Picker(
                    "Filter",
                    selection: Binding(
                        get: { settings.effect },
                        set: { newValue in
                            store.updateCoreImageNodeSettings(nodeID) { current in
                                let previous = current.effect
                                current.effect = newValue
                                if previous != newValue {
                                    let defaults = defaultSettings(for: newValue)
                                    current.primary = defaults.primary
                                    current.secondary = defaults.secondary
                                }
                            }
                        }
                    )
                ) {
                    ForEach([
                        CoreImageEffectKind.blur,
                        .bloom,
                        .hueRotate,
                        .posterize,
                        .levels,
                        .glow,
                        .edges,
                        .pixellate,
                        .twirl,
                        .kaleidoscope
                    ]) { effect in
                        Text(effect.label).tag(effect)
                    }
                }
                .pickerStyle(.menu)
            }

            LabeledSlider(
                title: primaryLabel,
                value: Binding(
                    get: { settings.primary },
                    set: { newValue in
                        store.updateCoreImageNodeSettings(nodeID) { $0.primary = newValue }
                    }
                ),
                range: primaryRange
            )

            if let secondaryLabel {
                LabeledSlider(
                    title: secondaryLabel,
                    value: Binding(
                        get: { settings.secondary },
                        set: { newValue in
                            store.updateCoreImageNodeSettings(nodeID) { $0.secondary = newValue }
                        }
                    ),
                    range: secondaryRange
                )
            }
        }
    }

    private var resolvedEffect: CoreImageEffectKind {
        switch kind {
        case .coreImage:
            return store.settings(forCoreImageNodeID: nodeID).effect
        case .blur:
            return .blur
        case .bloom:
            return .bloom
        case .hueRotate:
            return .hueRotate
        case .posterize:
            return .posterize
        case .levels:
            return .levels
        case .glow:
            return .glow
        default:
            return .blur
        }
    }

    private var primaryLabel: String {
        switch resolvedEffect {
        case .blur:
            return "Radius"
        case .bloom:
            return "Radius"
        case .hueRotate:
            return "Angle"
        case .posterize:
            return "Levels"
        case .levels:
            return "Black"
        case .glow:
            return "Radius"
        case .edges:
            return "Strength"
        case .pixellate:
            return "Size"
        case .twirl:
            return "Radius"
        case .kaleidoscope:
            return "Segments"
        }
    }

    private var secondaryLabel: String? {
        switch resolvedEffect {
        case .bloom, .glow:
            return "Intensity"
        case .levels:
            return "White"
        case .twirl:
            return "Angle"
        case .kaleidoscope:
            return "Spin"
        default:
            return nil
        }
    }

    private var primaryRange: ClosedRange<Double> {
        switch resolvedEffect {
        case .blur:
            return 0...40
        case .bloom:
            return 0...40
        case .hueRotate:
            return 0...1
        case .posterize:
            return 2...12
        case .levels:
            return 0...1
        case .glow:
            return 0...40
        case .edges:
            return 0...4
        case .pixellate:
            return 2...128
        case .twirl:
            return 0...1
        case .kaleidoscope:
            return 2...24
        }
    }

    private var secondaryRange: ClosedRange<Double> {
        switch resolvedEffect {
        case .bloom, .glow:
            return 0...2
        case .twirl:
            return -1...1
        case .kaleidoscope:
            return -1...1
        default:
            return 0...1
        }
    }

    private func defaultSettings(for effect: CoreImageEffectKind) -> CoreImageNodeSettings {
        switch effect {
        case .blur:
            return CoreImageNodeSettings(effect: .blur, primary: 12.0, secondary: 0.0)
        case .bloom:
            return CoreImageNodeSettings(effect: .bloom, primary: 10.0, secondary: 0.75)
        case .hueRotate:
            return CoreImageNodeSettings(effect: .hueRotate, primary: 0.5, secondary: 0.0)
        case .posterize:
            return CoreImageNodeSettings(effect: .posterize, primary: 4.0, secondary: 0.0)
        case .levels:
            return CoreImageNodeSettings(effect: .levels, primary: 0.0, secondary: 1.0)
        case .glow:
            return CoreImageNodeSettings(effect: .glow, primary: 10.0, secondary: 0.9)
        case .edges:
            return CoreImageNodeSettings(effect: .edges, primary: 1.5, secondary: 0.0)
        case .pixellate:
            return CoreImageNodeSettings(effect: .pixellate, primary: 24.0, secondary: 0.0)
        case .twirl:
            return CoreImageNodeSettings(effect: .twirl, primary: 0.35, secondary: 0.5)
        case .kaleidoscope:
            return CoreImageNodeSettings(effect: .kaleidoscope, primary: 6.0, secondary: 0.0)
        }
    }
}

private struct TrailNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forTrailNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(
                title: "Radius",
                value: Binding(
                    get: { settings.radius },
                    set: { newValue in
                        store.updateTrailNodeSettings(nodeID) { $0.radius = newValue }
                    }
                ),
                range: 0.005...0.15
            )
            LabeledSlider(
                title: "Duration",
                value: Binding(
                    get: { settings.duration },
                    set: { newValue in
                        store.updateTrailNodeSettings(nodeID) { $0.duration = newValue }
                    }
                ),
                range: 0.1...6.0
            )
        }
    }
}

private struct CircleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forCircleNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(
                title: "Radius",
                value: Binding(
                    get: { settings.radius },
                    set: { newValue in
                        store.updateCircleNodeSettings(nodeID) { $0.radius = newValue }
                    }
                ),
                range: 0.003...0.12
            )
            LabeledSlider(
                title: "Softness",
                value: Binding(
                    get: { settings.softness },
                    set: { newValue in
                        store.updateCircleNodeSettings(nodeID) { $0.softness = newValue }
                    }
                ),
                range: 0.0...1.0
            )
            LabeledSlider(
                title: "Alpha",
                value: Binding(
                    get: { settings.alpha },
                    set: { newValue in
                        store.updateCircleNodeSettings(nodeID) { $0.alpha = newValue }
                    }
                ),
                range: 0.0...1.0
            )
            HStack(spacing: 8) {
                LabeledSlider(
                    title: "R",
                    value: Binding(
                        get: { settings.red },
                        set: { newValue in
                            store.updateCircleNodeSettings(nodeID) { $0.red = newValue }
                        }
                    ),
                    range: 0.0...1.0
                )
                LabeledSlider(
                    title: "G",
                    value: Binding(
                        get: { settings.green },
                        set: { newValue in
                            store.updateCircleNodeSettings(nodeID) { $0.green = newValue }
                        }
                    ),
                    range: 0.0...1.0
                )
                LabeledSlider(
                    title: "B",
                    value: Binding(
                        get: { settings.blue },
                        set: { newValue in
                            store.updateCircleNodeSettings(nodeID) { $0.blue = newValue }
                        }
                    ),
                    range: 0.0...1.0
                )
            }
        }
    }
}

private struct NoteNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID
    @State private var draftText: String = ""

    var body: some View {
        let settings = store.settings(forNoteNodeID: nodeID)

        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: Binding(
                get: { draftText },
                set: { newValue in
                    draftText = newValue
                    store.updateNoteNodeSettings(nodeID) { $0.text = newValue }
                }
            ))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 88)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(
                        red: settings.backgroundRed,
                        green: settings.backgroundGreen,
                        blue: settings.backgroundBlue,
                        opacity: settings.backgroundAlpha
                    ))
            )
            .foregroundStyle(Color(
                red: settings.textRed,
                green: settings.textGreen,
                blue: settings.textBlue
            ))
            .onAppear {
                if draftText != settings.text {
                    draftText = settings.text
                }
            }
            .onChange(of: settings.text) { _, newValue in
                if draftText != newValue {
                    draftText = newValue
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Text Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ColorPicker(
                        "Text Color",
                        selection: Binding(
                            get: {
                                Color(
                                    red: settings.textRed,
                                    green: settings.textGreen,
                                    blue: settings.textBlue
                                )
                            },
                            set: { newValue in
                                let components = rgbComponents(from: newValue, fallbackAlpha: 1.0)
                                store.updateNoteNodeSettings(nodeID) {
                                    $0.textRed = components.red
                                    $0.textGreen = components.green
                                    $0.textBlue = components.blue
                                }
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Background")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ColorPicker(
                        "Background",
                        selection: Binding(
                            get: {
                                Color(
                                    red: settings.backgroundRed,
                                    green: settings.backgroundGreen,
                                    blue: settings.backgroundBlue,
                                    opacity: settings.backgroundAlpha
                                )
                            },
                            set: { newValue in
                                let components = rgbComponents(from: newValue, fallbackAlpha: settings.backgroundAlpha)
                                store.updateNoteNodeSettings(nodeID) {
                                    $0.backgroundRed = components.red
                                    $0.backgroundGreen = components.green
                                    $0.backgroundBlue = components.blue
                                    $0.backgroundAlpha = components.alpha
                                }
                            }
                        ),
                        supportsOpacity: true
                    )
                    .labelsHidden()
                }
            }

            LabeledSlider(
                title: "Font",
                value: Binding(
                    get: { settings.fontSize },
                    set: { newValue in
                        store.updateNoteNodeSettings(nodeID) { $0.fontSize = newValue }
                    }
                ),
                range: 12...96
            )
        }
    }

    private func rgbComponents(from color: Color, fallbackAlpha: Double) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return (
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            alpha: Double(nsColor.alphaComponent.isFinite ? nsColor.alphaComponent : CGFloat(fallbackAlpha))
        )
    }
}

private struct FeedbackNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forFeedbackNodeID: nodeID)
        VStack(alignment: .leading, spacing: 10) {
            LabeledSlider(
                title: "Feedback",
                value: Binding(
                    get: { settings.level },
                    set: { newValue in
                        store.updateFeedbackNodeSettings(nodeID) { $0.level = newValue }
                    }
                ),
                range: 0.0...0.999
            )

            Picker("Blend", selection: Binding(
                get: { settings.blendMode },
                set: { newValue in
                    store.updateFeedbackNodeSettings(nodeID) { $0.blendMode = newValue }
                }
            )) {
                ForEach(FeedbackBlendMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text("Feedback uses the previous frame of this node. Higher values keep longer trails; Add is bright, Screen is softer, Multiply is darker.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
        }
    }
}

private struct ReactionDiffusionNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forReactionDiffusionNodeID: nodeID)
        VStack(alignment: .leading, spacing: 10) {
            LabeledSlider(
                title: "Feed",
                value: Binding(
                    get: { settings.feed },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.feed = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Kill",
                value: Binding(
                    get: { settings.kill },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.kill = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Diffusion A",
                value: Binding(
                    get: { settings.diffusionA },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.diffusionA = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Diffusion B",
                value: Binding(
                    get: { settings.diffusionB },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.diffusionB = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Speed",
                value: Binding(
                    get: { settings.speed },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.speed = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Seed",
                value: Binding(
                    get: { settings.seed },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.seed = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Input Drive",
                value: Binding(
                    get: { settings.inputDrive },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.inputDrive = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Display Boost",
                value: Binding(
                    get: { settings.displayBoost },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.displayBoost = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Hue Shift",
                value: Binding(
                    get: { settings.hueShift },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.hueShift = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Saturation",
                value: Binding(
                    get: { settings.saturation },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.saturation = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Source Color",
                value: Binding(
                    get: { settings.sourceColor },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.sourceColor = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Reset",
                value: Binding(
                    get: { settings.reset },
                    set: { newValue in
                        store.updateReactionDiffusionNodeSettings(nodeID) { $0.reset = newValue }
                    }
                ),
                range: 0...1
            )

            ColorPicker(
                "Tint",
                selection: Binding(
                    get: {
                        Color(red: settings.red, green: settings.green, blue: settings.blue, opacity: settings.alpha)
                    },
                    set: { newValue in
                        let components = rgbaComponents(from: newValue)
                        store.updateReactionDiffusionNodeSettings(nodeID) { settings in
                            settings.red = components.red
                            settings.green = components.green
                            settings.blue = components.blue
                            settings.alpha = components.alpha
                        }
                    }
                ),
                supportsOpacity: true
            )
            .font(.caption.weight(.semibold))

            Text("This node owns its simulation feedback internally. Use Reset above 0.5 to reseed, then return it to 0.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
        }
    }
}

private struct TransformNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forTransformNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LabeledSlider(
                    title: "X",
                    value: Binding(
                        get: { settings.x },
                        set: { newValue in
                            store.updateTransformNodeSettings(nodeID) { $0.x = newValue }
                        }
                    ),
                    range: -1...2
                )
                LabeledSlider(
                    title: "Y",
                    value: Binding(
                        get: { settings.y },
                        set: { newValue in
                            store.updateTransformNodeSettings(nodeID) { $0.y = newValue }
                        }
                    ),
                    range: -1...2
                )
            }

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "Scale X",
                    value: Binding(
                        get: { settings.scaleX },
                        set: { newValue in
                            store.updateTransformNodeSettings(nodeID) { $0.scaleX = newValue }
                        }
                    ),
                    range: 0.05...2.0
                )
                LabeledSlider(
                    title: "Scale Y",
                    value: Binding(
                        get: { settings.scaleY },
                        set: { newValue in
                            store.updateTransformNodeSettings(nodeID) { $0.scaleY = newValue }
                        }
                    ),
                    range: 0.05...2.0
                )
            }

            LabeledSlider(
                title: "Rot Z",
                value: Binding(
                    get: { settings.rotationZ },
                    set: { newValue in
                        store.updateTransformNodeSettings(nodeID) { $0.rotationZ = newValue }
                    }
                ),
                range: -180...180
            )

            LabeledSlider(
                title: "Opacity",
                value: Binding(
                    get: { settings.opacity },
                    set: { newValue in
                        store.updateTransformNodeSettings(nodeID) { $0.opacity = newValue }
                    }
                ),
                range: 0...1
            )
        }
    }
}

private struct BillboardNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forBillboardNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LabeledSlider(
                    title: "X",
                    value: Binding(
                        get: { settings.x },
                        set: { newValue in
                            store.updateBillboardNodeSettings(nodeID) { $0.x = newValue }
                        }
                    ),
                    range: -1...2
                )
                LabeledSlider(
                    title: "Y",
                    value: Binding(
                        get: { settings.y },
                        set: { newValue in
                            store.updateBillboardNodeSettings(nodeID) { $0.y = newValue }
                        }
                    ),
                    range: -1...2
                )
            }

            LabeledSlider(
                title: "Z",
                value: Binding(
                    get: { settings.z },
                    set: { newValue in
                        store.updateBillboardNodeSettings(nodeID) { $0.z = newValue }
                    }
                ),
                range: -20...20
            )

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "Width",
                    value: Binding(
                        get: { settings.width },
                        set: { newValue in
                            store.updateBillboardNodeSettings(nodeID) { $0.width = newValue }
                        }
                    ),
                    range: 0.05...2.0
                )
                LabeledSlider(
                    title: "Height",
                    value: Binding(
                        get: { settings.height },
                        set: { newValue in
                            store.updateBillboardNodeSettings(nodeID) { $0.height = newValue }
                        }
                    ),
                    range: 0.05...2.0
                )
            }

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "Rot X",
                    value: Binding(
                        get: { settings.rotationX },
                        set: { newValue in
                            store.updateBillboardNodeSettings(nodeID) { $0.rotationX = newValue }
                        }
                    ),
                    range: -180...180
                )
                LabeledSlider(
                    title: "Rot Y",
                    value: Binding(
                        get: { settings.rotationY },
                        set: { newValue in
                            store.updateBillboardNodeSettings(nodeID) { $0.rotationY = newValue }
                        }
                    ),
                    range: -180...180
                )
            }

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "Rot Z",
                    value: Binding(
                        get: { settings.rotationZ },
                        set: { newValue in
                            store.updateBillboardNodeSettings(nodeID) { $0.rotationZ = newValue }
                        }
                    ),
                    range: -180...180
                )
                LabeledSlider(
                    title: "Opacity",
                    value: Binding(
                        get: { settings.opacity },
                        set: { newValue in
                            store.updateBillboardNodeSettings(nodeID) { $0.opacity = newValue }
                        }
                    ),
                    range: 0...1
                )
            }

            ColorPicker(
                "Tint",
                selection: Binding(
                    get: {
                        Color(
                            red: settings.red,
                            green: settings.green,
                            blue: settings.blue,
                            opacity: settings.alpha
                        )
                    },
                    set: { newValue in
                        let components = rgbaComponents(from: newValue)
                        store.updateBillboardNodeSettings(nodeID) { settings in
                            settings.red = components.red
                            settings.green = components.green
                            settings.blue = components.blue
                            settings.alpha = components.alpha
                        }
                    }
                ),
                supportsOpacity: true
            )
            .font(.caption.weight(.semibold))
        }
    }
}

private struct LineNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forLineNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LabeledSlider(
                    title: "X1",
                    value: Binding(
                        get: { settings.x1 },
                        set: { newValue in
                            store.updateLineNodeSettings(nodeID) { $0.x1 = newValue }
                        }
                    ),
                    range: -1...2
                )
                LabeledSlider(
                    title: "Y1",
                    value: Binding(
                        get: { settings.y1 },
                        set: { newValue in
                            store.updateLineNodeSettings(nodeID) { $0.y1 = newValue }
                        }
                    ),
                    range: -1...2
                )
            }

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "X2",
                    value: Binding(
                        get: { settings.x2 },
                        set: { newValue in
                            store.updateLineNodeSettings(nodeID) { $0.x2 = newValue }
                        }
                    ),
                    range: -1...2
                )
                LabeledSlider(
                    title: "Y2",
                    value: Binding(
                        get: { settings.y2 },
                        set: { newValue in
                            store.updateLineNodeSettings(nodeID) { $0.y2 = newValue }
                        }
                    ),
                    range: -1...2
                )
            }

            HStack(spacing: 8) {
                LabeledSlider(
                    title: "Thickness",
                    value: Binding(
                        get: { settings.thickness },
                        set: { newValue in
                            store.updateLineNodeSettings(nodeID) { $0.thickness = newValue }
                        }
                    ),
                    range: 0.001...0.2
                )
                LabeledSlider(
                    title: "Opacity",
                    value: Binding(
                        get: { settings.opacity },
                        set: { newValue in
                            store.updateLineNodeSettings(nodeID) { $0.opacity = newValue }
                        }
                    ),
                    range: 0...1
                )
            }

            LabeledSlider(
                title: "Z",
                value: Binding(
                    get: { settings.z },
                    set: { newValue in
                        store.updateLineNodeSettings(nodeID) { $0.z = newValue }
                    }
                ),
                range: -20...20
            )

            ColorPicker(
                "Color",
                selection: Binding(
                    get: {
                        Color(
                            red: settings.red,
                            green: settings.green,
                            blue: settings.blue,
                            opacity: settings.alpha
                        )
                    },
                    set: { newValue in
                        let components = rgbaComponents(from: newValue)
                        store.updateLineNodeSettings(nodeID) { settings in
                            settings.red = components.red
                            settings.green = components.green
                            settings.blue = components.blue
                            settings.alpha = components.alpha
                        }
                    }
                ),
                supportsOpacity: true
            )
            .font(.caption.weight(.semibold))
        }
    }
}

private struct Scene3DPrimitiveNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.resolvedScene3DPrimitiveSettings(forNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Picker("Primitive", selection: Binding(
                get: { settings.primitive },
                set: { newValue in
                    store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.primitive = newValue }
                }
            )) {
                ForEach(Scene3DPrimitiveKind.allCases) { primitive in
                    Text(primitive.label).tag(primitive)
                }
            }
            .pickerStyle(.menu)

            LabeledSlider(
                title: "Pos X",
                value: Binding(
                    get: { settings.positionX },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.positionX = newValue }
                    }
                ),
                range: -20...20
            )

            LabeledSlider(
                title: "Pos Y",
                value: Binding(
                    get: { settings.positionY },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.positionY = newValue }
                    }
                ),
                range: -20...20
            )

            LabeledSlider(
                title: "Pos Z",
                value: Binding(
                    get: { settings.positionZ },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.positionZ = newValue }
                    }
                ),
                range: -20...20
            )

            LabeledSlider(
                title: "Rot X",
                value: Binding(
                    get: { settings.rotationX },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.rotationX = newValue }
                    }
                ),
                range: -180...180
            )

            LabeledSlider(
                title: "Rot Y",
                value: Binding(
                    get: { settings.rotationY },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.rotationY = newValue }
                    }
                ),
                range: -180...180
            )

            LabeledSlider(
                title: "Rot Z",
                value: Binding(
                    get: { settings.rotationZ },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.rotationZ = newValue }
                    }
                ),
                range: -180...180
            )

            LabeledSlider(
                title: "Scale",
                value: Binding(
                    get: { settings.scale },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.scale = newValue }
                    }
                ),
                range: 0.05...4
            )

            if settings.primitive == .terrain {
                LabeledSlider(
                    title: "Terrain Width",
                    value: Binding(
                        get: { settings.terrainWidth },
                        set: { newValue in
                            store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.terrainWidth = newValue }
                        }
                    ),
                    range: 0.5...120
                )

                LabeledSlider(
                    title: "Terrain Depth",
                    value: Binding(
                        get: { settings.terrainDepth },
                        set: { newValue in
                            store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.terrainDepth = newValue }
                        }
                    ),
                    range: 0.5...120
                )

                LabeledSlider(
                    title: "Terrain Segments",
                    value: Binding(
                        get: { settings.terrainSegments },
                        set: { newValue in
                            store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.terrainSegments = newValue }
                        }
                    ),
                    range: 2...256
                )
            }

            LabeledSlider(
                title: "Light",
                value: Binding(
                    get: { settings.lightIntensity },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.lightIntensity = newValue }
                    }
                ),
                range: 0...4000
            )

            ColorPicker(
                "Material",
                selection: Binding(
                    get: {
                        Color(
                            red: settings.materialRed,
                            green: settings.materialGreen,
                            blue: settings.materialBlue,
                            opacity: settings.materialAlpha
                        )
                    },
                    set: { newValue in
                        let components = rgbaComponents(from: newValue)
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { settings in
                            settings.materialRed = components.red
                            settings.materialGreen = components.green
                            settings.materialBlue = components.blue
                            settings.materialAlpha = components.alpha
                        }
                    }
                ),
                supportsOpacity: true
            )
            .font(.caption.weight(.semibold))

            LabeledSlider(
                title: "Red",
                value: Binding(
                    get: { settings.materialRed },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.materialRed = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Green",
                value: Binding(
                    get: { settings.materialGreen },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.materialGreen = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Blue",
                value: Binding(
                    get: { settings.materialBlue },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.materialBlue = newValue }
                    }
                ),
                range: 0...1
            )

            LabeledSlider(
                title: "Alpha",
                value: Binding(
                    get: { settings.materialAlpha },
                    set: { newValue in
                        store.updateScene3DPrimitiveNodeSettings(nodeID) { $0.materialAlpha = newValue }
                    }
                ),
                range: 0...1
            )
        }
    }
}

private struct Scene3DMaterialNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.resolvedScene3DMaterialSettings(forNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            ColorPicker(
                "Base Color",
                selection: Binding(
                    get: {
                        Color(
                            red: settings.red,
                            green: settings.green,
                            blue: settings.blue,
                            opacity: settings.alpha
                        )
                    },
                    set: { newValue in
                        let components = rgbaComponents(from: newValue)
                        store.updateScene3DMaterialNodeSettings(nodeID) { settings in
                            settings.red = components.red
                            settings.green = components.green
                            settings.blue = components.blue
                            settings.alpha = components.alpha
                        }
                    }
                ),
                supportsOpacity: true
            )
            .font(.caption.weight(.semibold))

            LabeledSlider(title: "Opacity", value: Binding(
                get: { settings.alpha },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.alpha = newValue }
                }
            ), range: 0...1)

            LabeledSlider(title: "Metallic", value: Binding(
                get: { settings.metallic },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.metallic = newValue }
                }
            ), range: 0...1)

            LabeledSlider(title: "Roughness", value: Binding(
                get: { settings.roughness },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.roughness = newValue }
                }
            ), range: 0...1)

            LabeledSlider(title: "Emission", value: Binding(
                get: { settings.emission },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.emission = newValue }
                }
            ), range: 0...1)

            LabeledSlider(title: "Displacement Scale", value: Binding(
                get: { settings.displacementScale },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.displacementScale = newValue }
                }
            ), range: -10...10)

            Toggle("Double Sided", isOn: Binding(
                get: { settings.doubleSided },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.doubleSided = newValue }
                }
            ))
            .font(.caption)

            Toggle("Wireframe", isOn: Binding(
                get: { settings.wireframe },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.wireframe = newValue }
                }
            ))
            .font(.caption)

            Picker("Projection", selection: Binding(
                get: { settings.textureProjection },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.textureProjection = newValue }
                }
            )) {
                ForEach(Scene3DTextureProjection.allCases, id: \.self) { projection in
                    Text(projection.displayName).tag(projection)
                }
            }
            .font(.caption)
            .pickerStyle(.menu)

            LabeledSlider(title: "Texture Scale", value: Binding(
                get: { settings.textureScale },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.textureScale = newValue }
                }
            ), range: 0.001...10)

            LabeledSlider(title: "Texture Offset X", value: Binding(
                get: { settings.textureOffsetX },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.textureOffsetX = newValue }
                }
            ), range: -10...10)

            LabeledSlider(title: "Texture Offset Y", value: Binding(
                get: { settings.textureOffsetY },
                set: { newValue in
                    store.updateScene3DMaterialNodeSettings(nodeID) { $0.textureOffsetY = newValue }
                }
            ), range: -10...10)
        }
    }
}

private struct Scene3DTransformNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScene3DTransformNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(title: "X", value: Binding(
                get: { settings.x },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.x = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Y", value: Binding(
                get: { settings.y },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.y = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Z", value: Binding(
                get: { settings.z },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.z = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Scale X", value: Binding(
                get: { settings.scaleX },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.scaleX = newValue }
                }
            ), range: 0.01...10)

            LabeledSlider(title: "Scale Y", value: Binding(
                get: { settings.scaleY },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.scaleY = newValue }
                }
            ), range: 0.01...10)

            LabeledSlider(title: "Scale Z", value: Binding(
                get: { settings.scaleZ },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.scaleZ = newValue }
                }
            ), range: 0.01...10)

            LabeledSlider(title: "Rotation X", value: Binding(
                get: { settings.rotationX },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.rotationX = newValue }
                }
            ), range: -360...360)

            LabeledSlider(title: "Rotation Y", value: Binding(
                get: { settings.rotationY },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.rotationY = newValue }
                }
            ), range: -360...360)

            LabeledSlider(title: "Rotation Z", value: Binding(
                get: { settings.rotationZ },
                set: { newValue in
                    store.updateScene3DTransformNodeSettings(nodeID) { $0.rotationZ = newValue }
                }
            ), range: -360...360)
        }
    }
}

private struct Scene3DTileNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScene3DTileNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Text("Center")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LabeledSlider(title: "Center X", value: Binding(
                get: { settings.centerX },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.centerX = newValue } }
            ), range: -500...500)

            LabeledSlider(title: "Center Y", value: Binding(
                get: { settings.centerY },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.centerY = newValue } }
            ), range: -500...500)

            LabeledSlider(title: "Center Z", value: Binding(
                get: { settings.centerZ },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.centerZ = newValue } }
            ), range: -500...500)

            Text("Spacing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LabeledSlider(title: "Spacing X", value: Binding(
                get: { settings.spacingX },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.spacingX = newValue } }
            ), range: 0...200)

            LabeledSlider(title: "Spacing Y", value: Binding(
                get: { settings.spacingY },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.spacingY = newValue } }
            ), range: 0...200)

            LabeledSlider(title: "Spacing Z", value: Binding(
                get: { settings.spacingZ },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.spacingZ = newValue } }
            ), range: 0...200)

            Text("Field Size")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LabeledSlider(title: "Field X", value: Binding(
                get: { settings.fieldX },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.fieldX = newValue } }
            ), range: 0...500)

            LabeledSlider(title: "Field Y", value: Binding(
                get: { settings.fieldY },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.fieldY = newValue } }
            ), range: 0...500)

            LabeledSlider(title: "Field Z", value: Binding(
                get: { settings.fieldZ },
                set: { newValue in store.updateScene3DTileNodeSettings(nodeID) { $0.fieldZ = newValue } }
            ), range: 0...500)

            Text("Set an axis spacing or field to 0 to keep that axis as one layer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Scene3DRenderNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScene3DRenderNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            NumericField(
                title: "Scene Count",
                value: Double(settings.sceneCount),
                onSubmit: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { settings in
                        settings.sceneCount = max(1, Int(newValue.rounded()))
                    }
                }
            )

            LabeledSlider(title: "Camera Distance", value: Binding(
                get: { settings.cameraDistance },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.cameraDistance = newValue }
                }
            ), range: -200...200)

            LabeledSlider(title: "Orbit", value: Binding(
                get: { settings.cameraOrbit },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.cameraOrbit = newValue }
                }
            ), range: -360...360)

            LabeledSlider(title: "Pitch", value: Binding(
                get: { settings.cameraPitch },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.cameraPitch = newValue }
                }
            ), range: -360...360)

            LabeledSlider(title: "Pan X", value: Binding(
                get: { settings.cameraPanX },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.cameraPanX = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Pan Y", value: Binding(
                get: { settings.cameraPanY },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.cameraPanY = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Background Alpha", value: Binding(
                get: { settings.backgroundAlpha },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.backgroundAlpha = newValue }
                }
            ), range: 0...1)

            LabeledSlider(title: "Default Light", value: Binding(
                get: { settings.defaultLightIntensity },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.defaultLightIntensity = newValue }
                }
            ), range: 0...2000)

            LabeledSlider(title: "Water Distortion", value: Binding(
                get: { settings.waterDistortion },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.waterDistortion = newValue }
                }
            ), range: 0...0.12)

            LabeledSlider(title: "Water Scale", value: Binding(
                get: { settings.waterScale },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.waterScale = newValue }
                }
            ), range: 0.25...12)

            LabeledSlider(title: "Water Speed", value: Binding(
                get: { settings.waterSpeed },
                set: { newValue in
                    store.updateScene3DRenderNodeSettings(nodeID) { $0.waterSpeed = newValue }
                }
            ), range: 0...4)
        }
    }
}

private struct Scene3DLightNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.resolvedScene3DLightSettings(forNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Type")
                    .font(.caption.weight(.semibold))

                Picker("Type", selection: Binding(
                    get: { settings.type },
                    set: { newValue in
                        store.updateScene3DLightNodeSettings(nodeID) { $0.type = newValue }
                    }
                )) {
                    ForEach(Scene3DLightType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            ColorPicker(
                "Color",
                selection: Binding(
                    get: {
                        Color(
                            red: settings.red,
                            green: settings.green,
                            blue: settings.blue,
                            opacity: settings.alpha
                        )
                    },
                    set: { newValue in
                        let components = rgbaComponents(from: newValue)
                        store.updateScene3DLightNodeSettings(nodeID) { settings in
                            settings.red = components.red
                            settings.green = components.green
                            settings.blue = components.blue
                            settings.alpha = components.alpha
                        }
                    }
                ),
                supportsOpacity: true
            )
            .font(.caption.weight(.semibold))

            LabeledSlider(title: "Intensity", value: Binding(
                get: { settings.intensity },
                set: { newValue in
                    store.updateScene3DLightNodeSettings(nodeID) { $0.intensity = newValue }
                }
            ), range: 0...4000)

            Text("Position")
                .font(.caption.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                NumericField(title: "X", value: settings.positionX, onSubmit: { newValue in
                    store.updateScene3DLightNodeSettings(nodeID) { $0.positionX = newValue }
                })
                NumericField(title: "Y", value: settings.positionY, onSubmit: { newValue in
                    store.updateScene3DLightNodeSettings(nodeID) { $0.positionY = newValue }
                })
                NumericField(title: "Z", value: settings.positionZ, onSubmit: { newValue in
                    store.updateScene3DLightNodeSettings(nodeID) { $0.positionZ = newValue }
                })
            }

            Text("Rotation")
                .font(.caption.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                NumericField(title: "Rotation X", value: settings.rotationX, onSubmit: { newValue in
                    store.updateScene3DLightNodeSettings(nodeID) { $0.rotationX = newValue }
                })
                NumericField(title: "Rotation Y", value: settings.rotationY, onSubmit: { newValue in
                    store.updateScene3DLightNodeSettings(nodeID) { $0.rotationY = newValue }
                })
                NumericField(title: "Rotation Z", value: settings.rotationZ, onSubmit: { newValue in
                    store.updateScene3DLightNodeSettings(nodeID) { $0.rotationZ = newValue }
                })
            }

            if settings.type == .spot {
                LabeledSlider(title: "Inner Spot", value: Binding(
                    get: { settings.innerSpotAngle },
                    set: { newValue in
                        store.updateScene3DLightNodeSettings(nodeID) { $0.innerSpotAngle = newValue }
                    }
                ), range: 0...90)

                LabeledSlider(title: "Outer Spot", value: Binding(
                    get: { settings.outerSpotAngle },
                    set: { newValue in
                        store.updateScene3DLightNodeSettings(nodeID) { $0.outerSpotAngle = newValue }
                    }
                ), range: 0...120)
            }

            Toggle("Cast Shadow", isOn: Binding(
                get: { settings.castsShadow },
                set: { newValue in
                    store.updateScene3DLightNodeSettings(nodeID) { $0.castsShadow = newValue }
                }
            ))
            .font(.caption)
        }
    }
}

private struct Scene3DTextNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    private let fonts: [(name: String, label: String)] = [
        ("", "System Bold"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Avenir Next", "Avenir Next"),
        ("Futura", "Futura"),
        ("Menlo", "Menlo"),
        ("Times New Roman", "Times New Roman")
    ]

    var body: some View {
        let settings = store.resolvedScene3DTextSettings(forNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            TextField("Text", text: Binding(
                get: { settings.text },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.text = newValue }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)

            Picker("Font", selection: Binding(
                get: { settings.fontName },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.fontName = newValue }
                }
            )) {
                ForEach(fonts, id: \.name) { font in
                    Text(font.label).tag(font.name)
                }
            }
            .pickerStyle(.menu)

            LabeledSlider(title: "Font Size", value: Binding(
                get: { settings.fontSize },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.fontSize = newValue }
                }
            ), range: 0.1...6)

            LabeledSlider(title: "Extrusion", value: Binding(
                get: { settings.extrusionDepth },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.extrusionDepth = newValue }
                }
            ), range: 0.01...2)

            LabeledSlider(title: "Chamfer", value: Binding(
                get: { settings.chamferRadius },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.chamferRadius = newValue }
                }
            ), range: 0...1)

            LabeledSlider(title: "Pos X", value: Binding(
                get: { settings.positionX },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.positionX = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Pos Y", value: Binding(
                get: { settings.positionY },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.positionY = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Pos Z", value: Binding(
                get: { settings.positionZ },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.positionZ = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Rot X", value: Binding(
                get: { settings.rotationX },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.rotationX = newValue }
                }
            ), range: -180...180)

            LabeledSlider(title: "Rot Y", value: Binding(
                get: { settings.rotationY },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.rotationY = newValue }
                }
            ), range: -180...180)

            LabeledSlider(title: "Rot Z", value: Binding(
                get: { settings.rotationZ },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.rotationZ = newValue }
                }
            ), range: -180...180)

            LabeledSlider(title: "Scale", value: Binding(
                get: { settings.scale },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.scale = newValue }
                }
            ), range: 0.05...4)

            LabeledSlider(title: "Light", value: Binding(
                get: { settings.lightIntensity },
                set: { newValue in
                    store.updateScene3DTextNodeSettings(nodeID) { $0.lightIntensity = newValue }
                }
            ), range: 0...4000)

            ColorPicker("Material", selection: Binding(
                get: {
                    Color(
                        red: settings.materialRed,
                        green: settings.materialGreen,
                        blue: settings.materialBlue,
                        opacity: settings.materialAlpha
                    )
                },
                set: { newValue in
                    let components = rgbaComponents(from: newValue)
                    store.updateScene3DTextNodeSettings(nodeID) { settings in
                        settings.materialRed = components.red
                        settings.materialGreen = components.green
                        settings.materialBlue = components.blue
                        settings.materialAlpha = components.alpha
                    }
                }
            ), supportsOpacity: true)
            .font(.caption.weight(.semibold))
        }
    }
}

private struct Scene3DModelNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.resolvedScene3DModelSettings(forNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.openScene3DModelPicker(for: nodeID)
            } label: {
                Text(settings.bookmarkData.isEmpty ? "Choose Model..." : "Replace Model...")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)

            Text(settings.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            LabeledSlider(title: "Pos X", value: Binding(
                get: { settings.positionX },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.positionX = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Pos Y", value: Binding(
                get: { settings.positionY },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.positionY = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Pos Z", value: Binding(
                get: { settings.positionZ },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.positionZ = newValue }
                }
            ), range: -50...50)

            LabeledSlider(title: "Rot X", value: Binding(
                get: { settings.rotationX },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.rotationX = newValue }
                }
            ), range: -180...180)

            LabeledSlider(title: "Rot Y", value: Binding(
                get: { settings.rotationY },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.rotationY = newValue }
                }
            ), range: -180...180)

            LabeledSlider(title: "Rot Z", value: Binding(
                get: { settings.rotationZ },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.rotationZ = newValue }
                }
            ), range: -180...180)

            LabeledSlider(title: "Scale", value: Binding(
                get: { settings.scale },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.scale = newValue }
                }
            ), range: 0.01...20)

            LabeledSlider(title: "Light", value: Binding(
                get: { settings.lightIntensity },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.lightIntensity = newValue }
                }
            ), range: 0...4000)

            Toggle("Play Animation", isOn: Binding(
                get: { settings.animationPlay >= 0.5 },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.animationPlay = newValue ? 1.0 : 0.0 }
                }
            ))
            .font(.caption)

            LabeledSlider(title: "Clip Start", value: Binding(
                get: { settings.animationClipStart },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.animationClipStart = newValue }
                }
            ), range: 0...1)

            LabeledSlider(title: "Clip End", value: Binding(
                get: { settings.animationClipEnd },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.animationClipEnd = newValue }
                }
            ), range: 0...1)

            LabeledSlider(title: "Anim Speed", value: Binding(
                get: { settings.animationSpeed },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.animationSpeed = newValue }
                }
            ), range: 0...4)

            Toggle("Loop Animation", isOn: Binding(
                get: { settings.animationLoops },
                set: { newValue in
                    store.updateScene3DModelNodeSettings(nodeID) { $0.animationLoops = newValue }
                }
            ))
            .font(.caption)
        }
    }
}

private struct Scene3DParticleNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forScene3DParticleNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            Picker("Emitter", selection: Binding(
                get: { settings.shape },
                set: { newValue in
                    store.updateScene3DParticleNodeSettings(nodeID) { $0.shape = newValue }
                }
            )) {
                ForEach(Scene3DParticleShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.menu)

            Picker("Blend", selection: Binding(
                get: { settings.blendMode },
                set: { newValue in
                    store.updateScene3DParticleNodeSettings(nodeID) { $0.blendMode = newValue }
                }
            )) {
                ForEach(Scene3DParticleBlendMode.allCases) { blendMode in
                    Text(blendMode.label).tag(blendMode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Sprite", selection: Binding(
                get: { settings.spriteStyle },
                set: { newValue in
                    store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteStyle = newValue }
                }
            )) {
                ForEach(Scene3DParticleSpriteStyle.allCases) { spriteStyle in
                    Text(spriteStyle.label).tag(spriteStyle)
                }
            }
            .pickerStyle(.segmented)

            LabeledSlider(title: "Pos X", value: Binding(get: { settings.positionX }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.positionX = newValue } }), range: -50...50)
            LabeledSlider(title: "Pos Y", value: Binding(get: { settings.positionY }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.positionY = newValue } }), range: -50...50)
            LabeledSlider(title: "Pos Z", value: Binding(get: { settings.positionZ }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.positionZ = newValue } }), range: -50...50)
            LabeledSlider(title: "Scale", value: Binding(get: { settings.scale }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.scale = newValue } }), range: 0.01...20)
            LabeledSlider(title: "Count", value: Binding(get: { settings.particleCount }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.particleCount = newValue } }), range: 0...100_000)
            LabeledSlider(title: "Birth Rate", value: Binding(get: { settings.birthRate }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.birthRate = newValue } }), range: 0...5000)
            LabeledSlider(title: "Lifetime", value: Binding(get: { settings.lifetime }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.lifetime = newValue } }), range: 0.05...20)
            LabeledSlider(title: "Speed", value: Binding(get: { settings.speed }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.speed = newValue } }), range: 0...20)
            LabeledSlider(title: "Spread", value: Binding(get: { settings.spread }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.spread = newValue } }), range: 0...180)
            LabeledSlider(title: "Box Width", value: Binding(get: { settings.boxWidth }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.boxWidth = newValue } }), range: 0.01...120)
            LabeledSlider(title: "Box Height", value: Binding(get: { settings.boxHeight }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.boxHeight = newValue } }), range: 0.01...80)
            LabeledSlider(title: "Box Depth", value: Binding(get: { settings.boxDepth }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.boxDepth = newValue } }), range: 0.01...120)
            LabeledSlider(title: "Size", value: Binding(get: { settings.size }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.size = newValue } }), range: 0.001...20)
            LabeledSlider(title: "Gravity Y", value: Binding(get: { settings.gravityY }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.gravityY = newValue } }), range: -20...20)
            LabeledSlider(title: "Sheet Columns", value: Binding(get: { settings.spriteSheetColumns }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteSheetColumns = newValue } }), range: 1...16)
            LabeledSlider(title: "Sheet Rows", value: Binding(get: { settings.spriteSheetRows }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteSheetRows = newValue } }), range: 1...16)
            LabeledSlider(title: "Sheet Count", value: Binding(get: { settings.spriteSheetCount }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteSheetCount = newValue } }), range: 1...256)
            LabeledSlider(title: "Sprite Wobble", value: Binding(get: { settings.spriteWobble }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteWobble = newValue } }), range: 0...1)
            LabeledSlider(title: "Wobble Speed", value: Binding(get: { settings.spriteWobbleSpeed }, set: { newValue in store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteWobbleSpeed = newValue } }), range: 0...10)

            Toggle("Flip Sprite X", isOn: Binding(
                get: { settings.spriteFlipX },
                set: { newValue in
                    store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteFlipX = newValue }
                }
            ))
            .font(.caption.weight(.semibold))

            Toggle("Flip Sprite Y", isOn: Binding(
                get: { settings.spriteFlipY },
                set: { newValue in
                    store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteFlipY = newValue }
                }
            ))
            .font(.caption.weight(.semibold))

            Toggle("Random Sprite", isOn: Binding(
                get: { settings.spriteSheetRandom },
                set: { newValue in
                    store.updateScene3DParticleNodeSettings(nodeID) { $0.spriteSheetRandom = newValue }
                }
            ))
            .font(.caption.weight(.semibold))

            ColorPicker(
                "Color",
                selection: Binding(
                    get: {
                        Color(red: settings.red, green: settings.green, blue: settings.blue, opacity: settings.alpha)
                    },
                    set: { newValue in
                        let components = rgbaComponents(from: newValue)
                        store.updateScene3DParticleNodeSettings(nodeID) { settings in
                            settings.red = components.red
                            settings.green = components.green
                            settings.blue = components.blue
                            settings.alpha = components.alpha
                        }
                    }
                ),
                supportsOpacity: true
            )
            .font(.caption.weight(.semibold))
        }
    }
}

private struct Scene3DGaussianSplatNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.resolvedScene3DGaussianSplatSettings(forNodeID: nodeID)
        let loading = (store.scalarOutputValue(forNodeID: nodeID, outputName: "Loading") ?? 0.0) >= 0.5
        let progress = store.scalarOutputValue(forNodeID: nodeID, outputName: "Progress") ?? 0.0
        let status = store.stringOutputValue(forNodeID: nodeID, outputName: "Status") ?? "Idle"

        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.openScene3DGaussianSplatPicker(for: nodeID)
            } label: {
                Text(settings.bookmarkData.isEmpty ? "Choose PLY..." : "Replace PLY...")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)

            Button {
                store.openScene3DGaussianSplatPanoramaPicker(for: nodeID)
            } label: {
                Text(settings.panoramaImageData.isEmpty ? "Choose Panorama..." : "Replace Panorama...")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)

            Button {
                store.openScene3DGaussianSplatDepthMapPicker(for: nodeID)
            } label: {
                Text(settings.panoramaDepthImageData.isEmpty ? "Choose Depth Map..." : "Replace Depth Map...")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)

            Text(settings.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(status)
                    Spacer()
                    Text("\(Int((progress * 100.0).rounded()))%")
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(loading ? .white.opacity(0.85) : .white.opacity(0.6))

                ProgressView(value: progress)
                    .opacity(loading || progress > 0 ? 1.0 : 0.35)
            }

            LabeledSlider(title: "Pos X", value: Binding(get: { settings.positionX }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.positionX = newValue } }), range: -50...50)
            LabeledSlider(title: "Pos Y", value: Binding(get: { settings.positionY }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.positionY = newValue } }), range: -50...50)
            LabeledSlider(title: "Pos Z", value: Binding(get: { settings.positionZ }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.positionZ = newValue } }), range: -50...50)
            LabeledSlider(title: "Rot X", value: Binding(get: { settings.rotationX }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.rotationX = newValue } }), range: -720...720)
            LabeledSlider(title: "Rot Y", value: Binding(get: { settings.rotationY }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.rotationY = newValue } }), range: -720...720)
            LabeledSlider(title: "Rot Z", value: Binding(get: { settings.rotationZ }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.rotationZ = newValue } }), range: -720...720)
            LabeledSlider(title: "Scale", value: Binding(get: { settings.scale }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.scale = newValue } }), range: 0.001...100)
            LabeledSlider(title: "Distance", value: Binding(get: { settings.cameraDistance }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.cameraDistance = newValue } }), range: -200...200)
            LabeledSlider(title: "Orbit", value: Binding(get: { settings.cameraOrbit }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.cameraOrbit = newValue } }), range: -360...360)
            LabeledSlider(title: "Pitch", value: Binding(get: { settings.cameraPitch }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.cameraPitch = newValue } }), range: -89...89)
            LabeledSlider(title: "Pan X", value: Binding(get: { settings.cameraPanX }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.cameraPanX = newValue } }), range: -50...50)
            LabeledSlider(title: "Pan Y", value: Binding(get: { settings.cameraPanY }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.cameraPanY = newValue } }), range: -50...50)
            LabeledSlider(title: "Point Size", value: Binding(get: { settings.pointSize }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.pointSize = newValue } }), range: 0.1...24)
            LabeledSlider(title: "Opacity", value: Binding(get: { settings.opacity }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.opacity = newValue } }), range: 0...1)
            LabeledSlider(title: "Explode", value: Binding(get: { settings.explode }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.explode = newValue } }), range: 0...100)
            LabeledSlider(title: "Chaos", value: Binding(get: { settings.chaos }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.chaos = newValue } }), range: 0...1)
            LabeledSlider(title: "Particle Speed", value: Binding(get: { settings.particleSpeed }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.particleSpeed = newValue } }), range: 0...10)
            LabeledSlider(title: "Particle Gravity", value: Binding(get: { settings.particleGravity }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.particleGravity = newValue } }), range: -10...10)
            LabeledSlider(title: "Particle Turbulence", value: Binding(get: { settings.particleTurbulence }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.particleTurbulence = newValue } }), range: 0...10)
            LabeledSlider(title: "Particle Boundary", value: Binding(get: { settings.particleBoundary }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.particleBoundary = newValue } }), range: 0.1...500)
            LabeledSlider(title: "Max Splats", value: Binding(get: { settings.maxSplats }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.maxSplats = newValue } }), range: 1_000...2_000_000)
            LabeledSlider(title: "Pano Radius", value: Binding(get: { settings.panoramaRadius }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.panoramaRadius = newValue } }), range: 0.01...50)
            LabeledSlider(title: "Pano Depth", value: Binding(get: { settings.panoramaDepthScale }, set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.panoramaDepthScale = newValue } }), range: 0...10)

            Toggle("Auto Center", isOn: Binding(
                get: { settings.autoCenter },
                set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.autoCenter = newValue } }
            ))
            .font(.caption)

            Toggle("Auto Scale", isOn: Binding(
                get: { settings.autoScale },
                set: { newValue in store.updateScene3DGaussianSplatNodeSettings(nodeID) { $0.autoScale = newValue } }
            ))
            .font(.caption)
        }
    }
}

private struct TransitionNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forTransitionNodeID: nodeID)
        VStack(alignment: .leading, spacing: 10) {
            Picker("Style", selection: Binding(
                get: { settings.style },
                set: { newValue in
                    store.updateTransitionNodeSettings(nodeID) { $0.style = newValue }
                }
            )) {
                ForEach(TransitionStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)

            LabeledSlider(
                title: "Softness",
                value: Binding(
                    get: { settings.softness },
                    set: { newValue in
                        store.updateTransitionNodeSettings(nodeID) { $0.softness = newValue }
                    }
                ),
                range: 0...1
            )

            Text("Progress comes from the input port. Softness controls the edge feathering of the transition.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
        }
    }
}

private struct LayersNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forLayerNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            NumericField(
                title: "Layer Count",
                value: Double(settings.layerCount),
                onSubmit: { newValue in
                    store.updateLayerNodeSettings(nodeID) { settings in
                        settings.layerCount = max(2, Int(newValue.rounded()))
                    }
                }
            )

            LabeledSlider(
                title: "Master Opacity",
                value: Binding(
                    get: { settings.opacity },
                    set: { newValue in
                        store.updateLayerNodeSettings(nodeID) { $0.opacity = newValue }
                    }
                ),
                range: 0...1
            )

            ForEach(Array(settings.layerOpacities.enumerated()), id: \.offset) { index, opacity in
                LabeledSlider(
                    title: "Opacity \(index + 1)",
                    value: Binding(
                        get: { settings.layerOpacities[index] },
                        set: { newValue in
                            store.updateLayerNodeSettings(nodeID) { settings in
                                guard settings.layerOpacities.indices.contains(index) else { return }
                                settings.layerOpacities[index] = newValue
                            }
                        }
                    ),
                    range: 0...1
                )
            }

            Text("Layers render from back to front. Each layer has its own opacity, and Master Opacity scales the whole stack.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
        }
    }
}

private struct ClearNodeEditor: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forClearNodeID: nodeID)

        VStack(alignment: .leading, spacing: 8) {
            LabeledSlider(
                title: "Red",
                value: Binding(
                    get: { settings.red },
                    set: { newValue in
                        store.updateClearNodeSettings(nodeID) { $0.red = newValue }
                    }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "Green",
                value: Binding(
                    get: { settings.green },
                    set: { newValue in
                        store.updateClearNodeSettings(nodeID) { $0.green = newValue }
                    }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "Blue",
                value: Binding(
                    get: { settings.blue },
                    set: { newValue in
                        store.updateClearNodeSettings(nodeID) { $0.blue = newValue }
                    }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "Alpha",
                value: Binding(
                    get: { settings.alpha },
                    set: { newValue in
                        store.updateClearNodeSettings(nodeID) { $0.alpha = newValue }
                    }
                ),
                range: 0...1
            )
        }
    }
}

private struct MonitorReadout: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let stringValue = store.stringValue(forMonitorNodeID: nodeID)
        let scalarValue = store.scalarValue(forMonitorNodeID: nodeID)
        let displayValue = stringValue ?? scalarValue.map { String(format: "%.4f", $0) }

        VStack(alignment: .leading, spacing: 6) {
            Text("Live Value")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
            Text(displayValue ?? "No Signal")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactMonitorReadout: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let stringValue = store.stringValue(forMonitorNodeID: nodeID)
        let scalarValue = store.scalarValue(forMonitorNodeID: nodeID)
        let displayValue = stringValue ?? scalarValue.map { String(format: "%.4f", $0) }

        VStack(alignment: .leading, spacing: 4) {
            Text("Live Value")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))

            Text(displayValue ?? "No Signal")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactNoteReadout: View {
    @ObservedObject var store: GraphStore
    let nodeID: GraphNode.ID

    var body: some View {
        let settings = store.settings(forNoteNodeID: nodeID)
        let textColor = Color(red: settings.textRed, green: settings.textGreen, blue: settings.textBlue)
        let backgroundColor = Color(
            red: settings.backgroundRed,
            green: settings.backgroundGreen,
            blue: settings.backgroundBlue,
            opacity: settings.backgroundAlpha
        )

        VStack(alignment: .leading, spacing: 4) {
            Text("Note")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))

            Text(settings.text.isEmpty ? "" : settings.text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(textColor)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(backgroundColor)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GraphPortView: View {
    let port: GraphPort
    let accent: Color
    let isHighlighted: Bool
    let hoverChanged: (Bool) -> Void

    var body: some View {
        Circle()
            .fill(isHighlighted ? .white : accent)
            .frame(width: GraphCanvasLayout.portRadius * 2, height: GraphCanvasLayout.portRadius * 2)
            .overlay {
                Circle()
                    .strokeBorder(.black.opacity(0.45), lineWidth: 2)
            }
            .shadow(color: accent.opacity(0.5), radius: isHighlighted ? 10 : 5)
            .onHover(perform: hoverChanged)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PortCenterPreferenceKey.self,
                        value: [
                            port.id: CGPoint(
                                x: proxy.frame(in: .named("canvas")).midX,
                                y: proxy.frame(in: .named("canvas")).midY
                            )
                        ]
                    )
                }
            )
    }
}

private struct CompactUniformEditor: View {
    @ObservedObject var store: GraphStore
    let uniform: UniformDescriptor

    var body: some View {
        if let liveUniform = store.currentUniform(matching: uniform.id) {
            UniformControlView(
                uniform: liveUniform,
                currentValueText: store.displayValue(for: liveUniform),
                onRangeChange: { minValue, maxValue in
                    store.updateUniformRange(liveUniform.id, minValue: minValue, maxValue: maxValue)
                },
                onChange: { value in
                    store.updateUniform(liveUniform.id, value: value)
                }
            )
        }
    }
}
