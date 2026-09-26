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
    float4 BackgroundEffects;
    float4 VisualizerEffects;
};

Texture2D BackgroundImage : register(t0);
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

float4 PSMain(VertexOutput input) : SV_TARGET
{
    float2 uv = input.UV;
    float2 p = (uv - 0.5) * float2(ViewWidth / max(ViewHeight, 1.0), 1.0);
    float x = saturate(uv.x);
    float energy = ReadBand(x);
    float bass = ReadBand(0.025);
    float treble = ReadBand(0.76);
    float pulse = 0.72 + 0.28 * sin(TimeSeconds * 1.8 + bass * 5.0);
    float glow = 0.0;
    float alpha = 0.0;
    float colorPosition = x;
    float lineDistance = 1.0;
    float radius = length(p);
    float angle = atan2(p.y, p.x) / 6.2831853 + 0.5;

    if (VisualizerKind == 0) // silk wave
    {
        float wave = 0.66 + sin(x * 25.0 + TimeSeconds * 1.3) * (0.035 + energy * 0.23 * Intensity);
        lineDistance = abs(uv.y - wave);
        glow = exp(-lineDistance * 85.0) + exp(-lineDistance * 22.0) * 0.42;
    }
    else if (VisualizerKind == 1 || VisualizerKind == 2) // spectrum / mirrored
    {
        float bars = max(0.012, energy * (0.12 + 0.48 * Intensity));
        float localX = frac(x * 72.0);
        float barMask = 1.0 - smoothstep(0.35, 0.48, abs(localX - 0.5));
        float center = VisualizerKind == 1 ? 0.78 : 0.5;
        float verticalDistance = abs(uv.y - center);
        glow = (1.0 - smoothstep(bars - 0.016, bars + 0.008, verticalDistance)) * barMask;
        glow += exp(-abs(verticalDistance - bars) * 40.0) * barMask * 0.55;
        colorPosition = x + verticalDistance * 0.7;
    }
    else if (VisualizerKind == 3) // breathing spectrum ring
    {
        float ring = 0.25 + ReadBand(angle) * 0.30 * Intensity;
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

    float3 color = VisualizerEffects.y > 0.5 ? FlowColor(colorPosition) : float3(0.74, 0.67, 1.0);
    alpha = saturate(glow * pulse * (0.40 + 0.34 * Intensity));
    float zoom = 1.0 + BackgroundEffects.w * 0.06 * saturate(TimeSeconds / 180.0);
    float2 zoomUV = (uv - 0.5) / zoom + 0.5;
    float imageAspect = BackgroundInfo.y / max(BackgroundInfo.z, 1.0);
    float frameAspect = ViewWidth / max(ViewHeight, 1.0);
    float2 imageUV = zoomUV;
    if (imageAspect > frameAspect)
        imageUV.x = (zoomUV.x - 0.5) * (frameAspect / imageAspect) + 0.5;
    else
        imageUV.y = (zoomUV.y - 0.5) * (imageAspect / frameAspect) + 0.5;
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
    float luminance = dot(background, float3(0.2126, 0.7152, 0.0722));
    background = lerp(luminance.xxx, background, BackgroundEffects.z);
    float vignette = smoothstep(0.24, 0.82, length((uv - 0.5) * float2(frameAspect, 1.0)));
    background *= 1.0 - vignette * BackgroundEffects.y * 0.46;
    float3 rgb = lerp(background, color * (0.84 + 0.20 * pulse), alpha);
    rgb = saturate(rgb + color * glow * 0.10);
    return float4(rgb, 1.0);
}
