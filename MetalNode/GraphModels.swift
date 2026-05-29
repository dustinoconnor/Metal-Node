//
//  GraphModels.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import CoreGraphics
import CoreVideo
import Foundation
import SwiftUI

enum UniformKind: String, Identifiable, CaseIterable {
    case float
    case color
    case point2D
    case float3
    case float4
    case image
    case bool

    var id: String { rawValue }

    var label: String {
        switch self {
        case .float: return "Float"
        case .color: return "Color"
        case .point2D: return "Point2D"
        case .float3: return "Float3"
        case .float4: return "Float4"
        case .image: return "Image"
        case .bool: return "Bool"
        }
    }
}

enum UniformValue: Equatable {
    case float(Double)
    case color(SIMD4<Float>)
    case point(CGPoint)
    case point3(Point3Value)
    case point4(Point4Value)
    case bool(Bool)
    case image(String)
}

enum AudioSignalKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case amplitude
    case low
    case mid
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amplitude: return "Amplitude"
        case .low: return "Low"
        case .mid: return "Mid"
        case .high: return "High"
        }
    }
}

enum FeedbackBlendMode: String, CaseIterable, Identifiable, Codable {
    case additive
    case screen
    case multiply

    var id: String { rawValue }

    var label: String {
        switch self {
        case .additive: return "Add"
        case .screen: return "Screen"
        case .multiply: return "Multiply"
        }
    }
}

enum CoreImageEffectKind: String, Codable, CaseIterable, Identifiable {
    case blur
    case bloom
    case hueRotate
    case posterize
    case levels
    case glow
    case edges
    case pixellate
    case twirl
    case kaleidoscope

    var label: String {
        switch self {
        case .blur: return "Blur"
        case .bloom: return "Bloom"
        case .hueRotate: return "Hue Rotate"
        case .posterize: return "Posterize"
        case .levels: return "Levels"
        case .glow: return "Glow"
        case .edges: return "Edges"
        case .pixellate: return "Pixellate"
        case .twirl: return "Twirl"
        case .kaleidoscope: return "Kaleidoscope"
        }
    }

    var id: String { rawValue }
}

struct ScaleNodeSettings: Equatable, Codable {
    var min: Double = 0.0
    var max: Double = 1.0
    var scaledMin: Double = 0.0
    var scaledMax: Double = 1.0
}

struct SliderNodeSettings: Equatable, Codable {
    var min: Double = 0.0
    var max: Double = 1.0
    var value: Double = 0.5
    var x: Double = 0.5
    var y: Double = 0.84
    var width: Double = 0.32
    var height: Double = 0.08
    var label: String = "Slider"
}

struct SliderStyleNodeSettings: Equatable, Codable {
    var backgroundRed: Double = 0.08
    var backgroundGreen: Double = 0.08
    var backgroundBlue: Double = 0.08
    var backgroundAlpha: Double = 0.86
    var trackRed: Double = 0.22
    var trackGreen: Double = 0.22
    var trackBlue: Double = 0.22
    var trackThickness: Double = 0.30
    var knobRed: Double = 0.12
    var knobGreen: Double = 0.84
    var knobBlue: Double = 0.74
    var knobScale: Double = 1.0
    var knobSymbol: String = ""
    var textRed: Double = 1.0
    var textGreen: Double = 1.0
    var textBlue: Double = 1.0
    var fontSize: Double = 0.22
    var fontWeight: SliderFontWeight = .medium
    var fontName: String = ""

    enum CodingKeys: String, CodingKey {
        case backgroundRed
        case backgroundGreen
        case backgroundBlue
        case backgroundAlpha
        case trackRed
        case trackGreen
        case trackBlue
        case trackThickness
        case knobRed
        case knobGreen
        case knobBlue
        case knobScale
        case knobSymbol
        case textRed
        case textGreen
        case textBlue
        case fontSize
        case fontWeight
        case fontName
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backgroundRed = try container.decodeIfPresent(Double.self, forKey: .backgroundRed) ?? 0.08
        backgroundGreen = try container.decodeIfPresent(Double.self, forKey: .backgroundGreen) ?? 0.08
        backgroundBlue = try container.decodeIfPresent(Double.self, forKey: .backgroundBlue) ?? 0.08
        backgroundAlpha = try container.decodeIfPresent(Double.self, forKey: .backgroundAlpha) ?? 0.86
        trackRed = try container.decodeIfPresent(Double.self, forKey: .trackRed) ?? 0.22
        trackGreen = try container.decodeIfPresent(Double.self, forKey: .trackGreen) ?? 0.22
        trackBlue = try container.decodeIfPresent(Double.self, forKey: .trackBlue) ?? 0.22
        trackThickness = try container.decodeIfPresent(Double.self, forKey: .trackThickness) ?? 0.30
        knobRed = try container.decodeIfPresent(Double.self, forKey: .knobRed) ?? 0.12
        knobGreen = try container.decodeIfPresent(Double.self, forKey: .knobGreen) ?? 0.84
        knobBlue = try container.decodeIfPresent(Double.self, forKey: .knobBlue) ?? 0.74
        knobScale = try container.decodeIfPresent(Double.self, forKey: .knobScale) ?? 1.0
        knobSymbol = try container.decodeIfPresent(String.self, forKey: .knobSymbol) ?? ""
        textRed = try container.decodeIfPresent(Double.self, forKey: .textRed) ?? 1.0
        textGreen = try container.decodeIfPresent(Double.self, forKey: .textGreen) ?? 1.0
        textBlue = try container.decodeIfPresent(Double.self, forKey: .textBlue) ?? 1.0
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0.22
        fontWeight = try container.decodeIfPresent(SliderFontWeight.self, forKey: .fontWeight) ?? .medium
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? ""
    }
}

enum SliderFontWeight: String, CaseIterable, Codable, Identifiable {
    case regular
    case medium
    case semibold
    case bold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semibold: return "Semibold"
        case .bold: return "Bold"
        }
    }
}

struct ButtonNodeSettings: Equatable, Codable {
    var title: String = "Button"
    var sfSymbol: String = "play.fill"
    var x: Double = 0.5
    var y: Double = 0.84
    var width: Double = 0.16
    var height: Double = 0.1
}

struct ButtonStyleNodeSettings: Equatable, Codable {
    var fillRed: Double = 0.12
    var fillGreen: Double = 0.36
    var fillBlue: Double = 0.92
    var hoverRed: Double = 0.24
    var hoverGreen: Double = 0.5
    var hoverBlue: Double = 1.0
    var pressedRed: Double = 0.96
    var pressedGreen: Double = 0.2
    var pressedBlue: Double = 0.58
    var textRed: Double = 1.0
    var textGreen: Double = 1.0
    var textBlue: Double = 1.0

    enum CodingKeys: String, CodingKey {
        case fillRed
        case fillGreen
        case fillBlue
        case hoverRed
        case hoverGreen
        case hoverBlue
        case pressedRed
        case pressedGreen
        case pressedBlue
        case textRed
        case textGreen
        case textBlue
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fillRed = try container.decodeIfPresent(Double.self, forKey: .fillRed) ?? 0.12
        fillGreen = try container.decodeIfPresent(Double.self, forKey: .fillGreen) ?? 0.36
        fillBlue = try container.decodeIfPresent(Double.self, forKey: .fillBlue) ?? 0.92
        hoverRed = try container.decodeIfPresent(Double.self, forKey: .hoverRed) ?? 0.24
        hoverGreen = try container.decodeIfPresent(Double.self, forKey: .hoverGreen) ?? 0.5
        hoverBlue = try container.decodeIfPresent(Double.self, forKey: .hoverBlue) ?? 1.0
        pressedRed = try container.decodeIfPresent(Double.self, forKey: .pressedRed) ?? 0.96
        pressedGreen = try container.decodeIfPresent(Double.self, forKey: .pressedGreen) ?? 0.2
        pressedBlue = try container.decodeIfPresent(Double.self, forKey: .pressedBlue) ?? 0.58
        textRed = try container.decodeIfPresent(Double.self, forKey: .textRed) ?? 1.0
        textGreen = try container.decodeIfPresent(Double.self, forKey: .textGreen) ?? 1.0
        textBlue = try container.decodeIfPresent(Double.self, forKey: .textBlue) ?? 1.0
    }
}

struct SelectNodeSettings: Equatable, Codable {
    var selectValue: Double = 0.0
    var threshold: Double = 0.5
    var scalarA: Double = 0.0
    var scalarB: Double = 1.0
    var stringA: String = ""
    var stringB: String = ""
    var colorA: ArrayColorValue = .init(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    var colorB: ArrayColorValue = .init(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

    enum CodingKeys: String, CodingKey {
        case selectValue
        case threshold
        case scalarA
        case scalarB
        case stringA
        case stringB
        case colorA
        case colorB
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectValue = try container.decodeIfPresent(Double.self, forKey: .selectValue) ?? 0.0
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.5
        scalarA = try container.decodeIfPresent(Double.self, forKey: .scalarA) ?? 0.0
        scalarB = try container.decodeIfPresent(Double.self, forKey: .scalarB) ?? 1.0
        stringA = try container.decodeIfPresent(String.self, forKey: .stringA) ?? ""
        stringB = try container.decodeIfPresent(String.self, forKey: .stringB) ?? ""
        colorA = try container.decodeIfPresent(ArrayColorValue.self, forKey: .colorA) ?? .init(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        colorB = try container.decodeIfPresent(ArrayColorValue.self, forKey: .colorB) ?? .init(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
    }
}

enum InterpolatorEasing: String, CaseIterable, Identifiable, Codable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In Out"
        }
    }
}

struct InterpolatorNodeSettings: Equatable, Codable {
    var start: Double = 0.0
    var end: Double = 1.0
    var duration: Double = 2.0
    var phase: Double = 0.0
    var autoreverses: Bool = true
    var easing: InterpolatorEasing = .easeInOut
}

struct PointInterpolatorNodeSettings: Equatable, Codable {
    var startX: Double = 0.0
    var startY: Double = 0.0
    var endX: Double = 1.0
    var endY: Double = 1.0
    var duration: Double = 2.0
    var phase: Double = 0.0
    var autoreverses: Bool = true
    var easing: InterpolatorEasing = .easeInOut
}

struct Point3InterpolatorNodeSettings: Equatable, Codable {
    var start: Point3Value = Point3Value(x: 0.0, y: 0.0, z: 0.0)
    var end: Point3Value = Point3Value(x: 1.0, y: 1.0, z: 1.0)
    var duration: Double = 2.0
    var phase: Double = 0.0
    var autoreverses: Bool = true
    var easing: InterpolatorEasing = .easeInOut
}

struct Point4InterpolatorNodeSettings: Equatable, Codable {
    var start: Point4Value = Point4Value(x: 0.0, y: 0.0, z: 0.0, w: 0.0)
    var end: Point4Value = Point4Value(x: 1.0, y: 1.0, z: 1.0, w: 1.0)
    var duration: Double = 2.0
    var phase: Double = 0.0
    var autoreverses: Bool = true
    var easing: InterpolatorEasing = .easeInOut
}

struct PointScaleNodeSettings: Equatable, Codable {
    var x: Double = 0.0
    var y: Double = 0.0
    var scale: Double = 1.0
}

struct Point3ScaleNodeSettings: Equatable, Codable {
    var value: Point3Value = Point3Value(x: 0.0, y: 0.0, z: 0.0)
    var scale: Double = 1.0
}

struct Point4ScaleNodeSettings: Equatable, Codable {
    var value: Point4Value = Point4Value(x: 0.0, y: 0.0, z: 0.0, w: 0.0)
    var scale: Double = 1.0
}

struct HoldNodeSettings: Equatable, Codable {
    var threshold: Double = 0.5
    var initialValue: Double = 0.0
}

enum ScalarSmoothMode: String, CaseIterable, Codable, Identifiable {
    case smooth
    case inertia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smooth: return "Smooth"
        case .inertia: return "Inertia"
        }
    }
}

struct ScalarSmoothNodeSettings: Equatable, Codable {
    var initialValue: Double = 0.0
    var amount: Double = 0.18
    var inertia: Double = 0.72
    var mode: ScalarSmoothMode = .smooth
}

struct RandomNodeSettings: Equatable, Codable {
    var min: Double = 0.0
    var max: Double = 1.0
    var trigger: Double = 0.0
    var rate: Double = 4.0
    var threshold: Double = 0.5
    var continuous: Bool = false

    enum CodingKeys: String, CodingKey {
        case min
        case max
        case trigger
        case rate
        case threshold
        case continuous
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        min = try container.decodeIfPresent(Double.self, forKey: .min) ?? 0.0
        max = try container.decodeIfPresent(Double.self, forKey: .max) ?? 1.0
        trigger = try container.decodeIfPresent(Double.self, forKey: .trigger) ?? 0.0
        rate = try container.decodeIfPresent(Double.self, forKey: .rate) ?? 4.0
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.5
        continuous = try container.decodeIfPresent(Bool.self, forKey: .continuous) ?? false
    }
}

struct PulseNodeSettings: Equatable, Codable {
    var gate: Double = 0.0
    var threshold: Double = 0.5

    enum CodingKeys: String, CodingKey {
        case gate
        case threshold
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gate = try container.decodeIfPresent(Double.self, forKey: .gate) ?? 0.0
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.5
    }
}

struct CounterNodeSettings: Equatable, Codable {
    var trigger: Double = 0.0
    var reset: Double = 0.0
    var step: Double = 1.0
    var minimum: Double = 0.0
    var maximum: Double = 10.0
    var initialValue: Double = 0.0
    var threshold: Double = 0.5
    var wrap: Bool = true

    enum CodingKeys: String, CodingKey {
        case trigger
        case reset
        case step
        case minimum
        case maximum
        case initialValue
        case threshold
        case wrap
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decodeIfPresent(Double.self, forKey: .trigger) ?? 0.0
        reset = try container.decodeIfPresent(Double.self, forKey: .reset) ?? 0.0
        step = try container.decodeIfPresent(Double.self, forKey: .step) ?? 1.0
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum) ?? 0.0
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum) ?? 10.0
        initialValue = try container.decodeIfPresent(Double.self, forKey: .initialValue) ?? 0.0
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.5
        wrap = try container.decodeIfPresent(Bool.self, forKey: .wrap) ?? true
    }
}

struct ToggleNodeSettings: Equatable, Codable {
    var trigger: Double = 0.0
    var reset: Double = 0.0
    var threshold: Double = 0.5
    var initialOn: Bool = false

    enum CodingKeys: String, CodingKey {
        case trigger
        case reset
        case threshold
        case initialOn
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decodeIfPresent(Double.self, forKey: .trigger) ?? 0.0
        reset = try container.decodeIfPresent(Double.self, forKey: .reset) ?? 0.0
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.5
        initialOn = try container.decodeIfPresent(Bool.self, forKey: .initialOn) ?? false
    }
}

struct DelayNodeSettings: Equatable, Codable {
    var trigger: Double = 0.0
    var duration: Double = 0.5
    var threshold: Double = 0.5

    enum CodingKeys: String, CodingKey {
        case trigger
        case duration
        case threshold
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decodeIfPresent(Double.self, forKey: .trigger) ?? 0.0
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0.5
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.5
    }
}

struct TimerNodeSettings: Equatable, Codable {
    var enabled: Double = 1.0
    var interval: Double = 1.0
    var threshold: Double = 0.5

    enum CodingKeys: String, CodingKey {
        case enabled
        case interval
        case threshold
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Double.self, forKey: .enabled) ?? 1.0
        interval = try container.decodeIfPresent(Double.self, forKey: .interval) ?? 1.0
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.5
    }
}

struct TrailNodeSettings: Equatable, Codable {
    var radius: Double = 0.035
    var duration: Double = 1.2
}

struct CircleNodeSettings: Equatable, Codable {
    var radius: Double = 0.02
    var softness: Double = 0.35
    var red: Double = 1.0
    var green: Double = 0.2
    var blue: Double = 0.2
    var alpha: Double = 1.0
}

struct NoteNodeSettings: Equatable, Codable {
    var text: String = "Note"
    var textRed: Double = 1.0
    var textGreen: Double = 1.0
    var textBlue: Double = 1.0
    var backgroundRed: Double = 0.18
    var backgroundGreen: Double = 0.16
    var backgroundBlue: Double = 0.08
    var backgroundAlpha: Double = 0.9
    var fontSize: Double = 42.0
}

struct StringNodeSettings: Equatable, Codable {
    var value: String = "Text"
}

struct ScalarVariableNodeSettings: Equatable, Codable {
    var value: Double = 0.0
}

struct StringVariableNodeSettings: Equatable, Codable {
    var value: String = ""
}

struct Point3Value: Equatable, Hashable, Codable {
    var x: Double = 0.0
    var y: Double = 0.0
    var z: Double = 0.0
}

struct Point4Value: Equatable, Hashable, Codable {
    var x: Double = 0.0
    var y: Double = 0.0
    var z: Double = 0.0
    var w: Double = 0.0
}

struct PointCombineNodeSettings: Equatable, Codable {
    var x: Double = 0.5
    var y: Double = 0.5
}

struct Point3CombineNodeSettings: Equatable, Codable {
    var x: Double = 0.0
    var y: Double = 0.0
    var z: Double = 0.0
}

struct Point4CombineNodeSettings: Equatable, Codable {
    var x: Double = 0.0
    var y: Double = 0.0
    var z: Double = 0.0
    var w: Double = 0.0
}

struct StringFormatNodeSettings: Equatable, Codable {
    var template: String = "{0}"
    var text1: String = ""
    var text2: String = ""
    var text3: String = ""
    var text4: String = ""
}

enum StringCompareOperation: String, CaseIterable, Identifiable, Codable {
    case equal
    case notEqual
    case contains
    case startsWith
    case endsWith

    var id: String { rawValue }

    var label: String {
        switch self {
        case .equal: return "="
        case .notEqual: return "!="
        case .contains: return "contains"
        case .startsWith: return "starts"
        case .endsWith: return "ends"
        }
    }
}

struct StringCompareNodeSettings: Equatable, Codable {
    var operation: StringCompareOperation = .equal
    var left: String = ""
    var right: String = ""
    var caseSensitive: Bool = true
}

struct StringSplitNodeSettings: Equatable, Codable {
    var separator: String = ","
    var text: String = ""
    var index: Double = 0.0
}

struct ColorNodeSettings: Equatable, Codable {
    var red: Double = 1.0
    var green: Double = 1.0
    var blue: Double = 1.0
    var alpha: Double = 1.0
}

struct HSLColorNodeSettings: Equatable, Codable {
    var hue: Double = 0.0
    var saturation: Double = 1.0
    var lightness: Double = 0.5
    var alpha: Double = 1.0
}

struct ScalarArrayNodeSettings: Equatable, Codable {
    var count: Int = 4
    var values: [Double] = [0.0, 0.0, 0.0, 0.0]

    private enum CodingKeys: String, CodingKey {
        case count
        case values
        case value1
        case value2
        case value3
        case value4
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = max(1, try container.decodeIfPresent(Int.self, forKey: .count) ?? 4)
        if let values = try container.decodeIfPresent([Double].self, forKey: .values) {
            self.values = values
        } else {
            self.values = [
                try container.decodeIfPresent(Double.self, forKey: .value1) ?? 0.0,
                try container.decodeIfPresent(Double.self, forKey: .value2) ?? 0.0,
                try container.decodeIfPresent(Double.self, forKey: .value3) ?? 0.0,
                try container.decodeIfPresent(Double.self, forKey: .value4) ?? 0.0
            ]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(values, forKey: .values)
    }
}

struct StringArrayNodeSettings: Equatable, Codable {
    var count: Int = 4
    var values: [String] = ["", "", "", ""]

    private enum CodingKeys: String, CodingKey {
        case count
        case values
        case value1
        case value2
        case value3
        case value4
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = max(1, try container.decodeIfPresent(Int.self, forKey: .count) ?? 4)
        if let values = try container.decodeIfPresent([String].self, forKey: .values) {
            self.values = values
        } else {
            self.values = [
                try container.decodeIfPresent(String.self, forKey: .value1) ?? "",
                try container.decodeIfPresent(String.self, forKey: .value2) ?? "",
                try container.decodeIfPresent(String.self, forKey: .value3) ?? "",
                try container.decodeIfPresent(String.self, forKey: .value4) ?? ""
            ]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(values, forKey: .values)
    }
}

struct ArrayColorValue: Equatable, Codable {
    var red: Double = 1.0
    var green: Double = 1.0
    var blue: Double = 1.0
    var alpha: Double = 1.0
}

struct ColorArrayNodeSettings: Equatable, Codable {
    var count: Int = 4
    var values: [ArrayColorValue] = Array(repeating: ArrayColorValue(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0), count: 4)

    private enum CodingKeys: String, CodingKey {
        case count
        case values
        case value1
        case value2
        case value3
        case value4
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = max(1, try container.decodeIfPresent(Int.self, forKey: .count) ?? 4)
        if let values = try container.decodeIfPresent([ArrayColorValue].self, forKey: .values) {
            self.values = values
        } else {
            self.values = [
                try container.decodeIfPresent(ArrayColorValue.self, forKey: .value1) ?? ArrayColorValue(),
                try container.decodeIfPresent(ArrayColorValue.self, forKey: .value2) ?? ArrayColorValue(),
                try container.decodeIfPresent(ArrayColorValue.self, forKey: .value3) ?? ArrayColorValue(),
                try container.decodeIfPresent(ArrayColorValue.self, forKey: .value4) ?? ArrayColorValue()
            ]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(values, forKey: .values)
    }
}

struct ImageArrayNodeSettings: Equatable, Codable {
    var count: Int = 4
}

struct ScalarArrayIndexNodeSettings: Equatable, Codable {
    var index: Double = 0.0
}

struct StringArrayIndexNodeSettings: Equatable, Codable {
    var index: Double = 0.0
}

struct ColorArrayIndexNodeSettings: Equatable, Codable {
    var index: Double = 0.0
}

struct TextImageNodeSettings: Equatable, Codable {
    var text: String = "Text"
    var textRed: Double = 1.0
    var textGreen: Double = 1.0
    var textBlue: Double = 1.0
    var backgroundRed: Double = 0.0
    var backgroundGreen: Double = 0.0
    var backgroundBlue: Double = 0.0
    var backgroundAlpha: Double = 0.0
    var fontSize: Double = 42.0
    var fontName: String = ""
    var x: Double = 0.5
    var y: Double = 0.5

    enum CodingKeys: String, CodingKey {
        case text
        case textRed
        case textGreen
        case textBlue
        case backgroundRed
        case backgroundGreen
        case backgroundBlue
        case backgroundAlpha
        case fontSize
        case fontName
        case x
        case y
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? "Text"
        textRed = try container.decodeIfPresent(Double.self, forKey: .textRed) ?? 1.0
        textGreen = try container.decodeIfPresent(Double.self, forKey: .textGreen) ?? 1.0
        textBlue = try container.decodeIfPresent(Double.self, forKey: .textBlue) ?? 1.0
        backgroundRed = try container.decodeIfPresent(Double.self, forKey: .backgroundRed) ?? 0.0
        backgroundGreen = try container.decodeIfPresent(Double.self, forKey: .backgroundGreen) ?? 0.0
        backgroundBlue = try container.decodeIfPresent(Double.self, forKey: .backgroundBlue) ?? 0.0
        backgroundAlpha = try container.decodeIfPresent(Double.self, forKey: .backgroundAlpha) ?? 0.0
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 42.0
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? ""
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
    }
}

enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case wipe
    case radial
    case checker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wipe: return "Wipe"
        case .radial: return "Radial"
        case .checker: return "Checker"
        }
    }
}

struct TransitionNodeSettings: Equatable, Codable {
    var progress: Double = 0.5
    var style: TransitionStyle = .wipe
    var softness: Double = 0.08

    enum CodingKeys: String, CodingKey {
        case progress
        case style
        case softness
    }

    init(progress: Double = 0.5, style: TransitionStyle = .wipe, softness: Double = 0.08) {
        self.progress = progress
        self.style = style
        self.softness = softness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0.5
        style = try container.decodeIfPresent(TransitionStyle.self, forKey: .style) ?? .wipe
        softness = try container.decodeIfPresent(Double.self, forKey: .softness) ?? 0.08
    }
}

struct TransformNodeSettings: Equatable, Codable {
    var x: Double = 0.5
    var y: Double = 0.5
    var z: Double = 0.0
    var scaleX: Double = 1.0
    var scaleY: Double = 1.0
    var rotationX: Double = 0.0
    var rotationY: Double = 0.0
    var rotationZ: Double = 0.0
    var opacity: Double = 1.0

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case z
        case scaleX
        case scaleY
        case rotation
        case rotationX
        case rotationY
        case rotationZ
        case opacity
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        z = try container.decodeIfPresent(Double.self, forKey: .z) ?? 0.0
        scaleX = try container.decodeIfPresent(Double.self, forKey: .scaleX) ?? 1.0
        scaleY = try container.decodeIfPresent(Double.self, forKey: .scaleY) ?? 1.0
        let legacyRotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0.0
        rotationX = try container.decodeIfPresent(Double.self, forKey: .rotationX) ?? 0.0
        rotationY = try container.decodeIfPresent(Double.self, forKey: .rotationY) ?? 0.0
        rotationZ = try container.decodeIfPresent(Double.self, forKey: .rotationZ) ?? legacyRotation
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(z, forKey: .z)
        try container.encode(scaleX, forKey: .scaleX)
        try container.encode(scaleY, forKey: .scaleY)
        try container.encode(rotationX, forKey: .rotationX)
        try container.encode(rotationY, forKey: .rotationY)
        try container.encode(rotationZ, forKey: .rotationZ)
        try container.encode(opacity, forKey: .opacity)
    }
}

struct BillboardNodeSettings: Equatable, Codable {
    var x: Double = 0.5
    var y: Double = 0.5
    var z: Double = 0.0
    var width: Double = 0.28
    var height: Double = 0.18
    var rotationX: Double = 0.0
    var rotationY: Double = 0.0
    var rotationZ: Double = 0.0
    var opacity: Double = 1.0
    var red: Double = 1.0
    var green: Double = 1.0
    var blue: Double = 1.0
    var alpha: Double = 1.0

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case z
        case width
        case height
        case rotation
        case rotationX
        case rotationY
        case rotationZ
        case opacity
        case red
        case green
        case blue
        case alpha
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        z = try container.decodeIfPresent(Double.self, forKey: .z) ?? 0.0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0.28
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 0.18
        let legacyRotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0.0
        rotationX = try container.decodeIfPresent(Double.self, forKey: .rotationX) ?? 0.0
        rotationY = try container.decodeIfPresent(Double.self, forKey: .rotationY) ?? 0.0
        rotationZ = try container.decodeIfPresent(Double.self, forKey: .rotationZ) ?? legacyRotation
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? 1.0
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? 1.0
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? 1.0
        alpha = try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(z, forKey: .z)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(rotationX, forKey: .rotationX)
        try container.encode(rotationY, forKey: .rotationY)
        try container.encode(rotationZ, forKey: .rotationZ)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(red, forKey: .red)
        try container.encode(green, forKey: .green)
        try container.encode(blue, forKey: .blue)
        try container.encode(alpha, forKey: .alpha)
    }
}

struct LineNodeSettings: Equatable, Codable {
    var x1: Double = 0.2
    var y1: Double = 0.2
    var x2: Double = 0.8
    var y2: Double = 0.2
    var z: Double = 0.0
    var thickness: Double = 0.02
    var opacity: Double = 1.0
    var red: Double = 1.0
    var green: Double = 1.0
    var blue: Double = 1.0
    var alpha: Double = 1.0
}

enum Scene3DPrimitiveKind: String, CaseIterable, Codable, Identifiable {
    case box
    case sphere
    case capsule
    case cone
    case cylinder
    case torus
    case plane
    case terrain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .box: return "Box"
        case .sphere: return "Sphere"
        case .capsule: return "Capsule"
        case .cone: return "Cone"
        case .cylinder: return "Cylinder"
        case .torus: return "Torus"
        case .plane: return "Plane"
        case .terrain: return "Terrain"
        }
    }
}

enum Scene3DLightType: String, CaseIterable, Codable, Identifiable {
    case omni
    case directional
    case spot
    case ambient

    var id: String { rawValue }

    var label: String {
        switch self {
        case .omni: return "Omni"
        case .directional: return "Directional"
        case .spot: return "Spot"
        case .ambient: return "Ambient"
        }
    }
}

struct Scene3DLightNodeSettings: Equatable, Codable {
    var type: Scene3DLightType = .omni
    var positionX: Double = 2.5
    var positionY: Double = 3.0
    var positionZ: Double = 5.0
    var rotationX: Double = -40.0
    var rotationY: Double = 40.0
    var rotationZ: Double = 0.0
    var intensity: Double = 1100.0
    var red: Double = 1.0
    var green: Double = 1.0
    var blue: Double = 1.0
    var alpha: Double = 1.0
    var innerSpotAngle: Double = 25.0
    var outerSpotAngle: Double = 50.0
    var castsShadow: Bool = false
}

struct Scene3DPrimitiveNodeSettings: Equatable, Codable {
    var primitive: Scene3DPrimitiveKind = .box
    var positionX: Double = 0.0
    var positionY: Double = 0.0
    var positionZ: Double = 0.0
    var rotationX: Double = 22.0
    var rotationY: Double = 30.0
    var rotationZ: Double = 0.0
    var scale: Double = 1.0
    var cameraDistance: Double = 4.0
    var cameraOrbit: Double = 0.0
    var cameraPitch: Double = 16.0
    var cameraPanX: Double = 0.0
    var cameraPanY: Double = 0.0
    var lightIntensity: Double = 1100.0
    var materialRed: Double = 0.84
    var materialGreen: Double = 0.9
    var materialBlue: Double = 1.0
    var materialAlpha: Double = 1.0
    var backgroundAlpha: Double = 0.0
    var terrainWidth: Double = 24.0
    var terrainDepth: Double = 24.0
    var terrainSegments: Double = 96.0
}

struct Scene3DTextNodeSettings: Equatable, Codable {
    var text: String = "Metal Composer"
    var fontName: String = ""
    var fontSize: Double = 1.0
    var extrusionDepth: Double = 0.24
    var chamferRadius: Double = 0.03
    var flatness: Double = 0.2
    var positionX: Double = 0.0
    var positionY: Double = 0.0
    var positionZ: Double = 0.0
    var rotationX: Double = 18.0
    var rotationY: Double = 0.0
    var rotationZ: Double = 0.0
    var scale: Double = 0.75
    var cameraDistance: Double = 6.0
    var cameraOrbit: Double = 0.0
    var cameraPitch: Double = 8.0
    var cameraPanX: Double = 0.0
    var cameraPanY: Double = 0.0
    var lightIntensity: Double = 1200.0
    var materialRed: Double = 0.92
    var materialGreen: Double = 0.95
    var materialBlue: Double = 1.0
    var materialAlpha: Double = 1.0
    var backgroundAlpha: Double = 0.0
}

struct Scene3DModelNodeSettings: Equatable, Codable {
    var filename: String = "Model"
    var bookmarkData: Data = Data()
    var parentFolderBookmarkData: Data = Data()
    var positionX: Double = 0.0
    var positionY: Double = 0.0
    var positionZ: Double = 0.0
    var rotationX: Double = 0.0
    var rotationY: Double = 0.0
    var rotationZ: Double = 0.0
    var scale: Double = 1.0
    var cameraDistance: Double = 6.0
    var cameraOrbit: Double = 0.0
    var cameraPitch: Double = 12.0
    var cameraPanX: Double = 0.0
    var cameraPanY: Double = 0.0
    var lightIntensity: Double = 100.0
    var animationPlay: Double = 1.0
    var animationClipStart: Double = 0.0
    var animationClipEnd: Double = 1.0
    var animationSpeed: Double = 1.0
    var animationLoops: Bool = true
    var backgroundAlpha: Double = 0.0
}

struct Scene3DGaussianSplatNodeSettings: Equatable, Codable {
    var filename: String = "Gaussian Splat"
    var bookmarkData: Data = Data()
    var panoramaImageData: Data = Data()
    var panoramaDepthImageData: Data = Data()
    var positionX: Double = 0.0
    var positionY: Double = 0.0
    var positionZ: Double = 0.0
    var rotationX: Double = 0.0
    var rotationY: Double = 0.0
    var rotationZ: Double = 0.0
    var scale: Double = 1.0
    var cameraDistance: Double = 5.0
    var cameraOrbit: Double = 0.0
    var cameraPitch: Double = 0.0
    var cameraPanX: Double = 0.0
    var cameraPanY: Double = 0.0
    var pointSize: Double = 1.0
    var opacity: Double = 1.0
    var explode: Double = 0.0
    var chaos: Double = 0.0
    var particleSpeed: Double = 0.8
    var particleGravity: Double = 0.0
    var particleTurbulence: Double = 0.25
    var particleBoundary: Double = 25.0
    var maxSplats: Double = 250_000.0
    var panoramaRadius: Double = 2.0
    var panoramaDepthScale: Double = 1.0
    var autoCenter: Bool = true
    var autoScale: Bool = true
    var backgroundAlpha: Double = 0.0

    init() {}

    init(filename: String = "Gaussian Splat", bookmarkData: Data = Data()) {
        self.filename = filename
        self.bookmarkData = bookmarkData
    }

    private enum CodingKeys: String, CodingKey {
        case filename
        case bookmarkData
        case panoramaImageData
        case panoramaDepthImageData
        case positionX
        case positionY
        case positionZ
        case rotationX
        case rotationY
        case rotationZ
        case scale
        case cameraDistance
        case cameraOrbit
        case cameraPitch
        case cameraPanX
        case cameraPanY
        case pointSize
        case opacity
        case explode
        case chaos
        case particleSpeed
        case particleGravity
        case particleTurbulence
        case particleBoundary
        case maxSplats
        case panoramaRadius
        case panoramaDepthScale
        case autoCenter
        case autoScale
        case backgroundAlpha
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "Gaussian Splat"
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData) ?? Data()
        panoramaImageData = try container.decodeIfPresent(Data.self, forKey: .panoramaImageData) ?? Data()
        panoramaDepthImageData = try container.decodeIfPresent(Data.self, forKey: .panoramaDepthImageData) ?? Data()
        positionX = try container.decodeIfPresent(Double.self, forKey: .positionX) ?? 0.0
        positionY = try container.decodeIfPresent(Double.self, forKey: .positionY) ?? 0.0
        positionZ = try container.decodeIfPresent(Double.self, forKey: .positionZ) ?? 0.0
        rotationX = try container.decodeIfPresent(Double.self, forKey: .rotationX) ?? 0.0
        rotationY = try container.decodeIfPresent(Double.self, forKey: .rotationY) ?? 0.0
        rotationZ = try container.decodeIfPresent(Double.self, forKey: .rotationZ) ?? 0.0
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        cameraDistance = try container.decodeIfPresent(Double.self, forKey: .cameraDistance) ?? 5.0
        cameraOrbit = try container.decodeIfPresent(Double.self, forKey: .cameraOrbit) ?? 0.0
        cameraPitch = try container.decodeIfPresent(Double.self, forKey: .cameraPitch) ?? 0.0
        cameraPanX = try container.decodeIfPresent(Double.self, forKey: .cameraPanX) ?? 0.0
        cameraPanY = try container.decodeIfPresent(Double.self, forKey: .cameraPanY) ?? 0.0
        pointSize = try container.decodeIfPresent(Double.self, forKey: .pointSize) ?? 1.0
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        explode = try container.decodeIfPresent(Double.self, forKey: .explode) ?? 0.0
        chaos = try container.decodeIfPresent(Double.self, forKey: .chaos) ?? 0.0
        particleSpeed = try container.decodeIfPresent(Double.self, forKey: .particleSpeed) ?? 0.8
        particleGravity = try container.decodeIfPresent(Double.self, forKey: .particleGravity) ?? 0.0
        particleTurbulence = try container.decodeIfPresent(Double.self, forKey: .particleTurbulence) ?? 0.25
        particleBoundary = try container.decodeIfPresent(Double.self, forKey: .particleBoundary) ?? 25.0
        maxSplats = try container.decodeIfPresent(Double.self, forKey: .maxSplats) ?? 250_000.0
        panoramaRadius = try container.decodeIfPresent(Double.self, forKey: .panoramaRadius) ?? 2.0
        panoramaDepthScale = try container.decodeIfPresent(Double.self, forKey: .panoramaDepthScale) ?? 1.0
        autoCenter = try container.decodeIfPresent(Bool.self, forKey: .autoCenter) ?? true
        autoScale = try container.decodeIfPresent(Bool.self, forKey: .autoScale) ?? true
        backgroundAlpha = try container.decodeIfPresent(Double.self, forKey: .backgroundAlpha) ?? 0.0
    }
}

enum Scene3DParticleShape: String, CaseIterable, Codable, Identifiable {
    case point
    case sphere
    case box

    var id: String { rawValue }

    var label: String {
        switch self {
        case .point: return "Point"
        case .sphere: return "Sphere"
        case .box: return "Box"
        }
    }
}

enum Scene3DParticleBlendMode: String, CaseIterable, Codable, Identifiable {
    case alpha
    case additive
    case screen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alpha: return "Alpha"
        case .additive: return "Additive"
        case .screen: return "Screen"
        }
    }
}

enum Scene3DParticleSpriteStyle: String, CaseIterable, Codable, Identifiable {
    case glow
    case fish
    case dust

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glow: return "Glow"
        case .fish: return "Fish"
        case .dust: return "Dust"
        }
    }
}

struct Scene3DParticleNodeSettings: Equatable, Codable {
    var shape: Scene3DParticleShape = .point
    var blendMode: Scene3DParticleBlendMode = .additive
    var spriteStyle: Scene3DParticleSpriteStyle = .glow
    var positionX: Double = 0.0
    var positionY: Double = 0.0
    var positionZ: Double = 0.0
    var rotationX: Double = 0.0
    var rotationY: Double = 0.0
    var rotationZ: Double = 0.0
    var scale: Double = 1.0
    var particleCount: Double = 1100.0
    var birthRate: Double = 550.0
    var lifetime: Double = 2.0
    var speed: Double = 1.2
    var spread: Double = 120.0
    var boxWidth: Double = 1.0
    var boxHeight: Double = 1.0
    var boxDepth: Double = 1.0
    var size: Double = 0.045
    var red: Double = 0.55
    var green: Double = 0.82
    var blue: Double = 1.0
    var alpha: Double = 0.85
    var spriteFlipX: Bool = false
    var spriteFlipY: Bool = false
    var spriteSheetColumns: Double = 1.0
    var spriteSheetRows: Double = 1.0
    var spriteSheetCount: Double = 1.0
    var spriteSheetRandom: Bool = true
    var spriteWobble: Double = 0.0
    var spriteWobbleSpeed: Double = 1.0
    var gravityY: Double = -0.25
    var cameraDistance: Double = 6.0
    var cameraOrbit: Double = 0.0
    var cameraPitch: Double = 12.0
    var cameraPanX: Double = 0.0
    var cameraPanY: Double = 0.0
    var backgroundAlpha: Double = 0.0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case shape
        case blendMode
        case spriteStyle
        case positionX
        case positionY
        case positionZ
        case rotationX
        case rotationY
        case rotationZ
        case scale
        case particleCount
        case birthRate
        case lifetime
        case speed
        case spread
        case boxWidth
        case boxHeight
        case boxDepth
        case size
        case red
        case green
        case blue
        case alpha
        case spriteFlipX
        case spriteFlipY
        case spriteSheetColumns
        case spriteSheetRows
        case spriteSheetCount
        case spriteSheetRandom
        case spriteWobble
        case spriteWobbleSpeed
        case gravityY
        case cameraDistance
        case cameraOrbit
        case cameraPitch
        case cameraPanX
        case cameraPanY
        case backgroundAlpha
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decodeIfPresent(Scene3DParticleShape.self, forKey: .shape) ?? .point
        blendMode = try container.decodeIfPresent(Scene3DParticleBlendMode.self, forKey: .blendMode) ?? .additive
        spriteStyle = try container.decodeIfPresent(Scene3DParticleSpriteStyle.self, forKey: .spriteStyle) ?? .glow
        positionX = try container.decodeIfPresent(Double.self, forKey: .positionX) ?? 0.0
        positionY = try container.decodeIfPresent(Double.self, forKey: .positionY) ?? 0.0
        positionZ = try container.decodeIfPresent(Double.self, forKey: .positionZ) ?? 0.0
        rotationX = try container.decodeIfPresent(Double.self, forKey: .rotationX) ?? 0.0
        rotationY = try container.decodeIfPresent(Double.self, forKey: .rotationY) ?? 0.0
        rotationZ = try container.decodeIfPresent(Double.self, forKey: .rotationZ) ?? 0.0
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        particleCount = try container.decodeIfPresent(Double.self, forKey: .particleCount) ?? 1100.0
        birthRate = try container.decodeIfPresent(Double.self, forKey: .birthRate) ?? 550.0
        lifetime = try container.decodeIfPresent(Double.self, forKey: .lifetime) ?? 2.0
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1.2
        spread = try container.decodeIfPresent(Double.self, forKey: .spread) ?? 120.0
        boxWidth = try container.decodeIfPresent(Double.self, forKey: .boxWidth) ?? 1.0
        boxHeight = try container.decodeIfPresent(Double.self, forKey: .boxHeight) ?? 1.0
        boxDepth = try container.decodeIfPresent(Double.self, forKey: .boxDepth) ?? 1.0
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 0.045
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? 0.55
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? 0.82
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? 1.0
        alpha = try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 0.85
        spriteFlipX = try container.decodeIfPresent(Bool.self, forKey: .spriteFlipX) ?? false
        spriteFlipY = try container.decodeIfPresent(Bool.self, forKey: .spriteFlipY) ?? false
        spriteSheetColumns = try container.decodeIfPresent(Double.self, forKey: .spriteSheetColumns) ?? 1.0
        spriteSheetRows = try container.decodeIfPresent(Double.self, forKey: .spriteSheetRows) ?? 1.0
        spriteSheetCount = try container.decodeIfPresent(Double.self, forKey: .spriteSheetCount) ?? 1.0
        spriteSheetRandom = try container.decodeIfPresent(Bool.self, forKey: .spriteSheetRandom) ?? true
        spriteWobble = try container.decodeIfPresent(Double.self, forKey: .spriteWobble) ?? 0.0
        spriteWobbleSpeed = try container.decodeIfPresent(Double.self, forKey: .spriteWobbleSpeed) ?? 1.0
        gravityY = try container.decodeIfPresent(Double.self, forKey: .gravityY) ?? -0.25
        cameraDistance = try container.decodeIfPresent(Double.self, forKey: .cameraDistance) ?? 6.0
        cameraOrbit = try container.decodeIfPresent(Double.self, forKey: .cameraOrbit) ?? 0.0
        cameraPitch = try container.decodeIfPresent(Double.self, forKey: .cameraPitch) ?? 12.0
        cameraPanX = try container.decodeIfPresent(Double.self, forKey: .cameraPanX) ?? 0.0
        cameraPanY = try container.decodeIfPresent(Double.self, forKey: .cameraPanY) ?? 0.0
        backgroundAlpha = try container.decodeIfPresent(Double.self, forKey: .backgroundAlpha) ?? 0.0
    }
}

struct Scene3DTransformNodeSettings: Equatable, Codable {
    var x: Double = 0.0
    var y: Double = 0.0
    var z: Double = 0.0
    var scaleX: Double = 1.0
    var scaleY: Double = 1.0
    var scaleZ: Double = 1.0
    var rotationX: Double = 0.0
    var rotationY: Double = 0.0
    var rotationZ: Double = 0.0
}

struct Scene3DTileNodeSettings: Equatable, Codable {
    var centerX: Double = 0.0
    var centerY: Double = 0.0
    var centerZ: Double = 0.0
    var spacingX: Double = 20.0
    var spacingY: Double = 0.0
    var spacingZ: Double = 20.0
    var fieldX: Double = 80.0
    var fieldY: Double = 0.0
    var fieldZ: Double = 80.0
}

struct Scene3DRenderNodeSettings: Equatable, Codable {
    var sceneCount: Int = 4
    var cameraDistance: Double = 6.0
    var cameraOrbit: Double = 0.0
    var cameraPitch: Double = 12.0
    var cameraPanX: Double = 0.0
    var cameraPanY: Double = 0.0
    var backgroundAlpha: Double = 0.0
    var defaultLightIntensity: Double = 100.0
    var waterDistortion: Double = 0.0
    var waterScale: Double = 3.2
    var waterSpeed: Double = 1.0

    enum CodingKeys: String, CodingKey {
        case sceneCount
        case cameraDistance
        case cameraOrbit
        case cameraPitch
        case cameraPanX
        case cameraPanY
        case backgroundAlpha
        case defaultLightIntensity
        case waterDistortion
        case waterScale
        case waterSpeed
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sceneCount = try container.decodeIfPresent(Int.self, forKey: .sceneCount) ?? 4
        cameraDistance = try container.decodeIfPresent(Double.self, forKey: .cameraDistance) ?? 6.0
        cameraOrbit = try container.decodeIfPresent(Double.self, forKey: .cameraOrbit) ?? 0.0
        cameraPitch = try container.decodeIfPresent(Double.self, forKey: .cameraPitch) ?? 12.0
        cameraPanX = try container.decodeIfPresent(Double.self, forKey: .cameraPanX) ?? 0.0
        cameraPanY = try container.decodeIfPresent(Double.self, forKey: .cameraPanY) ?? 0.0
        backgroundAlpha = try container.decodeIfPresent(Double.self, forKey: .backgroundAlpha) ?? 0.0
        defaultLightIntensity = try container.decodeIfPresent(Double.self, forKey: .defaultLightIntensity) ?? 100.0
        waterDistortion = try container.decodeIfPresent(Double.self, forKey: .waterDistortion) ?? 0.0
        waterScale = try container.decodeIfPresent(Double.self, forKey: .waterScale) ?? 3.2
        waterSpeed = try container.decodeIfPresent(Double.self, forKey: .waterSpeed) ?? 1.0
    }
}

extension Scene3DLightNodeSettings {
    private enum CodingKeys: String, CodingKey {
        case type, positionX, positionY, positionZ, rotationX, rotationY, rotationZ
        case intensity, red, green, blue, alpha
        case innerSpotAngle, outerSpotAngle, castsShadow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        type = try container.decodeIfPresent(Scene3DLightType.self, forKey: .type) ?? type
        positionX = try container.decodeIfPresent(Double.self, forKey: .positionX) ?? positionX
        positionY = try container.decodeIfPresent(Double.self, forKey: .positionY) ?? positionY
        positionZ = try container.decodeIfPresent(Double.self, forKey: .positionZ) ?? positionZ
        rotationX = try container.decodeIfPresent(Double.self, forKey: .rotationX) ?? rotationX
        rotationY = try container.decodeIfPresent(Double.self, forKey: .rotationY) ?? rotationY
        rotationZ = try container.decodeIfPresent(Double.self, forKey: .rotationZ) ?? rotationZ
        intensity = try container.decodeIfPresent(Double.self, forKey: .intensity) ?? intensity
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? red
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? green
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? blue
        alpha = try container.decodeIfPresent(Double.self, forKey: .alpha) ?? alpha
        innerSpotAngle = try container.decodeIfPresent(Double.self, forKey: .innerSpotAngle) ?? innerSpotAngle
        outerSpotAngle = try container.decodeIfPresent(Double.self, forKey: .outerSpotAngle) ?? outerSpotAngle
        castsShadow = try container.decodeIfPresent(Bool.self, forKey: .castsShadow) ?? castsShadow
    }
}

extension TrackballNodeSettings {
    private enum CodingKeys: String, CodingKey {
        case sensitivity, panSensitivity, zoomSensitivity, invertY, initialOrbit, initialPitch
        case initialDistance, minDistance, maxDistance, initialPanX, initialPanY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        sensitivity = try container.decodeIfPresent(Double.self, forKey: .sensitivity) ?? sensitivity
        panSensitivity = try container.decodeIfPresent(Double.self, forKey: .panSensitivity) ?? panSensitivity
        zoomSensitivity = try container.decodeIfPresent(Double.self, forKey: .zoomSensitivity) ?? zoomSensitivity
        invertY = try container.decodeIfPresent(Bool.self, forKey: .invertY) ?? invertY
        initialOrbit = try container.decodeIfPresent(Double.self, forKey: .initialOrbit) ?? initialOrbit
        initialPitch = try container.decodeIfPresent(Double.self, forKey: .initialPitch) ?? initialPitch
        initialDistance = try container.decodeIfPresent(Double.self, forKey: .initialDistance) ?? initialDistance
        minDistance = try container.decodeIfPresent(Double.self, forKey: .minDistance) ?? minDistance
        maxDistance = try container.decodeIfPresent(Double.self, forKey: .maxDistance) ?? maxDistance
        initialPanX = try container.decodeIfPresent(Double.self, forKey: .initialPanX) ?? initialPanX
        initialPanY = try container.decodeIfPresent(Double.self, forKey: .initialPanY) ?? initialPanY
    }
}

extension Scene3DPrimitiveNodeSettings {
    private enum CodingKeys: String, CodingKey {
        case primitive, positionX, positionY, positionZ, rotationX, rotationY, rotationZ, scale
        case cameraDistance, cameraOrbit, cameraPitch, cameraPanX, cameraPanY
        case lightIntensity, materialRed, materialGreen, materialBlue, materialAlpha, backgroundAlpha
        case terrainWidth, terrainDepth, terrainSegments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        primitive = try container.decodeIfPresent(Scene3DPrimitiveKind.self, forKey: .primitive) ?? primitive
        positionX = try container.decodeIfPresent(Double.self, forKey: .positionX) ?? positionX
        positionY = try container.decodeIfPresent(Double.self, forKey: .positionY) ?? positionY
        positionZ = try container.decodeIfPresent(Double.self, forKey: .positionZ) ?? positionZ
        rotationX = try container.decodeIfPresent(Double.self, forKey: .rotationX) ?? rotationX
        rotationY = try container.decodeIfPresent(Double.self, forKey: .rotationY) ?? rotationY
        rotationZ = try container.decodeIfPresent(Double.self, forKey: .rotationZ) ?? rotationZ
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        cameraDistance = try container.decodeIfPresent(Double.self, forKey: .cameraDistance) ?? cameraDistance
        cameraOrbit = try container.decodeIfPresent(Double.self, forKey: .cameraOrbit) ?? cameraOrbit
        cameraPitch = try container.decodeIfPresent(Double.self, forKey: .cameraPitch) ?? cameraPitch
        cameraPanX = try container.decodeIfPresent(Double.self, forKey: .cameraPanX) ?? cameraPanX
        cameraPanY = try container.decodeIfPresent(Double.self, forKey: .cameraPanY) ?? cameraPanY
        lightIntensity = try container.decodeIfPresent(Double.self, forKey: .lightIntensity) ?? lightIntensity
        materialRed = try container.decodeIfPresent(Double.self, forKey: .materialRed) ?? materialRed
        materialGreen = try container.decodeIfPresent(Double.self, forKey: .materialGreen) ?? materialGreen
        materialBlue = try container.decodeIfPresent(Double.self, forKey: .materialBlue) ?? materialBlue
        materialAlpha = try container.decodeIfPresent(Double.self, forKey: .materialAlpha) ?? materialAlpha
        backgroundAlpha = try container.decodeIfPresent(Double.self, forKey: .backgroundAlpha) ?? backgroundAlpha
        terrainWidth = try container.decodeIfPresent(Double.self, forKey: .terrainWidth) ?? terrainWidth
        terrainDepth = try container.decodeIfPresent(Double.self, forKey: .terrainDepth) ?? terrainDepth
        terrainSegments = try container.decodeIfPresent(Double.self, forKey: .terrainSegments) ?? terrainSegments
    }
}

extension Scene3DTextNodeSettings {
    private enum CodingKeys: String, CodingKey {
        case text, fontName, fontSize, extrusionDepth, chamferRadius, flatness
        case positionX, positionY, positionZ, rotationX, rotationY, rotationZ, scale
        case cameraDistance, cameraOrbit, cameraPitch, cameraPanX, cameraPanY
        case lightIntensity, materialRed, materialGreen, materialBlue, materialAlpha, backgroundAlpha
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? text
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        extrusionDepth = try container.decodeIfPresent(Double.self, forKey: .extrusionDepth) ?? extrusionDepth
        chamferRadius = try container.decodeIfPresent(Double.self, forKey: .chamferRadius) ?? chamferRadius
        flatness = try container.decodeIfPresent(Double.self, forKey: .flatness) ?? flatness
        positionX = try container.decodeIfPresent(Double.self, forKey: .positionX) ?? positionX
        positionY = try container.decodeIfPresent(Double.self, forKey: .positionY) ?? positionY
        positionZ = try container.decodeIfPresent(Double.self, forKey: .positionZ) ?? positionZ
        rotationX = try container.decodeIfPresent(Double.self, forKey: .rotationX) ?? rotationX
        rotationY = try container.decodeIfPresent(Double.self, forKey: .rotationY) ?? rotationY
        rotationZ = try container.decodeIfPresent(Double.self, forKey: .rotationZ) ?? rotationZ
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        cameraDistance = try container.decodeIfPresent(Double.self, forKey: .cameraDistance) ?? cameraDistance
        cameraOrbit = try container.decodeIfPresent(Double.self, forKey: .cameraOrbit) ?? cameraOrbit
        cameraPitch = try container.decodeIfPresent(Double.self, forKey: .cameraPitch) ?? cameraPitch
        cameraPanX = try container.decodeIfPresent(Double.self, forKey: .cameraPanX) ?? cameraPanX
        cameraPanY = try container.decodeIfPresent(Double.self, forKey: .cameraPanY) ?? cameraPanY
        lightIntensity = try container.decodeIfPresent(Double.self, forKey: .lightIntensity) ?? lightIntensity
        materialRed = try container.decodeIfPresent(Double.self, forKey: .materialRed) ?? materialRed
        materialGreen = try container.decodeIfPresent(Double.self, forKey: .materialGreen) ?? materialGreen
        materialBlue = try container.decodeIfPresent(Double.self, forKey: .materialBlue) ?? materialBlue
        materialAlpha = try container.decodeIfPresent(Double.self, forKey: .materialAlpha) ?? materialAlpha
        backgroundAlpha = try container.decodeIfPresent(Double.self, forKey: .backgroundAlpha) ?? backgroundAlpha
    }
}

extension Scene3DModelNodeSettings {
    private enum CodingKeys: String, CodingKey {
        case filename, bookmarkData, parentFolderBookmarkData, positionX, positionY, positionZ, rotationX, rotationY, rotationZ, scale
        case cameraDistance, cameraOrbit, cameraPitch, cameraPanX, cameraPanY
        case lightIntensity, animationPlay, animationClipStart, animationClipEnd, animationSpeed, animationLoops, backgroundAlpha
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? filename
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData) ?? bookmarkData
        parentFolderBookmarkData = try container.decodeIfPresent(Data.self, forKey: .parentFolderBookmarkData) ?? parentFolderBookmarkData
        positionX = try container.decodeIfPresent(Double.self, forKey: .positionX) ?? positionX
        positionY = try container.decodeIfPresent(Double.self, forKey: .positionY) ?? positionY
        positionZ = try container.decodeIfPresent(Double.self, forKey: .positionZ) ?? positionZ
        rotationX = try container.decodeIfPresent(Double.self, forKey: .rotationX) ?? rotationX
        rotationY = try container.decodeIfPresent(Double.self, forKey: .rotationY) ?? rotationY
        rotationZ = try container.decodeIfPresent(Double.self, forKey: .rotationZ) ?? rotationZ
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        cameraDistance = try container.decodeIfPresent(Double.self, forKey: .cameraDistance) ?? cameraDistance
        cameraOrbit = try container.decodeIfPresent(Double.self, forKey: .cameraOrbit) ?? cameraOrbit
        cameraPitch = try container.decodeIfPresent(Double.self, forKey: .cameraPitch) ?? cameraPitch
        cameraPanX = try container.decodeIfPresent(Double.self, forKey: .cameraPanX) ?? cameraPanX
        cameraPanY = try container.decodeIfPresent(Double.self, forKey: .cameraPanY) ?? cameraPanY
        lightIntensity = try container.decodeIfPresent(Double.self, forKey: .lightIntensity) ?? lightIntensity
        animationPlay = try container.decodeIfPresent(Double.self, forKey: .animationPlay) ?? animationPlay
        animationClipStart = try container.decodeIfPresent(Double.self, forKey: .animationClipStart) ?? animationClipStart
        animationClipEnd = try container.decodeIfPresent(Double.self, forKey: .animationClipEnd) ?? animationClipEnd
        animationSpeed = try container.decodeIfPresent(Double.self, forKey: .animationSpeed) ?? animationSpeed
        animationLoops = try container.decodeIfPresent(Bool.self, forKey: .animationLoops) ?? animationLoops
        backgroundAlpha = try container.decodeIfPresent(Double.self, forKey: .backgroundAlpha) ?? backgroundAlpha
    }
}

enum Scene3DTextureProjection: String, CaseIterable, Codable {
    case uv
    case planarX
    case planarY
    case planarZ
    case box

    var displayName: String {
        switch self {
        case .uv: return "UV"
        case .planarX: return "Planar X"
        case .planarY: return "Planar Y"
        case .planarZ: return "Planar Z"
        case .box: return "Box"
        }
    }

    var scalarValue: Double {
        switch self {
        case .uv: return 0.0
        case .planarX: return 1.0
        case .planarY: return 2.0
        case .planarZ: return 3.0
        case .box: return 4.0
        }
    }

    static func fromScalar(_ value: Double) -> Scene3DTextureProjection {
        switch Int(value.rounded()) {
        case 1: return .planarX
        case 2: return .planarY
        case 3: return .planarZ
        case 4: return .box
        default: return .uv
        }
    }
}

struct Scene3DMaterialNodeSettings: Equatable, Codable {
    var red: Double = 0.92
    var green: Double = 0.95
    var blue: Double = 1.0
    var alpha: Double = 1.0
    var metallic: Double = 0.35
    var roughness: Double = 0.28
    var emission: Double = 0.0
    var displacementScale: Double = 0.15
    var doubleSided: Bool = true
    var wireframe: Bool = false
    var textureProjection: Scene3DTextureProjection = .uv
    var textureScale: Double = 0.1
    var textureOffsetX: Double = 0.0
    var textureOffsetY: Double = 0.0

    enum CodingKeys: String, CodingKey {
        case red, green, blue, alpha, metallic, roughness, emission, displacementScale, doubleSided, wireframe
        case textureProjection, textureScale, textureOffsetX, textureOffsetY
    }

    init(
        red: Double = 0.92,
        green: Double = 0.95,
        blue: Double = 1.0,
        alpha: Double = 1.0,
        metallic: Double = 0.35,
        roughness: Double = 0.28,
        emission: Double = 0.0,
        displacementScale: Double = 0.15,
        doubleSided: Bool = true,
        wireframe: Bool = false,
        textureProjection: Scene3DTextureProjection = .uv,
        textureScale: Double = 0.1,
        textureOffsetX: Double = 0.0,
        textureOffsetY: Double = 0.0
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.metallic = metallic
        self.roughness = roughness
        self.emission = emission
        self.displacementScale = displacementScale
        self.doubleSided = doubleSided
        self.wireframe = wireframe
        self.textureProjection = textureProjection
        self.textureScale = textureScale
        self.textureOffsetX = textureOffsetX
        self.textureOffsetY = textureOffsetY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? 0.92
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? 0.95
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? 1.0
        alpha = try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 1.0
        metallic = try container.decodeIfPresent(Double.self, forKey: .metallic) ?? 0.35
        roughness = try container.decodeIfPresent(Double.self, forKey: .roughness) ?? 0.28
        emission = try container.decodeIfPresent(Double.self, forKey: .emission) ?? 0.0
        displacementScale = try container.decodeIfPresent(Double.self, forKey: .displacementScale) ?? 0.15
        doubleSided = try container.decodeIfPresent(Bool.self, forKey: .doubleSided) ?? true
        wireframe = try container.decodeIfPresent(Bool.self, forKey: .wireframe) ?? false
        textureProjection = try container.decodeIfPresent(Scene3DTextureProjection.self, forKey: .textureProjection) ?? .uv
        textureScale = try container.decodeIfPresent(Double.self, forKey: .textureScale) ?? 0.1
        textureOffsetX = try container.decodeIfPresent(Double.self, forKey: .textureOffsetX) ?? 0.0
        textureOffsetY = try container.decodeIfPresent(Double.self, forKey: .textureOffsetY) ?? 0.0
    }
}

struct PolarNodeSettings: Equatable, Codable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var angleOffsetDegrees: Double = 0.0
    var clockwise: Bool = false
}

struct HitZoneNodeSettings: Equatable, Codable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var innerRadius: Double = 0.0
    var outerRadius: Double = 0.42
}

struct RectHitNodeSettings: Equatable, Codable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 0.2
    var height: Double = 0.2
}

enum KeyboardKey: String, CaseIterable, Codable, Identifiable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine
    case space, tab, enter, escape, delete
    case minus, equal, leftBracket, rightBracket, backslash
    case semicolon, quote, comma, period, slash, grave
    case upArrow, downArrow, leftArrow, rightArrow
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .h: return "H"
        case .i: return "I"
        case .j: return "J"
        case .k: return "K"
        case .l: return "L"
        case .m: return "M"
        case .n: return "N"
        case .o: return "O"
        case .p: return "P"
        case .q: return "Q"
        case .r: return "R"
        case .s: return "S"
        case .t: return "T"
        case .u: return "U"
        case .v: return "V"
        case .w: return "W"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        case .zero: return "0"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .space: return "Space"
        case .tab: return "Tab"
        case .enter: return "Enter"
        case .escape: return "Escape"
        case .delete: return "Delete"
        case .minus: return "Minus"
        case .equal: return "Equal"
        case .leftBracket: return "Left Bracket"
        case .rightBracket: return "Right Bracket"
        case .backslash: return "Backslash"
        case .semicolon: return "Semicolon"
        case .quote: return "Quote"
        case .comma: return "Comma"
        case .period: return "Period"
        case .slash: return "Slash"
        case .grave: return "Grave"
        case .upArrow: return "Up Arrow"
        case .downArrow: return "Down Arrow"
        case .leftArrow: return "Left Arrow"
        case .rightArrow: return "Right Arrow"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .a: return 0
        case .s: return 1
        case .d: return 2
        case .f: return 3
        case .h: return 4
        case .g: return 5
        case .z: return 6
        case .x: return 7
        case .c: return 8
        case .v: return 9
        case .b: return 11
        case .q: return 12
        case .w: return 13
        case .e: return 14
        case .r: return 15
        case .y: return 16
        case .t: return 17
        case .one: return 18
        case .two: return 19
        case .three: return 20
        case .four: return 21
        case .six: return 22
        case .five: return 23
        case .equal: return 24
        case .nine: return 25
        case .seven: return 26
        case .minus: return 27
        case .eight: return 28
        case .zero: return 29
        case .rightBracket: return 30
        case .o: return 31
        case .u: return 32
        case .leftBracket: return 33
        case .i: return 34
        case .p: return 35
        case .enter: return 36
        case .l: return 37
        case .j: return 38
        case .quote: return 39
        case .k: return 40
        case .semicolon: return 41
        case .backslash: return 42
        case .comma: return 43
        case .slash: return 44
        case .n: return 45
        case .m: return 46
        case .period: return 47
        case .tab: return 48
        case .space: return 49
        case .grave: return 50
        case .delete: return 51
        case .escape: return 53
        case .f1: return 122
        case .f2: return 120
        case .f3: return 99
        case .f4: return 118
        case .f5: return 96
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        case .f10: return 109
        case .f11: return 103
        case .f12: return 111
        case .upArrow: return 126
        case .downArrow: return 125
        case .leftArrow: return 123
        case .rightArrow: return 124
        }
    }
}

struct KeyboardNodeSettings: Equatable, Codable {
    var key: KeyboardKey = .space
    var requiresCommand = false
    var requiresOption = false
    var requiresShift = false
    var requiresControl = false
}

enum ScreenBoundsMode: String, CaseIterable, Codable, Identifiable {
    case normalized
    case centered
    case pixels

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normalized: return "Normalized"
        case .centered: return "Centered"
        case .pixels: return "Pixels"
        }
    }
}

struct ScreenBoundsNodeSettings: Equatable, Codable {
    var mode: ScreenBoundsMode = .normalized
}

struct RenderBoundsNodeSettings: Equatable, Codable {
    var targetRenderNodeID: GraphNode.ID? = nil
}

enum RenderWindowLevelMode: String, CaseIterable, Codable, Identifiable {
    case normal
    case floating
    case desktop
    case screenSaver

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .floating: return "Floating"
        case .desktop: return "Desktop"
        case .screenSaver: return "Screen Saver"
        }
    }
}

struct RenderWindowNodeSettings: Equatable, Codable {
    var targetRenderNodeID: GraphNode.ID? = nil
    var title: String = ""
    var levelMode: RenderWindowLevelMode = .normal
    var fullscreen: Double = 0.0
    var width: Double = 960.0
    var height: Double = 640.0
    var x: Double = 180.0
    var y: Double = 180.0
    var fps: Double = 60.0

    enum CodingKeys: String, CodingKey {
        case targetRenderNodeID
        case title
        case levelMode
        case fullscreen
        case width
        case height
        case x
        case y
        case fps
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetRenderNodeID = try container.decodeIfPresent(GraphNode.ID.self, forKey: .targetRenderNodeID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        levelMode = try container.decodeIfPresent(RenderWindowLevelMode.self, forKey: .levelMode) ?? .normal
        fullscreen = try container.decodeIfPresent(Double.self, forKey: .fullscreen) ?? 0.0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 960.0
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 640.0
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 180.0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 180.0
        fps = try container.decodeIfPresent(Double.self, forKey: .fps) ?? 60.0
    }
}

struct GridLayoutNodeSettings: Equatable, Codable {
    var index: Double = 0.0
    var columns: Double = 4.0
    var originX: Double = 0.15
    var originY: Double = 0.15
    var spacingX: Double = 0.2
    var spacingY: Double = 0.2
}

enum MacroPublishedPortKind: Equatable, Codable {
    case fragmentShader
    case materialSignal(String)
    case oscPacketSignal(String)
    case pointSignal(String)
    case point3Signal(String)
    case point4Signal(String)
    case scalarSignal(String)
    case stringSignal(String)
    case colorSignal(String)
    case scalarArraySignal(String)
    case stringArraySignal(String)
    case colorArraySignal(String)
    case imageArraySignal(String)
    case audio(AudioSignalKind)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum KindTag: String, Codable {
        case fragmentShader
        case materialSignal
        case oscPacketSignal
        case pointSignal
        case point3Signal
        case point4Signal
        case scalarSignal
        case stringSignal
        case colorSignal
        case scalarArraySignal
        case stringArraySignal
        case colorArraySignal
        case imageArraySignal
        case audio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(KindTag.self, forKey: .type)
        switch type {
        case .fragmentShader:
            self = .fragmentShader
        case .materialSignal:
            self = .materialSignal(try container.decode(String.self, forKey: .value))
        case .oscPacketSignal:
            self = .oscPacketSignal(try container.decode(String.self, forKey: .value))
        case .pointSignal:
            self = .pointSignal(try container.decode(String.self, forKey: .value))
        case .point3Signal:
            self = .point3Signal(try container.decode(String.self, forKey: .value))
        case .point4Signal:
            self = .point4Signal(try container.decode(String.self, forKey: .value))
        case .scalarSignal:
            self = .scalarSignal(try container.decode(String.self, forKey: .value))
        case .stringSignal:
            self = .stringSignal(try container.decode(String.self, forKey: .value))
        case .colorSignal:
            self = .colorSignal(try container.decode(String.self, forKey: .value))
        case .scalarArraySignal:
            self = .scalarArraySignal(try container.decode(String.self, forKey: .value))
        case .stringArraySignal:
            self = .stringArraySignal(try container.decode(String.self, forKey: .value))
        case .colorArraySignal:
            self = .colorArraySignal(try container.decode(String.self, forKey: .value))
        case .imageArraySignal:
            self = .imageArraySignal(try container.decode(String.self, forKey: .value))
        case .audio:
            self = .audio(try container.decode(AudioSignalKind.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fragmentShader:
            try container.encode(KindTag.fragmentShader, forKey: .type)
        case .materialSignal(let value):
            try container.encode(KindTag.materialSignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .oscPacketSignal(let value):
            try container.encode(KindTag.oscPacketSignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .pointSignal(let value):
            try container.encode(KindTag.pointSignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .point3Signal(let value):
            try container.encode(KindTag.point3Signal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .point4Signal(let value):
            try container.encode(KindTag.point4Signal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .scalarSignal(let value):
            try container.encode(KindTag.scalarSignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .stringSignal(let value):
            try container.encode(KindTag.stringSignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .colorSignal(let value):
            try container.encode(KindTag.colorSignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .scalarArraySignal(let value):
            try container.encode(KindTag.scalarArraySignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .stringArraySignal(let value):
            try container.encode(KindTag.stringArraySignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .colorArraySignal(let value):
            try container.encode(KindTag.colorArraySignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .imageArraySignal(let value):
            try container.encode(KindTag.imageArraySignal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .audio(let value):
            try container.encode(KindTag.audio, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

struct MacroPublishedPortSettings: Equatable, Codable {
    var macroPortID: String
    var internalPortID: String
    var name: String
    var kind: MacroPublishedPortKind
    var isPublished: Bool = true

    private enum CodingKeys: String, CodingKey {
        case macroPortID
        case internalPortID
        case name
        case kind
        case isPublished
    }

    init(macroPortID: String, internalPortID: String, name: String, kind: MacroPublishedPortKind, isPublished: Bool = true) {
        self.macroPortID = macroPortID
        self.internalPortID = internalPortID
        self.name = name
        self.kind = kind
        self.isPublished = isPublished
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macroPortID = try container.decode(String.self, forKey: .macroPortID)
        internalPortID = try container.decode(String.self, forKey: .internalPortID)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(MacroPublishedPortKind.self, forKey: .kind)
        isPublished = try container.decodeIfPresent(Bool.self, forKey: .isPublished) ?? true
    }
}

struct MacroNodeSettings: Equatable, Codable {
    var childNodeIDs: [UUID]
    var publishedInputs: [MacroPublishedPortSettings]
    var publishedOutputs: [MacroPublishedPortSettings]
}

struct IteratorNodeSettings: Equatable, Codable {
    var childNodeIDs: [UUID]
    var publishedInputs: [MacroPublishedPortSettings]
    var publishedOutputs: [MacroPublishedPortSettings]
    var iterations: Double = 4.0
}

enum MIDIScaleMode: String, CaseIterable, Identifiable, Codable {
    case major
    case minor
    case dorian
    case mixolydian
    case pentatonic
    case chromatic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .major: return "Major"
        case .minor: return "Minor"
        case .dorian: return "Dorian"
        case .mixolydian: return "Mixolydian"
        case .pentatonic: return "Pentatonic"
        case .chromatic: return "Chromatic"
        }
    }

    var intervals: [Int] {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .pentatonic: return [0, 2, 4, 7, 9]
        case .chromatic: return Array(0...11)
        }
    }
}

struct HandTrackerNodeSettings: Equatable, Codable {
    var offsetX: Double = 0.0
    var offsetY: Double = 0.0
}

struct PinchNodeSettings: Equatable, Codable {
    var threshold: Double = 0.08
}

struct ScrollGestureNodeSettings: Equatable, Codable {
    var threshold: Double = 0.5
    var sensitivity: Double = 1.0
    var invertY: Bool = true
}

struct ZoomGestureNodeSettings: Equatable, Codable {
    var threshold: Double = 0.5
    var sensitivity: Double = 2.0
    var initialZoom: Double = 1.0
    var minZoom: Double = 0.5
    var maxZoom: Double = 3.0
}

struct TrackballNodeSettings: Equatable, Codable {
    var sensitivity: Double = 1.0
    var panSensitivity: Double = 6.0
    var zoomSensitivity: Double = 1.0
    var invertY: Bool = true
    var initialOrbit: Double = 0.0
    var initialPitch: Double = 0.0
    var initialDistance: Double = 6.0
    var minDistance: Double = -200.0
    var maxDistance: Double = 200.0
    var initialPanX: Double = 0.0
    var initialPanY: Double = 0.0
}

struct DepthEstimateNodeSettings: Equatable, Codable {
    var nearSpan: Double = 0.32
    var farSpan: Double = 0.08
    var smoothing: Double = 0.25
    var touchThreshold: Double = 0.7
    var invert: Bool = false
}

enum MathOperation: String, CaseIterable, Identifiable, Codable {
    case add
    case subtract
    case multiply
    case divide
    case minimum
    case maximum
    case power
    case sine
    case cosine
    case round
    case floor
    case ceil

    var id: String { rawValue }

    var label: String {
        switch self {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "×"
        case .divide: return "÷"
        case .minimum: return "min"
        case .maximum: return "max"
        case .power: return "pow"
        case .sine: return "sin"
        case .cosine: return "cos"
        case .round: return "round"
        case .floor: return "floor"
        case .ceil: return "ceil"
        }
    }
}

struct MathNodeSettings: Equatable, Codable {
    var operation: MathOperation = .add
    var a: Double = 0.0
    var b: Double = 0.0
}

struct ExpressionNodeSettings: Equatable, Codable {
    var expression: String = "a"
    var variables: [String: Double] = ["a": 0.0]
}

struct ClampNodeSettings: Equatable, Codable {
    var minimum: Double = 0.0
    var maximum: Double = 1.0
}

struct MapRangeNodeSettings: Equatable, Codable {
    var inputMinimum: Double = 0.0
    var inputMaximum: Double = 1.0
    var outputMinimum: Double = 0.0
    var outputMaximum: Double = 1.0
}

enum LogicOperation: String, CaseIterable, Identifiable, Codable {
    case and
    case or
    case xor
    case not

    var id: String { rawValue }

    var label: String {
        switch self {
        case .and: return "AND"
        case .or: return "OR"
        case .xor: return "XOR"
        case .not: return "NOT"
        }
    }
}

struct LogicNodeSettings: Equatable, Codable {
    var operation: LogicOperation = .and
    var threshold: Double = 0.5
}

enum CompareOperation: String, CaseIterable, Identifiable, Codable {
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case equal
    case notEqual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .equal: return "="
        case .notEqual: return "!="
        }
    }
}

struct CompareNodeSettings: Equatable, Codable {
    var operation: CompareOperation = .equal
    var referenceValue: Double = 0.5
    var epsilon: Double = 0.02
}

struct BeatDetectNodeSettings: Equatable, Codable {
    var kickThreshold: Double = 0.12
    var snareThreshold: Double = 0.10
    var kickSensitivity: Double = 2.5
    var snareSensitivity: Double = 2.8
}

struct MIDIOutNodeSettings: Equatable, Codable {
    var rootNote: String = "C"
    var scale: MIDIScaleMode = .pentatonic
    var lowOctave: Int = 0
    var highOctave: Int = 7
    var channel: Int = 0
    var velocity: Int = 100
    var destinationName: String = ""
}

struct MIDICCNodeSettings: Equatable, Codable {
    var ccNumber: Int = 1
    var channel: Int = 0
    var sourceMin: Double = 0.0
    var sourceMax: Double = 1.0
    var destinationName: String = ""
}

struct MIDIInputCCNodeSettings: Equatable, Codable {
    var ccNumber: Int = 1
    var channel: Int = 0
    var listenToAllChannels: Bool = false
}

struct MIDIInputNoteNodeSettings: Equatable, Codable {
    var noteNumber: Int = 60
    var channel: Int = 0
    var listenToAllChannels: Bool = false
    var listenToAllNotes: Bool = true
}

enum OSCOutputValueType: String, CaseIterable, Codable, Identifiable {
    case float
    case int
    case string

    var id: String { rawValue }

    var label: String {
        switch self {
        case .float: return "Float"
        case .int: return "Int"
        case .string: return "String"
        }
    }
}

struct OSCInputNodeSettings: Equatable, Codable {
    var port: Int = 8000
    var address: String = ""
}

struct OSCOutputNodeSettings: Equatable, Codable {
    var host: String = "127.0.0.1"
    var port: Int = 8000
    var address: String = "/value"
    var valueType: OSCOutputValueType = .float
}

struct OSCSendNodeSettings: Equatable, Codable {
    var host: String = "127.0.0.1"
    var port: Int = 8000
}

struct OSCMessageNodeSettings: Equatable, Codable {
    var address: String = "/value"
    var float1: Double = 0.0
    var int1: Double = 0.0
    var text1: String = ""
    var float2: Double = 0.0
    var int2: Double = 0.0
    var text2: String = ""
    var float3: Double = 0.0
    var int3: Double = 0.0
    var text3: String = ""
    var float4: Double = 0.0
    var int4: Double = 0.0
    var text4: String = ""

    enum CodingKeys: String, CodingKey {
        case address
        case float1
        case int1
        case text1
        case float2
        case int2
        case text2
        case float3
        case int3
        case text3
        case float4
        case int4
        case text4
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? "/value"
        float1 = try container.decodeIfPresent(Double.self, forKey: .float1) ?? 0.0
        int1 = try container.decodeIfPresent(Double.self, forKey: .int1) ?? 0.0
        text1 = try container.decodeIfPresent(String.self, forKey: .text1) ?? ""
        float2 = try container.decodeIfPresent(Double.self, forKey: .float2) ?? 0.0
        int2 = try container.decodeIfPresent(Double.self, forKey: .int2) ?? 0.0
        text2 = try container.decodeIfPresent(String.self, forKey: .text2) ?? ""
        float3 = try container.decodeIfPresent(Double.self, forKey: .float3) ?? 0.0
        int3 = try container.decodeIfPresent(Double.self, forKey: .int3) ?? 0.0
        text3 = try container.decodeIfPresent(String.self, forKey: .text3) ?? ""
        float4 = try container.decodeIfPresent(Double.self, forKey: .float4) ?? 0.0
        int4 = try container.decodeIfPresent(Double.self, forKey: .int4) ?? 0.0
        text4 = try container.decodeIfPresent(String.self, forKey: .text4) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
        try container.encode(float1, forKey: .float1)
        try container.encode(int1, forKey: .int1)
        try container.encode(text1, forKey: .text1)
        try container.encode(float2, forKey: .float2)
        try container.encode(int2, forKey: .int2)
        try container.encode(text2, forKey: .text2)
        try container.encode(float3, forKey: .float3)
        try container.encode(int3, forKey: .int3)
        try container.encode(text3, forKey: .text3)
        try container.encode(float4, forKey: .float4)
        try container.encode(int4, forKey: .int4)
        try container.encode(text4, forKey: .text4)
    }
}

struct OSCBundleNodeSettings: Equatable, Codable {
    var packetCount: Int = 4
}

struct ClearNodeSettings: Equatable, Codable {
    var red: Double = 0.0
    var green: Double = 0.0
    var blue: Double = 0.0
    var alpha: Double = 1.0
}

struct ImageNodeSettings: Equatable, Codable {
    var filename: String
    var imageData: Data
}

struct WebViewNodeSettings: Equatable, Codable {
    var urlString: String = "https://www.apple.com"
    var snapshotData: Data = Data()
    var lastSnapshotFilename: String = "WebView.png"
    var statusText: String = "Enter a URL and click Go."
}

enum AIImageStyle: String, CaseIterable, Identifiable, Codable {
    case illustration
    case animation
    case sketch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .illustration: return "Illustration"
        case .animation: return "Animation"
        case .sketch: return "Sketch"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? ""
        self = AIImageStyle(rawValue: rawValue) ?? .illustration
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AIImageNodeSettings: Equatable, Codable {
    var prompt: String = "A vivid cosmic nebula with luminous clouds of color, glowing stardust, deep space atmosphere, rich detail, cinematic lighting, and a dramatic abstract sci-fi composition"
    var style: AIImageStyle = .illustration
    var filename: String = "AI Image.png"
    var imageData: Data = Data()

    enum CodingKeys: String, CodingKey {
        case prompt
        case style
        case filename
        case imageData
    }

    init(prompt: String = "A vivid cosmic nebula with luminous clouds of color, glowing stardust, deep space atmosphere, rich detail, cinematic lighting, and a dramatic abstract sci-fi composition",
         style: AIImageStyle = .illustration,
         filename: String = "AI Image.png",
         imageData: Data = Data()) {
        self.prompt = prompt
        self.style = style
        self.filename = filename
        self.imageData = imageData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? "A vivid cosmic nebula with luminous clouds of color, glowing stardust, deep space atmosphere, rich detail, cinematic lighting, and a dramatic abstract sci-fi composition"
        style = try container.decodeIfPresent(AIImageStyle.self, forKey: .style) ?? .illustration
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "AI Image.png"
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData) ?? Data()
    }
}

struct VideoPlayerNodeSettings: Equatable, Codable {
    var filename: String = "Video"
    var bookmarkData: Data = Data()
    var isLooping: Bool = true
    var isPlaying: Bool = true
    var rate: Double = 1.0
    var seekPosition: Double = 0.0
    var volume: Double = 1.0

    enum CodingKeys: String, CodingKey {
        case filename
        case bookmarkData
        case isLooping
        case isPlaying
        case rate
        case seekPosition
        case volume
    }

    init(filename: String = "Video",
         bookmarkData: Data = Data(),
         isLooping: Bool = true,
         isPlaying: Bool = true,
         rate: Double = 1.0,
         seekPosition: Double = 0.0,
         volume: Double = 1.0) {
        self.filename = filename
        self.bookmarkData = bookmarkData
        self.isLooping = isLooping
        self.isPlaying = isPlaying
        self.rate = rate
        self.seekPosition = seekPosition
        self.volume = volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "Video"
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData) ?? Data()
        isLooping = try container.decodeIfPresent(Bool.self, forKey: .isLooping) ?? true
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? true
        rate = try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1.0
        seekPosition = try container.decodeIfPresent(Double.self, forKey: .seekPosition) ?? 0.0
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
    }
}

struct LayerNodeSettings: Equatable, Codable {
    var layerCount: Int = 2
    var opacity: Double = 1.0
    var layerOpacities: [Double] = [1.0, 1.0]

    enum CodingKeys: String, CodingKey {
        case layerCount
        case opacity
        case layerOpacities
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layerCount = try container.decodeIfPresent(Int.self, forKey: .layerCount) ?? 2
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        let decodedLayerOpacities = try container.decodeIfPresent([Double].self, forKey: .layerOpacities)
        if let decodedLayerOpacities, !decodedLayerOpacities.isEmpty {
            layerOpacities = decodedLayerOpacities
        } else {
            layerOpacities = Array(repeating: 1.0, count: max(layerCount, 2))
        }
    }
}

struct FeedbackNodeSettings: Equatable, Codable {
    var level: Double = 0.82
    var blendMode: FeedbackBlendMode = .screen
}

struct ReactionDiffusionNodeSettings: Equatable, Codable {
    var feed: Double = 0.52
    var kill: Double = 0.42
    var diffusionA: Double = 0.72
    var diffusionB: Double = 0.38
    var speed: Double = 0.45
    var seed: Double = 0.45
    var inputDrive: Double = 0.15
    var displayBoost: Double = 0.7
    var hueShift: Double = 0.0
    var saturation: Double = 0.85
    var sourceColor: Double = 0.0
    var reset: Double = 0.0
    var red: Double = 0.2
    var green: Double = 0.95
    var blue: Double = 0.85
    var alpha: Double = 1.0
}

struct UnderwaterNodeSettings: Equatable, Codable {
    var scale: Double = 3.2
    var distortion: Double = 0.035
    var octaves: Int = 5
    var lacunarity: Double = 2.0
    var gain: Double = 0.5
    var amplitude: Double = 0.6
    var textureScale: Double = 1.05
    var uvClampMargin: Double = 0.002

    enum CodingKeys: String, CodingKey {
        case scale
        case distortion
        case octaves
        case lacunarity
        case gain
        case amplitude
        case textureScale
        case uvClampMargin
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 3.2
        distortion = try container.decodeIfPresent(Double.self, forKey: .distortion) ?? 0.035
        octaves = try container.decodeIfPresent(Int.self, forKey: .octaves) ?? 5
        lacunarity = try container.decodeIfPresent(Double.self, forKey: .lacunarity) ?? 2.0
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 0.5
        amplitude = try container.decodeIfPresent(Double.self, forKey: .amplitude) ?? 0.6
        textureScale = try container.decodeIfPresent(Double.self, forKey: .textureScale) ?? 1.05
        uvClampMargin = try container.decodeIfPresent(Double.self, forKey: .uvClampMargin) ?? 0.002
    }
}

struct CoreImageNodeSettings: Equatable, Codable {
    var effect: CoreImageEffectKind = .blur
    var primary: Double = 8.0
    var secondary: Double = 0.75

    enum CodingKeys: String, CodingKey {
        case effect
        case primary
        case secondary
    }

    init(effect: CoreImageEffectKind = .blur, primary: Double = 8.0, secondary: Double = 0.75) {
        self.effect = effect
        self.primary = primary
        self.secondary = secondary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effect = try container.decodeIfPresent(CoreImageEffectKind.self, forKey: .effect) ?? .blur
        primary = try container.decodeIfPresent(Double.self, forKey: .primary) ?? 8.0
        secondary = try container.decodeIfPresent(Double.self, forKey: .secondary) ?? 0.75
    }
}

struct UniformDescriptor: Identifiable {
    let id: UUID
    let name: String
    let kind: UniformKind
    var defaultValue: UniformValue
    var minValue: Double?
    var maxValue: Double?
    let label: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: UniformKind,
        defaultValue: UniformValue,
        minValue: Double?,
        maxValue: Double?,
        label: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.minValue = minValue
        self.maxValue = maxValue
        self.label = label
    }
}

enum GraphNodeKind {
    case uniform(UniformDescriptor)
    case time
    case mouse
    case keyboard
    case pointSplit
    case pointCombine
    case point3Split
    case point3Combine
    case point4Split
    case point4Combine
    case pointInterpolate
    case point3Interpolate
    case point4Interpolate
    case pointScale
    case point3Scale
    case point4Scale
    case colorSplit
    case scroll
    case handTracker
    case pinch
    case scrollGesture
    case zoomGesture
    case trackball
    case depthEstimate
    case math
    case expression
    case clamp
    case mapRange
    case logic
    case compare
    case scalarVariable
    case stringVariable
    case colorVariable
    case scalarArrayVariable
    case stringArrayVariable
    case colorArrayVariable
    case imageArrayVariable
    case string
    case stringFormat
    case stringCompare
    case stringSplit
    case color
    case hslColor
    case scalarArray
    case stringArray
    case colorArray
    case imageArray
    case scalarArrayIndex
    case stringArrayIndex
    case colorArrayIndex
    case imageArrayIndex
    case arrayCount
    case textImage
    case audio
    case beatDetect
    case slider
    case sliderStyle
    case button
    case buttonStyle
    case polar
    case hitZone
    case rectHit
    case screenSize
    case screenBounds
    case renderBounds
    case renderWindow
    case gridLayout
    case macro
    case iterator
    case iteratorVariables
    case midiOut
    case midiCC
    case midiCCInput
    case midiNoteInput
    case oscInput
    case oscOutput
    case oscReceive
    case oscSend
    case oscGet4
    case oscGetArray
    case oscMake4
    case oscMakeArray
    case oscBundle
    case note
    case transform
    case billboard
    case line
    case scene3DTransform
    case scene3DTile
    case scene3DRender
    case scene3DLight
    case scene3DMaterial
    case scene3DPrimitive
    case scene3DText
    case scene3DModel
    case scene3DGaussianSplat
    case scene3DParticle
    case select
    case scalarSwitch
    case stringSwitch
    case colorSwitch
    case scalarMultiplexor
    case stringMultiplexor
    case colorMultiplexor
    case imageMultiplexor
    case transition
    case clear
    case image
    case webView
    case aiImage
    case videoPlayer
    case circle
    case scale
    case interpolator
    case hold
    case scalarSmooth
    case random
    case pulse
    case fireOnLoad
    case counter
    case toggle
    case delay
    case timer
    case trail
    case video
    case coreImage
    case blur
    case bloom
    case hueRotate
    case posterize
    case levels
    case glow
    case underwater
    case feedback
    case reactionDiffusion
    case monitor
    case mix
    case layers
    case metalFragment(isPrimary: Bool)
    case renderOutput(isPrimary: Bool)
}

enum GraphPortDirection {
    case input
    case output
}

enum GraphPortKind: Equatable, Hashable {
    case fragmentShader
    case scene3DSignal(String)
    case lightSignal(String)
    case materialSignal(String)
    case oscPacketSignal(String)
    case time
    case pointSignal(String)
    case point3Signal(String)
    case point4Signal(String)
    case audio(AudioSignalKind)
    case scalarSignal(String)
    case stringSignal(String)
    case colorSignal(String)
    case scalarArraySignal(String)
    case stringArraySignal(String)
    case colorArraySignal(String)
    case imageArraySignal(String)
    case sliderStyle
    case buttonStyle
    case uniform(UniformDescriptor.ID)
}

struct GraphPort: Identifiable, Equatable {
    let id: String
    let nodeID: GraphNode.ID
    let name: String
    let direction: GraphPortDirection
    let kind: GraphPortKind
}

struct GraphNode: Identifiable {
    let id: UUID
    let title: String
    let kind: GraphNodeKind
    let position: CGPoint
    let inputPorts: [GraphPort]
    let outputPorts: [GraphPort]
}

struct GraphConnection: Identifiable {
    let id = UUID()
    let fromPortID: GraphPort.ID
    let toPortID: GraphPort.ID
}

struct PreviewShaderPass {
    let metalSource: String
    let uniforms: [UniformDescriptor]
    let imageUniformSources: [PreviewPassSource?]
}

struct PreviewTrailPass {
    let point: CGPoint?
    let radius: Float
    let duration: Float
}

struct PreviewCirclePass {
    let point: CGPoint?
    let radius: Float
    let softness: Float
    let color: SIMD4<Float>
}

struct PreviewClearPass {
    let color: SIMD4<Float>
}

struct PreviewImagePass {
    let nodeID: UUID
    let imageData: Data
}

struct PreviewVideoPlayerPass {
    let nodeID: UUID
}

struct PreviewFeedbackPass {
    let nodeID: UUID
    let source: PreviewPassSource
    let level: Float
    let blendMode: FeedbackBlendMode
}

struct PreviewReactionDiffusionPass {
    let nodeID: UUID
    let source: PreviewPassSource?
    let settings: ReactionDiffusionNodeSettings
    let feed: Float
    let kill: Float
    let diffusionA: Float
    let diffusionB: Float
    let speed: Float
    let seed: Float
    let inputDrive: Float
    let displayBoost: Float
    let hueShift: Float
    let saturation: Float
    let sourceColor: Float
    let reset: Float
    let tint: SIMD4<Float>
}

struct PreviewUnderwaterPass {
    let nodeID: UUID
    let source: PreviewPassSource
    let scale: Float
    let distortion: Float
    let octaves: Int
    let lacunarity: Float
    let gain: Float
    let amplitude: Float
    let textureScale: Float
    let uvClampMargin: Float
}

struct PreviewCoreImagePass {
    let nodeID: UUID
    let source: PreviewPassSource
    let effect: CoreImageEffectKind
    let primary: Float
    let secondary: Float
}

struct PreviewLayerPass {
    let source: PreviewPassSource
    let opacity: Float
    let zIndex: Float
}

struct PreviewTransitionPass {
    let nodeID: UUID
    let primary: PreviewPassSource
    let secondary: PreviewPassSource
    let style: TransitionStyle
    let progress: Float
    let softness: Float
}

struct PreviewTransformPass {
    let nodeID: UUID
    let source: PreviewPassSource
    let x: Float
    let y: Float
    let z: Float
    let scaleX: Float
    let scaleY: Float
    let rotationDegreesX: Float
    let rotationDegreesY: Float
    let rotationDegreesZ: Float
    let opacity: Float
    let tint: SIMD4<Float>
}

struct PreviewLineInstance {
    let position: SIMD3<Float>
    let scale: SIMD2<Float>
    let rotationRadiansZ: Float
    let color: SIMD4<Float>
}

struct PreviewLineBatchPass {
    let nodeID: UUID
    let instances: [PreviewLineInstance]
}

struct PreviewScene3DPrimitivePass {
    let nodeID: UUID
    let settings: Scene3DPrimitiveNodeSettings
    let light: PreviewScene3DLight?
    let material: Scene3DMaterialNodeSettings
    let materialMaps: PreviewScene3DMaterialMaps?
}

struct PreviewScene3DTextPass {
    let nodeID: UUID
    let settings: Scene3DTextNodeSettings
    let light: PreviewScene3DLight?
    let material: Scene3DMaterialNodeSettings
    let materialMaps: PreviewScene3DMaterialMaps?
}

struct PreviewScene3DModelPass {
    let nodeID: UUID
    let settings: Scene3DModelNodeSettings
    let light: PreviewScene3DLight?
    let material: Scene3DMaterialNodeSettings?
    let materialMaps: PreviewScene3DMaterialMaps?
}

struct PreviewScene3DGaussianSplatPass {
    let nodeID: UUID
    let settings: Scene3DGaussianSplatNodeSettings
}

struct PreviewScene3DParticlePass {
    let nodeID: UUID
    let settings: Scene3DParticleNodeSettings
    let spriteSource: PreviewPassSource?
}

struct PreviewScene3DLight {
    let settings: Scene3DLightNodeSettings
}

indirect enum PreviewScene3DSource {
    case primitive(PreviewScene3DPrimitivePass)
    case text(PreviewScene3DTextPass)
    case model(PreviewScene3DModelPass)
    case gaussianSplat(PreviewScene3DGaussianSplatPass)
    case particle(PreviewScene3DParticlePass)
    case light(PreviewScene3DLight)
    case transform(
        nodeID: UUID,
        source: PreviewScene3DSource,
        x: Float,
        y: Float,
        z: Float,
        scaleX: Float,
        scaleY: Float,
        scaleZ: Float,
        rotationDegreesX: Float,
        rotationDegreesY: Float,
        rotationDegreesZ: Float
    )
    case tile(
        nodeID: UUID,
        source: PreviewScene3DSource,
        centerX: Float,
        centerY: Float,
        centerZ: Float,
        spacingX: Float,
        spacingY: Float,
        spacingZ: Float,
        fieldX: Float,
        fieldY: Float,
        fieldZ: Float
    )
}

struct PreviewScene3DRenderPass {
    let nodeID: UUID
    let sources: [PreviewScene3DSource]
    let cameraDistance: Float
    let cameraOrbit: Float
    let cameraPitch: Float
    let cameraPanX: Float
    let cameraPanY: Float
    let backgroundAlpha: Float
    let defaultLightIntensity: Float
    let waterDistortion: Float
    let waterScale: Float
    let waterSpeed: Float
}

struct PreviewScene3DMaterialMaps {
    let diffuse: PreviewPassSource?
    let specular: PreviewPassSource?
    let metallic: PreviewPassSource?
    let bump: PreviewPassSource?
    let displacement: PreviewPassSource?
}

indirect enum PreviewPassSource {
    case shader(PreviewShaderPass)
    case scene3DSource(PreviewScene3DSource)
    case scene3DRender(PreviewScene3DRenderPass)
    case trail(PreviewTrailPass)
    case circle(PreviewCirclePass)
    case clear(PreviewClearPass)
    case image(PreviewImagePass)
    case videoPlayer(PreviewVideoPlayerPass)
    case video
    case coreImage(PreviewCoreImagePass)
    case underwater(PreviewUnderwaterPass)
    case transform(PreviewTransformPass)
    case lineBatch(PreviewLineBatchPass)
    case scene3DPrimitive(PreviewScene3DPrimitivePass)
    case scene3DText(PreviewScene3DTextPass)
    case scene3DModel(PreviewScene3DModelPass)
    case scene3DGaussianSplat(PreviewScene3DGaussianSplatPass)
    case scene3DParticle(PreviewScene3DParticlePass)
    case transition(PreviewTransitionPass)
    case mix(primary: PreviewPassSource, secondary: PreviewPassSource, amount: Float)
    case layers(layers: [PreviewLayerPass], opacity: Float)
    case feedback(PreviewFeedbackPass)
    case reactionDiffusion(PreviewReactionDiffusionPass)
    case feedbackHistory(nodeID: UUID)
}

indirect enum PreviewRenderConfiguration {
    case empty
    case single(PreviewShaderPass)
    case scene3DRender(PreviewScene3DRenderPass)
    case trail(PreviewTrailPass)
    case circle(PreviewCirclePass)
    case clear(PreviewClearPass)
    case image(PreviewImagePass)
    case videoPlayer(PreviewVideoPlayerPass)
    case video
    case coreImage(PreviewCoreImagePass)
    case underwater(PreviewUnderwaterPass)
    case transform(PreviewTransformPass)
    case lineBatch(PreviewLineBatchPass)
    case scene3DPrimitive(PreviewScene3DPrimitivePass)
    case scene3DText(PreviewScene3DTextPass)
    case scene3DModel(PreviewScene3DModelPass)
    case scene3DGaussianSplat(PreviewScene3DGaussianSplatPass)
    case scene3DParticle(PreviewScene3DParticlePass)
    case feedback(PreviewFeedbackPass)
    case reactionDiffusion(PreviewReactionDiffusionPass)
    case transition(PreviewTransitionPass)
    case mix(primary: PreviewPassSource, secondary: PreviewPassSource, amount: Float)
    case layers(layers: [PreviewLayerPass], opacity: Float)
}

struct ShaderDocument {
    let name: String
    let description: String
    let source: String
    let shaderPrelude: String
    let shaderBody: String
    var uniforms: [UniformDescriptor]
    var nodes: [GraphNode]
    var connections: [GraphConnection]
}

extension UniformDescriptor {
    var displayValue: String {
        switch defaultValue {
        case .float(let value):
            return String(format: "%.2f", value)
        case .color(let value):
            return "rgba(\(Int(value.x * 255)), \(Int(value.y * 255)), \(Int(value.z * 255)), \(String(format: "%.2f", value.w)))"
        case .point(let point):
            return "\(Int(point.x)), \(Int(point.y))"
        case .point3(let point):
            return String(format: "%.2f, %.2f, %.2f", point.x, point.y, point.z)
        case .point4(let point):
            return String(format: "%.2f, %.2f, %.2f, %.2f", point.x, point.y, point.z, point.w)
        case .bool(let value):
            return value ? "true" : "false"
        case .image(let name):
            return name
        }
    }
}

extension GraphNode {
    var allPorts: [GraphPort] {
        inputPorts + outputPorts
    }

    var isPrimaryFragment: Bool {
        guard case .metalFragment(let isPrimary) = kind else {
            return false
        }
        return isPrimary
    }

    var isPrimaryRender: Bool {
        guard case .renderOutput(let isPrimary) = kind else {
            return false
        }
        return isPrimary
    }
}
