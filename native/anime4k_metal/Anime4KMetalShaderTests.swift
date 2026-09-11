import Foundation

@main
struct Anime4KMetalShaderTests {
    static func main() throws {
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
            _ = try Anime4KMetalShader.parse("//!HOOK MAIN\nvec4 hook() { return vec4(0); }")
            preconditionFailure("malformed shader without DESC should fail")
        } catch {
            // Expected: the translator must fail closed instead of silently
            // producing a no-op Metal pipeline.
        }

        print("Anime4KMetalShaderTests: PASS")
    }
}
