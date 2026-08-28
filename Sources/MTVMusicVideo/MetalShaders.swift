import Foundation

enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
        float2 uv [[attribute(1)]];
        float4 color [[attribute(2)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    struct Uniforms {
        float2 size;
        float2 pad;
    };

    vertex VertexOut vertex_main(VertexIn in [[stage_in]], constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        // Input geometry uses Core Graphics coordinates: origin bottom-left,
        // with larger Y values appearing higher in the finished frame. Texture
        // sampling is flipped separately when textured quads are assembled.
        float2 clip = float2(in.position.x / max(uniforms.size.x, 1.0) * 2.0 - 1.0,
                             in.position.y / max(uniforms.size.y, 1.0) * 2.0 - 1.0);
        out.position = float4(clip, 0.0, 1.0);
        out.uv = in.uv;
        out.color = in.color;
        return out;
    }

    fragment float4 fragment_color(VertexOut in [[stage_in]]) {
        return in.color;
    }

    fragment float4 fragment_radial(VertexOut in [[stage_in]]) {
        float2 delta = in.uv * 2.0 - 1.0;
        float falloff = saturate(1.0 - length(delta));
        falloff *= falloff;
        return float4(in.color.rgb * falloff, in.color.a * falloff);
    }

    fragment float4 fragment_texture(VertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler samp [[sampler(0)]]) {
        float4 sampled = tex.sample(samp, in.uv);
        return float4(sampled.rgb * in.color.a, sampled.a * in.color.a);
    }

    fragment float4 fragment_vignette(VertexOut in [[stage_in]]) {
        float2 delta = in.uv * 2.0 - 1.0;
        float dist = length(delta);
        float dark = smoothstep(0.36, 1.18, dist);
        return float4(0.0, 0.0, 0.0, dark * in.color.a);
    }
    """
}

struct GPUVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}

struct VisualizerMesh {
    var soft: [GPUVertex] = []
    var additive: [GPUVertex] = []
    var radials: [GPUVertex] = []
}

struct GPUUniforms {
    var size: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
}
