import Foundation

@main
struct Anime4KMetalPrecisionTests {
    static func main() {
        testMixedFP16StaysWithinReferenceTolerance()
        print("Anime4KMetalPrecisionTests: PASS")
    }

    /// Numerical guard for the mixed-FP16 policy.
    ///
    /// The production translator keeps coordinates/dimensions as Float while
    /// allowing sampled color/CNN vector math to use half precision. This
    /// reference kernel deliberately models the stricter case where every
    /// multiply and accumulation in the color path is rounded through Float16.
    /// If this worst-case model remains close to the Float32 reference, the
    /// actual mixed path has at least as much numerical headroom for this
    /// representative signed CNN convolution.
    private static func testMixedFP16StaysWithinReferenceTolerance() {
        let samples: [Float] = (0..<64).map { index in
            Float((index * 37) % 257) / 256.0
        }
        let kernel: [Float] = [
            -0.0625, 0.125, 0.25,
            0.375, 0.25, 0.125,
            -0.0625, 0.03125, -0.03125,
        ]
        let bias: Float = 0.05
        let absoluteTolerance: Float = 0.002

        var worstError: Float = 0
        var worstIndex = -1

        for start in 0...(samples.count - kernel.count) {
            var fp32 = bias
            var fp16 = Float16(bias)

            for offset in kernel.indices {
                let sample = samples[start + offset]
                let weight = kernel[offset]
                fp32 += sample * weight
                fp16 = Float16(
                    fp16 + Float16(Float16(sample) * Float16(weight))
                )
            }

            let clampedFP32 = min(max(fp32, 0), 1)
            let clampedFP16 = min(max(Float(fp16), 0), 1)
            let error = abs(clampedFP32 - clampedFP16)
            if error > worstError {
                worstError = error
                worstIndex = start
            }
        }

        precondition(
            worstError <= absoluteTolerance,
            "mixed FP16 numerical error \(worstError) exceeded " +
                "\(absoluteTolerance) at sample window \(worstIndex)"
        )
    }
}
