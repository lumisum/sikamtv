using System.Globalization;
using System.Text.RegularExpressions;

namespace SikaMTV.Core;

/// <summary>Shared product rules for timestamped LRC lyrics and SRT subtitles.</summary>
public static partial class SubtitleParser
{
    private static readonly Regex LrcTimestamp = new(
        @"\[(?<minute>\d{1,3}):(?<second>\d{2})(?:[.:](?<fraction>\d{1,3}))?\]",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex SrtTimestamp = new(
        @"(?<start>\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(?<end>\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public static IReadOnlyList<SubtitleCue> Parse(string source, SubtitleFormat format)
    {
        ArgumentNullException.ThrowIfNull(source);
        return format == SubtitleFormat.Lrc ? ParseLrc(source) : ParseSrt(source);
    }

    public static int? CurrentIndexAt(IReadOnlyList<SubtitleCue> cues, TimeSpan position)
    {
        if (cues.Count == 0 || position < cues[0].Start) return null;

        var low = 0;
        var high = cues.Count - 1;
        while (low <= high)
        {
            var middle = low + ((high - low) / 2);
            if (cues[middle].Start <= position) low = middle + 1;
            else high = middle - 1;
        }

        return Math.Clamp(high, 0, cues.Count - 1);
    }

    private static IReadOnlyList<SubtitleCue> ParseLrc(string source)
    {
        var result = new List<SubtitleCue>();
        foreach (var rawLine in source.Replace("\r", string.Empty, StringComparison.Ordinal).Split('\n'))
        {
            var matches = LrcTimestamp.Matches(rawLine);
            if (matches.Count == 0) continue;
            var text = LrcTimestamp.Replace(rawLine, string.Empty).Trim();
            foreach (Match match in matches)
            {
                var minutes = int.Parse(match.Groups["minute"].Value, CultureInfo.InvariantCulture);
                var seconds = int.Parse(match.Groups["second"].Value, CultureInfo.InvariantCulture);
                var fraction = ParseFraction(match.Groups["fraction"].Value);
                result.Add(new SubtitleCue(TimeSpan.FromMilliseconds((minutes * 60 + seconds) * 1000 + fraction), TimeSpan.Zero, text));
            }
        }

        return WithInferredEnds(result);
    }

    private static IReadOnlyList<SubtitleCue> ParseSrt(string source)
    {
        var result = new List<SubtitleCue>();
        var lines = source.Replace("\r", string.Empty, StringComparison.Ordinal).Split('\n');
        for (var index = 0; index < lines.Length; index++)
        {
            var match = SrtTimestamp.Match(lines[index]);
            if (!match.Success) continue;
            var start = ParseSrtTime(match.Groups["start"].Value);
            var end = ParseSrtTime(match.Groups["end"].Value);
            var textLines = new List<string>();
            for (var textIndex = index + 1; textIndex < lines.Length && !string.IsNullOrWhiteSpace(lines[textIndex]); textIndex++)
            {
                textLines.Add(Regex.Replace(lines[textIndex], "<[^>]+>", string.Empty).Trim());
                index = textIndex;
            }

            var text = string.Join(" ", textLines.Where(line => line.Length > 0));
            if (text.Length > 0 && end > start) result.Add(new SubtitleCue(start, end, text));
        }

        return result.OrderBy(cue => cue.Start).ToArray();
    }

    private static IReadOnlyList<SubtitleCue> WithInferredEnds(List<SubtitleCue> source)
    {
        var ordered = source.OrderBy(cue => cue.Start).ToArray();
        return ordered.Select((cue, index) => cue with
        {
            End = index + 1 < ordered.Length
                ? ordered[index + 1].Start
                : cue.Start + TimeSpan.FromSeconds(4)
        }).ToArray();
    }

    private static TimeSpan ParseSrtTime(string value)
    {
        var normalized = value.Replace(',', '.');
        return TimeSpan.TryParseExact(normalized, [@"h\:mm\:ss\.fff", @"hh\:mm\:ss\.fff"], CultureInfo.InvariantCulture, out var time)
            ? time
            : TimeSpan.Zero;
    }

    private static int ParseFraction(string fraction)
    {
        if (fraction.Length == 0) return 0;
        if (!int.TryParse(fraction, NumberStyles.None, CultureInfo.InvariantCulture, out var value)) return 0;
        return fraction.Length switch
        {
            1 => value * 100,
            2 => value * 10,
            _ => value
        };
    }
}
