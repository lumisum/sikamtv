using System.Numerics;

namespace SikaMTV.Core;

/// <summary>Creates a small, reusable saliency mask for protecting important image content.</summary>
public static class SceneSubjectAnalyzer
{
    public const int MaskSize = 256;

    public static byte[] AnalyzeBgra(byte[] pixels, int width, int height,
        IReadOnlyList<(float X, float Y, float Width, float Height)>? faceBounds = null)
    {
        if (width <= 0 || height <= 0 || pixels.Length < (long)width * height * 4)
            return new byte[MaskSize * MaskSize];

        var scores = new float[MaskSize * MaskSize];
        double meanR = 0, meanG = 0, meanB = 0;
        for (var y = 0; y < MaskSize; y += 4)
        for (var x = 0; x < MaskSize; x += 4)
        {
            var sample = Sample(x, y);
            meanR += sample.X; meanG += sample.Y; meanB += sample.Z;
        }
        const int sampleCount = (MaskSize / 4) * (MaskSize / 4);
        var average = new Vector3((float)(meanR / sampleCount), (float)(meanG / sampleCount), (float)(meanB / sampleCount));

        var maxScore = 0.0001f;
        for (var y = 0; y < MaskSize; y++)
        for (var x = 0; x < MaskSize; x++)
        {
            var color = Sample(x, y);
            var colorContrast = Vector3.Distance(color, average) * 0.577f;
            var saturation = Math.Max(color.X, Math.Max(color.Y, color.Z)) - Math.Min(color.X, Math.Min(color.Y, color.Z));
            var left = Sample(Math.Max(0, x - 3), y);
            var right = Sample(Math.Min(MaskSize - 1, x + 3), y);
            var up = Sample(x, Math.Max(0, y - 3));
            var down = Sample(x, Math.Min(MaskSize - 1, y + 3));
            var edge = (Vector3.Distance(left, right) + Vector3.Distance(up, down)) * 0.5f;
            var dx = (x / (float)(MaskSize - 1) - 0.5f) * 1.18f;
            var dy = (y / (float)(MaskSize - 1) - 0.48f) * 1.18f;
            var centerPrior = MathF.Exp(-(dx * dx + dy * dy) * 2.15f);
            var score = colorContrast * 0.48f + Math.Clamp(edge, 0, 1) * 0.28f + saturation * 0.08f + centerPrior * 0.16f;
            scores[y * MaskSize + x] = score;
            maxScore = Math.Max(maxScore, score);
        }

        var mask = new byte[scores.Length];
        for (var y = 0; y < MaskSize; y++)
        for (var x = 0; x < MaskSize; x++)
        {
            var index = y * MaskSize + x;
            var normalized = Math.Clamp(scores[index] / maxScore, 0, 1);
            mask[index] = (byte)Math.Clamp(MathF.Pow(normalized, 0.72f) * 220, 0, 220);
        }

        if (faceBounds is not null)
        {
            foreach (var face in faceBounds)
            {
                var centerX = (face.X + face.Width * 0.5f) * MaskSize;
                var centerY = (face.Y + face.Height * 0.5f) * MaskSize;
                var radiusX = Math.Max(8, face.Width * MaskSize * 1.15f);
                var radiusY = Math.Max(10, face.Height * MaskSize * 1.35f);
                var minX = Math.Max(0, (int)(centerX - radiusX * 1.8f));
                var maxX = Math.Min(MaskSize - 1, (int)(centerX + radiusX * 1.8f));
                var minY = Math.Max(0, (int)(centerY - radiusY * 1.8f));
                var maxY = Math.Min(MaskSize - 1, (int)(centerY + radiusY * 1.8f));
                for (var y = minY; y <= maxY; y++)
                for (var x = minX; x <= maxX; x++)
                {
                    var dx = (x - centerX) / radiusX;
                    var dy = (y - centerY) / radiusY;
                    var faceWeight = (byte)(Math.Clamp(MathF.Exp(-(dx * dx + dy * dy) * 0.48f), 0, 1) * 255);
                    var index = y * MaskSize + x;
                    mask[index] = Math.Max(mask[index], faceWeight);
                }
            }
        }

        return Blur(mask);

        Vector3 Sample(int x, int y)
        {
            var sourceX = Math.Min(width - 1, (int)((x + 0.5f) * width / MaskSize));
            var sourceY = Math.Min(height - 1, (int)((y + 0.5f) * height / MaskSize));
            var offset = (sourceY * width + sourceX) * 4;
            return new Vector3(pixels[offset + 2], pixels[offset + 1], pixels[offset]) / 255f;
        }
    }

    private static byte[] Blur(byte[] source)
    {
        var horizontal = new byte[source.Length];
        var output = new byte[source.Length];
        for (var y = 0; y < MaskSize; y++)
        for (var x = 0; x < MaskSize; x++)
        {
            var total = 0;
            for (var offset = -3; offset <= 3; offset++)
                total += source[y * MaskSize + Math.Clamp(x + offset, 0, MaskSize - 1)];
            horizontal[y * MaskSize + x] = (byte)(total / 7);
        }
        for (var y = 0; y < MaskSize; y++)
        for (var x = 0; x < MaskSize; x++)
        {
            var total = 0;
            for (var offset = -3; offset <= 3; offset++)
                total += horizontal[Math.Clamp(y + offset, 0, MaskSize - 1) * MaskSize + x];
            output[y * MaskSize + x] = (byte)(total / 7);
        }
        return output;
    }
}
