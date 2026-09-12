// Copyright 2021 Yi Xie
// Copyright 2026 AnimeWitcher contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// The mpv-style Anime4K shader parser & GLSL-to-MSL translation are derived
// from imxieyi/Anime4KMetal's Shared/MPVShader.swift (Apache-2.0), adapted to
// be independent of the demo player and reusable by AnimeWitcher.

import Foundation

enum Anime4KMetalPrecisionPolicy: String, CaseIterable {
    case fp32
    case mixedFP16

    fileprivate var colorScalar: String {
        self == .mixedFP16 ? "half" : "float"
    }

    fileprivate var vec3: String {
        self == .mixedFP16 ? "half3" : "float3"
    }

    fileprivate var vec4: String {
        self == .mixedFP16 ? "half4" : "float4"
    }

    fileprivate var mat3: String {
        self == .mixedFP16 ? "half3x3" : "float3x3"
    }

    fileprivate var mat4: String {
        self == .mixedFP16 ? "half4x4" : "float4x4"
    }
}

struct Anime4KMetalShader {
    var name: String
    var hook: String?
    var binds: [String]
    var save: String?
    var components: Int?
    var width: (String, Float)?
    var height: (String, Float)?
    var when: String?
    var sigma: Double?
    var code: [String]

    init(name: String) {
        self.name = name
        self.binds = []
        self.code = []
    }

    var functionName: String {
        let scalars = name.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
        let value = String(String.UnicodeScalarView(scalars))
        return value.isEmpty ? "Anime4KPass" : value
    }

    var inputTextureNames: [String] {
        var names = binds
        if hook == "MAIN" && !names.contains("MAIN") {
            names.append("MAIN")
        }
        return names
    }

    var outputTextureName: String {
        if let save, save != "MAIN" {
            return save
        }
        return "output"
    }

    /// Keep the historical property as the FP32 reference path. Mixed FP16 is
    /// explicitly selected so it cannot become the playback default before the
    /// real corpus and numerical tolerance gates are green.
    var metalSource: String {
        metalSource(precision: .fp32)
    }

    func metalSource(precision: Anime4KMetalPrecisionPolicy) -> String {
        let colorScalar = precision.colorScalar
        var header = """
        #include <metal_stdlib>
        using namespace metal;

        using vec2 = float2;
        using vec3 = \(precision.vec3);
        using vec4 = \(precision.vec4);
        using ivec2 = int2;
        using ivec3 = int3;
        using ivec4 = int4;
        using mat2 = float2x2;
        using mat3 = \(precision.mat3);
        using mat4 = \(precision.mat4);

        """

        if precision == .mixedFP16 {
            // Preserve explicitly-FP32 scalar math while allowing FP16 texture
            // samples to participate without ambiguous Metal overloads.
            header += """
            inline float min(float lhs, half rhs) {
                return metal::min(lhs, float(rhs));
            }

            """
        }

        for bind in binds {
            header += """
            #define \(bind)_pos mtlPos
            #define \(bind)_size float2(\(bind).get_width(), \(bind).get_height())
            #define \(bind)_pt (vec2(1, 1) / \(bind)_size)
            #define \(bind)_tex(pos) \(bind).sample(textureSampler, pos)
            #define \(bind)_texOff(off) \(bind)_tex(\(bind)_pos + \(bind)_pt * vec2(off))

            """
        }

        if hook == "MAIN" && !binds.contains("MAIN") {
            header += """
            #define MAIN_pos mtlPos
            #define MAIN_size vec2(MAIN.get_width(), MAIN.get_height())
            #define MAIN_pt (vec2(1, 1) / MAIN_size)
            #define MAIN_tex(pos) MAIN.sample(textureSampler, pos)
            #define MAIN_texOff(off) MAIN_tex(MAIN_pos + MAIN_pt * vec2(off))

            """
        }

        var extraArgs = "float2 mtlPos, sampler textureSampler, "
        var extraCallArgs = "mtlPos, textureSampler, "
        var entryArgs = ""

        for (index, bind) in binds.enumerated() {
            extraArgs += "texture2d<\(colorScalar), access::sample> \(bind), "
            extraCallArgs += "\(bind), "
            entryArgs += "texture2d<\(colorScalar), access::sample> \(bind) [[texture(\(index))]], "
        }

        var textureIndex = binds.count
        if hook == "MAIN" && !binds.contains("MAIN") {
            extraArgs += "texture2d<\(colorScalar), access::sample> MAIN, "
            extraCallArgs += "MAIN, "
            entryArgs += "texture2d<\(colorScalar), access::sample> MAIN [[texture(\(textureIndex))]], "
            textureIndex += 1
        }

        entryArgs += "texture2d<\(colorScalar), access::write> output [[texture(\(textureIndex))]], "
        entryArgs += "uint2 gid [[thread_position_in_grid]], "
        entryArgs += "sampler textureSampler [[sampler(0)]]"

        var knownFunctions: [String] = []
        var currentFunction: String?
        var body = ""

        for originalLine in code {
            if currentFunction == nil {
                let matches = Self.matches(
                    pattern: "(\\w*\\s+)(\\w+)\\((.*)\\)(\\s+\\{)",
                    text: originalLine
                )
                if matches.count == 5 {
                    let returnType = matches[1]
                    let function = matches[2]
                    let args = matches[3]
                    let suffix = matches[4]
                    currentFunction = function
                    knownFunctions.append(function)
                    var injected = extraArgs
                    if args.isEmpty && injected.hasSuffix(", ") {
                        injected.removeLast(2)
                    }
                    body += returnType + function + "(" + injected + args + ")" + suffix + "\n"
                    continue
                }
            } else if originalLine == "}" {
                currentFunction = nil
            }

            var line = originalLine
            for function in knownFunctions {
                line = line.replacingOccurrences(
                    of: function + "(",
                    with: function + "(" + extraCallArgs
                )
                line = line.replacingOccurrences(of: ", )", with: ")")
            }
            body += line + "\n"
        }

        var hookArgs = extraCallArgs
        if hookArgs.hasSuffix(", ") {
            hookArgs.removeLast(2)
        }

        body += """

        kernel void \(functionName)(\(entryArgs)) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            const float2 outputSize = float2(output.get_width(), output.get_height());
            const float2 denominator = max(outputSize - float2(1.0), float2(1.0));
            float2 mtlPos = float2(gid) / denominator;
            output.write(hook(\(hookArgs)), gid);
        }
        """

        return header + body
    }

    static func parse(_ glsl: String) throws -> [Anime4KMetalShader] {
        // `String.split(separator: "\n")` does not split CRLF text in Swift
        // because CRLF is treated as one extended grapheme cluster. Anime4K's
        // v4.0.1 release ZIP contains CRLF shaders even though the Git tree is
        // LF, so split using Foundation's newline character set instead.
        let lines = glsl
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var shaders: [Anime4KMetalShader] = []
        var current: Anime4KMetalShader?

        func requireCurrent(_ line: String) throws -> Anime4KMetalShader {
            guard let current else {
                throw Anime4KMetalShaderError.parseFailure(
                    "directive/code appears before //!DESC: \(line)"
                )
            }
            return current
        }

        for line in lines {
            if line.isEmpty { continue }

            if line.hasPrefix("//") {
                guard line.hasPrefix("//!") else { continue }

                let info = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let parts = info.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let directive = parts.first else { continue }

                if directive == "DESC" {
                    guard parts.count >= 2 else {
                        throw Anime4KMetalShaderError.parseFailure(line)
                    }
                    if let current { shaders.append(current) }
                    current = Anime4KMetalShader(name: parts.dropFirst().joined(separator: "-"))
                    continue
                }

                var shader = try requireCurrent(line)
                switch directive {
                case "HOOK":
                    guard parts.count == 2 else {
                        throw Anime4KMetalShaderError.parseFailure(line)
                    }
                    shader.hook = parts[1] == "PREKERNEL" ? "MAIN" : parts[1]

                case "BIND":
                    guard parts.count == 2 else {
                        throw Anime4KMetalShaderError.parseFailure(line)
                    }
                    shader.binds.append(parts[1])

                case "SAVE":
                    guard parts.count == 2 else {
                        throw Anime4KMetalShaderError.parseFailure(line)
                    }
                    shader.save = parts[1]

                case "COMPONENTS":
                    guard parts.count == 2, let value = Int(parts[1]) else {
                        throw Anime4KMetalShaderError.parseFailure(line)
                    }
                    shader.components = value

                case "WIDTH":
                    shader.width = try parseDimension(parts: parts, line: line)

                case "HEIGHT":
                    shader.height = try parseDimension(parts: parts, line: line)

                case "WHEN":
                    shader.when = info

                default:
                    throw Anime4KMetalShaderError.parseFailure(line)
                }
                current = shader
                continue
            }

            var shader = try requireCurrent(line)

            if line.contains("#define SPATIAL_SIGMA") {
                let matches = matches(
                    pattern: "#define SPATIAL_SIGMA ([-+]?\\d*\\.?\\d+).*",
                    text: line
                )
                if matches.count == 2, let value = Double(matches[1]) {
                    shader.sigma = value
                }
            }

            if line.contains("#define KERNELSIZE int(max(int(SPATIAL_SIGMA), 1) * 2 + 1)"),
               let sigma = shader.sigma {
                shader.code.append(
                    "#define KERNELSIZE \(Int(max(Int(sigma), 1) * 2 + 1))"
                )
                current = shader
                continue
            }

            shader.code.append(line)
            current = shader
        }

        if let current { shaders.append(current) }
        guard !shaders.isEmpty else {
            throw Anime4KMetalShaderError.parseFailure("no //!DESC shader passes found")
        }
        for shader in shaders {
            guard shader.hook != nil else {
                throw Anime4KMetalShaderError.parseFailure(
                    "shader \(shader.name) has no //!HOOK"
                )
            }
            guard shader.code.contains(where: { $0.contains("hook(") }) else {
                throw Anime4KMetalShaderError.parseFailure(
                    "shader \(shader.name) has no hook() function"
                )
            }
        }
        return shaders
    }

    private static func parseDimension(
        parts: [String],
        line: String
    ) throws -> (String, Float) {
        guard parts.count == 2 || parts.count == 4 else {
            throw Anime4KMetalShaderError.parseFailure(line)
        }
        let baseParts = parts[1].split(separator: ".")
        guard let base = baseParts.first, !base.isEmpty else {
            throw Anime4KMetalShaderError.parseFailure(line)
        }
        if parts.count == 2 {
            return (String(base), 1)
        }
        guard let amount = Float(parts[2]), amount != 0 else {
            throw Anime4KMetalShaderError.parseFailure(line)
        }
        switch parts[3] {
        case "*":
            return (String(base), amount)
        case "/":
            return (String(base), 1 / amount)
        default:
            throw Anime4KMetalShaderError.parseFailure(line)
        }
    }

    private static func matches(pattern: String, text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return []
        }
        return (0..<match.numberOfRanges).map { index in
            let matchRange = match.range(at: index)
            guard let range = Range(matchRange, in: text) else { return "" }
            return String(text[range])
        }
    }
}

enum Anime4KMetalShaderError: Error, LocalizedError {
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .parseFailure(let message):
            return "Anime4K Metal shader parse failure: \(message)"
        }
    }
}
