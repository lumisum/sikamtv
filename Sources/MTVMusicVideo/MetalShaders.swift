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

    struct PostUniforms {
        float4 viewport; // width, height, visual center x/y in normalized coordinates
        float4 audio;    // bass, mid, high, beat
        float4 style;    // time, integration, brilliance, trail
        float4 mode;     // color richness, depth, beat impact, history valid
        float4 structure; // energy, buildup, climax, quietness
        float4 character; // transient, warmth, section progress, awareness
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

    float luminance(float3 color) {
        return dot(color, float3(0.2126, 0.7152, 0.0722));
    }

    float hash21(float2 value) {
        value = fract(value * float2(123.34, 456.21));
        value += dot(value, value + 45.32);
        return fract(value.x * value.y);
    }

    float3 bloomLevel(texture2d<float> source, sampler samp, float2 uv, float2 offset) {
        float3 value = float3(0.0);
        value += source.sample(samp, clamp(uv + float2(offset.x, offset.y), float2(0.001), float2(0.999))).rgb;
        value += source.sample(samp, clamp(uv + float2(-offset.x, offset.y), float2(0.001), float2(0.999))).rgb;
        value += source.sample(samp, clamp(uv + float2(offset.x, -offset.y), float2(0.001), float2(0.999))).rgb;
        value += source.sample(samp, clamp(uv - float2(offset.x, offset.y), float2(0.001), float2(0.999))).rgb;
        return value * 0.25;
    }

    float3 softBrightPass(float3 color, float threshold) {
        float brightness = luminance(color);
        float knee = smoothstep(threshold - 0.16, threshold + 0.22, brightness);
        return color * knee * knee;
    }

    fragment float4 fragment_post(VertexOut in [[stage_in]],
                                  texture2d<float> scene [[texture(0)]],
                                  texture2d<float> history [[texture(1)]],
                                  sampler samp [[sampler(0)]],
                                  constant PostUniforms &post [[buffer(0)]]) {
        // Render targets use a top-left texture origin while scene geometry uses
        // Core Graphics coordinates. Flip only at this offscreen sampling edge.
        float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
        float2 center = post.viewport.zw;
        float2 delta = uv - center;
        float aspect = post.viewport.x / max(post.viewport.y, 1.0);
        float2 metric = float2(delta.x * aspect, delta.y);
        float radius = length(metric);
        float bass = post.audio.x;
        float mid = post.audio.y;
        float high = post.audio.z;
        float beat = post.audio.w;
        float time = post.style.x;
        float integration = post.style.y;
        float brilliance = post.style.z;
        float trail = post.style.w * post.mode.w;
        float richness = post.mode.x;
        float depth = post.mode.y;
        float beatImpact = post.mode.z;
        float awareness = post.character.w;
        float energy = mix(post.audio.y, post.structure.x, awareness);
        float buildup = post.structure.y * awareness;
        float climax = post.structure.z * awareness;
        float quietness = post.structure.w * awareness;
        float transient = post.character.x * awareness;
        float warmth = post.character.y;
        float sectionProgress = post.character.z;

        // Audio-driven refraction makes the visualization feel embedded in the
        // source image instead of sitting on top of it.
        float phraseFlow = buildup * 1.4 + climax * 0.85 - quietness * 0.35;
        float radialWave = sin(radius * (24.0 + mid * 10.0 + buildup * 5.0) - time * (1.05 + bass + phraseFlow * 0.22) + bass * 5.0 + sectionProgress * 1.6);
        float radialMask = exp(-radius * (3.2 - depth * 0.8));
        float2 direction = radius > 0.0001 ? metric / radius : float2(0.0);
        direction.x /= max(aspect, 0.0001);
        float refraction = integration * depth * (0.0008 + energy * 0.0008 + bass * 0.0020 + transient * beatImpact * 0.0018) * (1.0 - quietness * 0.42);
        uv += direction * radialWave * radialMask * refraction;
        uv += float2(
            sin((uv.y + time * 0.025) * 18.0 + mid * 3.0),
            cos((uv.x - time * 0.018) * 15.0 + high * 4.0)
        ) * integration * depth * (0.00025 + mid * 0.00055);
        uv = clamp(uv, float2(0.001), float2(0.999));

        float chroma = brilliance * richness * (0.00028 + high * 0.0010 + transient * beatImpact * 0.00075 + climax * 0.00055);
        float2 chromaDirection = normalize(metric + float2(0.0001)) * chroma;
        float3 color;
        color.r = scene.sample(samp, clamp(uv + chromaDirection, float2(0.001), float2(0.999))).r;
        color.g = scene.sample(samp, uv).g;
        color.b = scene.sample(samp, clamp(uv - chromaDirection, float2(0.001), float2(0.999))).b;

        // Three perceptual bloom scales produce a crisp core, a medium halo and
        // a broad atmospheric glow. Four diagonal taps per scale keep this pass
        // fast enough for realtime preview without extra full-size textures.
        float2 texel = 1.0 / max(post.viewport.xy, float2(1.0));
        float bloomSpread = 1.0 + depth * 0.65 + transient * beatImpact * 0.22;
        float3 bloomNear = softBrightPass(bloomLevel(scene, samp, uv, texel * 2.0 * bloomSpread), 0.62);
        float3 bloomMid = softBrightPass(bloomLevel(scene, samp, uv, texel * 5.5 * bloomSpread), 0.54);
        float3 bloomFar = softBrightPass(bloomLevel(scene, samp, uv, texel * 12.0 * bloomSpread), 0.46);
        float3 bloom = bloomNear * 0.48 + bloomMid * 0.34 + bloomFar * 0.18;
        float bloomGain = brilliance * (0.13 + energy * 0.07 + transient * beatImpact * 0.12 + climax * 0.15) * (1.0 - quietness * 0.34);
        color += bloom * bloomGain;

        float3 previous = history.sample(samp, uv - direction * trail * 0.0018).rgb;
        float trailMix = trail * (0.040 + mid * 0.040 + buildup * 0.040 + climax * 0.025 + transient * beatImpact * 0.030);
        color = mix(color, max(color, previous * 0.965), saturate(trailMix));

        float gray = luminance(color);
        color = mix(float3(gray), color, 0.72 + richness * 0.48 - quietness * 0.10);
        float3 emotionalTint = mix(float3(0.94, 1.01, 1.07), float3(1.07, 1.015, 0.93), warmth);
        color *= mix(float3(1.0), emotionalTint, awareness * (0.025 + energy * 0.035));
        float sectionArc = sin(sectionProgress * 3.14159265);
        float3 sectionTint = float3(
            1.0 + sin(sectionProgress * 6.2831853 + 0.0) * 0.035,
            1.0 + sin(sectionProgress * 6.2831853 + 2.0943951) * 0.028,
            1.0 + sin(sectionProgress * 6.2831853 + 4.1887902) * 0.035
        );
        color *= mix(float3(1.0), sectionTint, awareness * richness * (0.16 + buildup * 0.16) * sectionArc);
        color *= 1.0 + (transient * 0.045 + climax * 0.035) * beatImpact * brilliance;
        color = color / (1.0 + max(color - 1.0, float3(0.0)) * 0.62);

        float grain = (hash21(in.position.xy + time * 37.0) - 0.5) * (0.006 + brilliance * 0.009);
        color += grain * (0.45 + high * 0.55);
        return float4(clamp(color, 0.0, 1.0), 1.0);
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

struct GPUPostUniforms {
    var viewport: SIMD4<Float>
    var audio: SIMD4<Float>
    var style: SIMD4<Float>
    var mode: SIMD4<Float>
    var structure: SIMD4<Float>
    var character: SIMD4<Float>
}

struct PostProcessSettings {
    let time: Double
    let center: SIMD2<Float>
    let bass: Float
    let mid: Float
    let high: Float
    let beat: Float
    let integration: Float
    let brilliance: Float
    let trail: Float
    let colorRichness: Float
    let depth: Float
    let beatImpact: Float
    let energy: Float
    let transient: Float
    let buildup: Float
    let climax: Float
    let quiet: Float
    let warmth: Float
    let sectionProgress: Float
    let musicAwareness: Float

    func uniforms(size: CGSize, historyValid: Bool) -> GPUPostUniforms {
        GPUPostUniforms(
            viewport: SIMD4(Float(size.width), Float(size.height), center.x, center.y),
            audio: SIMD4(bass, mid, high, beat),
            style: SIMD4(Float(time), integration, brilliance, trail),
            mode: SIMD4(colorRichness, depth, beatImpact, historyValid ? 1 : 0),
            structure: SIMD4(energy, buildup, climax, quiet),
            character: SIMD4(transient, warmth, sectionProgress, musicAwareness)
        )
    }
}
