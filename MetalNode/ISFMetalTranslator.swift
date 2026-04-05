//
//  ISFMetalTranslator.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import Foundation

enum ISFMetalTranslator {
    static func translate(document: ShaderDocument) -> String {
        let translatedPrelude = translatePrelude(document.shaderPrelude, uniforms: document.uniforms)
        let translatedBody = translateBody(document.shaderBody, uniforms: document.uniforms)
        let uniformAliases = aliasLines(for: document.uniforms)
        let textureNotes = textureCommentLines(for: document.uniforms.filter { $0.kind == .image })
        let headerComment = [
            "// Imported ISF shader: \(document.name)",
            "// \(document.description)",
            "// Generated from ISF body using heuristic GLSL -> Metal rewrites."
        ].joined(separator: "\n")

        return """
        \(headerComment)
        \(textureNotes)
        \(translatedPrelude)

        // PreviewUniforms, RasterizerData, and typed uniform buffers are supplied by the host preview wrapper.
        fragment float4 generatedFragment(RasterizerData in [[stage_in]],
                                          constant PreviewUniforms& uniforms [[buffer(0)]],
                                          constant float* floatUniforms [[buffer(1)]],
                                          constant float4* colorUniforms [[buffer(2)]],
                                          constant float2* pointUniforms [[buffer(3)]],
                                          constant uint* boolUniforms [[buffer(4)]],
                                          constant float3* point3Uniforms [[buffer(5)]],
                                          constant float4* point4Uniforms [[buffer(6)]]) {
            float2 isf_FragNormCoord = in.uv;
            float2 fragCoord = in.uv * uniforms.resolution;
            constexpr sampler previewSampler(address::clamp_to_edge, filter::linear);
        \(uniformAliases)
        \(translatedBody.indented(spaces: 4))
        }
        """
    }

    private static func translatePrelude(_ prelude: String, uniforms: [UniformDescriptor]) -> String {
        guard !prelude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var output = translateImageCalls(prelude, imageUniforms: uniforms.filter { $0.kind == .image })
        output = rewriteRotationHelper(in: output)
        output = replaceTokens(in: output)
        output = stripUnsupportedQualifiers(in: output)
        return output
    }

    private static func aliasLines(for uniforms: [UniformDescriptor]) -> String {
        var aliasGroups: [String] = []
        var floatIndex = 0
        var colorIndex = 0
        var pointIndex = 0
        var point3Index = 0
        var point4Index = 0
        var boolIndex = 0

        for uniform in uniforms {
            switch uniform.kind {
            case .float:
                aliasGroups.append("    float \(uniform.name) = floatUniforms[\(floatIndex)];")
                floatIndex += 1
            case .color:
                aliasGroups.append("    float4 \(uniform.name) = colorUniforms[\(colorIndex)];")
                colorIndex += 1
            case .point2D:
                aliasGroups.append("    float2 \(uniform.name) = pointUniforms[\(pointIndex)];")
                pointIndex += 1
            case .float3:
                aliasGroups.append("    float3 \(uniform.name) = point3Uniforms[\(point3Index)];")
                point3Index += 1
            case .float4:
                aliasGroups.append("    float4 \(uniform.name) = point4Uniforms[\(point4Index)];")
                point4Index += 1
            case .bool:
                aliasGroups.append("    bool \(uniform.name) = (boolUniforms[\(boolIndex)] == 1);")
                boolIndex += 1
            case .image:
                aliasGroups.append("    // texture2d<float> \(uniform.name); // image uniforms are not wired into preview yet")
            }
        }

        aliasGroups.append("    float TIME = uniforms.time;")
        aliasGroups.append("    float4 DATE = uniforms.date;")
        aliasGroups.append("    float2 RENDERSIZE = uniforms.resolution;")
        return aliasGroups.joined(separator: "\n")
    }

    private static func textureCommentLines(for imageUniforms: [UniformDescriptor]) -> String {
        guard !imageUniforms.isEmpty else { return "" }
        let lines = imageUniforms.map { "// Image uniform requires texture binding: \($0.name)" }
        return lines.joined(separator: "\n")
    }

    private static func translateBody(_ body: String, uniforms: [UniformDescriptor]) -> String {
        var output = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return defaultBody()
        }

        output = translateImageCalls(output, imageUniforms: uniforms.filter { $0.kind == .image })
        output = rewriteAtanCalls(in: output)
        output = rewriteRotationApplications(in: output)
        output = replaceTokens(in: output)
        output = stripUnsupportedQualifiers(in: output)
        output = ensureReturnStatement(in: output)
        return output
    }

    private static func rewriteRotationHelper(in source: String) -> String {
        let pattern = #"mat2\s+rot\s*\(\s*float\s+([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\{[\s\S]*?return\s+mat2\s*\(\s*[^)]*\)\s*;\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }

        let range = NSRange(source.startIndex..., in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let angleRange = Range(match.range(at: 1), in: source),
              let fullRange = Range(match.range(at: 0), in: source) else {
            return source
        }

        let angleName = String(source[angleRange])
        let replacement = """
        float2 rotate2D(float2 v, float \(angleName)) {
            float c = cos(\(angleName));
            float s = sin(\(angleName));
            return float2(c * v.x - s * v.y, s * v.x + c * v.y);
        }
        """

        var output = source
        output.replaceSubrange(fullRange, with: replacement)
        return output
    }

    private static func rewriteRotationApplications(in source: String) -> String {
        var output = source

        let inPlacePattern = #"([A-Za-z_][A-Za-z0-9_\.]*)\s*\*=\s*rot\s*\(\s*([^)]+)\s*\)\s*;"#
        output = output.replacingOccurrences(
            of: inPlacePattern,
            with: "$1 = rotate2D($1, $2);",
            options: .regularExpression
        )

        let assignPattern = #"([A-Za-z_][A-Za-z0-9_\.]*)\s*=\s*([A-Za-z_][A-Za-z0-9_\.]*)\s*\*\s*rot\s*\(\s*([^)]+)\s*\)\s*;"#
        output = output.replacingOccurrences(
            of: assignPattern,
            with: "$1 = rotate2D($2, $3);",
            options: .regularExpression
        )

        return output
    }

    private static func rewriteAtanCalls(in source: String) -> String {
        source.replacingOccurrences(
            of: #"atan\s*\(\s*([^,()]+)\s*,\s*([^)]+)\)"#,
            with: "atan2($1, $2)",
            options: .regularExpression
        )
    }

    private static func translateImageCalls(_ body: String, imageUniforms: [UniformDescriptor]) -> String {
        var output = body
        for uniform in imageUniforms {
            let thisPixelPattern = #"IMG_THIS_PIXEL\s*\(\s*\#(uniform.name)\s*,\s*([^)]+)\)"#
            output = output.replacingOccurrences(
                of: thisPixelPattern,
                with: "\(uniform.name).sample(previewSampler, ($1) / uniforms.resolution)",
                options: .regularExpression
            )

            let normPixelPattern = #"IMG_NORM_PIXEL\s*\(\s*\#(uniform.name)\s*,\s*([^)]+)\)"#
            output = output.replacingOccurrences(
                of: normPixelPattern,
                with: "\(uniform.name).sample(previewSampler, $1)",
                options: .regularExpression
            )

            let sizePattern = #"IMG_SIZE\s*\(\s*\#(uniform.name)\s*\)"#
            output = output.replacingOccurrences(
                of: sizePattern,
                with: "uniforms.resolution",
                options: .regularExpression
            )
        }
        return output
    }

    private static func replaceTokens(in body: String) -> String {
        let replacements: [(String, String)] = [
            (#"\bvec2\b"#, "float2"),
            (#"\bvec3\b"#, "float3"),
            (#"\bvec4\b"#, "float4"),
            (#"\bivec2\b"#, "int2"),
            (#"\bivec3\b"#, "int3"),
            (#"\bivec4\b"#, "int4"),
            (#"\bmat2\b"#, "float2x2"),
            (#"\bmat3\b"#, "float3x3"),
            (#"\bmat4\b"#, "float4x4"),
            (#"\bgl_FragCoord\b"#, "float4(fragCoord, 0.0, 1.0)"),
            (#"\bisf_FragNormCoord\b"#, "isf_FragNormCoord"),
            (#"\bTIME\b"#, "TIME"),
            (#"\bDATE\b"#, "DATE"),
            (#"\bRENDERSIZE\b"#, "RENDERSIZE"),
            (#"\bPI\b"#, "3.14159265"),
            (#"\bmod\s*\("#, "fmod("),
            (#"\bfract\s*\("#, "fract("),
            (#"\bgl_FragColor\s*=\s*"#, "return "),
            (#"\bmix\s*\("#, "mix(")
        ]

        var output = body
        for (pattern, replacement) in replacements {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return output
    }

    private static func stripUnsupportedQualifiers(in body: String) -> String {
        body
            .replacingOccurrences(of: #"(?m)^\s*#ifdef\s+GL_ES\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*#endif\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*precision\s+\w+\s+float\s*;\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\bvarying\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\buniform\b"#, with: "", options: .regularExpression)
    }

    private static func ensureReturnStatement(in body: String) -> String {
        if body.contains("return ") {
            return body
        }

        if let colorAssignmentRange = body.range(of: #"(float4\s+\w+\s*=.+;)\s*$"#, options: .regularExpression) {
            let assignment = String(body[colorAssignmentRange])
            let variable = assignment
                .replacingOccurrences(of: #"float4\s+"#, with: "", options: .regularExpression)
                .components(separatedBy: "=")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "color"
            return body + "\nreturn \(variable);"
        }

        return body + "\nreturn float4(isf_FragNormCoord, 0.0, 1.0);"
    }

    private static func defaultBody() -> String {
        """
        float2 centered = isf_FragNormCoord - 0.5;
        float ripple = sin(length(centered) * 18.0 - uniforms.time * 2.2);
        float banded = smoothstep(-0.15, 0.9, ripple);
        float glow = exp(-length(centered) * 4.0);
        float3 color = mix(float3(0.03, 0.04, 0.08), float3(0.96, 0.44, 0.18), banded * glow);
        return float4(color, 1.0);
        """
    }
}

private extension String {
    func indented(spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : prefix + line
            }
            .joined(separator: "\n")
    }
}
