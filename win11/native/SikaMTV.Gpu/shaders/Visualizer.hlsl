cbuffer VisualState : register(b0)
{
    float TimeSeconds;
    float Intensity;
    float ViewWidth;
    float ViewHeight;
    uint VisualizerKind;
    uint BandCount;
    float2 Padding;
    float4 Bands[16];
    float4 BackgroundInfo;
    float4 BackgroundTransition;
    float4 BackgroundEffects;
    float4 VisualizerEffects;
    float4 ScenePalettePrimary;
    float4 ScenePaletteSecondary;
    float4 VisualizerAdvanced1;
    float4 VisualizerAdvanced2;
    float4 VisualizerAdvanced3;
    float4 AtmosphereSettings;
    float4 AtmosphereGeometry;
    float4 BackgroundColorSettings;
    float4 BackgroundMotion;
    float4 BackgroundMotion2;
    float4 BackgroundMotion3;
    float4 BackgroundTimeline;
};

Texture2D BackgroundImage : register(t0);
Texture2D SecondaryBackgroundImage : register(t1);
Texture2D SubjectMaskImage : register(t2);
Texture2D SecondarySubjectMaskImage : register(t3);
SamplerState BackgroundSampler : register(s0);

struct VertexOutput
{
    float4 Position : SV_POSITION;
    float2 UV : TEXCOORD0;
};

VertexOutput VSMain(uint vertexId : SV_VertexID)
{
    VertexOutput output;
    float2 position = vertexId == 0 ? float2(-1.0, -1.0) :
                      vertexId == 1 ? float2(-1.0,  3.0) : float2(3.0, -1.0);
    output.Position = float4(position, 0.0, 1.0);
    output.UV = float2((position.x + 1.0) * 0.5, (1.0 - position.y) * 0.5);
    return output;
}

float ReadBand(float normalizedFrequency)
{
    float bin = saturate(normalizedFrequency) * max(1.0, (float)BandCount - 1.0);
    uint lower = (uint)floor(bin);
    uint upper = min(lower + 1, BandCount - 1);
    float a = Bands[lower / 4][lower % 4];
    float b = Bands[upper / 4][upper % 4];
    return lerp(a, b, frac(bin));
}

float3 FlowColor(float position)
{
    float phase = frac(position + TimeSeconds * 0.055) * 7.0;
    float section = floor(phase);
    float blend = smoothstep(0.05, 0.95, frac(phase));
    float3 palette[7] = {
        float3(1.00, 0.25, 0.34), float3(1.00, 0.62, 0.20),
        float3(0.96, 0.88, 0.28), float3(0.20, 0.82, 0.48),
        float3(0.20, 0.72, 1.00), float3(0.40, 0.42, 1.00),
        float3(0.83, 0.34, 1.00)
    };
    uint first = (uint)section % 7;
    uint second = (first + 1) % 7;
    return lerp(palette[first], palette[second], blend);
}

float Hash21(float2 p)
{
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float3 AtmosphereColor(uint preset, float seed, float3 primary, float3 secondary)
{
    if (preset == 4 || preset == 15 || preset == 16) return lerp(float3(1.0, 0.48, 0.15), float3(1.0, 0.86, 0.50), seed);
    if (preset == 5 || preset == 7) return lerp(float3(0.28, 0.58, 0.23), float3(0.92, 0.46, 0.16), seed);
    if (preset == 6 || preset == 11) return lerp(float3(1.0, 0.50, 0.70), float3(1.0, 0.87, 0.58), seed);
    if (preset == 8) return lerp(float3(0.62, 1.0, 0.48), float3(1.0, 0.90, 0.36), seed);
    if (preset == 14) return lerp(float3(0.84, 0.53, 0.28), float3(1.0, 0.78, 0.42), seed);
    return lerp(secondary, primary, seed * 0.68 + 0.16);
}

float3 AtmosphereOverlay(float2 uv, float bass, float mid, float treble)
{
    uint preset = (uint)round(AtmosphereSettings.x);
    float strength = saturate(AtmosphereSettings.y);
    float response = saturate(AtmosphereSettings.z);
    float density = saturate(AtmosphereSettings.w);
    if (preset == 0 || strength <= 0.001) return 0;

    float3 primary = ScenePalettePrimary.rgb;
    float3 secondary = ScenePaletteSecondary.rgb;
    float3 tint = AtmosphereColor(preset, Hash21(floor(uv * 19.0)), primary, secondary);
    float time = TimeSeconds * (0.08 + response * (0.12 + bass * 0.30));
    float2 grid = uv * float2(23.0, 15.0);
    float2 cell = floor(grid);
    float2 local = frac(grid);
    float seed = Hash21(cell);
    float visibility = lerp(0.34, 1.0, density);
    float particles = 0.0;

    // Every screen-space cell owns one deterministic particle, avoiding per-pixel particle loops.
    float fall = frac(seed * 1.73 + TimeSeconds * (0.020 + seed * 0.025) * (0.55 + bass * response));
    float2 center = float2(frac(seed * 7.13 + 0.31), fall);
    float2 delta = local - center;
    float rainPreset = (preset == 3 || preset == 13) ? 1.0 : 0.0;
    float snowPreset = preset == 4 ? 1.0 : 0.0;
    float leafPreset = (preset == 5 || preset == 7) ? 1.0 : 0.0;
    float petalPreset = (preset == 6 || preset == 11) ? 1.0 : 0.0;
    float fireflyPreset = preset == 8 ? 1.0 : 0.0;
    float emberPreset = (preset == 15 || preset == 16) ? 1.0 : 0.0;
    float sandPreset = preset == 14 ? 1.0 : 0.0;

    float slantedRain = abs(delta.x + delta.y * 0.28);
    float rain = (1.0 - smoothstep(0.018, 0.050, slantedRain)) * (1.0 - smoothstep(0.05, 0.30, abs(delta.y))) * rainPreset;
    float snow = (1.0 - smoothstep(0.045, 0.13, length(delta))) * snowPreset;
    float angle = seed * 6.2831853 + TimeSeconds * (0.08 + bass * response * 0.14);
    float2 rotated = float2(delta.x * cos(angle) - delta.y * sin(angle), delta.x * sin(angle) + delta.y * cos(angle));
    float leaf = (1.0 - smoothstep(0.48, 0.78, length(float2(rotated.x * 1.65, rotated.y * 0.72)))) * leafPreset;
    float petal = (1.0 - smoothstep(0.30, 0.58, length(float2(rotated.x * 0.9, rotated.y * 1.85)))) * petalPreset;
    float twinkle = 0.45 + 0.55 * sin(TimeSeconds * (0.55 + seed * 1.4) + seed * 25.0);
    float firefly = (1.0 - smoothstep(0.018, 0.10, length(delta))) * fireflyPreset * max(0.12, twinkle);
    float ember = (1.0 - smoothstep(0.020, 0.09, length(delta))) * emberPreset * (0.40 + bass * response * 0.60);
    float sand = (1.0 - smoothstep(0.025, 0.08, abs(delta.y + delta.x * 0.16))) * (1.0 - smoothstep(0.08, 0.28, abs(delta.x))) * sandPreset;
    particles = rain * 0.68 + snow * 0.54 + leaf * 0.32 + petal * 0.34 + firefly * 0.82 + ember * 0.56 + sand * 0.22;

    float waterline = clamp(AtmosphereGeometry.x, 0.48, 0.88);
    float waterMask = smoothstep(waterline, waterline + 0.025, uv.y);
    float wavePhase = uv.x * 34.0 + TimeSeconds * (0.48 + bass * response * 0.72) + sin(uv.x * 9.0 + TimeSeconds * 0.18) * 1.2;
    float waveLine = exp(-abs(frac(wavePhase / 6.2831853) - 0.5) * 46.0);
    float waterPreset = (preset == 1 || preset == 2 || preset == 3 || preset == 9 || preset == 11 || preset == 12 || preset == 13) ? 1.0 : 0.0;
    float water = waveLine * waterMask * waterPreset * (0.025 + bass * response * 0.11);

    float cloud = sin(uv.x * 8.0 + TimeSeconds * 0.035) * sin(uv.y * 7.0 - TimeSeconds * 0.024 + mid);
    float cloudPreset = (preset == 1 || preset == 2 || preset == 9 || preset == 10 || preset == 12 || preset == 16) ? 1.0 : 0.0;
    float mist = smoothstep(0.30, 0.94, cloud + 0.45) * cloudPreset * (0.012 + strength * 0.045);
    float cityGlow = preset == 13 ? (1.0 - smoothstep(0.40, 0.96, uv.y)) * (0.018 + treble * response * 0.028) : 0.0;
    float alpha = saturate((particles * visibility + water + mist + cityGlow) * strength);
    return tint * alpha;
}

float4 PSMain(VertexOutput input) : SV_TARGET
{
    float2 uv = input.UV;
    float visualY = VisualizerKind == 10 ? 0.5 : clamp(VisualizerAdvanced1.x, 0.08, 0.92);
    float2 visualUV = uv;
    visualUV.y += 0.5 - visualY;
    float2 p = (visualUV - 0.5) * float2(ViewWidth / max(ViewHeight, 1.0), 1.0);
    float x = saturate(visualUV.x);
    float energy = ReadBand(x);
    float bass = ReadBand(0.025);
    float treble = ReadBand(0.76);
    float motionStyle = round(BackgroundMotion.x);
    float motionStyleGain = motionStyle == 1.0 ? 1.18 : (motionStyle == 2.0 ? 1.48 : 1.0);
    float motionEnabled = motionStyle < 2.5 ? 1.0 : 0.0;
    float motionLife = saturate(BackgroundMotion.y) * motionEnabled * motionStyleGain * saturate(BackgroundTimeline.y);
    float cameraMotion = saturate(BackgroundMotion.z) * motionEnabled;
    float audioWarp = saturate(BackgroundMotion.w) * motionEnabled;
    float parallax = saturate(BackgroundMotion2.x) * motionEnabled;
    float lightFlow = saturate(BackgroundMotion2.y) * motionEnabled * saturate(BackgroundTimeline.y);
    float subjectProtection = saturate(BackgroundMotion2.z);
    float smartComposition = saturate(BackgroundMotion2.w);
    float edgeLight = saturate(BackgroundMotion3.x);
    float smartBlur = saturate(BackgroundMotion3.y);
    float audioMotion = saturate(bass * 0.56 + energy * 0.31 + treble * 0.13);
    float2 motionCenter = uv - float2(0.5, 0.5);
    float motionPhase = TimeSeconds * (0.075 + audioMotion * audioWarp * 0.14);
    float cameraBreath = sin(TimeSeconds * 0.11 + bass * 0.5) * cameraMotion * motionLife * 0.008;
    float2 cameraDrift = float2(sin(TimeSeconds * 0.043), cos(TimeSeconds * 0.037)) * cameraMotion * motionLife * 0.003;
    float2 backgroundMotionUV = motionCenter / (1.0 + cameraBreath) + 0.5 + cameraDrift;
    backgroundMotionUV += float2(sin(motionPhase), cos(motionPhase * 0.81)) * audioMotion * parallax * motionLife * 0.002;
    float liquidMotion = motionStyle == 2.0 ? 1.45 : 1.0;
    backgroundMotionUV.x += sin(uv.y * 8.0 + motionPhase) * motionLife * (0.002 + audioMotion * audioWarp * 0.003) * liquidMotion;
    backgroundMotionUV.y += sin(uv.x * 6.0 - motionPhase * 0.73) * motionLife * (0.0015 + audioMotion * audioWarp * 0.002) * liquidMotion;
    float awareness = saturate(VisualizerAdvanced3.y);
    float beatImpact = saturate(VisualizerAdvanced3.x);
    float pulse = 0.74 + (0.08 + 0.20 * beatImpact) * sin(TimeSeconds * 1.8 + bass * (2.0 + awareness * 3.0));
    energy = lerp(0.16 + energy * 0.22, energy, awareness);
    float glow = 0.0;
    float alpha = 0.0;
    float colorPosition = x;
    float lineDistance = 1.0;
    float radius = length(p);
    float angle = atan2(p.y, p.x) / 6.2831853 + 0.5;

    if (VisualizerKind == 0) // silk wave
    {
        float wave = 0.66 + sin(x * 25.0 + TimeSeconds * 1.3) * (0.035 + energy * 0.23 * Intensity);
        lineDistance = abs(visualUV.y - wave);
        glow = exp(-lineDistance * 85.0) + exp(-lineDistance * 22.0) * 0.42;
    }
    else if (VisualizerKind == 1 || VisualizerKind == 2) // spectrum / mirrored
    {
        float bars = max(0.012, energy * (0.12 + 0.48 * Intensity));
        float localX = frac(x * (54.0 + VisualizerAdvanced1.z * 30.0));
        float barMask = 1.0 - smoothstep(0.35, 0.48, abs(localX - 0.5));
        float center = VisualizerKind == 1 ? 0.78 + (visualY - 0.5) : visualY;
        float verticalDistance = abs(uv.y - center);
        glow = (1.0 - smoothstep(bars - 0.016, bars + 0.008, verticalDistance)) * barMask;
        glow += exp(-abs(verticalDistance - bars) * 40.0) * barMask * 0.55;
        colorPosition = x + verticalDistance * 0.7;
    }
    else if (VisualizerKind == 3) // breathing spectrum ring
    {
        float ring = 0.25 + ReadBand(angle) * 0.30 * Intensity * (0.8 + VisualizerAdvanced1.z * 0.3);
        lineDistance = abs(radius - ring);
        glow = exp(-lineDistance * 75.0) + exp(-lineDistance * 17.0) * 0.48;
        colorPosition = angle;
    }
    else if (VisualizerKind == 4) // audio ripples
    {
        float ripple = frac(radius * 5.0 - TimeSeconds * 0.42 - bass * 0.5);
        lineDistance = min(ripple, 1.0 - ripple);
        float envelope = exp(-radius * 2.1) * (0.12 + energy * 0.6 * Intensity);
        glow = exp(-lineDistance * 45.0) * envelope;
        colorPosition = angle + radius * 0.5;
    }
    else if (VisualizerKind == 5) // aurora curtain
    {
        float curtain = 0.36 + sin(x * 8.0 + TimeSeconds * 0.22) * 0.12 +
                        sin(x * 19.0 - TimeSeconds * 0.17) * 0.055 + energy * 0.19 * Intensity;
        lineDistance = abs(uv.y - curtain);
        glow = exp(-lineDistance * 12.0) * (0.22 + treble * 0.8);
        colorPosition = x * 0.65 + uv.y * 0.35;
    }
    else if (VisualizerKind == 6) // prism tunnel
    {
        float spokes = abs(sin(angle * 38.0 + TimeSeconds * 0.15 + energy * 2.0));
        float ring = abs(frac(radius * 7.0 - TimeSeconds * 0.18) - 0.5);
        glow = exp(-spokes * 35.0) * exp(-ring * 20.0) * energy * Intensity;
        colorPosition = angle + radius;
    }
    else if (VisualizerKind == 7) // nebula
    {
        float cloud = sin(p.x * 7.0 + TimeSeconds * 0.12) * sin(p.y * 8.0 - TimeSeconds * 0.1);
        glow = smoothstep(0.2, 0.95, cloud + energy * Intensity * 0.8) * exp(-radius * 1.3);
        colorPosition = cloud * 0.35 + angle;
    }
    else if (VisualizerKind == 8) // flower mirror
    {
        float petals = abs(radius - (0.17 + 0.07 * sin(angle * 14.0 + TimeSeconds * 0.14) + energy * 0.24 * Intensity));
        glow = exp(-petals * 48.0) + exp(-petals * 15.0) * 0.35;
        colorPosition = angle;
    }
    else if (VisualizerKind == 9) // starfield
    {
        float2 cell = floor((uv + float2(TimeSeconds * 0.012, TimeSeconds * 0.025)) * float2(36.0, 24.0));
        float star = step(0.94, Hash21(cell));
        float twinkle = 0.35 + 0.65 * sin(TimeSeconds * (1.0 + Hash21(cell) * 4.0) + Hash21(cell + 3.2) * 6.28);
        glow = star * twinkle * (0.15 + treble * 1.2 * Intensity);
        colorPosition = Hash21(cell);
    }
    else // soft audio-reactive luminous border
    {
        float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
        float perimeter = uv.y < 0.035 || uv.y > 0.965 ? uv.x : uv.y;
        float breathe = ReadBand(perimeter) * 0.045 * Intensity;
        lineDistance = abs(edge - (0.012 + breathe));
        float cornerDistance = min(min(length(uv), length(uv - float2(1.0, 0.0))),
                                   min(length(uv - float2(0.0, 1.0)), length(uv - 1.0)));
        float cornerSoft = smoothstep(0.0, 0.035, cornerDistance);
        glow = (exp(-lineDistance * 36.0) + exp(-lineDistance * 9.0) * 0.65) * cornerSoft;
        colorPosition = perimeter + edge * 2.0;
    }

    float richness = saturate(VisualizerAdvanced2.z);
    float3 sceneColor = lerp(ScenePalettePrimary.rgb, ScenePaletteSecondary.rgb, saturate(colorPosition + 0.16 * sin(TimeSeconds * lerp(0.08, 0.20, VisualizerAdvanced2.x))));
    float3 color = VisualizerAdvanced3.z > 0.5
        ? lerp(sceneColor, FlowColor(colorPosition), saturate(VisualizerAdvanced3.w * (0.40 + richness * 0.60)))
        : sceneColor;
    color = lerp(dot(color, float3(0.2126, 0.7152, 0.0722)).xxx, color, 0.72 + richness * 0.45);
    color = saturate(color * (0.86 + VisualizerAdvanced1.w * 0.24));
    glow = lerp(glow, sqrt(saturate(glow)), saturate(VisualizerAdvanced2.y) * 0.24);
    alpha = saturate(glow * pulse * (0.34 + 0.36 * Intensity) * (0.35 + VisualizerAdvanced1.y * 0.85) * (0.78 + VisualizerAdvanced2.w * 0.28));
    float staticZoom = step(0.5, BackgroundTimeline.y);
    float zoom = 1.0 + staticZoom * BackgroundEffects.w * (0.014 + 0.026 * saturate(BackgroundTimeline.x)
        + 0.004 * (0.5 + 0.5 * sin(TimeSeconds * 0.16))) + cameraBreath * 0.5 + audioMotion * audioWarp * motionLife * 0.003;
    float2 zoomUV = (backgroundMotionUV - 0.5) / zoom + 0.5;
    float imageAspect = BackgroundInfo.y / max(BackgroundInfo.z, 1.0);
    float frameAspect = ViewWidth / max(ViewHeight, 1.0);
    float2 imageUV = zoomUV;
    if (imageAspect > frameAspect)
        imageUV.x = (zoomUV.x - 0.5) * (frameAspect / imageAspect) + 0.5;
    else
        imageUV.y = (zoomUV.y - 0.5) * (imageAspect / frameAspect) + 0.5;
    float2 maskUVCurrent = imageUV;
    float2 maskUVNext = imageUV;
    float transitionMix = 0.0;
    float3 crispBackground = BackgroundInfo.x > 0.5 ? BackgroundImage.Sample(BackgroundSampler, imageUV).rgb : float3(0.035, 0.040, 0.075);
    float blurRadius = BackgroundEffects.x * 0.008;
    float3 background = BackgroundInfo.x > 0.5
        ? BackgroundImage.Sample(BackgroundSampler, imageUV).rgb * 0.36
        + BackgroundImage.Sample(BackgroundSampler, imageUV + float2(blurRadius, 0)).rgb * 0.12
        + BackgroundImage.Sample(BackgroundSampler, imageUV - float2(blurRadius, 0)).rgb * 0.12
        + BackgroundImage.Sample(BackgroundSampler, imageUV + float2(0, blurRadius)).rgb * 0.12
        + BackgroundImage.Sample(BackgroundSampler, imageUV - float2(0, blurRadius)).rgb * 0.12
        + BackgroundImage.Sample(BackgroundSampler, imageUV + float2(blurRadius * 0.65, blurRadius * 0.65)).rgb * 0.04
        + BackgroundImage.Sample(BackgroundSampler, imageUV - float2(blurRadius * 0.65, blurRadius * 0.65)).rgb * 0.04
        + BackgroundImage.Sample(BackgroundSampler, imageUV + float2(blurRadius * 0.65, -blurRadius * 0.65)).rgb * 0.04
        + BackgroundImage.Sample(BackgroundSampler, imageUV - float2(blurRadius * 0.65, -blurRadius * 0.65)).rgb * 0.04
        : lerp(float3(0.035, 0.040, 0.075), float3(0.11, 0.075, 0.16), saturate(1.0 - uv.y));
    if (BackgroundTransition.z > 0.0 && BackgroundTransition.y > 0.5)
    {
        float transition = saturate(BackgroundTransition.x);
        float kind = round(BackgroundTransition.y);
        float2 currentUV = imageUV;
        float nextStaticZoom = step(0.5, BackgroundTimeline.w);
        float nextZoom = 1.0 + nextStaticZoom * BackgroundEffects.w * (0.014 + 0.026 * saturate(BackgroundTimeline.z)
            + 0.004 * (0.5 + 0.5 * sin(TimeSeconds * 0.16)));
        float2 nextZoomUV = (backgroundMotionUV - 0.5) / (nextZoom * (1.08 - 0.08 * transition)) + 0.5;
        float secondaryAspect = BackgroundTransition.z / max(BackgroundTransition.w, 1.0);
        if (secondaryAspect > frameAspect)
            nextZoomUV.x = (nextZoomUV.x - 0.5) * (frameAspect / secondaryAspect) + 0.5;
        else
            nextZoomUV.y = (nextZoomUV.y - 0.5) * (secondaryAspect / frameAspect) + 0.5;
        if (kind > 1.5 && kind < 2.5)
        {
            currentUV += float2(transition, 0.0);
            nextZoomUV -= float2(1.0 - transition, 0.0);
        }
        if (kind > 2.5 && kind < 3.5)
        {
            currentUV = (backgroundMotionUV - 0.5) / (zoom * (1.0 + 0.08 * transition)) + 0.5;
            if (imageAspect > frameAspect)
                currentUV.x = (currentUV.x - 0.5) * (frameAspect / imageAspect) + 0.5;
            else
                currentUV.y = (currentUV.y - 0.5) * (imageAspect / frameAspect) + 0.5;
        }
        float3 nextBackground = SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV).rgb * 0.36
            + SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV + float2(blurRadius, 0)).rgb * 0.12
            + SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV - float2(blurRadius, 0)).rgb * 0.12
            + SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV + float2(0, blurRadius)).rgb * 0.12
            + SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV - float2(0, blurRadius)).rgb * 0.12
            + SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV + float2(blurRadius * 0.65, blurRadius * 0.65)).rgb * 0.04
            + SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV - float2(blurRadius * 0.65, blurRadius * 0.65)).rgb * 0.04
            + SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV + float2(blurRadius * 0.65, -blurRadius * 0.65)).rgb * 0.04
            + SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV - float2(blurRadius * 0.65, -blurRadius * 0.65)).rgb * 0.04;
        if (kind > 3.5)
        {
            background = transition >= 0.5 ? nextBackground : background;
            crispBackground = transition >= 0.5 ? SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV).rgb : crispBackground;
            maskUVCurrent = currentUV;
            maskUVNext = nextZoomUV;
            transitionMix = transition;
        }
        else
        {
            float3 currentBackground = BackgroundImage.Sample(BackgroundSampler, currentUV).rgb * 0.36
                + BackgroundImage.Sample(BackgroundSampler, currentUV + float2(blurRadius, 0)).rgb * 0.12
                + BackgroundImage.Sample(BackgroundSampler, currentUV - float2(blurRadius, 0)).rgb * 0.12
                + BackgroundImage.Sample(BackgroundSampler, currentUV + float2(0, blurRadius)).rgb * 0.12
                + BackgroundImage.Sample(BackgroundSampler, currentUV - float2(0, blurRadius)).rgb * 0.12
                + BackgroundImage.Sample(BackgroundSampler, currentUV + float2(blurRadius * 0.65, blurRadius * 0.65)).rgb * 0.04
                + BackgroundImage.Sample(BackgroundSampler, currentUV - float2(blurRadius * 0.65, blurRadius * 0.65)).rgb * 0.04
                + BackgroundImage.Sample(BackgroundSampler, currentUV + float2(blurRadius * 0.65, -blurRadius * 0.65)).rgb * 0.04
                + BackgroundImage.Sample(BackgroundSampler, currentUV - float2(blurRadius * 0.65, -blurRadius * 0.65)).rgb * 0.04;
            background = lerp(currentBackground, nextBackground, transition);
            crispBackground = lerp(BackgroundImage.Sample(BackgroundSampler, currentUV).rgb,
                SecondaryBackgroundImage.Sample(BackgroundSampler, nextZoomUV).rgb, transition);
            maskUVCurrent = currentUV;
            maskUVNext = nextZoomUV;
            transitionMix = transition;
        }
    }
    float2 centralPoint = float2((uv.x - 0.5) * frameAspect, uv.y - 0.49);
    float centralProtection = exp(-dot(centralPoint, centralPoint) * 7.5);
    float maskA = BackgroundMotion3.z > 0.5
        ? SubjectMaskImage.Sample(BackgroundSampler, saturate(maskUVCurrent)).r : centralProtection * 0.48;
    float maskB = BackgroundMotion3.w > 0.5
        ? SecondarySubjectMaskImage.Sample(BackgroundSampler, saturate(maskUVNext)).r : centralProtection * 0.48;
    float protectedSubject = saturate(lerp(maskA, maskB, transitionMix) * smartComposition);
    if (smartBlur > 0.5)
        background = lerp(background, crispBackground, protectedSubject * 0.94);
    float luminance = dot(background, float3(0.2126, 0.7152, 0.0722));
    background = lerp(luminance.xxx, background, BackgroundEffects.z);
    float vignette = smoothstep(0.24, 0.82, length((uv - 0.5) * float2(frameAspect, 1.0)));
    background *= 1.0 - vignette * BackgroundEffects.y * 0.46;
    float3 atmosphere = AtmosphereOverlay(uv, bass, energy, treble);
    background = lerp(background, atmosphere, saturate(length(atmosphere) * 0.55));
    float overlayOpacity = saturate(BackgroundColorSettings.w);
    float3 overlayColor = BackgroundColorSettings.rgb;
    background = lerp(background, overlayColor, overlayOpacity);
    float darkness = saturate(VisualizerEffects.z);
    float backgroundLuminance = dot(background, float3(0.2126, 0.7152, 0.0722));
    float cornerDarkness = vignette * darkness * (0.40 + 0.60 * saturate(1.0 - backgroundLuminance));
    background *= 1.0 - cornerDarkness;
    float flow = sin((uv.x * 1.7 + uv.y * 0.62) * 6.2831853 - TimeSeconds * (0.12 + audioMotion * audioWarp * 0.18));
    background += ScenePalettePrimary.rgb * (0.008 + audioMotion * 0.014) * flow * lightFlow;
    alpha *= 1.0 - protectedSubject * subjectProtection * 0.78;
    float edgeGlow = 0.0;
    if (BackgroundMotion3.z > 0.5 && edgeLight > 0.001)
    {
        float2 maskTexel = 1.0 / 256.0;
        float neighborMask = max(max(SubjectMaskImage.Sample(BackgroundSampler, saturate(maskUVCurrent + float2(maskTexel.x * 2.0, 0))).r,
            SubjectMaskImage.Sample(BackgroundSampler, saturate(maskUVCurrent - float2(maskTexel.x * 2.0, 0))).r),
            max(SubjectMaskImage.Sample(BackgroundSampler, saturate(maskUVCurrent + float2(0, maskTexel.y * 2.0))).r,
                SubjectMaskImage.Sample(BackgroundSampler, saturate(maskUVCurrent - float2(0, maskTexel.y * 2.0))).r));
        edgeGlow = saturate(neighborMask - maskA) * edgeLight * (0.08 + audioMotion * 0.12);
    }
    float3 rgb = lerp(background, color * (0.84 + 0.20 * pulse), alpha);
    rgb += ScenePaletteSecondary.rgb * edgeGlow;
    rgb = saturate(rgb + color * glow * 0.10);
    return float4(rgb, 1.0);
}
