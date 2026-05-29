//
//  ContentView.swift
//  MetalNode
//
//  Created by Dustin O'Connor on 3/11/26.
//

import SwiftUI
import AppKit

private enum InspectorSectionID: Hashable {
    case selectedNode
    case nodeLibrary
    case uniformControls
}

private enum UIPreferenceKey {
    static let parameterInspectorWidth = "ui.parameterInspectorWidth"
    static let nodeLibraryWidth = "ui.nodeLibraryWidth"
}

private struct ParameterInspectorWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private struct NodeLibraryWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: GraphStore
    @AppStorage(UIPreferenceKey.parameterInspectorWidth) private var parameterInspectorWidth = 300.0
    @AppStorage(UIPreferenceKey.nodeLibraryWidth) private var nodeLibraryWidth = 320.0
    @State private var isNodeLibraryVisible = true
    @State private var isParameterInspectorVisible = true
    @State private var isStartupApplyingLayout = true

    var body: some View {
        HSplitView {
            if isParameterInspectorVisible {
                ParameterInspectorPanel(store: store)
                    .frame(minWidth: 240, idealWidth: parameterInspectorWidth, maxWidth: 420, maxHeight: .infinity)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ParameterInspectorWidthPreferenceKey.self,
                                value: geometry.size.width
                            )
                        }
                    )
            }

            NodeCanvasView(
                store: store,
                document: store.document,
                selectedNodeID: store.selectedNodeID,
                onSelect: store.selectNode
            )
            .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .navigationTitle(store.currentGraphDisplayName)
            .toolbar {
                ToolbarItemGroup {
                    Button("Open Graph") {
                        store.openGraphSnapshot()
                    }

                    Button(store.hasAuxiliaryWindowsVisible ? "Hide Windows" : "Show Render") {
                        if store.hasAuxiliaryWindowsVisible {
                            store.hideAuxiliaryWindows()
                        } else {
                            store.togglePreviewWindow()
                        }
                    }
                    .keyboardShortcut("p")

                    Button(isParameterInspectorVisible ? "Hide Parameters" : "Show Parameters") {
                        toggleParameterInspector()
                    }
                    .keyboardShortcut("i")

                    Button(isNodeLibraryVisible ? "Hide Library" : "Show Library") {
                        toggleNodeLibrary()
                    }
                    .keyboardShortcut(.return, modifiers: [.command])

                    Button(store.isGraphRunning ? "Running" : "Run") {
                        store.runGraph()
                    }
                    .disabled(store.isGraphRunning)

                    Button(store.isGraphRunning ? "Pause" : "Paused") {
                        store.pauseGraph()
                    }
                    .disabled(!store.isGraphRunning)

                    Button("Restart") {
                        store.restartGraphExecution()
                    }

                    Button(store.activePreviewVideoRecorder == nil ? "Export Movie" : "Exporting...") {
                        store.exportPreviewMovie()
                    }
                    .disabled(store.activePreviewVideoRecorder != nil)

                    Button("Save Graph") {
                        store.saveGraphSnapshot()
                    }
                }
            }

            if isNodeLibraryVisible {
                LibraryInspectorPanel(store: store)
                    .frame(minWidth: 250, idealWidth: nodeLibraryWidth, maxWidth: 420, maxHeight: .infinity)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: NodeLibraryWidthPreferenceKey.self,
                                value: geometry.size.width
                            )
                        }
                    )
            }
        }
        .background(
            MainSplitViewConfigurator(
                store: store,
                parameterInspectorWidth: $parameterInspectorWidth,
                nodeLibraryWidth: $nodeLibraryWidth,
                isStartupApplyingLayout: isStartupApplyingLayout,
                isParameterInspectorVisible: isParameterInspectorVisible,
                isNodeLibraryVisible: isNodeLibraryVisible
            )
        )
        .frame(minWidth: 760, minHeight: 520)
        .background(MainWindowConfigurator(store: store))
        .onAppear {
            store.graphWindowVisibilityDidChange(true)
            GraphStore.setCommandTargetStore(store)
            DispatchQueue.main.async {
                store.restoreLastOpenedGraphIfNeeded()
                parameterInspectorWidth = store.parameterInspectorWidth
                nodeLibraryWidth = store.nodeLibraryWidth
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    isStartupApplyingLayout = false
                }
            }
        }
        .onDisappear {
            store.graphWindowVisibilityDidChange(false)
        }
        .onChange(of: store.inspectorToggleRequestID) { _, _ in
            toggleNodeLibrary()
        }
        .onChange(of: store.parameterInspectorToggleRequestID) { _, _ in
            toggleParameterInspector()
        }
        .onChange(of: store.selectedNodeID) { _, newValue in
            GraphStore.setCommandTargetStore(store)
            if newValue != nil {
                isParameterInspectorVisible = true
            }
        }
        .onChange(of: store.parameterInspectorWidth) { _, newValue in
            if abs(parameterInspectorWidth - newValue) > 0.5 {
                parameterInspectorWidth = newValue
            }
        }
        .onChange(of: store.nodeLibraryWidth) { _, newValue in
            if abs(nodeLibraryWidth - newValue) > 0.5 {
                nodeLibraryWidth = newValue
            }
        }
        .onPreferenceChange(ParameterInspectorWidthPreferenceKey.self) { width in
            guard !isStartupApplyingLayout else { return }
            guard isParameterInspectorVisible, width >= 240 else { return }
            let measuredWidth = Double(width)
            if abs(parameterInspectorWidth - measuredWidth) > 0.5 {
                parameterInspectorWidth = measuredWidth
                UserDefaults.standard.set(measuredWidth, forKey: UIPreferenceKey.parameterInspectorWidth)
                Task { @MainActor in
                    store.updatePanelWidths(parameterWidth: measuredWidth, markDirty: true)
                }
            }
        }
        .onPreferenceChange(NodeLibraryWidthPreferenceKey.self) { width in
            guard !isStartupApplyingLayout else { return }
            guard isNodeLibraryVisible, width >= 250 else { return }
            let measuredWidth = Double(width)
            if abs(nodeLibraryWidth - measuredWidth) > 0.5 {
                nodeLibraryWidth = measuredWidth
                UserDefaults.standard.set(measuredWidth, forKey: UIPreferenceKey.nodeLibraryWidth)
                Task { @MainActor in
                    store.updatePanelWidths(libraryWidth: measuredWidth, markDirty: true)
                }
            }
        }
    }

    private func toggleNodeLibrary() {
        isNodeLibraryVisible.toggle()
    }

    private func toggleParameterInspector() {
        isParameterInspectorVisible.toggle()
    }
}

private struct MainSplitViewConfigurator: NSViewRepresentable {
    @ObservedObject var store: GraphStore
    @Binding var parameterInspectorWidth: Double
    @Binding var nodeLibraryWidth: Double
    let isStartupApplyingLayout: Bool
    let isParameterInspectorVisible: Bool
    let isNodeLibraryVisible: Bool

    final class Coordinator {
        weak var splitView: NSSplitView?
        var resizeObserver: NSObjectProtocol?
        var isApplyingLayout = false

        deinit {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureSplitView(for: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureSplitView(for: nsView, coordinator: context.coordinator)
        }
    }

    private func configureSplitView(for view: NSView, coordinator: Coordinator) {
        guard let splitView = nearestSplitView(from: view) else { return }
        if coordinator.splitView !== splitView {
            coordinator.resizeObserver.map(NotificationCenter.default.removeObserver)
            coordinator.splitView = splitView
            coordinator.resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: splitView,
                queue: .main
            ) { [weak coordinator] _ in
                guard let coordinator, !coordinator.isApplyingLayout else { return }
                guard !isStartupApplyingLayout else { return }
                guard let splitView = coordinator.splitView else { return }
                let widths = measuredWidths(in: splitView)
                if let parameter = widths.parameter {
                    parameterInspectorWidth = parameter
                    UserDefaults.standard.set(parameter, forKey: UIPreferenceKey.parameterInspectorWidth)
                    Task { @MainActor in
                        store.updatePanelWidths(parameterWidth: parameter, markDirty: true)
                    }
                }
                if let library = widths.library {
                    nodeLibraryWidth = library
                    UserDefaults.standard.set(library, forKey: UIPreferenceKey.nodeLibraryWidth)
                    Task { @MainActor in
                        store.updatePanelWidths(libraryWidth: library, markDirty: true)
                    }
                }
            }
        }

        applyStoredLayout(to: splitView, coordinator: coordinator)
    }

    private func nearestSplitView(from view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let candidate = current {
            if let splitView = candidate as? NSSplitView {
                return splitView
            }
            current = candidate.superview
        }
        return nil
    }

    private func applyStoredLayout(to splitView: NSSplitView, coordinator: Coordinator) {
        let subviews = splitView.subviews.filter { !$0.isHidden }
        guard subviews.count >= 2 else { return }

        coordinator.isApplyingLayout = true
        defer {
            DispatchQueue.main.async {
                coordinator.isApplyingLayout = false
            }
        }

        splitView.layoutSubtreeIfNeeded()

        switch (isParameterInspectorVisible, isNodeLibraryVisible, subviews.count) {
        case (true, true, 3):
            splitView.setPosition(CGFloat(parameterInspectorWidth), ofDividerAt: 0)
            splitView.setPosition(
                splitView.bounds.width - CGFloat(nodeLibraryWidth),
                ofDividerAt: 1
            )
        case (true, false, 2):
            splitView.setPosition(CGFloat(parameterInspectorWidth), ofDividerAt: 0)
        case (false, true, 2):
            splitView.setPosition(
                splitView.bounds.width - CGFloat(nodeLibraryWidth),
                ofDividerAt: 0
            )
        default:
            break
        }
    }

    private func measuredWidths(in splitView: NSSplitView) -> (parameter: Double?, library: Double?) {
        let subviews = splitView.subviews.filter { !$0.isHidden }
        switch (isParameterInspectorVisible, isNodeLibraryVisible, subviews.count) {
        case (true, true, 3):
            return (Double(subviews[0].frame.width), Double(subviews[2].frame.width))
        case (true, false, 2):
            return (Double(subviews[0].frame.width), nil)
        case (false, true, 2):
            return (nil, Double(subviews[1].frame.width))
        default:
            return (nil, nil)
        }
    }
}

private struct MainWindowConfigurator: NSViewRepresentable {
    @ObservedObject var store: GraphStore

    final class Coordinator {
        var configuredWindowNumber: Int?
        var closeObserver: NSObjectProtocol?

        deinit {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = true
        DispatchQueue.main.async {
            configureWindow(for: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView, coordinator: context.coordinator)
        }
    }

    private func configureWindow(for view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        if coordinator.configuredWindowNumber != window.windowNumber {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            coordinator.configuredWindowNumber = window.windowNumber
            if let closeObserver = coordinator.closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            coordinator.closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [store] _ in
                Task { @MainActor in
                    store.graphWindowVisibilityDidChange(false)
                }
            }
        }
        store.graphWindowVisibilityDidChange(window.isVisible)
        window.title = store.currentGraphDisplayName
        window.isDocumentEdited = store.isCurrentGraphDirty
        window.representedURL = store.currentGraphFileURL
    }
}

private struct LibrarySidebar: View {
    @ObservedObject var store: GraphStore
    let isInspectorVisible: Bool
    let toggleInspector: () -> Void

    var body: some View {
        List {
            Section("Pipeline") {
                Button {
                    store.importISFFile()
                } label: {
                    Label("Import ISF Shader", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)

                Button {
                    store.openGraphSnapshot()
                } label: {
                    Label("Open Saved Graph", systemImage: "folder")
                }
                .buttonStyle(.plain)

                Button {
                    if store.hasAuxiliaryWindowsVisible {
                        store.hideAuxiliaryWindows()
                    } else {
                        store.togglePreviewWindow()
                    }
                } label: {
                    Label(store.hasAuxiliaryWindowsVisible ? "Hide Windows" : "Open Render Window", systemImage: "macwindow")
                }
                .buttonStyle(.plain)

                Button {
                    toggleInspector()
                } label: {
                    Label(isInspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                }
                .buttonStyle(.plain)

                Label("Uniform Nodes", systemImage: "slider.horizontal.3")
                Label("Audio Reactivity", systemImage: "waveform")
                Label("Render Node", systemImage: "sparkles.rectangle.stack")
                Label("Uniform Graph", systemImage: "point.3.connected.trianglepath.dotted")
            }

            Section("Imported Shader") {
                Text(store.document.name)
                    .font(.headline)
                Text(store.document.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ISF Inputs") {
                ForEach(store.document.uniforms) { uniform in
                    Button {
                        store.selectNode(matching: uniform.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(uniform.name)
                            Text(uniform.kind.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("MetalNode")
    }
}

private struct LibraryInspectorPanel: View {
    @ObservedObject var store: GraphStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    NodeLibrarySection(store: store)
                        .id(InspectorSectionID.nodeLibrary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 72)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onAppear {
                syncInspectorFocus(with: proxy)
            }
            .onChange(of: store.inspectorFocusTarget) { _, _ in
                syncInspectorFocus(with: proxy)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.08, blue: 0.11),
                    Color(red: 0.10, green: 0.12, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func syncInspectorFocus(with proxy: ScrollViewProxy) {
        guard let target = store.inspectorFocusTarget else { return }

        switch target {
        case .fragmentNode, .renderNode:
            break
        case .nodeLibrary:
            proxy.scrollTo(InspectorSectionID.nodeLibrary, anchor: .center)
        case .uniform:
            break
        }
    }
}

private struct ParameterInspectorPanel: View {
    @ObservedObject var store: GraphStore

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                if let selectedNode = store.selectedNode {
                    SelectedNodePanel(store: store, node: selectedNode)
                        .id(InspectorSectionID.selectedNode)
                } else if let selectedUniform = store.selectedUniform {
                    UniformInspectorSection(store: store, uniform: selectedUniform)
                        .id(InspectorSectionID.uniformControls)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Parameters")
                            .font(.headline)
                        Text("Select a node to edit its parameters here. Inline port editing on the graph still works for quick changes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.1))
                    }
                }

                if store.hasFragmentNodes {
                    UniformFactorySection(store: store)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 72)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.08, blue: 0.11),
                    Color(red: 0.10, green: 0.12, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct CanvasAppearanceSection: View {
    @ObservedObject var store: GraphStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Canvas Appearance")
                .font(.headline)

            ColorPicker("Background Color", selection: $store.canvasBackgroundColor, supportsOpacity: false)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Opacity")
                    Spacer()
                    Text("\(Int(store.canvasBackgroundOpacity * 100))%")
                        .foregroundStyle(.secondary)
                }

                Slider(value: $store.canvasBackgroundOpacity, in: 0...1)
            }

            Text("Lower opacity makes the graph canvas more see-through over whatever is behind the app window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        }
    }
}

private struct UniformFactorySection: View {
    @ObservedObject var store: GraphStore
    @State private var name = ""
    @State private var kind: UniformKind = .float

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Uniform")
                .font(.headline)

            Text("Add a reusable uniform to the library.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Uniform name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Type")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Type", selection: $kind) {
                    ForEach(UniformKind.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Add Uniform") {
                let submittedName = name
                store.addUniform(named: submittedName, kind: kind)
                name = ""
                kind = .float
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        }
    }
}

private struct LibraryNodeDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let accent: Color
    let dragValue: String
}

private struct NodeLibrarySection: View {
    @ObservedObject var store: GraphStore
    @State private var searchText = ""
    @State private var selectedItemID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Node Library")
                .font(.headline)

            Text("Drag nodes into the graph. Click one to read what it does.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Search nodes or uniforms", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredEntries) { entry in
                        LibraryNodeChip(
                            title: entry.title,
                            symbolName: entry.symbolName,
                            accent: entry.accent,
                            dragValue: entry.dragValue,
                            isSelected: selectedDescriptor?.id == entry.id,
                            onSelect: {
                                selectedItemID = entry.id
                            }
                        )
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(minHeight: 260, idealHeight: 380, maxHeight: 420)

            if filteredEntries.isEmpty {
                Text("All imported uniforms are already on the graph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            libraryDescriptionCard
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        }
        .onAppear {
            if selectedDescriptor == nil {
                selectedItemID = filteredEntries.first?.id
            }
        }
        .onChange(of: searchText) { _, _ in
            if selectedDescriptor == nil {
                selectedItemID = filteredEntries.first?.id
            }
        }
    }

    private var filteredEntries: [LibraryNodeDescriptor] {
        allEntries.filter { entry in
            matches(entry.title, entry.detail)
        }
    }

    private var allEntries: [LibraryNodeDescriptor] {
        let coreEntries = store.availableCoreNodeTypes.compactMap { descriptor(for: $0) }
        let customPresetEntries = store.customFragmentPresets.map { preset in
            LibraryNodeDescriptor(
                id: "customFragmentPreset:\(preset.id.uuidString)",
                title: preset.title,
                detail: preset.detail,
                symbolName: "sparkles.rectangle.stack",
                accent: .green,
                dragValue: "customFragmentPreset:\(preset.id.uuidString)"
            )
        }
        let uniformEntries = store.availableUniformNodes.map { uniform in
            LibraryNodeDescriptor(
                id: "uniform:\(uniform.id.uuidString)",
                title: uniform.name,
                detail: uniform.kind.label,
                symbolName: symbolName(for: uniform.kind),
                accent: .orange,
                dragValue: "uniform:\(uniform.id.uuidString)"
            )
        }
        return coreEntries + customPresetEntries + uniformEntries
    }

    private var selectedDescriptor: LibraryNodeDescriptor? {
        if let selectedItemID,
           let matching = filteredEntries.first(where: { $0.id == selectedItemID }) {
            return matching
        }
        return filteredEntries.first
    }

    @ViewBuilder
    private var libraryDescriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)

            if let selectedDescriptor {
                HStack(spacing: 10) {
                    Circle()
                        .fill(selectedDescriptor.accent)
                        .frame(width: 10, height: 10)
                    Text(selectedDescriptor.title)
                        .font(.subheadline.weight(.semibold))
                }

                Text(selectedDescriptor.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a library node to read what it does.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func matches(_ title: String, _ subtitle: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return true }
        let query = trimmed.lowercased()
        return title.lowercased().contains(query) || subtitle.lowercased().contains(query)
    }

    private func descriptor(for nodeType: LibraryCoreNodeType) -> LibraryNodeDescriptor? {
        switch nodeType {
        case .time:
            return descriptor("time", "Time", "Animated input", .blue, "core:time")
        case .mouse:
            return descriptor("mouse", "Mouse", "Interactive point input", .cyan, "core:mouse")
        case .pointSplit:
            return descriptor("pointSplit", "Point Split", "Split point to X and Y", .cyan, "core:pointSplit")
        case .pointCombine:
            return descriptor("pointCombine", "Point Combine", "Build point from X and Y", .cyan, "core:pointCombine")
        case .point3Split:
            return descriptor("point3Split", "Point3 Split", "Split point3 to X Y Z", .cyan, "core:point3Split")
        case .point3Combine:
            return descriptor("point3Combine", "Point3 Combine", "Build point3 from X Y Z", .cyan, "core:point3Combine")
        case .point4Split:
            return descriptor("point4Split", "Point4 Split", "Split point4 to X Y Z W", .cyan, "core:point4Split")
        case .point4Combine:
            return descriptor("point4Combine", "Point4 Combine", "Build point4 from X Y Z W", .cyan, "core:point4Combine")
        case .pointInterpolate:
            return descriptor("pointInterpolate", "Interpolate Point", "Animated point2 between start and end", .blue, "core:pointInterpolate")
        case .point3Interpolate:
            return descriptor("point3Interpolate", "Interpolate Point3", "Animated point3 between start and end", .blue, "core:point3Interpolate")
        case .point4Interpolate:
            return descriptor("point4Interpolate", "Interpolate Point4", "Animated point4 between start and end", .blue, "core:point4Interpolate")
        case .pointScale:
            return descriptor("pointScale", "Scale Point", "Multiply point2 by scalar", .blue, "core:pointScale")
        case .point3Scale:
            return descriptor("point3Scale", "Scale Point3", "Multiply point3 by scalar", .blue, "core:point3Scale")
        case .point4Scale:
            return descriptor("point4Scale", "Scale Point4", "Multiply point4 by scalar", .blue, "core:point4Scale")
        case .colorSplit:
            return descriptor("colorSplit", "Color Split", "Split color to R G B A", .pink, "core:colorSplit")
        case .scroll:
            return descriptor("scroll", "Scroll", "Trackpad or wheel scroll input", .teal, "core:scroll")
        case .handTracker:
            return descriptor("handTracker", "Hand Tracker", "Vision fingertip source", .green, "core:handTracker")
        case .pinch:
            return descriptor("pinch", "Pinch", "Finger and thumb click gesture", .mint, "core:pinch")
        case .scrollGesture:
            return descriptor("scrollGesture", "Scroll Gesture", "Gated vertical motion", .cyan, "core:scrollGesture")
        case .zoomGesture:
            return descriptor("zoomGesture", "Zoom Gesture", "Two-point pinch zoom", .blue, "core:zoomGesture")
        case .trackball:
            return descriptor("trackball", "Trackball", "Orbit, pan, zoom, and object rotation control", .blue, "core:trackball")
        case .depthEstimate:
            return descriptor("depthEstimate", "Depth Estimate", "Infer z from hand span", .teal, "core:depthEstimate")
        case .math:
            return descriptor("math", "Math", "Scalar math and rounding", .orange, "core:math")
        case .expression:
            return descriptor("expression", "Expression", "Scalar formula with named inputs", .orange, "core:expression")
        case .clamp:
            return descriptor("clamp", "Clamp", "Limit a scalar value", .yellow, "core:clamp")
        case .mapRange:
            return descriptor("mapRange", "Map Range", "Remap one range to another", .mint, "core:mapRange")
        case .logic:
            return descriptor("logic", "Logic", "Boolean scalar gate", .indigo, "core:logic")
        case .compare:
            return descriptor("compare", "Compare", "Threshold compare gate", .purple, "core:compare")
        case .random:
            return descriptor("random", "Random", "Triggered or continuous random scalar", .orange, "core:random")
        case .pulse:
            return descriptor("pulse", "Pulse", "One-frame rising edge gate", .indigo, "core:pulse")
        case .fireOnLoad:
            return descriptor("fireOnLoad", "Fire On Load", "One-frame pulse when graph opens", .blue, "core:fireOnLoad")
        case .counter:
            return descriptor("counter", "Counter", "Count on trigger edges", .yellow, "core:counter")
        case .toggle:
            return descriptor("toggle", "Toggle", "Flip on each trigger", .green, "core:toggle")
        case .delay:
            return descriptor("delay", "Delay", "Pulse after a timed delay", .indigo, "core:delay")
        case .timer:
            return descriptor("timer", "Timer", "Repeating timed pulse", .cyan, "core:timer")
        case .string:
            return descriptor("string", "String", "Constant string value", .orange, "core:string")
        case .stringFormat:
            return descriptor("stringFormat", "String Format", "Template text formatter", .orange, "core:stringFormat")
        case .stringCompare:
            return descriptor("stringCompare", "String Compare", "Text compare gate", .purple, "core:stringCompare")
        case .stringSplit:
            return descriptor("stringSplit", "String Split", "Split text into parts", .orange, "core:stringSplit")
        case .color:
            return descriptor("color", "Color", "Constant RGBA color", .pink, "core:color")
        case .hslColor:
            return descriptor("hslColor", "HSL Color", "Constant HSLA color", .pink, "core:hslColor")
        case .scalarArray:
            return descriptor("scalarArray", "Scalar Array", "Dynamic numeric list", .orange, "core:scalarArray")
        case .stringArray:
            return descriptor("stringArray", "String Array", "Dynamic text list", .orange, "core:stringArray")
        case .colorArray:
            return descriptor("colorArray", "Color Array", "Dynamic palette list", .pink, "core:colorArray")
        case .imageArray:
            return descriptor("imageArray", "Image Array", "Dynamic source list", .blue, "core:imageArray")
        case .scalarArrayIndex:
            return descriptor("scalarArrayIndex", "Scalar Array Index", "Pick scalar from array", .yellow, "core:scalarArrayIndex")
        case .stringArrayIndex:
            return descriptor("stringArrayIndex", "String Array Index", "Pick text from array", .yellow, "core:stringArrayIndex")
        case .colorArrayIndex:
            return descriptor("colorArrayIndex", "Color Array Index", "Pick color from array", .yellow, "core:colorArrayIndex")
        case .imageArrayIndex:
            return descriptor("imageArrayIndex", "Image Array Index", "Pick source from array", .yellow, "core:imageArrayIndex")
        case .arrayCount:
            return descriptor("arrayCount", "Array Count", "Count items in array", .mint, "core:arrayCount")
        case .textImage:
            return descriptor("textImage", "Text Image", "Render string to source", .yellow, "core:textImage")
        case .audio:
            return descriptor("audio", "Audio", "Amplitude, bands, and spectrum array", .pink, "core:audio")
        case .beatDetect:
            return descriptor("beatDetect", "Beat Detect", "Kick and snare trigger source", .pink, "core:beatDetect")
        case .slider:
            return descriptor("slider", "Slider", "On-screen scalar control", .mint, "core:slider")
        case .sliderStyle:
            return descriptor("sliderStyle", "Slider Style", "Theme for on-screen sliders", .teal, "core:sliderStyle")
        case .button:
            return descriptor("button", "Button", "On-screen button control", .blue, "core:button")
        case .buttonStyle:
            return descriptor("buttonStyle", "Button Style", "Theme for on-screen buttons", .indigo, "core:buttonStyle")
        case .polar:
            return descriptor("polar", "Polar", "Point to angle and radius", .yellow, "core:polar")
        case .hitZone:
            return descriptor("hitZone", "Hit Zone", "Circular point gate", .mint, "core:hitZone")
        case .rectHit:
            return descriptor("rectHit", "Rect Hit", "Rectangular point gate", .mint, "core:rectHit")
        case .screenSize:
            return descriptor("screenSize", "Screen Size", "Main screen width, height, aspect", .cyan, "core:screenSize")
        case .screenBounds:
            return descriptor("screenBounds", "Screen Bounds", "Screen edges in normalized, centered, or pixels", .cyan, "core:screenBounds")
        case .renderBounds:
            return descriptor("renderBounds", "Render Bounds", "Track a render window's pixel bounds", .cyan, "core:renderBounds")
        case .renderWindow:
            return descriptor("renderWindow", "Window Control", "Set render window size, position, title, Syphon output, level, and fullscreen", .cyan, "core:renderWindow")
        case .keyboard:
            return descriptor("keyboard", "Keyboard", "Selected key with optional modifiers", .blue, "core:keyboard")
        case .gridLayout:
            return descriptor("gridLayout", "Grid Layout", "Index to grid X and Y", .mint, "core:gridLayout")
        case .scalarMultiplexor:
            return descriptor("scalarMultiplexor", "Scalar Multiplexor", "Indexed scalar selector", .yellow, "core:scalarMultiplexor")
        case .stringMultiplexor:
            return descriptor("stringMultiplexor", "String Multiplexor", "Indexed string selector", .orange, "core:stringMultiplexor")
        case .colorMultiplexor:
            return descriptor("colorMultiplexor", "Color Multiplexor", "Indexed color selector", .pink, "core:colorMultiplexor")
        case .imageMultiplexor:
            return descriptor("imageMultiplexor", "Image Multiplexor", "Indexed image or fragment selector", .blue, "core:imageMultiplexor")
        case .macro:
            return nil
        case .iterator:
            return descriptor("iterator", "Iterator", "Repeat a subgraph", .purple, "core:iterator")
        case .iteratorVariables:
            return descriptor("iteratorVariables", "Iterator Variables", "Index progress iterations", .indigo, "core:iteratorVariables")
        case .midiOut:
            return descriptor("midiOut", "MIDI Out", "Point to note mapping", .orange, "core:midiOut")
        case .midiCC:
            return descriptor("midiCC", "MIDI CC", "Scalar to controller output", .orange, "core:midiCC")
        case .midiCCInput:
            return descriptor("midiCCInput", "MIDI CC In", "Controller input source", .orange, "core:midiCCInput")
        case .midiNoteInput:
            return descriptor("midiNoteInput", "MIDI Note In", "Note and velocity input source", .orange, "core:midiNoteInput")
        case .oscInput:
            return nil
        case .oscOutput:
            return nil
        case .oscReceive:
            return descriptor("oscReceive", "OSC Receive", "Slim OSC packet input", .orange, "core:oscReceive")
        case .oscSend:
            return descriptor("oscSend", "OSC Send", "Send OSC packets or bundles", .orange, "core:oscSend")
        case .oscGet4:
            return descriptor("oscGet4", "OSC Get 4", "Read up to four OSC values", .orange, "core:oscGet4")
        case .oscGetArray:
            return descriptor("oscGetArray", "OSC Get Array", "Read numeric OSC values as an array", .orange, "core:oscGetArray")
        case .oscMake4:
            return descriptor("oscMake4", "OSC Make 4", "Build one OSC message", .orange, "core:oscMake4")
        case .oscMakeArray:
            return descriptor("oscMakeArray", "OSC Make Array", "Build one OSC float-array message", .orange, "core:oscMakeArray")
        case .oscBundle:
            return descriptor("oscBundle", "OSC Bundle", "Combine OSC messages into one bundle", .orange, "core:oscBundle")
        case .note:
            return descriptor("note", "Note", "Graph note and screen overlay", .yellow, "core:note")
        case .transform:
            return descriptor("transform", "Transform", "Position scale rotate", .cyan, "core:transform")
        case .scene3DTransform:
            return descriptor("scene3DTransform", "3D Transform", "Transform a 3D scene signal downstream", .blue, "core:scene3DTransform")
        case .scene3DTile:
            return descriptor("scene3DTile", "3D Tile", "Repeat a 3D scene in a wrapped infinite field", .blue, "core:scene3DTile")
        case .scene3DRender:
            return descriptor("scene3DRender", "3D Render", "Render one or more 3D scene signals to a shader source", .blue, "core:scene3DRender")
        case .billboard:
            return descriptor("billboard", "Billboard", "Position size tint", .pink, "core:billboard")
        case .line:
            return descriptor("line", "Line", "Endpoints thickness color", .red, "core:line")
        case .scene3DLight:
            return descriptor("scene3DLight", "3D Light", "Reusable SceneKit light for 3D nodes", .blue, "core:scene3DLight")
        case .scene3DMaterial:
            return descriptor("scene3DMaterial", "3D Material", "Reusable base material for 3D nodes", .blue, "core:scene3DMaterial")
        case .scene3DPrimitive:
            return descriptor("scene3DPrimitive", "3D Primitive", "SceneKit primitive rendered as a source", .blue, "core:scene3DPrimitive")
        case .scene3DText:
            return descriptor("scene3DText", "3D Text", "SceneKit 3D text with font and extrusion controls", .blue, "core:scene3DText")
        case .scene3DModel:
            return descriptor("scene3DModel", "3D Model", "SceneKit model file rendered as a source", .blue, "core:scene3DModel")
        case .scene3DGaussianSplat:
            return descriptor("scene3DGaussianSplat", "Gaussian Splat", "PLY or panorama depth-splat source", .purple, "core:scene3DGaussianSplat")
        case .scene3DParticle:
            return descriptor("scene3DParticle", "3D Particles", "SceneKit particle emitter rendered as a source", .blue, "core:scene3DParticle")
        case .scene3DFishSchool:
            return descriptor("scene3DFishSchool", "3D Fish School", "Small SceneKit particle school for 3D scenes", .cyan, "core:scene3DFishSchool")
        case .scene3DDustHaze:
            return descriptor("scene3DDustHaze", "3D Dust Haze", "Slow soft dust volume for desert fog and haze", .yellow, "core:scene3DDustHaze")
        case .select:
            return descriptor("select", "Select", "Switch between two sources", .mint, "core:select")
        case .scalarSwitch:
            return descriptor("scalarSwitch", "Scalar Switch", "Switch between two numbers", .orange, "core:scalarSwitch")
        case .stringSwitch:
            return descriptor("stringSwitch", "String Switch", "Switch between two strings", .teal, "core:stringSwitch")
        case .colorSwitch:
            return descriptor("colorSwitch", "Color Switch", "Switch between two colors", .pink, "core:colorSwitch")
        case .circle:
            return descriptor("circle", "Circle", "Tracking point marker", .red, "core:circle")
        case .clear:
            return descriptor("clear", "Clear", "Solid color background", .gray, "core:clear")
        case .imageNode:
            return descriptor("image", "Image", "Choose or drag image file", .yellow, "core:image")
        case .webView:
            return descriptor("webView", "WebView", "Interactive web page source", .orange, "core:webView")
        case .aiImage:
            return descriptor("aiImage", "AI Image", "Apple Intelligence image source", .orange, "core:aiImage")
        case .videoPlayer:
            return descriptor("videoPlayer", "Video Player", "Movie file source", .orange, "core:videoPlayer")
        case .video:
            return descriptor("video", "Webcam", "Live camera source", .blue, "core:video")
        case .coreImage:
            return descriptor("coreImage", "Core Image", "Filter picker node", .pink, "core:coreImage")
        case .blur:
            return descriptor("blur", "Blur", "Soft Gaussian blur", .blue, "core:blur")
        case .bloom:
            return descriptor("bloom", "Bloom", "Bright glow bloom", .yellow, "core:bloom")
        case .hueRotate:
            return descriptor("hueRotate", "Hue Rotate", "Shift image colors", .pink, "core:hueRotate")
        case .posterize:
            return descriptor("posterize", "Posterize", "Classic color bands", .orange, "core:posterize")
        case .levels:
            return descriptor("levels", "Levels", "Black/white image contrast", .indigo, "core:levels")
        case .glow:
            return descriptor("glow", "Glow", "Soft luminous halo", .mint, "core:glow")
        case .underwater:
            return descriptor("underwater", "Underwater", "FBM image distortion", .teal, "core:underwater")
        case .feedback:
            return descriptor("feedback", "Feedback", "Frame echo source", .indigo, "core:feedback")
        case .scale:
            return descriptor("scale", "Scale", "Remap float ranges", .mint, "core:scale")
        case .interpolator:
            return descriptor("interpolator", "Interpolator", "Looping eased value", .blue, "core:interpolator")
        case .hold:
            return descriptor("hold", "Sample & Hold", "Freeze value while gate is low", .indigo, "core:hold")
        case .scalarSmooth:
            return descriptor("scalarSmooth", "Scalar Smooth", "Smooth or inertial scalar follower", .mint, "core:scalarSmooth")
        case .trail:
            return descriptor("trail", "Trail", "Rainbow point history", .purple, "core:trail")
        case .monitor:
            return descriptor("monitor", "Monitor", "Live text or scalar readout", .teal, "core:monitor")
        case .mix:
            return descriptor("mix", "Mix", "Blend two shaders", .purple, "core:mix")
        case .transition:
            return descriptor("transition", "Transition", "Wipe, radial, checker", .purple, "core:transition")
        case .layers:
            return descriptor("layers", "Layers", "Foreground over background", .orange, "core:layers")
        case .plasma:
            return descriptor("plasma", "Plasma", "Colorful FBM preset", .pink, "core:plasma")
        case .lavaLamp:
            return descriptor("lavaLamp", "Lava Lamp", "Creamy metaball lava preset", .red, "core:lavaLamp")
        case .organicMotion:
            return descriptor("organicMotion", "Organic Motion", "Mouse-reactive background preset", .mint, "core:organicMotion")
        case .colorDiffusionFlow:
            return descriptor("colorDiffusionFlow", "ColorDiffusionFlow", "Mojovideotech diffusion preset", .orange, "core:colorDiffusionFlow")
        case .nebula:
            return descriptor("nebula", "Nebula", "Aurora cloud preset", .indigo, "core:nebula")
        case .liquidChrome:
            return descriptor("liquidChrome", "Liquid Chrome", "Reflective audio-reactive preset", .gray, "core:liquidChrome")
        case .liquidFlux:
            return descriptor("liquidFlux", "Liquid Flux", "Fluid collision audio preset", .cyan, "core:liquidFlux")
        case .prismRings:
            return descriptor("prismRings", "Prism Rings", "Chromatic ring preset", .teal, "core:prismRings")
        case .turntableSpectrum:
            return descriptor("turntableSpectrum", "Turntable Spectrum", "Circular audio deck preset", .orange, "core:turntableSpectrum")
        case .hologramScan:
            return descriptor("hologramScan", "Hologram Scan", "Retro hologram scanline preset", .teal, "core:hologramScan")
        case .hologramVideo:
            return descriptor("hologramVideo", "Hologram Video", "Scanline image glitch video effect", .cyan, "core:hologramVideo")
        case .badTVGlitch:
            return descriptor("badTVGlitch", "Bad TV Glitch", "RGB split displacement video effect", .indigo, "core:badTVGlitch")
        case .heatDistortion:
            return descriptor("heatDistortion", "Heat Distortion", "Shimmering refractive video effect", .orange, "core:heatDistortion")
        case .liquidGlass:
            return descriptor("liquidGlass", "Liquid Glass", "Soft glass refraction video effect", .blue, "core:liquidGlass")
        case .chromaticAberration:
            return descriptor("chromaticAberration", "Chromatic Aberration", "RGB edge split video effect", .pink, "core:chromaticAberration")
        case .aurora:
            return descriptor("aurora", "Aurora", "Flowing sky curtain preset", .mint, "core:aurora")
        case .digitalRain:
            return descriptor("digitalRain", "Digital Rain", "Falling code stream preset", .green, "core:digitalRain")
        case .plasmaVortex:
            return descriptor("plasmaVortex", "Plasma Vortex", "Twisting plasma spiral preset", .pink, "core:plasmaVortex")
        case .cyberTunnel:
            return descriptor("cyberTunnel", "Cyber Tunnel", "Neon tunnel preset", .blue, "core:cyberTunnel")
        case .rgbOffsetSplit:
            return descriptor("rgbOffsetSplit", "RGB Offset Split", "Channel split offset video effect", .pink, "core:rgbOffsetSplit")
        case .edgeDetection:
            return descriptor("edgeDetection", "Edge Detection", "Edge detection video effect", .mint, "core:edgeDetection")
        case .liquidNoiseWipe:
            return descriptor("liquidNoiseWipe", "Liquid Noise Wipe", "Liquid noise wipe transition", .cyan, "core:liquidNoiseWipe")
        case .mercuryMelt:
            return descriptor("mercuryMelt", "Mercury Melt", "Mercury melt video effect", .gray, "core:mercuryMelt")
        case .glitchDisplacement:
            return descriptor("glitchDisplacement", "Glitch Displacement", "Glitch displacement video effect", .indigo, "core:glitchDisplacement")
        case .datamosh:
            return descriptor("datamosh", "Datamosh", "Feedback data mosh video effect", .indigo, "core:datamosh")
        case .temporalGhostTrails:
            return descriptor("temporalGhostTrails", "Temporal Ghost Trails", "Temporal ghost trails video effect", .cyan, "core:temporalGhostTrails")
        case .frameMelt:
            return descriptor("frameMelt", "Frame Melt", "Frame melt feedback video effect", .orange, "core:frameMelt")
        case .reactionDiffusion:
            return descriptor("reactionDiffusion", "Reaction Diffusion", "Gray-Scott feedback simulation texture", .mint, "core:reactionDiffusion")
        case .prismSplit:
            return descriptor("prismSplit", "Prism Split", "Prism split video effect", .pink, "core:prismSplit")
        case .ghostFrameEcho:
            return descriptor("ghostFrameEcho", "Ghost Frame Echo", "Ghost frame echo video effect", .cyan, "core:ghostFrameEcho")
        case .pixelSortBands:
            return descriptor("pixelSortBands", "Pixel Sort Bands", "Pixel sort bands video effect", .orange, "core:pixelSortBands")
        case .phyllotaxisPetalSpiral:
            return descriptor("phyllotaxisPetalSpiral", "Phyllotaxis Petal Spiral", "Colored phyllotaxis petal spiral", .pink, "core:phyllotaxisPetalSpiral")
        case .fbmNoiseHeightMap:
            return descriptor("fbmNoiseHeightMap", "FBM Noise Height Map", "Grayscale FBM terrain displacement map", .mint, "core:fbmNoiseHeightMap")
        case .metalFragment:
            return descriptor("fragment", "Metal Fragment", "Additional shader source", .green, "core:fragment")
        case .renderOutput:
            return descriptor("render", "Render Window", "Output target", .cyan, "core:render")
        }
    }

    private func descriptor(_ id: String, _ title: String, _ detail: String, _ accent: Color, _ dragValue: String) -> LibraryNodeDescriptor {
        LibraryNodeDescriptor(
            id: id,
            title: title,
            detail: detail,
            symbolName: symbolName(for: id),
            accent: accent,
            dragValue: dragValue
        )
    }

    private func symbolName(for id: String) -> String {
        switch id {
        case "time":
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case "mouse":
            return "cursorarrow"
        case "pointSplit":
            return "arrow.branch"
        case "pointCombine":
            return "point.bottomleft.forward.to.point.topright.scurvepath"
        case "point3Split":
            return "cube.transparent"
        case "point3Combine":
            return "cube.fill"
        case "point4Split":
            return "square.3.layers.3d.down.right"
        case "point4Combine":
            return "square.3.layers.3d"
        case "pointInterpolate":
            return "point.topleft.down.to.point.bottomright.curvepath"
        case "point3Interpolate":
            return "cube"
        case "point4Interpolate":
            return "square.stack.3d.up"
        case "pointScale":
            return "arrow.up.left.and.arrow.down.right"
        case "point3Scale":
            return "scale.3d"
        case "point4Scale":
            return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case "colorSplit":
            return "circle.lefthalf.filled"
        case "scroll":
            return "scroll"
        case "handTracker":
            return "hand.point.up.left.fill"
        case "pinch":
            return "hand.draw.fill"
        case "scrollGesture":
            return "arrow.up.and.down.and.arrow.left.and.right"
        case "zoomGesture":
            return "minus.magnifyingglass"
        case "depthEstimate":
            return "view.3d"
        case "math":
            return "plus.forwardslash.minus"
        case "clamp":
            return "lessthan.circle"
        case "mapRange", "scale":
            return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case "logic":
            return "switch.2"
        case "compare":
            return "equal.circle"
        case "string", "stringFormat", "stringCompare", "stringSplit", "textImage", "note":
            return "textformat"
        case "color", "hslColor", "colorArray", "colorArrayIndex", "clear":
            return "paintpalette"
        case "scalarArray", "stringArray", "imageArray", "arrayCount":
            return "list.bullet.rectangle"
        case "scalarArrayIndex", "stringArrayIndex", "imageArrayIndex":
            return "list.number"
        case "audio":
            return "waveform"
        case "slider", "sliderStyle":
            return "slider.horizontal.3"
        case "button", "buttonStyle":
            return "button.programmable"
        case "polar":
            return "scope"
        case "hitZone":
            return "smallcircle.filled.circle"
        case "rectHit":
            return "rectangle.inset.filled"
        case "iterator":
            return "repeat"
        case "iteratorVariables":
            return "text.line.first.and.arrowtriangle.forward"
        case "midiOut", "midiCC", "midiCCInput", "midiNoteInput", "oscInput", "oscOutput", "oscReceive", "oscSend", "oscGet4", "oscGetArray", "oscMake4", "oscMakeArray", "oscBundle":
            return "pianokeys"
        case "transform":
            return "move.3d"
        case "billboard":
            return "photo.on.rectangle"
        case "select":
            return "arrow.triangle.branch"
        case "circle":
            return "circle.fill"
        case "image":
            return "photo"
        case "webView":
            return "globe"
        case "aiImage":
            return "sparkles.rectangle.stack"
        case "videoPlayer", "video":
            return "film"
        case "coreImage":
            return "camera.filters"
        case "blur":
            return "drop"
        case "bloom", "glow":
            return "sparkles"
        case "hueRotate":
            return "circle.lefthalf.filled"
        case "posterize", "levels":
            return "square.3.layers.3d.down.right"
        case "feedback":
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case "interpolator":
            return "waveform.path.ecg"
        case "hold":
            return "pause.circle"
        case "scalarSmooth":
            return "point.topleft.down.curvedto.point.bottomright.up"
        case "trail":
            return "scribble.variable"
        case "monitor":
            return "gauge.with.dots.needle.33percent"
        case "mix":
            return "circle.lefthalf.striped.horizontal"
        case "transition":
            return "rectangle.2.swap"
        case "layers":
            return "square.3.stack.3d"
        case "plasma", "lavaLamp", "organicMotion", "colorDiffusionFlow", "nebula", "liquidChrome", "liquidFlux", "prismRings", "turntableSpectrum", "underwater", "datamosh", "temporalGhostTrails", "frameMelt", "reactionDiffusion", "fbmNoiseHeightMap":
            return "wand.and.stars"
        case "fragment":
            return "chevron.left.forwardslash.chevron.right"
        case "render":
            return "display"
        default:
            return "square.grid.2x2"
        }
    }

    private func symbolName(for uniformKind: UniformKind) -> String {
        switch uniformKind {
        case .float:
            return "dial.medium"
        case .color:
            return "paintpalette"
        case .point2D:
            return "point.bottomleft.forward.to.point.topright.scurvepath"
        case .float3:
            return "point.3.connected.trianglepath.dotted"
        case .float4:
            return "square.2.layers.3d"
        case .image:
            return "photo"
        case .bool:
            return "switch.2"
        }
    }
}

private struct LibraryNodeChip: View {
    let title: String
    let symbolName: String
    let accent: Color
    let dragValue: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.2))
                .frame(width: 44, height: 30)
                .overlay {
                    Image(systemName: symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                }

            Text(title)
                .font(.subheadline.weight(.semibold))

            Spacer()
            Image(systemName: "hand.draw")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? accent.opacity(0.20) : .black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? accent.opacity(0.65) : .white.opacity(0.06), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .onDrag {
            onSelect()
            return NSItemProvider(object: dragValue as NSString)
        }
    }
}

private struct SelectedNodePanel: View {
    @ObservedObject var store: GraphStore
    let node: GraphNode
    @State private var draftTitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected Node")
                .font(.headline)
            Text(node.title)
                .font(.title3.weight(.medium))
            HStack(spacing: 8) {
                TextField("Rename node", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        applyRename()
                    }
                Button("Rename") {
                    applyRename()
                }
                .buttonStyle(.bordered)
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()
                .overlay(.white.opacity(0.12))

            NodeInspectorControls(store: store, node: node)
        }
        .onAppear {
            draftTitle = ""
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        }
    }

    private func applyRename() {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        store.renameNode(node.id, to: trimmedTitle)
        draftTitle = ""
    }

    private var description: String {
        switch node.kind {
        case .uniform(let uniform):
            return "Uniform input node for \(uniform.kind.label.lowercased()) values."
        case .time:
            return "Built-in animated time source for shaders that use TIME."
        case .mouse:
            return "Built-in mouse position source for point2D shader inputs."
        case .pointSplit:
            return "Splits any point signal into X and Y scalar outputs so you can drive seek, compare, scale, or other scalar-only nodes."
        case .pointCombine:
            return "Builds a point signal from X and Y scalar inputs so you can feed point-based nodes from math, arrays, iterator variables, or other scalar sources."
        case .point3Split:
            return "Splits a point3 signal into X, Y, and Z scalar outputs for 3D transforms, rotations, and future SceneKit or RealityKit graph work."
        case .point3Combine:
            return "Builds a point3 signal from X, Y, and Z scalar inputs so you can route 3D position, rotation, or other vector-style values through the graph."
        case .point4Split:
            return "Splits a point4 signal into X, Y, Z, and W scalar outputs for quaternion, homogeneous coordinates, or other four-component graph values."
        case .point4Combine:
            return "Builds a point4 signal from X, Y, Z, and W scalar inputs so you can prepare quaternion-style or float4-style values for later 3D and fragment workflows."
        case .pointInterpolate:
            return "Animates between start and end point values using the same easing and ping-pong timing as the scalar interpolator, but outputs a point2 signal."
        case .point3Interpolate:
            return "Animates between start and end point3 values so you can drive 3D position and rotation-style vectors with eased motion."
        case .point4Interpolate:
            return "Animates between start and end point4 values for quaternion-style or float4-style vector motion."
        case .pointScale:
            return "Scales a point2 value by a scalar amount. Useful for iterator layouts, coordinate remaps, and 2D vector math."
        case .point3Scale:
            return "Scales a point3 value by a scalar amount for 3D transforms, rotations, and future SceneKit or RealityKit work."
        case .point4Scale:
            return "Scales a point4 value by a scalar amount for float4 and quaternion-style workflows."
        case .colorSplit:
            return "Splits a color signal into separate R, G, B, and A scalar outputs so you can feed float uniforms, math nodes, and Metal fragment parameters."
        case .scroll:
            return "Built-in trackpad or wheel scroll source with cumulative X and Y scalar outputs."
        case .handTracker:
            return "Vision hand tracker with finger and thumb points plus tracked-state outputs."
        case .pinch:
            return "Measures finger-to-thumb distance and outputs pinch distance, strength, and a 0 or 1 pinched signal."
        case .scrollGesture:
            return "Accumulates vertical motion from Point A, or from the midpoint when Point B is also connected. Feed it into WebView Scroll Y."
        case .zoomGesture:
            return "Accumulates pinch distance changes from two points and outputs a live zoom value for WebView Zoom."
        case .trackball:
            return "Tracks left-mouse dragging over a preview and turns it into orbit and pitch values for 3D scene control."
        case .depthEstimate:
            return "Estimates near/far hand depth from finger-to-thumb span and outputs normalized depth, raw span, and a touch gate for virtual surfaces."
        case .math:
            return "Applies scalar math like add, subtract, multiply, divide, min, max, power, sin, cos, round, floor, or ceil to numeric inputs."
        case .expression:
            return "Evaluates a scalar expression with named inputs so you can write formulas like cos(angle) * radius + centerX without building long math-node chains."
        case .clamp:
            return "Clamps an incoming scalar between Min and Max, using connected inputs when present or local fallback values when not."
        case .mapRange:
            return "Maps an incoming scalar from an input range into a new output range, good for audio scaling and animation remapping."
        case .logic:
            return "Boolean logic for scalar signals like tracked, pinched, hit zones, and custom gesture gates."
        case .compare:
            return "Compares an incoming scalar against a number and outputs 0 or 1 for gesture thresholds and gates."
        case .random:
            return "Generates a random scalar between Min and Max, either continuously at Rate or repeatedly while Trigger stays above the threshold."
        case .pulse:
            return "Turns a gate into a one-frame pulse on the rising edge so you can fire random, hold, or iterator events once."
        case .fireOnLoad:
            return "Outputs 1 for one frame when the graph session loads, useful for seeding random values automatically on open."
        case .counter:
            return "Counts by Step whenever Trigger rises, with Min, Max, Reset, and optional wrap for index or sequencing work."
        case .toggle:
            return "Flips between 0 and 1 on each trigger edge and can be reset back to its initial state."
        case .delay:
            return "Waits for Duration seconds after Trigger rises, then outputs a one-frame pulse."
        case .timer:
            return "Outputs a one-frame pulse every Interval seconds while Enabled stays above the threshold."
        case .scalarVariable:
            return "Compact scalar variable node for fanning one numeric value out to multiple inputs."
        case .stringVariable:
            return "Compact string variable node for reusing one text value across multiple string inputs."
        case .colorVariable:
            return "Compact color variable node for reusing one color signal across multiple tint, text, and billboard inputs."
        case .scalarArrayVariable:
            return "Compact scalar array relay node for reusing one numeric array across multiple index, count, or iterator paths."
        case .stringArrayVariable:
            return "Compact string array relay node for reusing one text array across multiple compare, label, or iterator paths."
        case .colorArrayVariable:
            return "Compact color array relay node for reusing one palette across multiple billboard, text, or style paths."
        case .imageArrayVariable:
            return "Compact image array relay node for reusing one image list across multiple index, iterator, or layout paths."
        case .string:
            return "Constant string source node. Use it to feed prompt, label, compare, split, and text rendering nodes."
        case .stringFormat:
            return "Formats text using a template with {0}, {1}, {2}, and {3} placeholders. Reuse the same placeholder if you want the same input repeated."
        case .stringCompare:
            return "Compares two strings with equal, not-equal, contains, starts-with, or ends-with and outputs 0 or 1."
        case .stringSplit:
            return "Splits incoming text by a separator and outputs the selected part by index."
        case .color:
            return "Constant RGBA color source node for feeding color arrays and future tint or style inputs."
        case .hslColor:
            return "Constant HSLA color source node. Useful for iterator-driven palettes and animated hue changes without hand-building RGB."
        case .scalarArray:
            return "Builds a small scalar array from multiple numeric inputs so you can count items and index specific values."
        case .stringArray:
            return "Builds a small string array from multiple text inputs so you can reuse and index lists of labels or values."
        case .colorArray:
            return "Builds a small color array from multiple color inputs for palettes and repeated color selection."
        case .imageArray:
            return "Builds a dynamic list of connected image or source inputs so you can index visual items like clips, text images, buttons, or generated art."
        case .scalarArrayIndex:
            return "Indexes a scalar array and outputs one selected numeric item by index."
        case .stringArrayIndex:
            return "Indexes a string array and outputs one selected text item by index."
        case .colorArrayIndex:
            return "Indexes a color array and outputs one selected color item by index."
        case .imageArrayIndex:
            return "Indexes an image array and outputs one selected visual source by index."
        case .arrayCount:
            return "Outputs the number of items in a connected array so you can drive iteration, layout, and bounds logic."
        case .textImage:
            return "Renders a string into an image source with font and X/Y positioning so you can feed text into Render, Layers, and effects."
        case .audio:
            return "Live audio source driven by the current macOS input device, with amplitude outputs plus a 256-band spectrum array you can index inside iterators. BlackHole works here when it is selected as the system/default input."
        case .beatDetect:
            return "Beat detection source built on the live audio input. It outputs one-frame Kick and Snare triggers plus Kick Level and Snare Level values so you can drive toggles, counters, pulses, and reactive layouts."
        case .slider:
            return "On-screen slider source with a visible control plus scalar value output."
        case .sliderStyle:
            return "Reusable slider color theme node. Assign it from a Slider node to keep slider cards compact."
        case .button:
            return "On-screen button source with configurable SF Symbol, title, style input, and pressed plus hover scalar outputs."
        case .buttonStyle:
            return "Reusable button color theme node for fill, hover, pressed, and text colors."
        case .polar:
            return "Turns a point into angle, degrees, normalized angle, and radius values for turntable or orbital controls."
        case .hitZone:
            return "Tests whether a point is inside a circular or ring-shaped hit zone and outputs 1 or 0 for touch gating."
        case .rectHit:
            return "Tests whether a point is inside a rectangular region using Center, Width, and Height, which is better for billboards, grids, and UI cells."
        case .screenSize:
            return "Outputs the main screen width, height, and aspect ratio as scalar values for layout or shader math."
        case .screenBounds:
            return "Outputs left, right, top, bottom, center, width, height, and aspect using normalized, centered, or pixel coordinate space."
        case .renderBounds:
            return "Outputs the current pixel bounds of a specific render window so layouts and shaders can respond to the actual preview size."
        case .renderWindow:
            return "Controls a render window's title, Syphon output name, level, fullscreen state, position, and pixel size so you can build compact previews, overlays, desktop windows, or fixed output layouts."
        case .keyboard:
            return "Outputs 1 while a selected key is pressed, with optional Command, Option, Shift, and Control requirements for shortcuts and fullscreen toggles."
        case .gridLayout:
            return "Turns an item index into grid column, row, and normalized X/Y coordinates for iterator-driven lists and grids."
        case .scalarMultiplexor:
            return "Selects one scalar input by index and outputs that value. Useful when you want indexed routing without building an array first."
        case .stringMultiplexor:
            return "Selects one string input by index and outputs that text value."
        case .colorMultiplexor:
            return "Selects one color input by index and outputs that color."
        case .imageMultiplexor:
            return "Selects one image or fragment source by index and outputs that visual source."
        case .macro:
            return "Wraps a selected subgraph into a reusable macro node with auto-published boundary ports."
        case .iterator:
            return "Repeats a published visual subgraph with iterator variables for index, progress, and total iteration count."
        case .iteratorVariables:
            return "Iterator-only helper node that outputs Index, Progress, and Iterations inside the iterator editor."
        case .select:
            return "Switches between Source A and Source B when the Select input crosses the node threshold."
        case .scalarSwitch:
            return "Switches between scalar A and B when the Select input crosses the node threshold."
        case .stringSwitch:
            return "Switches between string A and B when the Select input crosses the node threshold."
        case .colorSwitch:
            return "Switches between color A and B when the Select input crosses the node threshold."
        case .circle:
            return "Draws a lightweight tracking dot from a point signal, with adjustable radius, softness, color, and alpha."
        case .clear:
            return "Solid color background source for Layers or direct render output."
        case .image:
            return "Embedded image source node. Drag an image file from Finder onto the graph canvas to create one."
        case .webView:
            return "Interactive WKWebView source that snapshots its current page so you can run it through image effects."
        case .aiImage:
            return "On-device Apple Intelligence image generator that stores its generated result inside the graph."
        case .videoPlayer:
            return "Movie file source with play, rate, seek, and loop control. Feed it into render, effects, layers, or transitions."
        case .video:
            return "Live webcam source node that can render directly or sit behind other nodes through Layers."
        case .blur:
            return "Core Image blur effect node for softening any connected source."
        case .bloom:
            return "Core Image bloom effect node for bright soft glow."
        case .hueRotate:
            return "Core Image hue adjustment node for rotating colors around the spectrum."
        case .posterize:
            return "Core Image posterize node for reducing an image into stepped color bands."
        case .levels:
            return "Image levels node for crushing blacks and stretching whites before masks, feedback, or reaction diffusion."
        case .glow:
            return "Core Image glow node for soft luminous halos around bright areas."
        case .coreImage:
            return "Generic filter node with a stock picker for blur, bloom, hue rotate, posterize, glow, edges, pixellate, twirl, and kaleidoscope."
        case .underwater:
            return "Image or video distortion effect driven by animated FBM noise. Feed it from Image, Webcam, Layers, or another source node."
        case .feedback:
            return "Feeds a source back through itself using the previous frame, with adjustable level and blend mode."
        case .reactionDiffusion:
            return "GPU reaction-diffusion simulation with internal ping-pong state, optional texture drive, and reset control."
        case .transition:
            return "Transitions between two sources with wipe, radial, or checker styles. Drive Progress from a slider, audio, or interpolator."
        case .scale:
            return "Remaps a scalar input using scaledMin + (value - min) * (scaledMax - scaledMin) / (max - min)."
        case .interpolator:
            return "Generates a looping scalar value between start and end using linear or eased timing."
        case .hold:
            return "Samples the incoming value while Gate is above the threshold, then keeps the last sampled value when the gate drops."
        case .scalarSmooth:
            return "Follows a target scalar smoothly. Use Smooth for soft interpolation, or Inertia for springy camera and trackball motion."
        case .midiOut:
            return "Maps a point signal to notes where X selects the scale degree and Y selects the octave, then sends MIDI to the IAC bus or another destination."
        case .midiCC:
            return "Maps a scalar input range to MIDI CC 0...127 so you can drive jog wheels, controller knobs, or software parameters."
        case .midiCCInput:
            return "Listens for incoming MIDI controller messages and outputs the current value, normalized value, and a one-frame trigger for graphics control."
        case .midiNoteInput:
            return "Listens for incoming MIDI notes and outputs note number, velocity, normalized velocity, gate, and trigger so controllers can drive visuals directly."
        case .oscInput:
            return "Receives OSC over UDP, filters by port and address, and outputs float, int, text, address, plus a one-frame trigger."
        case .oscOutput:
            return "Sends OSC over UDP to a host, port, and address using either a float, int, or string input."
        case .oscReceive:
            return "Receives OSC packets over UDP and outputs a slim packet signal, the current address, and a one-frame trigger for helper nodes."
        case .oscSend:
            return "Sends a packet or bundle built downstream so one node can forward complete OSC messages without bloated inline ports."
        case .oscGet4:
            return "Reads the first message in an OSC packet and exposes up to four values as float, int, and text outputs."
        case .oscGetArray:
            return "Reads the first message in an OSC packet and exposes all numeric arguments as a scalar array for iterators, indexing, and motion data."
        case .oscMake4:
            return "Builds one OSC message with an address and up to four values so it can be reused, bundled, or sent later."
        case .oscMakeArray:
            return "Builds one OSC message from a scalar array so float-array data can be sent as landmarks, tracking points, or batched control values."
        case .oscBundle:
            return "Combines up to four OSC messages into one bundle packet for grouped sends to other apps."
        case .note:
            return "Editable graph note node that can also render as a transparent text overlay source through Layers or Render."
        case .transform:
            return "Wraps a visual source and repositions, scales, rotates, and fades it over transparent output. Use it for grids, picture-in-picture, and control layouts."
        case .scene3DTransform:
            return "Wraps a 3D scene signal with downstream position, rotation, and scale so you can keep models upright, stack transforms, and prepare for lights, physics, and scene graphs."
        case .scene3DTile:
            return "Repeats a 3D scene signal across a wrapped field. Animate Center Z or Center X to make terrain, objects, or wireframe mountains appear to travel forever."
        case .scene3DRender:
            return "Renders one or more 3D scene signals into a shader source with shared camera controls. Use it to combine models, primitives, text, lights, and downstream transforms into one scene."
        case .billboard:
            return "Wraps a visual source with X, Y, Z, width, height, rotation, opacity, and tint color. If no source is connected it renders as a solid tinted quad. Use it for labels, sprites, list items, and z-ordered iterator layouts."
        case .line:
            return "Draws a colored line between X1/Y1 and X2/Y2 with adjustable thickness, opacity, and color input. Use it with iterator variables plus array indexing for spectrum analyzers, grids, and geometric wireframe layouts."
        case .scene3DLight:
            return "Builds a reusable SceneKit light with type, position, rotation, color, intensity, and spot controls so multiple 3D nodes can share one lighting rig."
        case .scene3DMaterial:
            return "Builds a reusable base material for 3D primitives, text, and imported models with color, opacity, metallic, roughness, emission, and double-sided controls."
        case .scene3DPrimitive:
            return "Renders a built-in SceneKit primitive like a box, sphere, torus, or plane into the graph. Use it as the first 3D source while we build out model loading, cameras, lights, and materials."
        case .scene3DText:
            return "Renders editable SceneKit 3D text into the graph with font, extrusion, chamfer, transform, camera, light, and color controls."
        case .scene3DModel:
            return "Loads a SceneKit-compatible 3D model file like DAE or USD and renders it into the graph with transform, camera, and light controls. Use it as a real 3D source before we build out full materials and animation controls."
        case .scene3DGaussianSplat:
            return """
            Loads a Gaussian splat PLY file or builds a pseudo-splat room from an equirectangular panorama plus a matching grayscale depth matte.

            Depth matte prompt: Create an accurate grayscale depth map for this equirectangular panorama. White should be closest to the camera/viewer and black should be farthest away. Preserve the same aspect ratio, alignment, horizon, and object shapes exactly. Do not add texture, color, outlines, labels, or artistic shading; output only a smooth grayscale depth matte.
            """
        case .scene3DParticle:
            return "Creates a SceneKit particle emitter with transform, birth rate, lifetime, speed, spread, size, color, and blend controls."
        case .trail:
            return "Persistent rainbow trail renderer driven by a point signal like Mouse."
        case .monitor:
            return "Displays a live string or numeric value so you can verify split text, HUD labels, audio, or scalar output."
        case .mix:
            return "Blend node for combining two fragment outputs. Mix is clamped to 0...1, where 0 is Shader A and 1 is Shader B."
        case .layers:
            return "Composites a foreground source over a background source using alpha and an optional opacity input."
        case .metalFragment:
            return "Fragment node with one input port per imported uniform."
        case .renderOutput:
            return "Output window node. Use Open on the node card to send that render to the detached render window."
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GraphStore())
}
