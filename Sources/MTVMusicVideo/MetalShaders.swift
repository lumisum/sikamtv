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

    struct BackgroundUniforms {
        float4 viewport;  // width, height, visual center x/y
        float4 audio;     // bass, mid, high, transient
        float4 structure; // energy, buildup, climax, quietness
        float4 controls;  // life, camera, warp, parallax
        float4 mode;      // light flow, subject protection, style, reactivity
        float4 clock;     // time, section progress, warmth, awareness
        float4 mask;      // Vision mask availability
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

    float luminance(float3 color);

    fragment float4 fragment_background(VertexOut in [[stage_in]],
                                         texture2d<float> tex [[texture(0)]],
                                         texture2d<float> subjectMaskTexture [[texture(1)]],
                                         sampler samp [[sampler(0)]],
                                         constant BackgroundUniforms &motion [[buffer(0)]]) {
        float2 uv = in.uv;
        float2 center = float2(0.5);
        float aspect = motion.viewport.x / max(motion.viewport.y, 1.0);
        float bass = motion.audio.x;
        float mid = motion.audio.y;
        float high = motion.audio.z;
        float transient = motion.audio.w;
        float energy = motion.structure.x;
        float buildup = motion.structure.y;
        float climax = motion.structure.z;
        float quietness = motion.structure.w;
        float life = motion.controls.x * motion.mode.w;
        float camera = motion.controls.y;
        float warp = motion.controls.z;
        float parallax = motion.controls.w;
        float lightFlow = motion.mode.x;
        float protection = motion.mode.y;
        float style = motion.mode.z;
        float time = motion.clock.x;
        float section = motion.clock.y;
        float warmth = motion.clock.z;
        float awareness = motion.clock.w;
        float hasVisionMask = motion.mask.x;
        float subjectMode = motion.mask.y;
        float edgeLightStrength = motion.mask.z;

        // Stable camera breathing: low frequencies and the long-form energy arc
        // influence scale and drift without tying position directly to loudness.
        float styleCamera = style < 0.5 ? 0.62 : (style < 1.5 ? 1.0 : 0.78);
        float musicalPace = 0.65 + energy * 0.42 + buildup * 0.22;
        float zoom = 1.0 + life * camera * styleCamera * (0.008 + energy * 0.008 + climax * 0.005)
            + sin(time * (0.15 + musicalPace * 0.045)) * life * camera * 0.0025;
        float2 drift = float2(
            sin(time * 0.071 + section * 1.2),
            cos(time * 0.057 - section * 0.9)
        ) * life * camera * float2(0.0045, 0.0035) * (1.0 - quietness * 0.55);
        uv = center + (uv - center) / zoom + drift;

        float2 visualCenter = float2(motion.viewport.z, motion.viewport.w);
        float2 delta = uv - visualCenter;
        float2 metric = float2(delta.x * aspect, delta.y);
        float radius = length(metric);
        float centralProtection = exp(-dot(float2((uv.x - 0.5) * aspect, uv.y - 0.52), float2((uv.x - 0.5) * aspect, uv.y - 0.52)) * 7.5);
        float2 maskTexel = 1.0 / float2(subjectMaskTexture.get_width(), subjectMaskTexture.get_height());
        float visionCenter = subjectMaskTexture.sample(samp, clamp(uv, float2(0.002), float2(0.998))).r;
        float visionSoft = visionCenter * 0.36;
        visionSoft += subjectMaskTexture.sample(samp, clamp(uv + float2(maskTexel.x * 4.0, 0.0), float2(0.002), float2(0.998))).r * 0.16;
        visionSoft += subjectMaskTexture.sample(samp, clamp(uv - float2(maskTexel.x * 4.0, 0.0), float2(0.002), float2(0.998))).r * 0.16;
        visionSoft += subjectMaskTexture.sample(samp, clamp(uv + float2(0.0, maskTexel.y * 4.0), float2(0.002), float2(0.998))).r * 0.16;
        visionSoft += subjectMaskTexture.sample(samp, clamp(uv - float2(0.0, maskTexel.y * 4.0), float2(0.002), float2(0.998))).r * 0.16;
        float visionProtection = max(visionCenter * 0.72, visionSoft);
        float protectedArea = mix(centralProtection, max(visionProtection, centralProtection * 0.14), hasVisionMask);
        float motionMask = 1.0 - protection * smoothstep(0.02, 0.94, protectedArea) * 0.86;

        // A luminance-derived pseudo-depth layer creates restrained 2.5D
        // parallax from a single image without requiring an ML model.
        float3 pilot = tex.sample(samp, clamp(uv, float2(0.002), float2(0.998))).rgb;
        float pseudoDepth = (luminance(pilot) - 0.48) * 2.0;
        float2 parallaxFlow = float2(sin(time * 0.063), cos(time * 0.051));
        uv += parallaxFlow * pseudoDepth * life * parallax * motionMask * 0.0028;

        float liquidBoost = style > 1.5 ? 1.65 : (style > 0.5 ? 1.0 : 0.52);
        float wave = sin(radius * (18.0 + mid * 9.0) - time * (0.72 + energy * 0.58) + section * 2.0);
        float2 direction = radius > 0.0001 ? metric / radius : float2(0.0);
        direction.x /= max(aspect, 0.0001);
        float impulse = bass * 0.48 + transient * 0.74 + climax * 0.25;
        uv += direction * wave * exp(-radius * 2.8) * life * warp * liquidBoost * motionMask
            * (0.0011 + impulse * 0.0022) * (1.0 - quietness * 0.48);
        uv += float2(
            sin((uv.y + time * 0.018) * 15.0 + mid * 2.5),
            cos((uv.x - time * 0.014) * 13.0 + high * 3.0)
        ) * life * warp * liquidBoost * motionMask * (0.00035 + buildup * 0.00045);
        uv = clamp(uv, float2(0.002), float2(0.998));

        float3 color = tex.sample(samp, uv).rgb;
        float caustic = sin(uv.x * 18.0 + uv.y * 13.0 - time * (0.24 + mid * 0.20) + section * 2.4)
            * sin(uv.y * 21.0 - uv.x * 7.0 + time * 0.17);
        float light = caustic * life * lightFlow * motionMask * (0.012 + energy * 0.018 + climax * 0.015);
        float3 lightTint = mix(float3(0.88, 0.96, 1.08), float3(1.08, 1.00, 0.86), warmth);
        color += (1.0 - color) * lightTint * max(0.0, light);
        color *= 1.0 - max(0.0, -light) * 0.42;
        color += (1.0 - color) * transient * life * awareness * 0.010 * motionMask;
        if (subjectMode > 0.5) {
            float subject = subjectMaskTexture.sample(samp, uv).r;
            float softSubject = subject * 0.44;
            softSubject += subjectMaskTexture.sample(samp, clamp(uv + float2(maskTexel.x * 3.0, 0.0), float2(0.002), float2(0.998))).r * 0.14;
            softSubject += subjectMaskTexture.sample(samp, clamp(uv - float2(maskTexel.x * 3.0, 0.0), float2(0.002), float2(0.998))).r * 0.14;
            softSubject += subjectMaskTexture.sample(samp, clamp(uv + float2(0.0, maskTexel.y * 3.0), float2(0.002), float2(0.998))).r * 0.14;
            softSubject += subjectMaskTexture.sample(samp, clamp(uv - float2(0.0, maskTexel.y * 3.0), float2(0.002), float2(0.998))).r * 0.14;
            if (subjectMode < 1.5) {
                float alpha = smoothstep(0.025, 0.94, softSubject) * in.color.a;
                return float4(clamp(color, 0.0, 1.0) * alpha, alpha);
            }
            float wideSubject = softSubject * 0.28;
            wideSubject += subjectMaskTexture.sample(samp, clamp(uv + float2(maskTexel.x * 9.0, 0.0), float2(0.002), float2(0.998))).r * 0.18;
            wideSubject += subjectMaskTexture.sample(samp, clamp(uv - float2(maskTexel.x * 9.0, 0.0), float2(0.002), float2(0.998))).r * 0.18;
            wideSubject += subjectMaskTexture.sample(samp, clamp(uv + float2(0.0, maskTexel.y * 9.0), float2(0.002), float2(0.998))).r * 0.18;
            wideSubject += subjectMaskTexture.sample(samp, clamp(uv - float2(0.0, maskTexel.y * 9.0), float2(0.002), float2(0.998))).r * 0.18;
            float atmosphere = smoothstep(0.015, 0.46, wideSubject)
                * (1.0 - smoothstep(0.50, 0.96, softSubject));
            float pulse = 0.026 + energy * 0.018 + buildup * 0.012 + climax * 0.022;
            float alpha = pow(atmosphere, 0.82) * edgeLightStrength * pulse * in.color.a;
            float3 nearby = tex.sample(samp, clamp(uv + float2(maskTexel.x * 5.0, -maskTexel.y * 3.0), float2(0.002), float2(0.998))).rgb;
            float3 atmosphereTint = mix(color, nearby, 0.42);
            atmosphereTint = mix(atmosphereTint, float3(1.0), 0.10 + high * 0.05);
            return float4(atmosphereTint * alpha, alpha);
        }
        return float4(clamp(color, 0.0, 1.0) * in.color.a, in.color.a);
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
        float refraction = integration * depth * (0.00055 + energy * 0.00055 + bass * 0.0012 + transient * beatImpact * 0.00055) * (1.0 - quietness * 0.42);
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
        float highlightProtection = 1.0 - smoothstep(0.70, 0.98, luminance(color)) * 0.68;
        color += bloom * bloomGain * highlightProtection;

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
        float impactLight = (transient * 0.030 + climax * 0.024) * beatImpact * brilliance;
        color += (1.0 - saturate(color)) * impactLight;
        color = color / (1.0 + max(color - 0.82, float3(0.0)) * 0.38);

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

struct GPUBackgroundUniforms {
    var viewport: SIMD4<Float>
    var audio: SIMD4<Float>
    var structure: SIMD4<Float>
    var controls: SIMD4<Float>
    var mode: SIMD4<Float>
    var clock: SIMD4<Float>
    var mask: SIMD4<Float>
}

struct BackgroundMotionSettings {
    let time: Double
    let center: SIMD2<Float>
    let features: AudioFrameFeatures
    let style: BackgroundMotionStyle
    let life: Float
    let camera: Float
    let warp: Float
    let parallax: Float
    let lightFlow: Float
    let subjectProtection: Float
    let awareness: Float
    let smartCompositionEnabled: Bool
    let edgeLight: Float

    func uniforms(size: CGSize, reactivity: Float, hasVisionMask: Bool, subjectMode: Float = 0) -> GPUBackgroundUniforms {
        let styleValue: Float
        switch style {
        case .natural: styleValue = 0
        case .immersive: styleValue = 1
        case .liquid: styleValue = 2
        case .off: styleValue = 0
        }
        let enabledLife = style == .off ? 0 : life
        return GPUBackgroundUniforms(
            viewport: SIMD4(Float(size.width), Float(size.height), center.x, center.y),
            audio: SIMD4(features.bass, features.mid, features.high, features.transient),
            structure: SIMD4(features.energy, features.buildup, features.climax, features.quiet),
            controls: SIMD4(enabledLife, camera, warp, parallax),
            mode: SIMD4(lightFlow, subjectProtection, styleValue, reactivity),
            clock: SIMD4(Float(time), features.sectionProgress, features.warmth, awareness),
            mask: SIMD4(hasVisionMask ? 1 : 0, subjectMode, edgeLight, 0)
        )
    }
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
