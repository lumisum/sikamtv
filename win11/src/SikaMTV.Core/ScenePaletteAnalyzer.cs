using System.Numerics;

namespace SikaMTV.Core;

/// <summary>Finds two saturated, separated hues that remain legible over a background image.</summary>
public static class ScenePaletteAnalyzer
{
    public static (Vector3 Primary, Vector3 Secondary) AnalyzeBgra(byte[]? pixels, int width, int height)
    {
        if (pixels is null || width <= 0 || height <= 0 || pixels.Length < width * height * 4)
            return (new Vector3(0.48f, 0.72f, 1.0f), new Vector3(0.82f, 0.52f, 0.94f));

        const int bucketCount = 12;
        var weights = new float[bucketCount];
        var red = new float[bucketCount];
        var green = new float[bucketCount];
        var blue = new float[bucketCount];
        var stepX = Math.Max(1, width / 48);
        var stepY = Math.Max(1, height / 48);

        for (var y = stepY / 2; y < height; y += stepY)
        for (var x = stepX / 2; x < width; x += stepX)
        {
            var offset = (y * width + x) * 4;
            var b = pixels[offset] / 255f;
            var g = pixels[offset + 1] / 255f;
            var r = pixels[offset + 2] / 255f;
            var max = Math.Max(r, Math.Max(g, b));
            var min = Math.Min(r, Math.Min(g, b));
            var chroma = max - min;
            if (chroma < 0.045f || max < 0.08f) continue;

            var hue = Hue(r, g, b, max, chroma);
            var bucket = Math.Min(bucketCount - 1, (int)(hue * bucketCount));
            var weight = (0.2f + chroma * 1.4f) * (0.45f + Math.Min(0.8f, max));
            weights[bucket] += weight;
            red[bucket] += r * weight;
            green[bucket] += g * weight;
            blue[bucket] += b * weight;
        }

        var ranked = Enumerable.Range(0, bucketCount).OrderByDescending(index => weights[index]).ToArray();
        if (weights[ranked[0]] <= 0) return (new Vector3(0.48f, 0.72f, 1.0f), new Vector3(0.82f, 0.52f, 0.94f));
        var first = ranked[0];
        var second = ranked.Skip(1).Where(index =>
        {
            var distance = Math.Abs(index - first);
            return Math.Min(distance, bucketCount - distance) >= 2 && weights[index] > weights[first] * 0.08f;
        }).Select(index => (int?)index).FirstOrDefault();
        return (Average(first), second.HasValue
            ? Average(second.Value)
            : FromHue((((first + 0.5f) / bucketCount) + 0.5f) % 1));

        Vector3 Average(int index)
        {
            var divisor = Math.Max(weights[index], 0.0001f);
            var color = new Vector3(red[index] / divisor, green[index] / divisor, blue[index] / divisor);
            return Enrich(color, 0.68f);
        }
    }

    private static float Hue(float r, float g, float b, float max, float chroma)
    {
        var hue = max == r ? (g - b) / chroma : max == g ? 2 + (b - r) / chroma : 4 + (r - g) / chroma;
        hue /= 6;
        return hue < 0 ? hue + 1 : hue;
    }

    private static Vector3 FromHue(float hue)
    {
        const float chroma = 0.72f;
        var section = hue * 6;
        var x = chroma * (1 - Math.Abs(section % 2 - 1));
        var rgb = section switch
        {
            < 1 => new Vector3(chroma, x, 0), < 2 => new Vector3(x, chroma, 0),
            < 3 => new Vector3(0, chroma, x), < 4 => new Vector3(0, x, chroma),
            < 5 => new Vector3(x, 0, chroma), _ => new Vector3(chroma, 0, x)
        };
        return rgb + new Vector3(0.18f);
    }

    private static Vector3 Enrich(Vector3 color, float minimumSaturation)
    {
        var max = Math.Max(color.X, Math.Max(color.Y, color.Z));
        var min = Math.Min(color.X, Math.Min(color.Y, color.Z));
        var lightness = (max + min) * 0.5f;
        var saturation = max - min;
        if (saturation < minimumSaturation)
        {
            var hue = Hue(color.X, color.Y, color.Z, max, Math.Max(0.0001f, saturation));
            saturation = minimumSaturation;
            var chroma = (1 - Math.Abs(2 * lightness - 1)) * saturation;
            var section = hue * 6;
            var x = chroma * (1 - Math.Abs(section % 2 - 1));
            var rgb = section switch
            {
                < 1 => new Vector3(chroma, x, 0),
                < 2 => new Vector3(x, chroma, 0),
                < 3 => new Vector3(0, chroma, x),
                < 4 => new Vector3(0, x, chroma),
                < 5 => new Vector3(x, 0, chroma),
                _ => new Vector3(chroma, 0, x)
            };
            var m = lightness - chroma * 0.5f;
            color = rgb + new Vector3(m);
        }
        return Vector3.Clamp(color, Vector3.Zero, Vector3.One);
    }
}
