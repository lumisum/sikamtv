using System.Globalization;
using System.Text;

namespace SikaMTV.Core;

public readonly record struct ArticlePageTiming(double StartSeconds, double DurationSeconds)
{
    public double EndSeconds => StartSeconds + DurationSeconds;
    public double TransitionSeconds => Math.Clamp(DurationSeconds * 0.14, 0.35, 1.1);
    public double TransitionStartSeconds => Math.Max(StartSeconds, EndSeconds - TransitionSeconds);
}

public static class ArticleReadingTiming
{
    public static double DefaultRate(bool english) => english ? 150 : 220;

    public static int CountReadingUnits(string text, bool english)
    {
        if (english)
        {
            return text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
                .Count(token => token.EnumerateRunes().Any(Rune.IsLetterOrDigit));
        }

        return text.EnumerateRunes().Count(rune =>
        {
            var category = Rune.GetUnicodeCategory(rune);
            return !Rune.IsWhiteSpace(rune) && category is not (
                UnicodeCategory.ConnectorPunctuation or UnicodeCategory.DashPunctuation or
                UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation or
                UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation or
                UnicodeCategory.OtherPunctuation);
        });
    }

    public static double DurationSeconds(string text, bool english, double unitsPerMinute, double endHoldSeconds)
    {
        var units = CountReadingUnits(text, english);
        if (units == 0) return 0;
        var reading = units / Math.Max(60, unitsPerMinute) * 60;
        return Math.Max(12, reading + Math.Max(1, endHoldSeconds));
    }

    public static IReadOnlyList<ArticlePageTiming> AllocatePageTimings(IReadOnlyList<int> pageUnitCounts, double readingSeconds)
    {
        if (pageUnitCounts.Count == 0 || readingSeconds <= 0) return [];
        var dwell = Math.Min(4.5, Math.Max(0.55, readingSeconds / pageUnitCounts.Count * 0.62));
        var distributable = Math.Max(0, readingSeconds - dwell * pageUnitCounts.Count);
        var totalUnits = Math.Max(1, pageUnitCounts.Sum(count => Math.Max(1, count)));
        var result = new List<ArticlePageTiming>(pageUnitCounts.Count);
        var start = 0.0;
        foreach (var unitCount in pageUnitCounts)
        {
            var duration = dwell + distributable * Math.Max(1, unitCount) / totalUnits;
            result.Add(new ArticlePageTiming(start, duration));
            start += duration;
        }

        return result;
    }
}
