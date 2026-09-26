using System.Globalization;
using System.Text;

namespace SikaMTV.Core;

public static class ArticlePaginator
{
    /// <summary>Splits text into readable pages while retaining paragraph and sentence boundaries.</summary>
    public static IReadOnlyList<string> Paginate(string text, bool english, int targetUnits)
    {
        var normalized = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Trim();
        if (normalized.Length == 0) return [];
        targetUnits = Math.Max(40, targetUnits);

        var pages = new List<string>();
        var page = new StringBuilder();
        var pageUnits = 0;
        foreach (var paragraph in normalized.Split('\n').Select(line => line.Trim()).Where(line => line.Length > 0))
        {
            var elements = TextElements(paragraph);
            var cursor = 0;
            while (cursor < elements.Count)
            {
                var remaining = targetUnits - pageUnits;
                if (remaining <= 0 && page.Length > 0)
                {
                    FlushPage(pages, page, ref pageUnits);
                    remaining = targetUnits;
                }

                var units = 0;
                var end = cursor;
                var preferredBreak = -1;
                var preferredUnits = 0;
                var inEnglishWord = false;
                while (end < elements.Count)
                {
                    var increment = UnitIncrement(elements[end], english, ref inEnglishWord);
                    if (units + increment > remaining && end > cursor) break;
                    units += increment;
                    end++;
                    if (IsNaturalBreak(elements[end - 1], english) && units >= targetUnits * 0.70)
                    {
                        preferredBreak = end;
                        preferredUnits = units;
                    }
                    if (units >= remaining) break;
                }

                if (end < elements.Count && preferredBreak > cursor)
                {
                    end = preferredBreak;
                    units = preferredUnits;
                }
                if (end == cursor) end++;
                if (page.Length > 0 && page[^1] != '\n') page.AppendLine();
                for (var index = cursor; index < end; index++) page.Append(elements[index]);
                cursor = end;
                pageUnits += units;

                if (cursor < elements.Count) FlushPage(pages, page, ref pageUnits);
            }

            if (page.Length > 0 && page[^1] != '\n') page.AppendLine();
        }

        FlushPage(pages, page, ref pageUnits);
        return pages;
    }

    private static List<string> TextElements(string text)
    {
        var result = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext()) result.Add(enumerator.GetTextElement());
        return result;
    }

    private static int UnitIncrement(string element, bool english, ref bool inEnglishWord)
    {
        var hasLetterOrDigit = element.EnumerateRunes().Any(Rune.IsLetterOrDigit);
        if (english)
        {
            if (!hasLetterOrDigit)
            {
                inEnglishWord = false;
                return 0;
            }

            if (inEnglishWord) return 0;
            inEnglishWord = true;
            return 1;
        }

        return IsReadingCharacter(element) ? 1 : 0;
    }

    private static bool IsReadingCharacter(string element) => element.EnumerateRunes().Any(rune =>
        {
            var category = Rune.GetUnicodeCategory(rune);
        return !Rune.IsWhiteSpace(rune) && category is not (
            UnicodeCategory.ConnectorPunctuation or UnicodeCategory.DashPunctuation or
            UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation or
            UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation or
            UnicodeCategory.OtherPunctuation);
        });

    private static bool IsNaturalBreak(string element, bool english) =>
        element is "。" or "！" or "？" or "；" or "." or "!" or "?" or ";" ||
        (english && element.All(char.IsWhiteSpace));

    private static void FlushPage(List<string> pages, StringBuilder page, ref int units)
    {
        var content = page.ToString().Trim();
        if (content.Length > 0) pages.Add(content);
        page.Clear();
        units = 0;
    }
}
