import Foundation

@main
struct Anime4KMetalShaderTests {
    static func main() throws {
        try testSyntheticFixture()
        try emitCorpusMetalSourcesIfRequested()
        print("Anime4KMetalShaderTests: PASS")
    }

    private static func testSyntheticFixture() throws {
        let source = """
        //!DESC Anime4K-Test-Pass
        //!HOOK MAIN
        //!BIND MAIN
        //!SAVE scaled
        //!WIDTH MAIN.w 2 *
        //!HEIGHT MAIN.h 2 *
        //!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *
        vec4 hook() {
            return MAIN_tex(MAIN_pos);
        }
        """

        let passes = try Anime4KMetalShader.parse(source)
        precondition(passes.count == 1, "expected one parsed shader pass")
        let shader = passes[0]
        precondition(shader.name == "Anime4K-Test-Pass")
        precondition(shader.hook == "MAIN")
        precondition(shader.binds == ["MAIN"])
        precondition(shader.save == "scaled")
        precondition(shader.width?.0 == "MAIN" && shader.width?.1 == 2)
        precondition(shader.height?.0 == "MAIN" && shader.height?.1 == 2)
        precondition(shader.when != nil)

        let metal = shader.metalSource
        precondition(metal.contains("#include <metal_stdlib>"))
        precondition(metal.contains("kernel void Anime4KTestPass"))
        precondition(metal.contains("texture2d<float, access::sample> MAIN"))
        precondition(metal.contains("texture2d<float, access::write> output"))

        do {
            _ = try Anime4KMetalShader.parse(
                "//!HOOK MAIN\nvec4 hook() { return vec4(0); }"
            )
            preconditionFailure("malformed shader without DESC should fail")
        } catch {
            // Expected: the translator must fail closed instead of silently
            // producing a no-op Metal pipeline.
        }
    }

    /// When called with `OUTPUT_DIR shader1.glsl ...`, translate every pass in
    /// the real pinned corpus into an individual `.metal` file. The CI helper
    /// then feeds those files to Apple's Metal compiler. Keeping MSL emission
    /// here means corpus verification exercises the exact production parser and
    /// translator rather than a second implementation in the shell script.
    private static func emitCorpusMetalSourcesIfRequested() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { return }
        guard arguments.count >= 2 else {
            throw CorpusVerificationError.usage
        }

        let outputDirectory = URL(
            fileURLWithPath: arguments[0],
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var generatedPasses = 0
        for path in arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard let source = String(data: data, encoding: .utf8) else {
                throw CorpusVerificationError.notUTF8(path)
            }

            let passes: [Anime4KMetalShader]
            do {
                passes = try Anime4KMetalShader.parse(source)
            } catch {
                throw CorpusVerificationError.parseFailure(
                    path,
                    String(describing: error)
                )
            }
            guard !passes.isEmpty else {
                throw CorpusVerificationError.noPasses(path)
            }

            let shaderBase = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(
                    of: "[^A-Za-z0-9_-]",
                    with: "_",
                    options: .regularExpression
                )
            for (index, pass) in passes.enumerated() {
                let filename = String(
                    format: "%@-%03d-%@.metal",
                    shaderBase,
                    index,
                    pass.functionName
                )
                let output = outputDirectory.appendingPathComponent(filename)
                try pass.metalSource.write(
                    to: output,
                    atomically: true,
                    encoding: .utf8
                )
                generatedPasses += 1
            }
        }

        guard generatedPasses > 0 else {
            throw CorpusVerificationError.noGeneratedPasses
        }
        print(
            "Anime4K corpus translation: \(arguments.count - 1) files, " +
            "\(generatedPasses) Metal passes"
        )
    }
}

enum CorpusVerificationError: Error, LocalizedError {
    case usage
    case notUTF8(String)
    case parseFailure(String, String)
    case noPasses(String)
    case noGeneratedPasses

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: Anime4KMetalShaderTests OUTPUT_DIR shader.glsl ..."
        case .notUTF8(let path):
            return "Anime4K corpus shader is not UTF-8: \(path)"
        case .parseFailure(let path, let detail):
            return "Anime4K corpus parse failed for \(path): \(detail)"
        case .noPasses(let path):
            return "Anime4K corpus shader parsed to zero passes: \(path)"
        case .noGeneratedPasses:
            return "Anime4K corpus produced no Metal passes"
        }
    }
}
