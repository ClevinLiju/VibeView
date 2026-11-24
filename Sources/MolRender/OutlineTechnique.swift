import SceneKit
import Metal
import simd

/// Screen-space silhouette outlines as an `SCNTechnique` post pass over the color and depth buffers.
///
/// SceneKit renders with reversed Z, so view depth is proportional to 1/d. For each pixel the pass
/// compares the depth of 8 neighbors at `widthPixels` and measures the surface slope relative to the
/// view ray: slope = (Δz/z) / (pixel angle). Silhouettes (against the background or other atoms) have a
/// near-infinite slope; the steep rim of every sphere yields the classic outline. The measure does not
/// depend on the camera distance, so outlines stay stable while zooming.
///
/// Custom technique symbols do not reliably bind to Metal buffers, so the parameters are baked into the
/// shader source and a small cache keyed by parameters avoids recompiling.
@MainActor enum OutlineTechnique {
    struct Key: Hashable { let r: Int, g: Int, b: Int, a: Int, width: Int, pixelAngle: Int }
    private static var cache: [Key: SCNTechnique] = [:]
    private static var failed = false

    /// - Parameters:
    ///   - widthPixels: outline half-width in device pixels.
    ///   - pixelAngle: angular size of one pixel (radians) = 2 tan(fov/2) / heightPixels.
    static func technique(color: RGBA, widthPixels: Double, pixelAngle: Double) -> SCNTechnique? {
        guard !failed else { return nil }
        let key = Key(r: Int(color.r * 255), g: Int(color.g * 255), b: Int(color.b * 255), a: Int(color.a * 255),
                      width: Int((widthPixels * 8).rounded()), pixelAngle: Int((pixelAngle * 1e6).rounded()))
        if let t = cache[key] { return t }
        guard let device = MTLCreateSystemDefaultDevice() else { failed = true; return nil }
        let src = source(color: color, width: max(0.5, widthPixels), pixelAngle: max(1e-6, pixelAngle))
        guard let lib = try? device.makeLibrary(source: src, options: nil) else { failed = true; return nil }
        let dict: [String: Any] = [
            "passes": ["molscope_outline": [
                "draw": "DRAW_QUAD",
                "metalVertexShader": "molscope_outline_vert",
                "metalFragmentShader": "molscope_outline_frag",
                "inputs": ["colorSampler": "COLOR", "depthSampler": "DEPTH"],
                "outputs": ["color": "COLOR"],
            ]],
            "sequence": ["molscope_outline"],
        ]
        guard let t = SCNTechnique(dictionary: dict) else { failed = true; return nil }
        t.library = lib
        if cache.count > 16 { cache.removeAll() }
        cache[key] = t
        return t
    }

    static func source(color c: RGBA, width: Double, pixelAngle: Double) -> String {
        func f(_ x: Double) -> String { String(format: "%.6f", x) }
        return """
        #include <metal_stdlib>
        using namespace metal;
        struct VIn { float4 position [[attribute(0)]]; };
        struct VOut { float4 position [[position]]; float2 uv; };
        vertex VOut molscope_outline_vert(VIn in [[stage_in]]) {
            VOut o; o.position = in.position;
            o.uv = float2((in.position.x + 1.0) * 0.5, 1.0 - (in.position.y + 1.0) * 0.5);
            return o;
        }
        constant float4 kColor = float4(\(f(c.r)), \(f(c.g)), \(f(c.b)), \(f(c.a)));
        constant float kWidth = \(f(width));
        constant float kPixelAngle = \(f(pixelAngle));
        static float viewZ(float d) { return 1.0 / max(d, 1e-7); }
        fragment half4 molscope_outline_frag(VOut in [[stage_in]],
                                             texture2d<half> colorSampler [[texture(0)]],
                                             depth2d<float> depthSampler [[texture(1)]]) {
            constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
            half4 c = colorSampler.sample(s, in.uv);
            float2 px = float2(1.0 / depthSampler.get_width(), 1.0 / depthSampler.get_height()) * kWidth;
            float z0 = viewZ(depthSampler.sample(s, in.uv));
            float slope = 0.0;
            for (int k = 0; k < 8; k++) {
                float a = float(k) * 0.7853982;
                float z = viewZ(depthSampler.sample(s, in.uv + px * float2(cos(a), sin(a))));
                slope = max(slope, (z - z0) / z0);
            }
            slope /= (kWidth * kPixelAngle);
            float edge = smoothstep(5.0, 12.0, slope) * kColor.a;
            return half4(mix(c.rgb, half3(kColor.rgb), half(edge)), max(c.a, half(edge)));
        }
        """
    }
}
