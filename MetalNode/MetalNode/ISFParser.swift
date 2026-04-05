//
//  ISFParser.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import CoreGraphics
import Foundation

enum ISFParser {
    static func parse(shaderSource: String) -> ShaderDocument {
        let metadata = parseMetadata(in: shaderSource)
        let name = metadata["DESCRIPTION"] as? String ?? "Imported ISF Shader"
        let description = "ISF metadata converted into graph uniforms and a Metal fragment scaffold."
        let uniforms = parseUniforms(from: metadata["INPUTS"] as? [[String: Any]] ?? [])
        let strippedSource = sourceWithoutMetadata(in: shaderSource)
        let prelude = shaderPrelude(in: strippedSource)
        let body = shaderBody(in: strippedSource)
        let fragmentNodeID = UUID()
        let timeNodeID = UUID()
        let renderNodeID = UUID()
        let timeInput = GraphPort(
            id: fragmentTimeInputID(for: fragmentNodeID),
            nodeID: fragmentNodeID,
            name: "TIME",
            direction: .input,
            kind: .time
        )
        let fragmentUniformInputs = uniforms.map { uniform in
            GraphPort(
                id: fragmentUniformInputID(for: uniform, nodeID: fragmentNodeID),
                nodeID: fragmentNodeID,
                name: uniform.name,
                direction: .input,
                kind: .uniform(uniform.id)
            )
        }
        let fragmentOutput = GraphPort(
            id: fragmentOutputID(for: fragmentNodeID),
            nodeID: fragmentNodeID,
            name: "Shader",
            direction: .output,
            kind: .fragmentShader
        )
        let renderInput = GraphPort(
            id: "render:input",
            nodeID: renderNodeID,
            name: "Shader",
            direction: .input,
            kind: .fragmentShader
        )
        let fragmentNode = GraphNode(
            id: fragmentNodeID,
            title: "Metal Fragment",
            kind: .metalFragment(isPrimary: true),
            position: CGPoint(x: 320, y: 180),
            inputPorts: [timeInput] + fragmentUniformInputs,
            outputPorts: [fragmentOutput]
        )
        let timeNode = GraphNode(
            id: timeNodeID,
            title: "Time",
            kind: .time,
            position: CGPoint(x: 40, y: 120),
            inputPorts: [],
            outputPorts: [
                GraphPort(
                    id: "time:output",
                    nodeID: timeNodeID,
                    name: "TIME",
                    direction: .output,
                    kind: .time
                )
            ]
        )
        let renderNode = GraphNode(
            id: renderNodeID,
            title: "Render",
            kind: .renderOutput(isPrimary: true),
            position: CGPoint(x: 760, y: 260),
            inputPorts: [renderInput],
            outputPorts: []
        )

        let connections = [
            GraphConnection(fromPortID: "time:output", toPortID: timeInput.id),
            GraphConnection(fromPortID: fragmentOutput.id, toPortID: renderInput.id)
        ]

        return ShaderDocument(
            name: name,
            description: description,
            source: shaderSource,
            shaderPrelude: prelude,
            shaderBody: body,
            uniforms: uniforms,
            nodes: [timeNode, fragmentNode, renderNode],
            connections: connections
        )
    }

    static func fragmentTimeInputID(for nodeID: UUID) -> String {
        "fragment:\(nodeID.uuidString):time"
    }

    static func fragmentUniformInputID(for uniform: UniformDescriptor, nodeID: UUID) -> String {
        "fragment:\(nodeID.uuidString):uniform:\(uniform.name)"
    }

    static func fragmentOutputID(for nodeID: UUID) -> String {
        "fragment:\(nodeID.uuidString):output"
    }

    private static func parseMetadata(in shaderSource: String) -> [String: Any] {
        let pattern = #"/\*\s*(\{[\s\S]*?\})\s*\*/"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }

        let range = NSRange(shaderSource.startIndex..., in: shaderSource)
        guard
            let match = regex.firstMatch(in: shaderSource, range: range),
            let jsonRange = Range(match.range(at: 1), in: shaderSource)
        else {
            return [:]
        }

        let jsonString = String(shaderSource[jsonRange])
        guard let jsonData = jsonString.data(using: .utf8) else {
            return [:]
        }

        return (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] ?? [:]
    }

    private static func parseUniforms(from inputs: [[String: Any]]) -> [UniformDescriptor] {
        inputs.compactMap { input in
            guard
                let name = input["NAME"] as? String,
                let type = (input["TYPE"] as? String)?.lowercased()
            else {
                return nil
            }

            let label = input["LABEL"] as? String
            switch type {
            case "float":
                let minValue = input["MIN"] as? Double
                let maxValue = input["MAX"] as? Double
                let defaultValue = (input["DEFAULT"] as? Double) ?? minValue ?? 0.5
                return UniformDescriptor(
                    name: name,
                    kind: .float,
                    defaultValue: .float(defaultValue),
                    minValue: minValue,
                    maxValue: maxValue,
                    label: label
                )
            case "color":
                let values = input["DEFAULT"] as? [Double] ?? [1, 0.35, 0.2, 1]
                let color = SIMD4<Float>(
                    Float(values[safe: 0] ?? 1),
                    Float(values[safe: 1] ?? 0.35),
                    Float(values[safe: 2] ?? 0.2),
                    Float(values[safe: 3] ?? 1)
                )
                return UniformDescriptor(
                    name: name,
                    kind: .color,
                    defaultValue: .color(color),
                    minValue: nil,
                    maxValue: nil,
                    label: label
                )
            case "point2d":
                let values = input["DEFAULT"] as? [Double] ?? [0.5, 0.5]
                return UniformDescriptor(
                    name: name,
                    kind: .point2D,
                    defaultValue: .point(CGPoint(x: values[safe: 0] ?? 0.5, y: values[safe: 1] ?? 0.5)),
                    minValue: nil,
                    maxValue: nil,
                    label: label
                )
            case "float3":
                let values = input["DEFAULT"] as? [Double] ?? [0.0, 0.0, 0.0]
                return UniformDescriptor(
                    name: name,
                    kind: .float3,
                    defaultValue: .point3(Point3Value(
                        x: values[safe: 0] ?? 0.0,
                        y: values[safe: 1] ?? 0.0,
                        z: values[safe: 2] ?? 0.0
                    )),
                    minValue: nil,
                    maxValue: nil,
                    label: label
                )
            case "float4":
                let values = input["DEFAULT"] as? [Double] ?? [0.0, 0.0, 0.0, 0.0]
                return UniformDescriptor(
                    name: name,
                    kind: .float4,
                    defaultValue: .point4(Point4Value(
                        x: values[safe: 0] ?? 0.0,
                        y: values[safe: 1] ?? 0.0,
                        z: values[safe: 2] ?? 0.0,
                        w: values[safe: 3] ?? 0.0
                    )),
                    minValue: nil,
                    maxValue: nil,
                    label: label
                )
            case "bool":
                return UniformDescriptor(
                    name: name,
                    kind: .bool,
                    defaultValue: .bool((input["DEFAULT"] as? Bool) ?? true),
                    minValue: nil,
                    maxValue: nil,
                    label: label
                )
            case "image":
                return UniformDescriptor(
                    name: name,
                    kind: .image,
                    defaultValue: .image(label ?? "Texture"),
                    minValue: nil,
                    maxValue: nil,
                    label: label
                )
            default:
                return nil
            }
        }
    }

    private static func sourceWithoutMetadata(in shaderSource: String) -> String {
        let pattern = #"/\*\s*\{[\s\S]*?\}\s*\*/"#
        return shaderSource
            .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shaderPrelude(in shaderSource: String) -> String {
        guard let mainRange = shaderSource.range(of: #"void\s+main\s*\(\s*(?:void)?\s*\)\s*\{"#, options: .regularExpression) else {
            return ""
        }
        return String(shaderSource[..<mainRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shaderBody(in shaderSource: String) -> String {
        guard let mainRange = shaderSource.range(of: #"void\s+main\s*\(\s*(?:void)?\s*\)\s*\{"#, options: .regularExpression) else {
            return shaderSource.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let suffix = shaderSource[mainRange.upperBound...]
        guard let closingIndex = suffix.lastIndex(of: "}") else {
            return String(suffix).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(suffix[..<closingIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
