//
//  CodeEditorWindowView.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import AppKit
import SwiftUI

struct CodeEditorWindowView: View {
    @EnvironmentObject private var store: GraphStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.selectedFragmentTitle)
                        .font(.title2.weight(.semibold))
                    Text("Double-click a fragment node to edit that node's Metal source.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Make Preset Node") {
                    store.makePresetNodeFromSelectedFragment()
                }

                Button("Close") {
                    store.closeCodeEditorWindow()
                }
            }

            MetalSyntaxTextView(text: Binding(
                get: { store.editableMetalSource },
                set: { store.updateEditableMetalSourceFromEditor($0) }
            ))
                .padding(14)
                .background(.black.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.1))
                }

            if let metalCompilerMessage = store.metalCompilerMessage {
                Text(metalCompilerMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 560)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.08),
                    Color(red: 0.09, green: 0.10, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct MetalSyntaxTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyHighlightedText(text, preservingSelection: false)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            context.coordinator.applyHighlightedText(text, preservingSelection: true)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MetalSyntaxTextView
        weak var textView: NSTextView?
        private var isApplying = false

        init(_ parent: MetalSyntaxTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            parent.text = textView.string
            applyHighlightedText(textView.string, preservingSelection: true)
        }

        func applyHighlightedText(_ source: String, preservingSelection: Bool) {
            guard let textView else { return }
            isApplying = true
            let selection = textView.selectedRanges
            let attributed = Self.highlightedString(for: source)
            textView.textStorage?.setAttributedString(attributed)
            if preservingSelection {
                textView.selectedRanges = selection
            }
            isApplying = false
        }

        private static func highlightedString(for source: String) -> NSAttributedString {
            let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.12

            let fullRange = NSRange(location: 0, length: (source as NSString).length)
            let result = NSMutableAttributedString(
                string: source,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: NSColor(calibratedWhite: 0.90, alpha: 1.0),
                    .paragraphStyle: paragraph
                ]
            )

            func apply(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
                regex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
                    guard let match else { return }
                    result.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }

            apply("(?m)//.*$", color: NSColor(calibratedRed: 0.43, green: 0.71, blue: 0.48, alpha: 1.0))
            apply("(?s)/\\*.*?\\*/", color: NSColor(calibratedRed: 0.43, green: 0.71, blue: 0.48, alpha: 1.0))
            apply("\"(?:\\\\.|[^\"\\\\])*\"", color: NSColor(calibratedRed: 0.90, green: 0.67, blue: 0.37, alpha: 1.0))
            apply("\\b\\d+(?:\\.\\d+)?\\b", color: NSColor(calibratedRed: 0.76, green: 0.58, blue: 0.96, alpha: 1.0))
            apply("\\b(float|float2|float3|float4|half|half2|half3|half4|int|uint|bool|texture2d|sampler|constant|struct|fragment|vertex|return|if|else|for|while|using|namespace)\\b",
                  color: NSColor(calibratedRed: 0.49, green: 0.73, blue: 0.98, alpha: 1.0))
            apply("\\b(sin|cos|mix|clamp|fract|floor|ceil|abs|min|max|smoothstep|length|dot|normalize|pow|exp|atan2)\\b",
                  color: NSColor(calibratedRed: 0.95, green: 0.44, blue: 0.61, alpha: 1.0))
            apply("\\b(PreviewUniforms|RasterizerData|TIME|RENDERSIZE|TextureSampler|Texture|floatUniforms|colorUniforms|pointUniforms|boolUniforms|uniforms|in)\\b",
                  color: NSColor(calibratedRed: 0.56, green: 0.84, blue: 0.75, alpha: 1.0))
            apply("(?m)^\\s*#\\w+.*$", color: NSColor(calibratedRed: 0.88, green: 0.50, blue: 0.25, alpha: 1.0))

            return result
        }
    }
}
