//
//  UniformControls.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import SwiftUI

struct UniformInspectorSection: View {
    @ObservedObject var store: GraphStore
    let uniform: UniformDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uniform Controls")
                .font(.headline)
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

struct UniformControlView: View {
    let uniform: UniformDescriptor
    let currentValueText: String
    let onRangeChange: ((Double, Double) -> Void)?
    let onChange: (UniformValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(uniform.label ?? uniform.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(currentValueText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            switch uniform.defaultValue {
            case .float(let value):
                let sliderRange = (uniform.minValue ?? 0.0)...(uniform.maxValue ?? max(1.0, value))
                VStack(alignment: .leading, spacing: 8) {
                    NumericField(
                        title: "Value",
                        value: value
                    ) { newValue in
                        let clampedValue = min(max(newValue, sliderRange.lowerBound), sliderRange.upperBound)
                        onChange(.float(clampedValue))
                    }

                    Slider(
                        value: Binding(
                            get: { value },
                            set: { onChange(.float($0)) }
                        ),
                        in: sliderRange
                    )

                    HStack {
                        Text("Range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(formatted(sliderRange.lowerBound)) ... \(formatted(sliderRange.upperBound))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let onRangeChange {
                        HStack(spacing: 10) {
                            NumericField(
                                title: "Min",
                                value: uniform.minValue ?? 0.0
                            ) { newMin in
                                onRangeChange(newMin, uniform.maxValue ?? max(newMin, value, 1.0))
                            }

                            NumericField(
                                title: "Max",
                                value: uniform.maxValue ?? max(1.0, value)
                            ) { newMax in
                                onRangeChange(uniform.minValue ?? min(0.0, newMax), newMax)
                            }
                        }
                    }
                }
            case .bool(let value):
                Toggle("Enabled", isOn: Binding(
                    get: { value },
                    set: { onChange(.bool($0)) }
                ))
                .toggleStyle(.switch)
            case .point(let point):
                VStack(alignment: .leading, spacing: 8) {
                    LabeledSlider(
                        title: "X",
                        value: Binding(
                            get: { point.x },
                            set: { onChange(.point(CGPoint(x: $0, y: point.y))) }
                        ),
                        range: 0...1
                    )
                    LabeledSlider(
                        title: "Y",
                        value: Binding(
                            get: { point.y },
                            set: { onChange(.point(CGPoint(x: point.x, y: $0))) }
                        ),
                        range: 0...1
                    )
                }
            case .point3(let point):
                VectorFieldRow(
                    components: [
                        VectorFieldComponent(label: "X", value: point.x),
                        VectorFieldComponent(label: "Y", value: point.y),
                        VectorFieldComponent(label: "Z", value: point.z)
                    ]
                ) { values in
                    onChange(.point3(Point3Value(
                        x: values[0],
                        y: values[1],
                        z: values[2]
                    )))
                }
            case .point4(let point):
                VectorFieldRow(
                    components: [
                        VectorFieldComponent(label: "X", value: point.x),
                        VectorFieldComponent(label: "Y", value: point.y),
                        VectorFieldComponent(label: "Z", value: point.z),
                        VectorFieldComponent(label: "W", value: point.w)
                    ]
                ) { values in
                    onChange(.point4(Point4Value(
                        x: values[0],
                        y: values[1],
                        z: values[2],
                        w: values[3]
                    )))
                }
            case .color(let color):
                VStack(alignment: .leading, spacing: 8) {
                    ColorChannelSlider(label: "R", value: Binding(
                        get: { Double(color.x) },
                        set: { onChange(.color(SIMD4(Float($0), color.y, color.z, color.w))) }
                    ))
                    ColorChannelSlider(label: "G", value: Binding(
                        get: { Double(color.y) },
                        set: { onChange(.color(SIMD4(color.x, Float($0), color.z, color.w))) }
                    ))
                    ColorChannelSlider(label: "B", value: Binding(
                        get: { Double(color.z) },
                        set: { onChange(.color(SIMD4(color.x, color.y, Float($0), color.w))) }
                    ))
                    ColorChannelSlider(label: "A", value: Binding(
                        get: { Double(color.w) },
                        set: { onChange(.color(SIMD4(color.x, color.y, color.z, Float($0)))) }
                    ))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z), opacity: Double(color.w)))
                        .frame(height: 18)
                }
            case .image(let name):
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private struct VectorFieldComponent: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}

private struct VectorFieldRow: View {
    let components: [VectorFieldComponent]
    let onChange: ([Double]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
                NumericField(title: component.label, value: component.value) { newValue in
                    var updated = components.map(\.value)
                    updated[index] = newValue
                    onChange(updated)
                }
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                NumericField(
                    title: title,
                    value: value
                ) { newValue in
                    value = min(max(newValue, range.lowerBound), range.upperBound)
                }
                .frame(width: 78)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct NumericField: View {
    let title: String
    let value: Double
    let onSubmit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(
                title,
                text: Binding(
                    get: { text.isEmpty ? String(format: "%.2f", value) : text },
                    set: { text = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
            .onChange(of: value) { _, newValue in
                if !isFocused {
                    text = String(format: "%.2f", newValue)
                }
            }
        }
        .onAppear {
            text = String(format: "%.2f", value)
        }
    }

    private func commit() {
        guard let parsed = Double(text) else {
            text = String(format: "%.2f", value)
            return
        }
        onSubmit(parsed)
        text = String(format: "%.2f", parsed)
    }
}

struct KeyboardNavigableTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var font: NSFont = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize)
    var onCommit: (() -> Void)? = nil
    var onAdvance: (() -> Void)? = nil
    var onRetreat: (() -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil

    init(
        _ placeholder: String,
        text: Binding<String>,
        isFocused: Binding<Bool>,
        font: NSFont = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize),
        onCommit: (() -> Void)? = nil,
        onAdvance: (() -> Void)? = nil,
        onRetreat: (() -> Void)? = nil,
        onFocusChange: ((Bool) -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        _isFocused = isFocused
        self.font = font
        self.onCommit = onCommit
        self.onAdvance = onAdvance
        self.onRetreat = onRetreat
        self.onFocusChange = onFocusChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = FocusAwareTextField(frame: .zero)
        textField.isEditable = true
        textField.isSelectable = true
        textField.isEnabled = true
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.backgroundColor = .controlBackgroundColor
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.commitFromAction(_:))
        textField.placeholderString = placeholder
        textField.focusDelegate = context.coordinator
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
        textField.font = font

        if isFocused, textField.window?.firstResponder !== textField.currentEditor() {
            DispatchQueue.main.async {
                guard textField.window != nil else { return }
                textField.window?.makeFirstResponder(textField)
            }
        } else if !isFocused, textField.window?.firstResponder === textField.currentEditor() {
            DispatchQueue.main.async {
                guard textField.window != nil else { return }
                textField.window?.makeFirstResponder(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, FocusAwareTextFieldDelegate {
        var parent: KeyboardNavigableTextField

        init(_ parent: KeyboardNavigableTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused = false
            parent.onFocusChange?(false)
            parent.onCommit?()
        }

        func textFieldDidBecomeFirstResponder(_ textField: NSTextField) {
            if parent.isFocused == false {
                parent.isFocused = true
            }
            parent.onFocusChange?(true)
        }

        func textFieldDidResignFirstResponder(_ textField: NSTextField) {
            if parent.isFocused {
                parent.isFocused = false
            }
            parent.onFocusChange?(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit?()
                return true
            case #selector(NSResponder.insertTab(_:)):
                if let onAdvance = parent.onAdvance {
                    onAdvance()
                } else {
                    control.window?.selectNextKeyView(control)
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if let onRetreat = parent.onRetreat {
                    onRetreat()
                } else {
                    control.window?.selectPreviousKeyView(control)
                }
                return true
            default:
                return false
            }
        }

        @objc
        func commitFromAction(_ sender: NSTextField) {
            parent.text = sender.stringValue
            parent.onCommit?()
        }
    }
}

protocol FocusAwareTextFieldDelegate: AnyObject {
    func textFieldDidBecomeFirstResponder(_ textField: NSTextField)
    func textFieldDidResignFirstResponder(_ textField: NSTextField)
}

final class FocusAwareTextField: NSTextField {
    weak var focusDelegate: FocusAwareTextFieldDelegate?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            focusDelegate?.textFieldDidBecomeFirstResponder(self)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            focusDelegate?.textFieldDidResignFirstResponder(self)
        }
        return resigned
    }
}

struct ColorChannelSlider: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(value: $value, in: 0...1)
            Text(String(format: "%.2f", value))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
