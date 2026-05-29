//
//  MetalNodeApp.swift
//  MetalNode
//
//  Created by Dustin O'Connor on 3/11/26.
//

import AppKit
import SwiftUI

@main
struct MetalNodeApp: App {
    var body: some Scene {
        WindowGroup("Metal Composer", id: "graph") {
            RootWindowView()
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            MetalNodeCommands()
        }

        Settings {
            CanvasPreferencesView()
        }
    }
}

private struct RootWindowView: View {
    @StateObject private var store = GraphStore()

    var body: some View {
        ContentView()
            .environmentObject(store)
            .focusedSceneObject(store)
    }
}

private struct CanvasPreferencesView: View {
    @AppStorage("canvasBackgroundOpacity") private var canvasBackgroundOpacity = 0.5
    @AppStorage("canvasBackgroundRed") private var canvasBackgroundRed = 0.0
    @AppStorage("canvasBackgroundGreen") private var canvasBackgroundGreen = 0.0
    @AppStorage("canvasBackgroundBlue") private var canvasBackgroundBlue = 0.0

    private var canvasBackgroundColor: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: canvasBackgroundRed,
                    green: canvasBackgroundGreen,
                    blue: canvasBackgroundBlue
                )
            },
            set: { newColor in
                let nsColor = NSColor(newColor).usingColorSpace(.deviceRGB) ?? .black
                canvasBackgroundRed = Double(nsColor.redComponent)
                canvasBackgroundGreen = Double(nsColor.greenComponent)
                canvasBackgroundBlue = Double(nsColor.blueComponent)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Canvas Appearance")
                    .font(.headline)

                ColorPicker("Background Color", selection: canvasBackgroundColor, supportsOpacity: false)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text("\(Int(canvasBackgroundOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $canvasBackgroundOpacity, in: 0...1)
                }

                Text("Lower opacity makes the graph canvas more see-through over whatever is behind the app window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: Alignment.leading)
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}

private struct MetalNodeCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var store: GraphStore?

    private var resolvedStore: GraphStore? {
        store ?? GraphStore.activeCommandTargetStore
    }

    private var activeTextResponderCanHandleEditCommands: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder else {
            return false
        }
        return responder is NSTextView || responder is NSText
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Graph…") {
                if let resolvedStore {
                    resolvedStore.openGraphSnapshot()
                } else {
                    openWindow(id: "graph")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        GraphStore.activeCommandTargetStore?.openGraphSnapshot()
                    }
                }
            }
            .keyboardShortcut("o")

            Button("Import ISF…") {
                resolvedStore?.importISFFile()
            }
            .disabled(resolvedStore == nil)

            Button("Import Metal…") {
                resolvedStore?.importMetalFile()
            }
            .disabled(resolvedStore == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                resolvedStore?.saveGraphSnapshot()
            }
            .keyboardShortcut("s")
            .disabled(resolvedStore == nil)

            Button("Save As…") {
                resolvedStore?.saveGraphSnapshotAs()
            }
            .keyboardShortcut("S")
            .disabled(resolvedStore == nil)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
                    return
                }
                resolvedStore?.copySelectedNode()
            }
            .keyboardShortcut("c")
            .disabled(!(activeTextResponderCanHandleEditCommands || (resolvedStore?.canCopySelectedNode ?? false)))

            Button("Paste") {
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
                    return
                }
                resolvedStore?.pasteCopiedNode()
            }
            .keyboardShortcut("v")
            .disabled(!(activeTextResponderCanHandleEditCommands || (resolvedStore?.canPasteCopiedNode ?? false)))
        }

        CommandGroup(after: .pasteboard) {
            Button("Select All") {
                if activeTextResponderCanHandleEditCommands {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    return
                }
                resolvedStore?.selectAllVisibleNodes()
            }
            .keyboardShortcut("a")
            .disabled(!(activeTextResponderCanHandleEditCommands || (resolvedStore?.canSelectAllVisibleNodes ?? false)))

            Button("Duplicate") {
                if activeTextResponderCanHandleEditCommands {
                    return
                }
                resolvedStore?.duplicateSelectedNode()
            }
            .keyboardShortcut("d")
            .disabled(!(resolvedStore?.canDuplicateSelectedNode ?? false))
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if activeTextResponderCanHandleEditCommands {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                    return
                }
                resolvedStore?.undoGraphChange()
            }
            .keyboardShortcut("z")
            .disabled(resolvedStore == nil)

            Button("Redo") {
                if activeTextResponderCanHandleEditCommands {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                    return
                }
                resolvedStore?.redoGraphChange()
            }
            .keyboardShortcut("Z")
            .disabled(resolvedStore == nil)
        }

        CommandMenu("Graph") {
            Button("Rebuild Graph") {
                resolvedStore?.rebuildCurrentGraph()
            }
            .keyboardShortcut("r")
            .disabled(resolvedStore == nil)

            Button(resolvedStore?.isCodeEditorVisible == true ? "Hide Code Editor" : "Edit Fragment") {
                resolvedStore?.toggleCodeEditorWindow()
            }
            .keyboardShortcut("e")
            .disabled(!(resolvedStore?.hasFragmentNodes ?? false))

            Button("Exit Container Editor") {
                resolvedStore?.exitActiveContainerEditor()
            }
            .keyboardShortcut("u", modifiers: [.command])
            .disabled(!(resolvedStore?.canExitContainerEditor ?? false))

            Button("Focus Selection") {
                resolvedStore?.requestCanvasFocusSelection()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(resolvedStore?.selectedNodeIDs.isEmpty ?? true)

            Button("Align Left") {
                resolvedStore?.alignSelectedNodesLeft()
            }
            .disabled(!(resolvedStore?.canAlignSelectedNodes ?? false))

            Button("Align Top") {
                resolvedStore?.alignSelectedNodesTop()
            }
            .disabled(!(resolvedStore?.canAlignSelectedNodes ?? false))

            Toggle(
                "Snap to Grid",
                isOn: Binding(
                    get: { resolvedStore?.snapToGridEnabled ?? true },
                    set: { resolvedStore?.setSnapToGridEnabled($0) }
                )
            )
            .disabled(resolvedStore == nil)

            Button("Snap Selection to Grid") {
                resolvedStore?.snapSelectedNodesToGrid()
            }
            .disabled(!(resolvedStore?.canSnapSelectedNodesToGrid ?? false))

            Button("Create Macro") {
                resolvedStore?.createMacroFromSelection()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!(resolvedStore?.canCreateMacroSelection ?? false))

            Button("Copy Node") {
                resolvedStore?.copySelectedNode()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!(resolvedStore?.canCopySelectedNode ?? false))

            Button("Paste Node") {
                resolvedStore?.pasteCopiedNode()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!(resolvedStore?.canPasteCopiedNode ?? false))

            Button("Duplicate Node") {
                resolvedStore?.duplicateSelectedNode()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!(resolvedStore?.canDuplicateSelectedNode ?? false))
        }

        CommandMenu("View") {
            Button("Toggle Parameters") {
                resolvedStore?.requestParameterInspectorToggle()
            }
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(resolvedStore == nil)

            Button("Toggle Node Library") {
                resolvedStore?.requestInspectorToggle()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(resolvedStore == nil)

            Button("Zoom In") {
                resolvedStore?.requestCanvasZoomIn()
            }
            .keyboardShortcut("=", modifiers: [.command])
            .disabled(resolvedStore == nil)

            Button("Zoom Out") {
                resolvedStore?.requestCanvasZoomOut()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(resolvedStore == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Preview Full Screen") {
                if resolvedStore?.togglePreviewWindowFullScreen() == true {
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }
}
