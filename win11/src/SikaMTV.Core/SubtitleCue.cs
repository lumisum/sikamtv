namespace SikaMTV.Core;

public sealed record SubtitleCue(TimeSpan Start, TimeSpan End, string Text);

public enum SubtitleFormat
{
    Lrc,
    Srt
}

public enum TextMode
{
    Lyrics,
    Article
}

public enum VideoAspectRatio
{
    Portrait916,
    Landscape169,
    Square
}

public enum VisualizerKind
{
    Wave,
    Spectrum,
    Mirror,
    Circle,
    Ripple,
    Aurora,
    Prism,
    Nebula,
    Flower,
    Starfield,
    Border
}

public enum VisualTemplate
{
    Zen,
    Ethereal,
    Minimal,
    Cinema,
    Electronic
}
