using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Text;
using Windows.ApplicationModel.DataTransfer;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Graphics.Imaging;
using Windows.Media.FaceAnalysis;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using WinRT.Interop;
using SikaMTV.Core;

namespace SikaMTV.Win11;

public sealed partial class MainWindow : Window
{
    private sealed record BackgroundFrameData(byte[] Pixels, byte[] SubjectMask, uint Width, uint Height, Vector3 Primary, Vector3 Secondary);
    private readonly ObservableCollection<MediaEntry> _assets = [];
    private readonly List<MediaEntry> _allAssets = [];
    private readonly List<MediaEntry> _backgroundAssets = [];
    private readonly Dictionary<string, BackgroundFrameData> _backgroundImageCache = new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> _backgroundImageCacheOrder = new();
    private readonly Dictionary<string, byte[]> _subjectMaskCache = new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> _subjectMaskCacheOrder = new();
    private readonly Dictionary<string, (Vector3 Primary, Vector3 Secondary)> _backgroundPaletteCache = new(StringComparer.OrdinalIgnoreCase);
    private readonly MediaPlayer _audioPlayer = new();
    private readonly MediaPlayer _backgroundPlayer = new();
    private readonly SemaphoreSlim _subjectAnalysisLock = new(1, 1);
    private FaceDetector? _faceDetector;
    private readonly DispatcherQueueTimer _playbackTimer;
    private readonly DispatcherQueueTimer _exportProgressTimer;
    private readonly Stopwatch _articleClock = new();
    private readonly Microsoft.UI.Xaml.Media.TranslateTransform _introTranslate = new();
    private readonly Microsoft.UI.Xaml.Media.TranslateTransform _introStatic = new();
    private readonly Microsoft.UI.Xaml.Media.ScaleTransform _introScale = new();
    private readonly Microsoft.UI.Xaml.Media.TranslateTransform _lyricTranslate = new();
    private readonly Microsoft.UI.Xaml.Media.ScaleTransform _lyricScale = new();
    private readonly Microsoft.UI.Xaml.Media.SolidColorBrush _lyricWhiteBrush = new(Windows.UI.Color.FromArgb(255, 255, 255, 255));
    private readonly Microsoft.UI.Xaml.Media.SolidColorBrush _lyricAccentBrush = new(Windows.UI.Color.FromArgb(255, 197, 176, 255));
    private IReadOnlyList<SubtitleCue> _cues = [];
    private IReadOnlyList<string> _articlePages = [];
    private IReadOnlyList<ArticlePageTiming> _articleTimings = [];
    private MediaEntry? _backgroundAsset;
    private MediaEntry? _audioAsset;
    private MediaEntry? _subtitleAsset;
    private bool _updatingSlider;
    private bool _isScrubbing;
    private bool _isArticleMode;
    private bool _gpuInitialized;
    private bool _gpuPanelAttached;
    private bool _exportInProgress;
    private StorageFile? _exportDestination;
    private double _articleElapsedOffset;
    private double _articleDurationSeconds;
    private readonly float[] _audioBands = new float[64];
    private byte[]? _backgroundPixels;
    private uint _backgroundPixelWidth;
    private uint _backgroundPixelHeight;
    private string _requestedPreviewPair = string.Empty;
    private string _appliedPreviewPair = string.Empty;
    private string _previewAudioVideoPath = string.Empty;
    private int _previewPairGeneration;
    private bool _backgroundAudioPlaying;
    private string _selectedFontFamily = "素材集市康康体";
    private string _automaticSongTitle = string.Empty;
    private Vector3 _scenePalettePrimary = new(0.48f, 0.72f, 1.0f);
    private Vector3 _scenePaletteSecondary = new(0.82f, 0.52f, 0.94f);

    public MainWindow()
    {
        InitializeComponent();
        InitializeTextShadows();
        IntroOverlay.RenderTransform = _introTranslate;
        AssetsList.ItemsSource = _assets;
        _audioPlayer.MediaOpened += AudioPlayer_MediaOpened;
        _audioPlayer.MediaEnded += AudioPlayer_MediaEnded;
        _audioPlayer.IsLoopingEnabled = false;
        ArticleTextBox.TextChanged += (_, _) =>
        {
            UpdateArticleSettings();
            RebuildArticlePages();
            UpdateLyrics(CurrentTimelinePosition());
            UpdateGenerateAvailability();
        };
        SongTitleBox.TextChanged += (_, _) => UpdateIntroText();
        AuthorNameBox.TextChanged += (_, _) => UpdateIntroText();
        PlaybackSlider.PointerPressed += (_, _) => _isScrubbing = true;
        PlaybackSlider.PointerReleased += (_, _) => _isScrubbing = false;
        _backgroundPlayer.IsMuted = true;
        BackgroundVideo.SetMediaPlayer(_backgroundPlayer);
        _playbackTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _playbackTimer.Interval = TimeSpan.FromMilliseconds(33);
        _playbackTimer.IsRepeating = true;
        _playbackTimer.Tick += PlaybackTimer_Tick;
        _playbackTimer.Start();
        _exportProgressTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _exportProgressTimer.Interval = TimeSpan.FromMilliseconds(250);
        _exportProgressTimer.IsRepeating = true;
        _exportProgressTimer.Tick += ExportProgressTimer_Tick;
        PreviewDropSurface.DragEnter += PreviewDropSurface_DragOver;
        Closed += (_, _) =>
        {
            _playbackTimer.Stop();
            _exportProgressTimer.Stop();
            if (_exportInProgress) NvidiaGpuBridge.CancelVideoExport();
            if (_gpuInitialized)
            {
                NvidiaGpuBridge.StopPreviewBackgroundVideo();
                NvidiaGpuBridge.Shutdown();
            }
            _audioPlayer.Dispose();
            _backgroundPlayer.Dispose();
        };
        RegisterBundledFonts();
        InitializeNvidiaStatus();
        IntroDateText.Text = DateTime.Now.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        UpdateIntroText();
        ApplySelectedFont();
        UpdateArticleSettings();
        RebuildArticlePages();
        ApplyLyricsStyle();
        TemplateBox_SelectionChanged(TemplateBox, null!);
        UpdateGenerateAvailability();
    }

    private async void ImportAssetsButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker
        {
            SuggestedStartLocation = PickerLocationId.MusicLibrary,
            ViewMode = PickerViewMode.List
        };
        foreach (var extension in SupportedExtensions) picker.FileTypeFilter.Add(extension);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count == 0) return;
        await AddFilesToLibraryAsync(files);
    }

    private async void ImportArticleButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, ViewMode = PickerViewMode.List };
        picker.FileTypeFilter.Add(".txt");
        picker.FileTypeFilter.Add(".md");
        picker.FileTypeFilter.Add(".markdown");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        ArticleTextBox.Text = await FileIO.ReadTextAsync(file);
        TextModeBox.SelectedIndex = 1;
        SetStatus($"已载入文章：{file.Name}");
    }

    private async void ImportFontButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads, ViewMode = PickerViewMode.List };
        picker.FileTypeFilter.Add(".ttf");
        picker.FileTypeFilter.Add(".otf");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;

        var fontsDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SikaMTV", "Fonts");
        Directory.CreateDirectory(fontsDirectory);
        var importedFontPath = Path.Combine(fontsDirectory, $"{Path.GetFileNameWithoutExtension(file.Name)}-{Guid.NewGuid():N}{Path.GetExtension(file.Name)}");
        await Task.Run(() => File.Copy(file.Path, importedFontPath));
        if (!PrivateFontRegistrar.TryRegister(importedFontPath, out var error))
        {
            SetStatus($"字体导入失败：{error}");
            return;
        }

        var familyName = file.DisplayName;
        if (_gpuInitialized)
        {
            var family = new System.Text.StringBuilder(256);
            if (NvidiaGpuBridge.GetFontFamily(importedFontPath, family, family.Capacity) >= 0 && family.Length > 0)
                familyName = family.ToString();
        }
        var fontUri = $"{new Uri(importedFontPath).AbsoluteUri}#{Uri.EscapeDataString(familyName)}";
        var item = new ComboBoxItem { Content = $"{familyName}（已导入）", Tag = fontUri };
        FontBox.Items.Add(item);
        FontBox.SelectedItem = item;
        _selectedFontFamily = fontUri;
        ApplySelectedFont();
        SetStatus("字体已复制到 SikaMTV 私有应用目录并用于本次作品。请确认您拥有使用该字体的授权。");
    }

    private async Task AddFilesToLibraryAsync(IEnumerable<StorageFile> files)
    {
        var added = 0;
        foreach (var file in files)
        {
            var kind = MediaEntry.Classify(file.FileType);
            if (kind is null) continue;
            var entry = new MediaEntry(file, kind.Value);
            if (_allAssets.Any(existing => existing.File.Path.Equals(file.Path, StringComparison.OrdinalIgnoreCase))) continue;
            _allAssets.Add(entry);
            added++;

            // New files stay in the library until the user explicitly adds them to a project slot.
        }

        RefreshAssetFilter();
        SetStatus(added == 0 ? "没有新增素材" : $"已导入 {added} 个素材。将素材加入下方项目工作区后即可预览。");
        await Task.CompletedTask;
    }

    private async void AddAssetToProject_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not MediaEntry entry) return;
        await AssignAssetToProjectAsync(entry);
        SetStatus($"已将“{entry.Name}”加入项目工作区");
    }

    private async Task AssignAssetToProjectAsync(MediaEntry entry)
    {
        switch (entry.Kind)
        {
            case MediaKind.Image:
            case MediaKind.Video:
                if (!_backgroundAssets.Any(existing => existing.File.Path.Equals(entry.File.Path, StringComparison.OrdinalIgnoreCase)))
                    _backgroundAssets.Add(entry);
                _backgroundAsset ??= entry;
                if (!ReferenceEquals(_backgroundAsset, entry))
                {
                    if (entry.Kind == MediaKind.Image && !_backgroundImageCache.ContainsKey(entry.File.Path))
                        CacheBackgroundPixels(entry.File.Path, await LoadBackgroundPixelsAsync(entry));
                    else if (entry.Kind == MediaKind.Video)
                        await LoadBackgroundVideoPaletteAsync(entry);
                }
                UpdateBackgroundSummary();
                if (ReferenceEquals(_backgroundAsset, entry)) await ShowBackgroundAsync(entry);
                break;
            case MediaKind.Audio:
                _audioAsset = entry;
                WorkspaceAudioText.Text = entry.Name;
                await LoadAudioAsync(entry);
                break;
            case MediaKind.Subtitle:
                _subtitleAsset = entry;
                WorkspaceTextText.Text = entry.Name;
                if (Path.GetExtension(entry.Name).ToLowerInvariant() is ".txt" or ".md" or ".markdown")
                {
                    TextModeBox.SelectedIndex = 1;
                    ArticleTextBox.Text = await FileIO.ReadTextAsync(entry.File);
                }
                else
                {
                    await LoadSubtitlesAsync(entry);
                }
                break;
        }

        UpdateGenerateAvailability();
    }

    private async Task ShowBackgroundAsync(MediaEntry entry)
    {
        PreviewPlaceholder.Visibility = Visibility.Collapsed;
        BackgroundVideoAudioToggle.IsEnabled = entry.Kind == MediaKind.Video;
        BackgroundVideoVolumeSlider.IsEnabled = entry.Kind == MediaKind.Video && BackgroundVideoAudioToggle.IsOn;
        if (entry.Kind == MediaKind.Image)
        {
            if (_gpuInitialized)
            {
                NvidiaGpuBridge.StopPreviewBackgroundVideo();
                NvidiaGpuBridge.ClearBackgroundImage();
                VisualizerPanel.Visibility = Visibility.Visible;
            }
            BackgroundVideo.Visibility = Visibility.Collapsed;
            _backgroundPlayer.Source = null;
            _previewAudioVideoPath = string.Empty;
            _backgroundAudioPlaying = false;
            using var stream = await entry.File.OpenAsync(FileAccessMode.Read);
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(stream);
            BackgroundImage.Source = bitmap;
            BackgroundImage.Visibility = Visibility.Visible;
            _backgroundPixels = null;
            _backgroundPixelWidth = 0;
            _backgroundPixelHeight = 0;

            if (!_backgroundImageCache.TryGetValue(entry.File.Path, out var decoded))
            {
                decoded = await LoadBackgroundPixelsAsync(entry);
                CacheBackgroundPixels(entry.File.Path, decoded);
            }
            _backgroundPixels = decoded.Pixels;
            _backgroundPixelWidth = decoded.Width;
            _backgroundPixelHeight = decoded.Height;
            (_scenePalettePrimary, _scenePaletteSecondary) = (decoded.Primary, decoded.Secondary);
            if (_gpuInitialized) CommitGpuBackground();
        }
        else
        {
            _backgroundPixels = null;
            try
            {
                using var thumbnail = await entry.File.GetThumbnailAsync(Windows.Storage.FileProperties.ThumbnailMode.VideosView, 192);
                if (thumbnail is not null)
                {
                    var decoder = await BitmapDecoder.CreateAsync(thumbnail);
                    using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
                    var buffer = new Windows.Storage.Streams.Buffer(checked((uint)(bitmap.PixelWidth * bitmap.PixelHeight * 4)));
                    bitmap.CopyToBuffer(buffer);
                    var pixels = new byte[checked((int)buffer.Length)];
                    using var reader = DataReader.FromBuffer(buffer);
                    reader.ReadBytes(pixels);
                    var palette = ScenePaletteAnalyzer.AnalyzeBgra(pixels, (int)bitmap.PixelWidth, (int)bitmap.PixelHeight);
                    (_scenePalettePrimary, _scenePaletteSecondary) = palette;
                    _backgroundPaletteCache[entry.File.Path] = palette;
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
            {
                SetStatus($"已载入视频背景；未能读取预览帧配色，使用柔和默认配色（{exception.Message}）。");
            }
            if (_gpuInitialized)
            {
                NvidiaGpuBridge.StopPreviewBackgroundVideo();
                NvidiaGpuBridge.ClearBackgroundImage();
                NvidiaGpuBridge.UpdatePreviewBackgroundVideo(entry.File.Path, 0, VideoLoopToggle.IsOn ? 1 : 0);
            }
            BackgroundImage.Visibility = Visibility.Collapsed;
            var mediaSource = MediaSource.CreateFromStorageFile(entry.File);
            _backgroundPlayer.Source = mediaSource;
            _previewAudioVideoPath = entry.File.Path;
            _backgroundAudioPlaying = false;
            _backgroundPlayer.IsLoopingEnabled = VideoLoopToggle.IsOn;
            _backgroundPlayer.IsMuted = !BackgroundVideoAudioToggle.IsOn;
            _backgroundPlayer.Volume = BackgroundVideoVolumeSlider.Value;
            BackgroundVideo.Visibility = Visibility.Collapsed;
            VisualizerPanel.Visibility = Visibility.Visible;
        }
        ApplyAdvancedVisualSettings();
    }

    private void UpdateBackgroundSummary()
    {
        var hasVideoBackground = _backgroundAssets.Any(asset => asset.Kind == MediaKind.Video);
        BackgroundVideoAudioToggle.IsEnabled = hasVideoBackground;
        BackgroundVideoVolumeSlider.IsEnabled = hasVideoBackground && BackgroundVideoAudioToggle.IsOn;
        WorkspaceBackgroundText.Text = _backgroundAssets.Count switch
        {
            0 => "未添加 · 图片 / 视频",
            1 => _backgroundAssets[0].Name,
            _ => $"{_backgroundAssets.Count} 个背景 · 按音乐时长自动轮播"
        };
    }

    private async Task<BackgroundFrameData> LoadBackgroundPixelsAsync(MediaEntry entry)
    {
        using var stream = await entry.File.OpenAsync(FileAccessMode.Read);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var scale = Math.Min(1.0, Math.Min(1920.0 / decoder.OrientedPixelWidth, 1080.0 / decoder.OrientedPixelHeight));
        var transform = new BitmapTransform
        {
            ScaledWidth = (uint)Math.Max(1, Math.Round(decoder.OrientedPixelWidth * scale)),
            ScaledHeight = (uint)Math.Max(1, Math.Round(decoder.OrientedPixelHeight * scale)),
            InterpolationMode = BitmapInterpolationMode.Fant
        };
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage);
        var buffer = new Windows.Storage.Streams.Buffer(checked((uint)(bitmap.PixelWidth * bitmap.PixelHeight * 4)));
        bitmap.CopyToBuffer(buffer);
        var pixels = new byte[checked((int)buffer.Length)];
        using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
        var palette = ScenePaletteAnalyzer.AnalyzeBgra(pixels, bitmap.PixelWidth, bitmap.PixelHeight);
        if (!_subjectMaskCache.TryGetValue(entry.File.Path, out var subjectMask))
        {
            var faces = await DetectFaceBoundsAsync(bitmap);
            subjectMask = await Task.Run(() => SceneSubjectAnalyzer.AnalyzeBgra(
                pixels, (int)bitmap.PixelWidth, (int)bitmap.PixelHeight, faces));
            CacheSubjectMask(entry.File.Path, subjectMask);
        }
        return new BackgroundFrameData(pixels, subjectMask, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, palette.Primary, palette.Secondary);
    }

    private async Task<IReadOnlyList<(float X, float Y, float Width, float Height)>> DetectFaceBoundsAsync(SoftwareBitmap source)
    {
        await _subjectAnalysisLock.WaitAsync();
        try
        {
            if (!FaceDetector.GetSupportedBitmapPixelFormats().Contains(BitmapPixelFormat.Gray8)) return [];
            _faceDetector ??= await FaceDetector.CreateAsync();
            if (source.BitmapPixelFormat == BitmapPixelFormat.Gray8)
            {
                var faces = await _faceDetector.DetectFacesAsync(source);
                return faces.Select(face => ((float)face.FaceBox.X / source.PixelWidth, (float)face.FaceBox.Y / source.PixelHeight,
                    (float)face.FaceBox.Width / source.PixelWidth, (float)face.FaceBox.Height / source.PixelHeight)).ToArray();
            }

            using var gray = SoftwareBitmap.Convert(source, BitmapPixelFormat.Gray8);
            var detected = await _faceDetector.DetectFacesAsync(gray);
            return detected.Select(face => ((float)face.FaceBox.X / gray.PixelWidth, (float)face.FaceBox.Y / gray.PixelHeight,
                (float)face.FaceBox.Width / gray.PixelWidth, (float)face.FaceBox.Height / gray.PixelHeight)).ToArray();
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            SetStatus($"已使用显著性保护；本机人脸识别暂不可用（{exception.Message}）。");
            return [];
        }
        finally
        {
            _subjectAnalysisLock.Release();
        }
    }

    private void CacheBackgroundPixels(string path, BackgroundFrameData data)
    {
        _backgroundPaletteCache[path] = (data.Primary, data.Secondary);
        CacheSubjectMask(path, data.SubjectMask);
        if (!_backgroundImageCache.ContainsKey(path)) _backgroundImageCacheOrder.Enqueue(path);
        _backgroundImageCache[path] = data;
        while (_backgroundImageCacheOrder.Count > 4)
        {
            var expired = _backgroundImageCacheOrder.Dequeue();
            if (!string.Equals(expired, path, StringComparison.OrdinalIgnoreCase)) _backgroundImageCache.Remove(expired);
        }
    }

    private void CacheSubjectMask(string path, byte[] mask)
    {
        if (!_subjectMaskCache.ContainsKey(path)) _subjectMaskCacheOrder.Enqueue(path);
        _subjectMaskCache[path] = mask;
        while (_subjectMaskCacheOrder.Count > 128)
            _subjectMaskCache.Remove(_subjectMaskCacheOrder.Dequeue());
    }

    private async Task LoadPreviewBackgroundPairAsync(string pairKey, int generation,
        MediaEntry current, MediaEntry? next)
    {
        try
        {
            if (current.Kind == MediaKind.Image && !_backgroundImageCache.TryGetValue(current.File.Path, out _))
                CacheBackgroundPixels(current.File.Path, await LoadBackgroundPixelsAsync(current));
            if (next?.Kind == MediaKind.Image && !_backgroundImageCache.TryGetValue(next.File.Path, out _))
                CacheBackgroundPixels(next.File.Path, await LoadBackgroundPixelsAsync(next));
            if (current.Kind == MediaKind.Video)
                (_scenePalettePrimary, _scenePaletteSecondary) = await LoadBackgroundVideoPaletteAsync(current);
            if (generation != _previewPairGeneration || !string.Equals(pairKey, _requestedPreviewPair, StringComparison.Ordinal)) return;

            if (current.Kind == MediaKind.Image && _backgroundImageCache.TryGetValue(current.File.Path, out var primary))
            {
                _backgroundPixels = primary.Pixels;
                _backgroundPixelWidth = primary.Width;
                _backgroundPixelHeight = primary.Height;
                _scenePalettePrimary = primary.Primary;
                _scenePaletteSecondary = primary.Secondary;
                NvidiaGpuBridge.SetBackgroundImage(primary.Pixels, primary.Width, primary.Height, primary.Width * 4);
                NvidiaGpuBridge.SetSubjectMask(primary.SubjectMask, SceneSubjectAnalyzer.MaskSize, SceneSubjectAnalyzer.MaskSize, SceneSubjectAnalyzer.MaskSize, 0);
            }
            else
            {
                NvidiaGpuBridge.SetSubjectMask([], 0, 0, 0, 0);
            }
            if (next?.Kind == MediaKind.Image && _backgroundImageCache.TryGetValue(next.File.Path, out var secondary))
            {
                NvidiaGpuBridge.SetBackgroundImageSecondary(secondary.Pixels, secondary.Width, secondary.Height, secondary.Width * 4);
                NvidiaGpuBridge.SetSubjectMask(secondary.SubjectMask, SceneSubjectAnalyzer.MaskSize, SceneSubjectAnalyzer.MaskSize, SceneSubjectAnalyzer.MaskSize, 1);
            }
            else NvidiaGpuBridge.SetSubjectMask([], 0, 0, 0, 1);
            _appliedPreviewPair = pairKey;
            ApplyAdvancedVisualSettings();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            if (generation == _previewPairGeneration)
                SetStatus($"背景轮播预览载入失败：{exception.Message}");
        }
    }

    private void UpdateBackgroundCarouselPreview(double visualTime)
    {
        if (_backgroundAssets.Count == 0) return;
        var duration = _isArticleMode ? _articleDurationSeconds : _audioPlayer.PlaybackSession.NaturalDuration.TotalSeconds;
        var singleVideoDuration = _backgroundAssets.Count == 1 && _backgroundAssets[0].Kind == MediaKind.Video
            ? _backgroundPlayer.PlaybackSession.NaturalDuration.TotalSeconds : 0;
        var state = BackgroundPreviewTimeline.At(visualTime, duration, _backgroundAssets.Count,
            BackgroundTransitionBox.SelectedIndex, BackgroundTransitionDurationSlider.Value,
            singleVideoDuration, VideoLoopToggle.IsOn);
        var current = _backgroundAssets[state.CurrentIndex];
        var next = state.NextIndex is int nextIndex ? _backgroundAssets[nextIndex] : null;
        UpdateBackgroundAudioPreview(current, state.CurrentLocalTime);
        if (!_gpuInitialized || !_gpuPanelAttached || _exportInProgress) return;
        var pairKey = $"{state.CurrentIndex}:{state.NextIndex?.ToString() ?? "-"}";
        if (!string.Equals(pairKey, _requestedPreviewPair, StringComparison.Ordinal))
        {
            _requestedPreviewPair = pairKey;
            var generation = ++_previewPairGeneration;
            _ = LoadPreviewBackgroundPairAsync(pairKey, generation, current, next);
        }
        if (!string.Equals(pairKey, _appliedPreviewPair, StringComparison.Ordinal)) return;

        var paletteA = _backgroundPaletteCache.GetValueOrDefault(current.File.Path,
            (Primary: _scenePalettePrimary, Secondary: _scenePaletteSecondary));
        var paletteB = next is null ? paletteA : _backgroundPaletteCache.GetValueOrDefault(next.File.Path, paletteA);
        var paletteMix = state.NextIndex.HasValue ? state.TransitionProgress : 0;
        var primaryPalette = Vector3.Lerp(paletteA.Primary, paletteB.Primary, paletteMix);
        var secondaryPalette = Vector3.Lerp(paletteA.Secondary, paletteB.Secondary, paletteMix);
        NvidiaGpuBridge.SetScenePalette(primaryPalette.X, primaryPalette.Y, primaryPalette.Z,
            secondaryPalette.X, secondaryPalette.Y, secondaryPalette.Z);
        var segmentDuration = Math.Max(state.SegmentDuration, 0.001);
        NvidiaGpuBridge.SetBackgroundMotionTimeline(
            (float)Math.Clamp(state.CurrentLocalTime / segmentDuration, 0, 1),
            current.Kind == MediaKind.Image ? 1f : 0.16f,
            (float)Math.Clamp(state.NextLocalTime / segmentDuration, 0, 1),
            next is null ? 0f : next.Kind == MediaKind.Image ? 1f : 0.16f);

        var primaryVideo = current.Kind == MediaKind.Video ? current.File.Path : string.Empty;
        var secondaryVideo = next?.Kind == MediaKind.Video ? next.File.Path : string.Empty;
        NvidiaGpuBridge.UpdatePreviewBackgroundCarousel(primaryVideo, state.CurrentLocalTime,
            secondaryVideo, state.NextLocalTime, VideoLoopToggle.IsOn ? 1 : 0,
            state.TransitionProgress, state.TransitionKind);
    }

    private void UpdateBackgroundAudioPreview(MediaEntry current, double localTime)
    {
        var path = current.Kind == MediaKind.Video ? current.File.Path : string.Empty;
        if (!string.Equals(path, _previewAudioVideoPath, StringComparison.OrdinalIgnoreCase))
        {
            _backgroundPlayer.Pause();
            _backgroundPlayer.Source = path.Length == 0 ? null : MediaSource.CreateFromStorageFile(current.File);
            _previewAudioVideoPath = path;
            _backgroundAudioPlaying = false;
        }
        if (path.Length == 0) return;

        _backgroundPlayer.IsLoopingEnabled = VideoLoopToggle.IsOn;
        _backgroundPlayer.IsMuted = !BackgroundVideoAudioToggle.IsOn;
        _backgroundPlayer.Volume = BackgroundVideoVolumeSlider.Value;
        var duration = _backgroundPlayer.PlaybackSession.NaturalDuration.TotalSeconds;
        var target = duration > 0 && VideoLoopToggle.IsOn ? localTime % duration : localTime;
        if (Math.Abs(_backgroundPlayer.PlaybackSession.Position.TotalSeconds - target) > 0.3)
            _backgroundPlayer.PlaybackSession.Position = TimeSpan.FromSeconds(Math.Max(0, target));
        var shouldPlay = _audioPlayer.PlaybackSession.PlaybackState == MediaPlaybackState.Playing && BackgroundVideoAudioToggle.IsOn;
        if (shouldPlay != _backgroundAudioPlaying)
        {
            if (shouldPlay) _backgroundPlayer.Play();
            else _backgroundPlayer.Pause();
            _backgroundAudioPlaying = shouldPlay;
        }
    }

    private async Task<(Vector3 Primary, Vector3 Secondary)> LoadBackgroundVideoPaletteAsync(MediaEntry entry)
    {
        if (_backgroundPaletteCache.TryGetValue(entry.File.Path, out var cached)) return cached;
        try
        {
            using var thumbnail = await entry.File.GetThumbnailAsync(Windows.Storage.FileProperties.ThumbnailMode.VideosView, 192);
            if (thumbnail is null) return (_scenePalettePrimary, _scenePaletteSecondary);
            var decoder = await BitmapDecoder.CreateAsync(thumbnail);
            using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            var buffer = new Windows.Storage.Streams.Buffer(checked((uint)(bitmap.PixelWidth * bitmap.PixelHeight * 4)));
            bitmap.CopyToBuffer(buffer);
            var pixels = new byte[checked((int)buffer.Length)];
            using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
            var palette = ScenePaletteAnalyzer.AnalyzeBgra(pixels, bitmap.PixelWidth, bitmap.PixelHeight);
            _backgroundPaletteCache[entry.File.Path] = palette;
            return palette;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            SetStatus($"未能读取视频配色，将使用默认配色：{exception.Message}");
            return (_scenePalettePrimary, _scenePaletteSecondary);
        }
    }

    private async Task<string> BuildBackgroundManifestAsync()
    {
        var maskPaths = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var asset in _backgroundAssets)
        {
            if (asset.Kind == MediaKind.Image)
            {
                if (!_backgroundImageCache.TryGetValue(asset.File.Path, out var imageData))
                {
                    CacheBackgroundPixels(asset.File.Path, await LoadBackgroundPixelsAsync(asset));
                    imageData = _backgroundImageCache[asset.File.Path];
                }
                var cacheRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "SikaMTV", "Cache", "subject-masks");
                Directory.CreateDirectory(cacheRoot);
                var key = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(asset.File.Path)));
                var maskPath = Path.Combine(cacheRoot, key + ".mask");
                await File.WriteAllBytesAsync(maskPath, imageData.SubjectMask);
                maskPaths[asset.File.Path] = maskPath;
            }
            else
            {
                await LoadBackgroundVideoPaletteAsync(asset);
            }
        }

        static string Color(Vector3 value) => string.Join(',',
            value.X.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture),
            value.Y.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture),
            value.Z.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture));

        var lines = new List<string>(_backgroundAssets.Count);
        foreach (var asset in _backgroundAssets)
        {
            var palette = _backgroundPaletteCache.GetValueOrDefault(asset.File.Path,
                (Primary: _scenePalettePrimary, Secondary: _scenePaletteSecondary));
            var maskPath = maskPaths.GetValueOrDefault(asset.File.Path, string.Empty);
            lines.Add($"{(asset.Kind == MediaKind.Video ? 'V' : 'I')}|{asset.File.Path}|{Color(palette.Primary)}|{Color(palette.Secondary)}|{maskPath}");
        }
        return string.Join("\n", lines);
    }

    private async Task LoadAudioAsync(MediaEntry entry)
    {
        _audioPlayer.Pause();
        _audioPlayer.Source = MediaSource.CreateFromStorageFile(entry.File);
        UseAudioFilenameButton.Visibility = Visibility.Visible;
        var filename = Path.GetFileNameWithoutExtension(entry.Name);
        if (string.IsNullOrWhiteSpace(SongTitleBox.Text) ||
            string.Equals(SongTitleBox.Text, _automaticSongTitle, StringComparison.Ordinal))
        {
            _automaticSongTitle = filename;
            SongTitleBox.Text = filename;
        }
        if (_gpuInitialized) NvidiaGpuBridge.SetAudioSource(entry.File.Path);
        _audioPlayer.IsLoopingEnabled = _isArticleMode;
        _articleElapsedOffset = 0;
        _articleClock.Reset();
        CurrentTimeText.Text = "00:00";
        DurationText.Text = "00:00";
        PlaybackSlider.Value = 0;
        var audioStem = Path.GetFileNameWithoutExtension(entry.Name);
        var matchingSubtitle = _allAssets.FirstOrDefault(asset => asset.Kind == MediaKind.Subtitle &&
            (Path.GetExtension(asset.Name).ToLowerInvariant() is ".lrc" or ".srt") &&
            string.Equals(Path.GetFileNameWithoutExtension(asset.Name), audioStem, StringComparison.OrdinalIgnoreCase));
        if (matchingSubtitle is not null)
        {
            _subtitleAsset = matchingSubtitle;
            WorkspaceTextText.Text = matchingSubtitle.Name;
            await LoadSubtitlesAsync(matchingSubtitle);
        }
        UpdateIntroText();
    }

    private async Task LoadSubtitlesAsync(MediaEntry entry)
    {
        var source = await FileIO.ReadTextAsync(entry.File);
        var format = Path.GetExtension(entry.Name).Equals(".srt", StringComparison.OrdinalIgnoreCase)
            ? SubtitleFormat.Srt
            : SubtitleFormat.Lrc;
        _cues = SubtitleParser.Parse(source, format);
        SetStatus($"已解析 { _cues.Count } 条字幕；歌词窗口默认显示 5 句以容忍时间戳偏差。");
        UpdateLyrics(TimeSpan.Zero);
    }

    private void ClearWorkspaceButton_Click(object sender, RoutedEventArgs e)
    {
        _audioPlayer.Pause();
        _audioPlayer.Source = null;
        _backgroundPlayer.Pause();
        _backgroundPlayer.Source = null;
        _backgroundAsset = null;
        _backgroundAssets.Clear();
        _previewPairGeneration++;
        _requestedPreviewPair = _appliedPreviewPair = string.Empty;
        _backgroundImageCache.Clear();
        _backgroundImageCacheOrder.Clear();
        _subjectMaskCache.Clear();
        _subjectMaskCacheOrder.Clear();
        _previewAudioVideoPath = string.Empty;
        BackgroundVideoAudioToggle.IsEnabled = false;
        BackgroundVideoVolumeSlider.IsEnabled = false;
        _audioAsset = null;
        _subtitleAsset = null;
        UseAudioFilenameButton.Visibility = Visibility.Collapsed;
        _cues = [];
        if (_gpuInitialized) NvidiaGpuBridge.SetAudioSource(null);
        _articlePages = [];
        _articleTimings = [];
        _articleElapsedOffset = 0;
        _articleDurationSeconds = 0;
        _articleClock.Reset();
        BackgroundImage.Source = null;
        BackgroundImage.Visibility = Visibility.Collapsed;
        BackgroundVideo.Visibility = Visibility.Collapsed;
        _backgroundPixels = null;
        if (_gpuInitialized)
        {
            NvidiaGpuBridge.StopPreviewBackgroundVideo();
            NvidiaGpuBridge.ClearBackgroundImage();
            VisualizerPanel.Visibility = Visibility.Visible;
        }
        PreviewPlaceholder.Visibility = Visibility.Visible;
        UpdateBackgroundSummary();
        WorkspaceAudioText.Text = "未添加 · WAV / MP3 / M4A";
        WorkspaceTextText.Text = "未添加 · LRC / SRT / TXT";
        UpdateLyrics(TimeSpan.Zero);
        UpdateGenerateAvailability();
    }

    private void ClearWorkspaceSlot_Click(object sender, RoutedEventArgs e)
    {
        var slot = (sender as Button)?.Tag?.ToString();
        switch (slot)
        {
            case "Background":
                _backgroundPlayer.Pause();
                _backgroundPlayer.Source = null;
                _backgroundAsset = null;
                _backgroundAssets.Clear();
                _previewPairGeneration++;
                _requestedPreviewPair = _appliedPreviewPair = string.Empty;
                _backgroundImageCache.Clear();
                _backgroundImageCacheOrder.Clear();
                _subjectMaskCache.Clear();
                _subjectMaskCacheOrder.Clear();
                _previewAudioVideoPath = string.Empty;
                BackgroundVideoAudioToggle.IsEnabled = false;
                BackgroundVideoVolumeSlider.IsEnabled = false;
                _backgroundPixels = null;
                BackgroundImage.Source = null;
                BackgroundImage.Visibility = Visibility.Collapsed;
                BackgroundVideo.Visibility = Visibility.Collapsed;
                PreviewPlaceholder.Visibility = Visibility.Visible;
                if (_gpuInitialized)
                {
                    NvidiaGpuBridge.StopPreviewBackgroundVideo();
                    NvidiaGpuBridge.ClearBackgroundImage();
                }
                UpdateBackgroundSummary();
                break;
            case "Audio":
                _audioPlayer.Pause();
                _audioPlayer.Source = null;
                _audioAsset = null;
                UseAudioFilenameButton.Visibility = Visibility.Collapsed;
                _articleElapsedOffset = 0;
                _articleClock.Reset();
                if (_gpuInitialized) NvidiaGpuBridge.SetAudioSource(null);
                CurrentTimeText.Text = "00:00";
                DurationText.Text = "00:00";
                PlaybackSlider.Value = 0;
                PlayIcon.Glyph = "\uE768";
                WorkspaceAudioText.Text = "未添加 · WAV / MP3 / M4A";
                break;
            case "Text":
                _subtitleAsset = null;
                _cues = [];
                ArticleTextBox.Text = string.Empty;
                _articlePages = [];
                _articleTimings = [];
                WorkspaceTextText.Text = "未添加 · LRC / SRT / TXT";
                UpdateLyrics(TimeSpan.Zero);
                break;
        }
        UpdateGenerateAvailability();
    }

    private void PlayButton_Click(object sender, RoutedEventArgs e)
    {
        if (_audioPlayer.PlaybackSession.PlaybackState == MediaPlaybackState.Playing)
        {
            _audioPlayer.Pause();
            _backgroundPlayer.Pause();
            _articleElapsedOffset = GetArticleElapsedSeconds();
            _articleClock.Stop();
            PlayIcon.Glyph = "\uE768";
        }
        else
        {
            if (_isArticleMode)
            {
                if (_articleElapsedOffset >= _articleDurationSeconds) _articleElapsedOffset = 0;
                SeekAudioForArticle(_articleElapsedOffset);
                _articleClock.Restart();
            }
            _audioPlayer.Play();
            SyncBackgroundAudioToSong();
            PlayIcon.Glyph = "\uE769";
        }
    }

    private void PlaybackTimer_Tick(DispatcherQueueTimer sender, object args)
    {
        var session = _audioPlayer.PlaybackSession;
        var position = CurrentTimelinePosition();
        var duration = _isArticleMode ? TimeSpan.FromSeconds(_articleDurationSeconds) : session.NaturalDuration;
        CurrentTimeText.Text = FormatTime(position);
        DurationText.Text = FormatTime(duration);
        if (!_isScrubbing)
        {
            _updatingSlider = true;
            PlaybackSlider.Maximum = Math.Max(1, duration.TotalSeconds);
            PlaybackSlider.Value = Math.Clamp(position.TotalSeconds, 0, PlaybackSlider.Maximum);
            _updatingSlider = false;
        }
        UpdateLyrics(position);
        UpdateBackgroundCarouselPreview(position.TotalSeconds);
        RenderVisualizer(position.TotalSeconds, session.Position.TotalSeconds, session.PlaybackState == MediaPlaybackState.Playing);
        if (_isArticleMode && _articleDurationSeconds > 0 && position.TotalSeconds >= _articleDurationSeconds && session.PlaybackState == MediaPlaybackState.Playing)
        {
            _audioPlayer.Pause();
            _backgroundPlayer.Pause();
            _articleElapsedOffset = _articleDurationSeconds;
            _articleClock.Stop();
            PlayIcon.Glyph = "\uE768";
            UpdateLyrics(TimeSpan.FromSeconds(_articleElapsedOffset));
        }
    }

    private void PlaybackSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_updatingSlider || _audioAsset is null) return;
        if (_isArticleMode)
        {
            _articleElapsedOffset = e.NewValue;
            SeekAudioForArticle(_articleElapsedOffset);
            if (_articleClock.IsRunning) _articleClock.Restart();
            UpdateLyrics(TimeSpan.FromSeconds(_articleElapsedOffset));
            return;
        }

        _audioPlayer.PlaybackSession.Position = TimeSpan.FromSeconds(e.NewValue);
        SyncBackgroundAudioToSong();
    }

    private void AudioPlayer_MediaOpened(MediaPlayer sender, object args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            PlaybackSlider.Maximum = Math.Max(1, sender.PlaybackSession.NaturalDuration.TotalSeconds);
            DurationText.Text = FormatTime(sender.PlaybackSession.NaturalDuration);
            UpdateArticleSettings();
            UpdateGenerateAvailability();
        });
    }

    private void AudioPlayer_MediaEnded(MediaPlayer sender, object args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_isArticleMode)
            {
                _backgroundPlayer.Pause();
                PlayIcon.Glyph = "\uE768";
            }
        });
    }

    private void UpdateLyrics(TimeSpan position)
    {
        if (UpdateIntroOverlay(position))
        {
            LyricsOverlay.Visibility = Visibility.Collapsed;
            return;
        }

        if (_isArticleMode)
        {
            var seconds = position.TotalSeconds;
            var pageIndex = FindArticlePageIndex(seconds);
            pageIndex = Math.Clamp(pageIndex, 0, Math.Max(0, _articlePages.Count - 1));
            CurrentLyricText.Text = _articlePages.Count == 0 ? string.Empty : _articlePages[pageIndex];
            CurrentLyricText.FontSize = ArticleFontSizeSlider.Value;
            CurrentLyricText.Opacity = 1;
            CurrentLyricText.Foreground = _lyricWhiteBrush;
            _lyricTranslate.Y = 0;
            CurrentLyricText.RenderTransform = _lyricTranslate;
            LyricsOverlay.Spacing = Math.Max(8, ArticleLineSpacingSlider.Value * 8);
            PreviousLyricText.Text = string.Empty;
            Previous2LyricText.Text = string.Empty;
            NextLyricText.Text = string.Empty;
            Next2LyricText.Text = pageIndex + 1 < _articlePages.Count ? "下一页 · " + _articlePages[pageIndex + 1][..Math.Min(36, _articlePages[pageIndex + 1].Length)] : string.Empty;
            LyricsOverlay.Visibility = _articlePages.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            return;
        }

        var current = SubtitleParser.CurrentIndexAt(_cues, position);
        var showFive = LyricWindowBox.SelectedIndex == 1;
        Previous2LyricText.Visibility = showFive ? Visibility.Visible : Visibility.Collapsed;
        Next2LyricText.Visibility = showFive ? Visibility.Visible : Visibility.Collapsed;
        if (current is null)
        {
            Previous2LyricText.Text = string.Empty;
            PreviousLyricText.Text = string.Empty;
            CurrentLyricText.Text = string.Empty;
            NextLyricText.Text = _cues.Count == 0 ? string.Empty : _cues[0].Text;
            Next2LyricText.Text = showFive && _cues.Count > 1 ? _cues[1].Text : string.Empty;
            LyricsOverlay.Visibility = _cues.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            return;
        }

        var index = current.Value;
        Previous2LyricText.Text = showFive && index > 1 ? _cues[index - 2].Text : string.Empty;
        PreviousLyricText.Text = index > 0 ? _cues[index - 1].Text : string.Empty;
        CurrentLyricText.Text = _cues[index].Text;
        NextLyricText.Text = index + 1 < _cues.Count ? _cues[index + 1].Text : string.Empty;
        Next2LyricText.Text = showFive && index + 2 < _cues.Count ? _cues[index + 2].Text : string.Empty;
        ApplyLyricTransitionFrame(_cues[index].Start.TotalSeconds, position.TotalSeconds);
        LyricsOverlay.Visibility = Visibility.Visible;
    }

    private void TextModeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ArticleTextBox is null || ImportArticleButton is null || ArticleParameters is null || PreviewModeText is null) return;
        _isArticleMode = TextModeBox.SelectedIndex == 1;
        _audioPlayer.Pause();
        if (_audioAsset is not null) _audioPlayer.PlaybackSession.Position = TimeSpan.Zero;
        PlayIcon.Glyph = "\uE768";
        _audioPlayer.IsLoopingEnabled = _isArticleMode;
        ArticleTextBox.Visibility = _isArticleMode ? Visibility.Visible : Visibility.Collapsed;
        ImportArticleButton.Visibility = _isArticleMode ? Visibility.Visible : Visibility.Collapsed;
        ArticleParameters.Visibility = _isArticleMode ? Visibility.Visible : Visibility.Collapsed;
        PreviewModeText.Text = _isArticleMode ? "文章阅读 · BGM 循环" : "歌词视频 · Ethereal";
        if (_backgroundAsset?.Kind == MediaKind.Video) _backgroundPlayer.Pause();
        _articleElapsedOffset = 0;
        _articleClock.Reset();
        RebuildArticlePages();
        if (!_isArticleMode) ApplyLyricsStyle();
        UpdateLyrics(CurrentTimelinePosition());
        UpdateGenerateAvailability();
    }

    private void AspectRatioBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PreviewFrame is null || AspectRatioBox.SelectedItem is not ComboBoxItem item) return;
        (PreviewFrame.Width, PreviewFrame.Height) = item.Tag?.ToString() switch
        {
            "Landscape169" => (640, 360),
            "Square" => (580, 580),
            _ => (360, 640)
        };
        var landscape = item.Tag?.ToString() == "Landscape169";
        IntroOverlay.HorizontalAlignment = landscape ? HorizontalAlignment.Left : HorizontalAlignment.Center;
        IntroOverlay.VerticalAlignment = VerticalAlignment.Top;
        IntroOverlay.Margin = landscape ? new Thickness(24, 24, 18, 0) : new Thickness(18, 70, 18, 0);
        IntroOverlay.MaxWidth = landscape ? 420 : 320;
        UpdateIntroText();
        UpdateArticleSettings();
        ApplyLyricsStyle();
    }

    private void ArticleSettings_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        UpdateArticleSettings();
        RebuildArticlePages();
        UpdateLyrics(CurrentTimelinePosition());
    }

    private void LanguageBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (FontBox is null || FontBox.Items.Count == 0) return;
        ArticleRateSlider.IsEnabled = LanguageBox.SelectedIndex == 0;
        var wanted = LanguageBox.SelectedIndex == 1
            ? "ms-appx:///Assets/Fonts/Cramaten-2.ttf#Cramaten"
            : "ms-appx:///Assets/Fonts/SikaDefault.ttf#素材集市康康体";
        var preferred = FontBox.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag?.ToString() == wanted);
        if (preferred is not null) FontBox.SelectedItem = preferred;
        UpdateArticleSettings();
        RebuildArticlePages();
        UpdateLyrics(CurrentTimelinePosition());
    }

    private void FontBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ApplySelectedFont();
        UpdateLyrics(CurrentTimelinePosition());
    }

    private void LyricsStyle_ValueChanged(object sender, RangeBaseValueChangedEventArgs e) => ApplyLyricsStyle();

    private void LyricsStyle_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ApplyLyricsStyle();
        if (ReferenceEquals(sender, LyricWindowBox))
            UpdateLyrics(CurrentTimelinePosition());
        else if (ReferenceEquals(sender, LyricAnimationBox))
            UpdateLyrics(CurrentTimelinePosition());
    }

    private void VisualSettings_ValueChanged(object sender, RangeBaseValueChangedEventArgs e) => ApplyAdvancedVisualSettings();

    private void VisualSettings_Toggled(object sender, RoutedEventArgs e) => ApplyAdvancedVisualSettings();

    private void VisualSettings_SelectionChanged(object sender, SelectionChangedEventArgs e) => ApplyAdvancedVisualSettings();

    private void ApplyAdvancedVisualSettings()
    {
        if (!_gpuInitialized || VisualizerPositionSlider is null || AtmospherePresetBox is null) return;
        var backgroundMotionEnabled = BackgroundMotionStyleBox.SelectedIndex != 3;
        BackgroundLifeSlider.IsEnabled = backgroundMotionEnabled;
        BackgroundCameraSlider.IsEnabled = backgroundMotionEnabled;
        BackgroundAudioWarpSlider.IsEnabled = backgroundMotionEnabled;
        BackgroundParallaxSlider.IsEnabled = backgroundMotionEnabled;
        BackgroundLightFlowSlider.IsEnabled = backgroundMotionEnabled;
        var settings = new[]
        {
            (float)VisualizerPositionSlider.Value, (float)VisualizerGlowSlider.Value,
            (float)VisualizerDensitySlider.Value, (float)VisualizerBrillianceSlider.Value,
            (float)VisualizerSmoothingSlider.Value, (float)VisualizerIntegrationSlider.Value,
            (float)VisualizerColorRichnessSlider.Value, (float)VisualizerTrailSlider.Value,
            0.55f, (float)MusicAwarenessSlider.Value, RainbowToggle.IsOn ? 1.0f : 0.0f, (float)RainbowIntensitySlider.Value,
            _scenePalettePrimary.X, _scenePalettePrimary.Y, _scenePalettePrimary.Z,
            _scenePaletteSecondary.X, _scenePaletteSecondary.Y, _scenePaletteSecondary.Z,
            (float)Math.Clamp(AtmospherePresetBox.SelectedIndex, 0, 16),
            (float)AtmosphereIntensitySlider.Value, (float)AtmosphereResponseSlider.Value,
            (float)AtmosphereDensitySlider.Value, (float)AtmosphereWaterlineSlider.Value,
            1.0f, 0.82f, 0.12f, (float)BackgroundDarknessSlider.Value,
            (float)OverlayRedSlider.Value, (float)OverlayGreenSlider.Value,
            (float)OverlayBlueSlider.Value, (float)OverlayOpacitySlider.Value,
            (float)BackgroundMotionStyleBox.SelectedIndex, (float)BackgroundLifeSlider.Value,
            (float)BackgroundCameraSlider.Value, (float)BackgroundAudioWarpSlider.Value,
            (float)BackgroundParallaxSlider.Value, (float)BackgroundLightFlowSlider.Value,
            (float)SubjectProtectionSlider.Value, SmartCompositionToggle.IsOn ? 1.0f : 0.0f,
            (float)SubjectEdgeLightSlider.Value, SmartBlurToggle.IsOn ? 1.0f : 0.0f
        };
        NvidiaGpuBridge.SetAdvancedVisualSettings(settings, settings.Length);
        NvidiaGpuBridge.SetAudioSmoothing((float)VisualizerSmoothingSlider.Value);
    }

    private void ApplyLyricsStyle()
    {
        if (LyricsOverlay is null || LyricFontSizeSlider is null || PreviewFrame is null ||
            LyricWidthSlider is null || LyricLineSpacingSlider is null || LyricInactiveOpacitySlider is null || LyricAlignmentBox is null || LyricGlowSlider is null) return;
        var size = LyricFontSizeSlider.Value;
        CurrentLyricText.FontSize = size;
        PreviousLyricText.FontSize = size * 0.68;
        NextLyricText.FontSize = size * 0.68;
        Previous2LyricText.FontSize = size * 0.52;
        Next2LyricText.FontSize = size * 0.52;
        LyricsOverlay.MaxWidth = PreviewFrame.Width * LyricWidthSlider.Value;
        LyricsOverlay.Spacing = Math.Max(3, size * (LyricLineSpacingSlider.Value - 1) * 0.16);
        PreviousLyricText.Opacity = Math.Max(LyricInactiveOpacitySlider.Value, 0.66);
        NextLyricText.Opacity = Math.Max(LyricInactiveOpacitySlider.Value, 0.66);
        Previous2LyricText.Opacity = Math.Max(LyricInactiveOpacitySlider.Value * 0.88, 0.42);
        Next2LyricText.Opacity = Math.Max(LyricInactiveOpacitySlider.Value * 0.88, 0.42);
        var outputScale = PreviewFrame.Width > PreviewFrame.Height ? 3.0 :
            Math.Abs(PreviewFrame.Width - PreviewFrame.Height) < 1 ? 1080.0 / 580.0 : 3.0;
        var lyricGlow = (float)LyricGlowSlider.Value;
        foreach (var text in LyricTextElements())
        {
            if (text.Shadow is not DropShadow shadow) continue;
            shadow.Opacity = lyricGlow * 0.20f;
            shadow.BlurRadius = (float)Math.Max(0.35, lyricGlow / outputScale);
        }
        var alignment = LyricAlignmentBox.SelectedIndex switch
        {
            0 => TextAlignment.Left,
            2 => TextAlignment.Right,
            _ => TextAlignment.Center
        };
        Previous2LyricText.TextAlignment = alignment;
        PreviousLyricText.TextAlignment = alignment;
        CurrentLyricText.TextAlignment = alignment;
        NextLyricText.TextAlignment = alignment;
        Next2LyricText.TextAlignment = alignment;
        LyricsOverlay.RenderTransform = new Microsoft.UI.Xaml.Media.TranslateTransform
        {
            Y = (LyricPositionSlider.Value - 0.5) * PreviewFrame.Height
        };
    }

    private void TemplateBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (VisualizerBox is null || VisualizerIntensitySlider is null || BlurSlider is null ||
            VisualizerPositionSlider is null || LyricFontSizeSlider is null) return;
        var profile = TemplateBox.SelectedIndex switch
        {
            0 => (visualizer: 4, intensity: 0.74, blur: 0.67, darkness: 0.22, position: 0.30, scale: 1.05, glow: 0.88, density: 0.58, color: 0.56, lyricSize: 44.0, lyricY: 0.58, animation: 0, lyricGlow: 0.66, inactive: 0.25, duration: 0.55, awareness: 0.94, smoothing: 0.78, brilliance: 0.68, integration: 0.84, trail: 0.24),
            1 => (visualizer: 5, intensity: 0.86, blur: 0.58, darkness: 0.22, position: 0.31, scale: 1.08, glow: 0.96, density: 0.86, color: 0.78, lyricSize: 42.0, lyricY: 0.60, animation: 4, lyricGlow: 0.82, inactive: 0.24, duration: 0.52, awareness: 0.96, smoothing: 0.72, brilliance: 0.76, integration: 0.66, trail: 0.30),
            2 => (visualizer: 0, intensity: 0.56, blur: 0.17, darkness: 0.18, position: 0.22, scale: 0.92, glow: 0.32, density: 0.42, color: 0.32, lyricSize: 38.0, lyricY: 0.56, animation: 1, lyricGlow: 0.28, inactive: 0.34, duration: 0.30, awareness: 0.78, smoothing: 0.82, brilliance: 0.38, integration: 0.88, trail: 0.12),
            3 => (visualizer: 6, intensity: 0.62, blur: 0.83, darkness: 0.34, position: 0.27, scale: 1.12, glow: 0.82, density: 0.48, color: 0.64, lyricSize: 50.0, lyricY: 0.59, animation: 0, lyricGlow: 0.74, inactive: 0.20, duration: 0.60, awareness: 0.92, smoothing: 0.75, brilliance: 0.70, integration: 0.82, trail: 0.30),
            _ => (visualizer: 1, intensity: 1.0, blur: 0.33, darkness: 0.20, position: 0.22, scale: 1.02, glow: 0.95, density: 0.82, color: 0.88, lyricSize: 40.0, lyricY: 0.60, animation: 3, lyricGlow: 0.80, inactive: 0.26, duration: 0.28, awareness: 1.0, smoothing: 0.42, brilliance: 0.84, integration: 0.54, trail: 0.32)
        };
        VisualizerBox.SelectedIndex = profile.visualizer;
        VisualizerIntensitySlider.Value = profile.intensity;
        BlurSlider.Value = profile.blur;
        BackgroundDarknessSlider.Value = profile.darkness;
        VisualizerPositionSlider.Value = profile.position;
        VisualizerScaleSlider.Value = profile.scale;
        VisualizerGlowSlider.Value = profile.glow;
        VisualizerDensitySlider.Value = profile.density;
        VisualizerColorRichnessSlider.Value = profile.color;
        MusicAwarenessSlider.Value = profile.awareness;
        VisualizerSmoothingSlider.Value = profile.smoothing;
        VisualizerBrillianceSlider.Value = profile.brilliance;
        VisualizerIntegrationSlider.Value = profile.integration;
        VisualizerTrailSlider.Value = profile.trail;
        LyricFontSizeSlider.Value = profile.lyricSize;
        LyricPositionSlider.Value = profile.lyricY;
        LyricAnimationBox.SelectedIndex = profile.animation;
        LyricGlowSlider.Value = profile.lyricGlow;
        LyricInactiveOpacitySlider.Value = profile.inactive;
        LyricAnimationDurationSlider.Value = profile.duration;
        ApplyLyricsStyle();
        ApplyAdvancedVisualSettings();
    }

    private void VideoSettings_Toggled(object sender, RoutedEventArgs e)
    {
        if (VideoLoopToggle is null || BackgroundVideoAudioToggle is null || BackgroundVideoVolumeSlider is null) return;
        _backgroundPlayer.IsLoopingEnabled = VideoLoopToggle.IsOn;
        _backgroundPlayer.IsMuted = !BackgroundVideoAudioToggle.IsOn;
        _backgroundPlayer.Volume = BackgroundVideoVolumeSlider.Value;
        BackgroundVideoVolumeSlider.IsEnabled = _backgroundAssets.Any(asset => asset.Kind == MediaKind.Video) && BackgroundVideoAudioToggle.IsOn;
        if (_audioPlayer.PlaybackSession.PlaybackState == MediaPlaybackState.Playing && _backgroundAssets.Any(asset => asset.Kind == MediaKind.Video))
        {
            if (BackgroundVideoAudioToggle.IsOn)
                SyncBackgroundAudioToSong();
            else
            {
                _backgroundPlayer.Pause();
                _backgroundAudioPlaying = false;
            }
        }
    }

    private void VideoSettings_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (BackgroundVideoVolumeSlider is not null) _backgroundPlayer.Volume = BackgroundVideoVolumeSlider.Value;
    }

    private void IntroSettings_Toggled(object sender, RoutedEventArgs e) => UpdateIntroText();

    private void UseAudioFilenameButton_Click(object sender, RoutedEventArgs e)
    {
        if (_audioAsset is not null)
        {
            _automaticSongTitle = Path.GetFileNameWithoutExtension(_audioAsset.Name);
            SongTitleBox.Text = _automaticSongTitle;
        }
    }

    private void IntroSettings_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        UpdateIntroText();
    }

    private void UpdateIntroText()
    {
        if (SongTitleBox is null || AuthorNameBox is null || ShowIntroDateToggle is null || IntroEnabledToggle is null ||
            IntroTitleText is null || IntroAuthorText is null || IntroDateText is null ||
            IntroTitleSizeSlider is null || PreviewFrame is null || AspectRatioBox is null) return;
        IntroTitleText.Text = string.IsNullOrWhiteSpace(SongTitleBox.Text) ? "" : SongTitleBox.Text.Trim();
        IntroAuthorText.Text = AuthorNameBox.Text.Trim();
        var previewWidth = PreviewFrame?.Width ?? 360;
        var outputWidth = AspectRatioBox?.SelectedIndex == 1 ? 1920.0 : 1080.0;
        IntroTitleText.FontSize = IntroTitleSizeSlider.Value * previewWidth / outputWidth;
        IntroAuthorText.FontSize = IntroTitleText.FontSize * 0.46;
        IntroDateText.FontSize = IntroTitleText.FontSize * 0.30;
        IntroDateText.Visibility = ShowIntroDateToggle.IsOn ? Visibility.Visible : Visibility.Collapsed;
        SongTitleBox.IsEnabled = IntroEnabledToggle.IsOn;
        UseAudioFilenameButton.IsEnabled = IntroEnabledToggle.IsOn && _audioAsset is not null;
        AuthorNameBox.IsEnabled = IntroEnabledToggle.IsOn;
        ShowIntroDateToggle.IsEnabled = IntroEnabledToggle.IsOn;
        IntroDurationSlider.IsEnabled = IntroEnabledToggle.IsOn;
        IntroTitleSizeSlider.IsEnabled = IntroEnabledToggle.IsOn;
        IntroAnimationDurationSlider.IsEnabled = IntroEnabledToggle.IsOn;
        IntroAnimationBox.IsEnabled = IntroEnabledToggle.IsOn;
    }

    private bool UpdateIntroOverlay(TimeSpan position)
    {
        var active = IntroEnabledToggle.IsOn && _audioAsset is not null &&
            !string.IsNullOrWhiteSpace(SongTitleBox.Text) && position.TotalSeconds < IntroDurationSlider.Value;
        if (!active)
        {
            IntroOverlay.Visibility = Visibility.Collapsed;
            return false;
        }

        UpdateIntroText();
        var fadeDuration = Math.Max(0.2, IntroAnimationDurationSlider.Value);
        var fadeIn = SmoothTransition(position.TotalSeconds / fadeDuration);
        var fadeOut = SmoothTransition((IntroDurationSlider.Value - position.TotalSeconds) / fadeDuration);
        IntroOverlay.Opacity = Math.Min(fadeIn, fadeOut);
        switch (IntroAnimationBox.SelectedIndex)
        {
            case 0:
                if (!ReferenceEquals(IntroOverlay.RenderTransform, _introTranslate)) IntroOverlay.RenderTransform = _introTranslate;
                _introTranslate.Y = (1 - fadeIn) * 12;
                break;
            case 2:
                if (!ReferenceEquals(IntroOverlay.RenderTransform, _introScale)) IntroOverlay.RenderTransform = _introScale;
                _introScale.CenterX = IntroOverlay.ActualWidth / 2;
                _introScale.CenterY = IntroOverlay.ActualHeight / 2;
                _introScale.ScaleX = _introScale.ScaleY = 0.97 + fadeIn * 0.03;
                break;
            default:
                if (!ReferenceEquals(IntroOverlay.RenderTransform, _introStatic)) IntroOverlay.RenderTransform = _introStatic;
                break;
        }
        IntroOverlay.Visibility = Visibility.Visible;
        return true;
    }

    private void ApplySelectedFont()
    {
        if (FontBox?.SelectedItem is not ComboBoxItem item) return;
        _selectedFontFamily = item.Tag?.ToString() ?? item.Content?.ToString() ?? "Segoe UI";
        var font = new Microsoft.UI.Xaml.Media.FontFamily(_selectedFontFamily);
        Previous2LyricText.FontFamily = font;
        PreviousLyricText.FontFamily = font;
        CurrentLyricText.FontFamily = font;
        NextLyricText.FontFamily = font;
        Next2LyricText.FontFamily = font;
        IntroTitleText.FontFamily = font;
        IntroAuthorText.FontFamily = font;
        IntroDateText.FontFamily = font;
    }

    private void InitializeTextShadows()
    {
        var compositor = ElementCompositionPreview.GetElementVisual(CurrentLyricText).Compositor;
        var lyricTexts = LyricTextElements();
        foreach (var text in lyricTexts.Concat([IntroTitleText, IntroAuthorText, IntroDateText]))
        {
            var shadow = compositor.CreateDropShadow();
            shadow.SourcePolicy = CompositionDropShadowSourcePolicy.InheritFromVisualContent;
            shadow.Color = Windows.UI.Color.FromArgb(255, 255, 255, 255);
            shadow.Offset = Vector3.Zero;
            shadow.Opacity = lyricTexts.Contains(text) ? 0 : 0.20f;
            shadow.BlurRadius = lyricTexts.Contains(text) ? 0 : 0.5f;
            text.Shadow = shadow;
        }
    }

    private TextBlock[] LyricTextElements() =>
        [Previous2LyricText, PreviousLyricText, CurrentLyricText, NextLyricText, Next2LyricText];

    private void UpdateArticleSettings()
    {
        if (ArticleRateSlider is null || ArticleTextBox is null) return;
        var english = LanguageBox.SelectedIndex == 1;
        var rate = english ? 150 : ArticleRateSlider.Value;
        var hold = ArticleEndHoldSlider.Value;
        _articleDurationSeconds = ArticleReadingTiming.DurationSeconds(ArticleTextBox.Text, english, rate, hold);
        ArticleDurationText.Text = $"预计阅读 {FormatTime(TimeSpan.FromSeconds(_articleDurationSeconds))} · BGM 自动循环";
        if (_isArticleMode)
        {
            PlaybackSlider.Maximum = Math.Max(1, _articleDurationSeconds);
            DurationText.Text = FormatTime(TimeSpan.FromSeconds(_articleDurationSeconds));
        }
    }

    private void RebuildArticlePages()
    {
        if (ArticleTextBox is null || ArticleRateSlider is null) return;
        var english = LanguageBox.SelectedIndex == 1;
        var targetUnits = Math.Clamp((int)(PreviewFrame.Width / Math.Max(16, ArticleFontSizeSlider.Value) * 3.2), 40, 180);
        _articlePages = ArticlePaginator.Paginate(ArticleTextBox.Text, english, targetUnits);
        var counts = _articlePages.Select(page => ArticleReadingTiming.CountReadingUnits(page, english)).ToArray();
        var readingTime = Math.Max(1, _articleDurationSeconds - ArticleEndHoldSlider.Value);
        _articleTimings = ArticleReadingTiming.AllocatePageTimings(counts, readingTime);
    }

    private int FindArticlePageIndex(double seconds)
    {
        var low = 0;
        var high = _articleTimings.Count - 1;
        var result = 0;
        while (low <= high)
        {
            var middle = low + ((high - low) / 2);
            if (_articleTimings[middle].StartSeconds <= seconds)
            {
                result = middle;
                low = middle + 1;
            }
            else
            {
                high = middle - 1;
            }
        }

        return Math.Clamp(result, 0, Math.Max(0, _articlePages.Count - 1));
    }

    private TimeSpan CurrentTimelinePosition()
    {
        if (_isArticleMode) return TimeSpan.FromSeconds(GetArticleElapsedSeconds());
        return _audioPlayer.PlaybackSession.Position;
    }

    private double GetArticleElapsedSeconds() => _articleElapsedOffset + (_articleClock.IsRunning ? _articleClock.Elapsed.TotalSeconds : 0);

    private void SeekAudioForArticle(double elapsedSeconds)
    {
        var duration = _audioPlayer.PlaybackSession.NaturalDuration.TotalSeconds;
        if (duration > 0) _audioPlayer.PlaybackSession.Position = TimeSpan.FromSeconds(elapsedSeconds % duration);
        SyncBackgroundAudioToSong();
    }

    private void SyncBackgroundAudioToSong()
    {
        if (_audioAsset is null || _backgroundAssets.Count == 0) return;
        UpdateBackgroundCarouselPreview(CurrentTimelinePosition().TotalSeconds);
    }

    private void ApplyLyricTransitionFrame(double cueStartSeconds, double currentSeconds)
    {
        var duration = Math.Max(0.18, LyricAnimationDurationSlider.Value);
        var progress = Math.Clamp((currentSeconds - cueStartSeconds) / duration, 0, 1);
        var eased = SmoothTransition(progress);
        var animation = LyricAnimationBox.SelectedIndex;
        CurrentLyricText.Opacity = animation switch
        {
            1 or 3 => eased,
            5 => 1,
            _ => 0.22 + eased * 0.78
        };
        if (animation == 4)
        {
            var color = Windows.UI.Color.FromArgb(255, (byte)Math.Round(197 + 58 * eased), (byte)Math.Round(176 + 79 * eased), 255);
            if (_lyricAccentBrush.Color != color) _lyricAccentBrush.Color = color;
            CurrentLyricText.Foreground = _lyricAccentBrush;
        }
        else
        {
            CurrentLyricText.Foreground = _lyricWhiteBrush;
        }
        if (CurrentLyricText.Shadow is DropShadow lyricShadow)
            lyricShadow.Color = animation == 4 ? _lyricAccentBrush.Color : _lyricWhiteBrush.Color;

        if (animation == 0)
        {
            _lyricTranslate.Y = (1 - eased) * 16;
            CurrentLyricText.RenderTransform = _lyricTranslate;
        }
        else if (animation is 2 or 4)
        {
            var start = animation == 4 ? 0.84 : 0.93;
            _lyricScale.CenterX = CurrentLyricText.ActualWidth / 2;
            _lyricScale.CenterY = CurrentLyricText.ActualHeight / 2;
            _lyricScale.ScaleX = _lyricScale.ScaleY = start + (1 - start) * eased;
            CurrentLyricText.RenderTransform = _lyricScale;
        }
        else
        {
            _lyricTranslate.Y = 0;
            CurrentLyricText.RenderTransform = _lyricTranslate;
        }
    }

    private static double SmoothTransition(double value)
    {
        var progress = Math.Clamp(value, 0, 1);
        return progress * progress * (3 - 2 * progress);
    }

    private void RenderVisualizer(double visualTime, double audioPosition, bool playing)
    {
        if (!_gpuInitialized || !_gpuPanelAttached || _exportInProgress) return;
        if (_backgroundAssets.Count == 0 && BackgroundVideo.Visibility == Visibility.Visible)
        {
            BackgroundVideo.Visibility = Visibility.Collapsed;
            VisualizerPanel.Visibility = Visibility.Visible;
        }
        NvidiaGpuBridge.SetAudioPlaybackState(audioPosition, playing ? 1 : 0);
        NvidiaGpuBridge.CopyAudioBands(_audioBands, _audioBands.Length);
        var kind = (uint)Math.Clamp(VisualizerBox.SelectedIndex, 0, 10);
        var result = NvidiaGpuBridge.Render(
            (float)visualTime,
            kind,
            (float)VisualizerIntensitySlider.Value,
            (float)BlurSlider.Value,
            (float)VignetteSlider.Value,
            (float)SaturationSlider.Value,
            SlowZoomToggle.IsOn ? 1.0f : 0.0f,
            (float)VisualizerScaleSlider.Value,
            RainbowToggle.IsOn ? 1.0f : 0.0f,
            _audioBands,
            _audioBands.Length);
        if (result < 0)
        {
            _gpuPanelAttached = false;
            GpuStatusText.Text = "Direct3D 预览暂不可用";
            SetStatus($"GPU 预览初始化失败（HRESULT 0x{result:X8}）。素材与歌词仍可编辑。");
        }
    }

    private void VisualizerPanel_Loaded(object sender, RoutedEventArgs e)
    {
        if (!_gpuInitialized || _gpuPanelAttached) return;
        try
        {
            var unknown = Marshal.GetIUnknownForObject(VisualizerPanel);
            int result;
            try
            {
                var width = Math.Max(1u, (uint)Math.Ceiling(VisualizerPanel.ActualWidth * VisualizerPanel.CompositionScaleX));
                var height = Math.Max(1u, (uint)Math.Ceiling(VisualizerPanel.ActualHeight * VisualizerPanel.CompositionScaleY));
                result = NvidiaGpuBridge.AttachPanel(unknown, width, height);
            }
            finally
            {
                Marshal.Release(unknown);
            }

            _gpuPanelAttached = result >= 0;
            if (!_gpuPanelAttached) SetStatus($"Direct3D 预览初始化失败（HRESULT 0x{result:X8}）。");
            else
            {
                VisualizerPanel.Visibility = Visibility.Visible;
                CommitGpuBackground();
            }
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException)
        {
            SetStatus($"无法连接 Direct3D 预览：{exception.Message}");
        }
    }

    private void VisualizerPanel_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_gpuInitialized || !_gpuPanelAttached) return;
        var width = Math.Max(1u, (uint)Math.Ceiling(e.NewSize.Width * VisualizerPanel.CompositionScaleX));
        var height = Math.Max(1u, (uint)Math.Ceiling(e.NewSize.Height * VisualizerPanel.CompositionScaleY));
        var result = NvidiaGpuBridge.ResizePanel(width, height);
        if (result < 0) _gpuPanelAttached = false;
    }

    private void RegisterBundledFonts()
    {
        var fontsDirectory = Path.Combine(AppContext.BaseDirectory, "Assets", "Fonts");
        foreach (var fontName in new[] { "SikaDefault.ttf", "Cramaten-2.ttf" })
        {
            var path = Path.Combine(fontsDirectory, fontName);
            if (File.Exists(path)) PrivateFontRegistrar.TryRegister(path, out _);
        }

        var importedDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SikaMTV", "Fonts");
        if (!Directory.Exists(importedDirectory)) return;
        foreach (var path in Directory.EnumerateFiles(importedDirectory)
                     .Where(path => Path.GetExtension(path).Equals(".ttf", StringComparison.OrdinalIgnoreCase) ||
                                    Path.GetExtension(path).Equals(".otf", StringComparison.OrdinalIgnoreCase))
                     .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            if (!PrivateFontRegistrar.TryRegister(path, out _)) continue;
            var family = new System.Text.StringBuilder(256);
            var familyName = NvidiaGpuBridge.GetFontFamily(path, family, family.Capacity) >= 0 && family.Length > 0
                ? family.ToString()
                : Path.GetFileNameWithoutExtension(path);
            FontBox.Items.Add(new ComboBoxItem
            {
                Content = $"{familyName}（已导入）",
                Tag = $"{new Uri(path).AbsoluteUri}#{Uri.EscapeDataString(familyName)}"
            });
        }
    }

    private void CommitGpuBackground()
    {
        if (!_gpuInitialized || !_gpuPanelAttached || _backgroundPixels is null || _backgroundPixelWidth == 0 || _backgroundPixelHeight == 0)
            return;
        var stride = _backgroundPixelWidth * 4;
        var result = NvidiaGpuBridge.SetBackgroundImage(_backgroundPixels, _backgroundPixelWidth, _backgroundPixelHeight, stride);
        if (result >= 0)
        {
            if (_backgroundAsset is not null && _backgroundImageCache.TryGetValue(_backgroundAsset.File.Path, out var data))
                NvidiaGpuBridge.SetSubjectMask(data.SubjectMask, SceneSubjectAnalyzer.MaskSize, SceneSubjectAnalyzer.MaskSize, SceneSubjectAnalyzer.MaskSize, 0);
            BackgroundImage.Visibility = Visibility.Collapsed;
            VisualizerPanel.Visibility = Visibility.Visible;
        }
        else
        {
            SetStatus($"背景 GPU 上传失败（HRESULT 0x{result:X8}），继续使用系统图像预览。");
        }
    }

    private void AssetSearchBox_TextChanged(object sender, TextChangedEventArgs e) => RefreshAssetFilter();

    private void RefreshAssetFilter()
    {
        if (AssetsList is null) return;
        var query = AssetSearchBox.Text.Trim();
        _assets.Clear();
        foreach (var entry in _allAssets.Where(entry => query.Length == 0 || entry.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
            _assets.Add(entry);
        AssetCountText.Text = $"{_allAssets.Count} 个素材";
    }

    private async void PreviewDropSurface_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        await AddFilesToLibraryAsync(items.OfType<StorageFile>());
        PreviewStatusText.Text = "素材已导入资源库，可加入项目工作区";
    }

    private void AssetsList_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        var files = e.Items.OfType<MediaEntry>().Select(entry => entry.File).ToArray();
        if (files.Length > 0) e.Data.SetStorageItems(files);
    }

    private void Workspace_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "加入项目工作区";
        e.DragUIOverride.IsCaptionVisible = true;
    }

    private async void Workspace_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var files = (await e.DataView.GetStorageItemsAsync()).OfType<StorageFile>().ToArray();
        await AddFilesToLibraryAsync(files);
        foreach (var file in files)
        {
            var entry = _allAssets.FirstOrDefault(asset => asset.File.Path.Equals(file.Path, StringComparison.OrdinalIgnoreCase));
            if (entry is not null) await AssignAssetToProjectAsync(entry);
        }
        SetStatus("拖入的素材已加入项目工作区");
    }

    private void PreviewDropSurface_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "添加到 SikaMTV 素材库";
        e.DragUIOverride.IsCaptionVisible = true;
    }

    private async void GenerateButton_Click(object sender, RoutedEventArgs e)
    {
        if (_exportInProgress)
        {
            GenerateButton.IsEnabled = false;
            ExportStatusText.Text = "正在停止导出…";
            NvidiaGpuBridge.CancelVideoExport();
            return;
        }

        if (_backgroundAsset is null || _audioAsset is null)
        {
            SetStatus("请先在项目工作区加入背景与音乐。");
            return;
        }

        var audioDuration = _audioPlayer.PlaybackSession.NaturalDuration.TotalSeconds;
        var outputDuration = _isArticleMode ? _articleDurationSeconds : audioDuration;
        if (audioDuration <= 0 || outputDuration <= 0)
        {
            SetStatus("音频仍在读取时长，请稍候再生成。");
            return;
        }
        if (!_gpuInitialized)
        {
            SetStatus("Direct3D 渲染模块尚未启动，无法生成视频。");
            return;
        }
        if (_backgroundAsset.Kind == MediaKind.Image)
        {
            if (_backgroundPixels is null || _backgroundPixelWidth == 0 || _backgroundPixelHeight == 0)
            {
                SetStatus("背景图片尚未解码完成，请稍候再生成。");
                return;
            }
            var upload = NvidiaGpuBridge.SetBackgroundImage(_backgroundPixels, _backgroundPixelWidth, _backgroundPixelHeight, _backgroundPixelWidth * 4);
            if (upload < 0)
            {
                SetStatus($"背景图片无法上传到 GPU（HRESULT 0x{upload:X8}）。");
                return;
            }
        }

        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.VideosLibrary,
            SuggestedFileName = string.IsNullOrWhiteSpace(SongTitleBox.Text) ? "SikaMTV" : SongTitleBox.Text.Trim()
        };
        picker.FileTypeChoices.Add("MP4 视频", [".mp4"]);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var destination = await picker.PickSaveFileAsync();
        if (destination is null) return;

        var selectedRatio = (AspectRatioBox.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        var (width, height) = selectedRatio switch
        {
            "Landscape169" => (1920u, 1080u),
            "Square" => (1080u, 1080u),
            _ => (1080u, 1920u)
        };
        SetStatus("正在准备背景素材与智能配色…");
        string backgroundManifest;
        try
        {
            backgroundManifest = await BuildBackgroundManifestAsync();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            SetStatus($"准备背景素材失败：{exception.Message}");
            return;
        }
        var fontFamily = ExportFontFamily();
        var timeline = BuildExportTimeline();
        IntroDateText.Text = DateTime.Now.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var result = NvidiaGpuBridge.StartVideoExport(
            backgroundManifest, _audioAsset.File.Path, destination.Path, timeline,
            SongTitleBox.Text.Trim(), AuthorNameBox.Text.Trim(), IntroDateText.Text, fontFamily,
            audioDuration, outputDuration, width, height,
            (uint)Math.Clamp(VisualizerBox.SelectedIndex, 0, 10),
            (float)VisualizerIntensitySlider.Value, (float)BlurSlider.Value, (float)VignetteSlider.Value,
            (float)SaturationSlider.Value, SlowZoomToggle.IsOn ? 1.0f : 0.0f,
            (float)VisualizerScaleSlider.Value, RainbowToggle.IsOn ? 1.0f : 0.0f,
            (float)VisualizerSmoothingSlider.Value,
            (float)LyricFontSizeSlider.Value, (float)LyricPositionSlider.Value,
            (float)LyricWidthSlider.Value, (float)LyricLineSpacingSlider.Value,
            (float)LyricInactiveOpacitySlider.Value, (float)LyricGlowSlider.Value,
            (float)LyricAnimationDurationSlider.Value, LyricAlignmentBox.SelectedIndex,
            LyricWindowBox.SelectedIndex == 1 ? 5 : 3, LyricAnimationBox.SelectedIndex,
            _isArticleMode ? 1 : 0, (float)ArticleFontSizeSlider.Value, (float)ArticleLineSpacingSlider.Value,
            (float)IntroDurationSlider.Value, (float)IntroTitleSizeSlider.Value,
            (float)IntroAnimationDurationSlider.Value, IntroEnabledToggle.IsOn ? 1 : 0,
            ShowIntroDateToggle.IsOn ? 1 : 0,
            IntroAnimationBox.SelectedIndex, VideoLoopToggle.IsOn ? 1 : 0,
            BackgroundTransitionBox.SelectedIndex, (float)BackgroundTransitionDurationSlider.Value,
            BackgroundVideoAudioToggle.IsOn ? 1 : 0, (float)BackgroundVideoVolumeSlider.Value);
        if (result < 0)
        {
            SetStatus($"无法开始视频生成（HRESULT 0x{result:X8}）。");
            return;
        }

        _exportDestination = destination;
        _exportInProgress = true;
        ExportProgressBar.Value = 0;
        ExportStatusText.Text = "正在分析音乐并初始化 GPU 编码…";
        ExportProgressPanel.Visibility = Visibility.Visible;
        GenerateLabel.Text = "停止生成";
        GenerateIcon.Glyph = "\uE71A";
        GenerateButton.IsEnabled = true;
        SetExportInputsEnabled(false);
        SetStatus("正在使用 Direct3D GPU 渲染画面，并通过 Media Foundation 硬件编码优先生成 MP4。");
        _exportProgressTimer.Start();
    }

    private void ExportProgressTimer_Tick(DispatcherQueueTimer sender, object args)
    {
        NvidiaGpuBridge.GetVideoExportProgress(out var progress, out var isRunning, out var result);
        ExportProgressBar.Value = Math.Clamp(progress * 100.0, 0, 100);
        if (isRunning != 0)
        {
            ExportStatusText.Text = progress <= 0.001f ? "正在分析音乐并初始化 GPU 编码…" : $"正在生成视频 · {progress:P0}";
            return;
        }

        _exportProgressTimer.Stop();
        _exportInProgress = false;
        GenerateLabel.Text = "生成视频";
        GenerateIcon.Glyph = "\uE768";
        SetExportInputsEnabled(true);
        ExportProgressPanel.Visibility = Visibility.Collapsed;
        UpdateGenerateAvailability();
        if (result >= 0)
        {
            ExportProgressBar.Value = 100;
            SetStatus("视频生成完成，可播放或在文件资源管理器中查看。");
            if (_exportDestination is not null) _ = ShowExportCompletionAsync(_exportDestination);
        }
        else if (result == unchecked((int)0x800704C7))
        {
            SetStatus("视频生成已取消。");
        }
        else
        {
            SetStatus($"视频生成失败（HRESULT 0x{result:X8}）。请检查音频格式、磁盘空间与 GPU 驱动后重试。");
        }
    }

    private void SetExportInputsEnabled(bool enabled)
    {
        AssetPanel.IsHitTestVisible = enabled;
        SettingsPanel.IsHitTestVisible = enabled;
        PreviewDropSurface.IsHitTestVisible = enabled;
        ImportAssetsButton.IsEnabled = enabled;
        ClearBackgroundButton.IsEnabled = enabled;
        ClearAudioButton.IsEnabled = enabled;
        ClearTextButton.IsEnabled = enabled;
        ClearWorkspaceButton.IsEnabled = enabled;
        AspectRatioBox.IsEnabled = enabled;
        PlayButton.IsEnabled = enabled;
        PlaybackSlider.IsEnabled = enabled;
    }

    private async Task ShowExportCompletionAsync(StorageFile file)
    {
        var dialog = new ContentDialog
        {
            Title = "视频已生成",
            Content = file.Path,
            PrimaryButtonText = "播放视频",
            SecondaryButtonText = "在文件资源管理器中显示",
            CloseButtonText = "完成",
            XamlRoot = PreviewDropSurface.XamlRoot
        };
        var choice = await dialog.ShowAsync();
        if (choice == ContentDialogResult.Primary)
        {
            await Windows.System.Launcher.LaunchFileAsync(file);
        }
        else if (choice == ContentDialogResult.Secondary)
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{file.Path}\"") { UseShellExecute = true });
        }
    }

    private string ExportFontFamily()
    {
        var value = _selectedFontFamily;
        var separator = value.LastIndexOf('#');
        if (separator >= 0 && separator + 1 < value.Length) value = value[(separator + 1)..];
        return Uri.UnescapeDataString(value);
    }

    private string BuildExportTimeline()
    {
        var builder = new StringBuilder();
        if (_isArticleMode)
        {
            for (var index = 0; index < Math.Min(_articlePages.Count, _articleTimings.Count); index++)
            {
                var timing = _articleTimings[index];
                builder.Append(timing.StartSeconds.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)).Append('\t')
                    .Append(timing.EndSeconds.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)).Append('\t')
                    .Append(OneLine(_articlePages[index])).Append('\n');
            }
        }
        else
        {
            for (var index = 0; index < _cues.Count; index++)
            {
                var cue = _cues[index];
                var end = cue.End > cue.Start ? cue.End : index + 1 < _cues.Count ? _cues[index + 1].Start : cue.Start + TimeSpan.FromSeconds(4);
                builder.Append(cue.Start.TotalSeconds.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)).Append('\t')
                    .Append(end.TotalSeconds.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)).Append('\t')
                    .Append(OneLine(cue.Text)).Append('\n');
            }
        }
        return builder.ToString();
    }

    private static string OneLine(string value) => string.Join(' ',
        value.Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ')
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private void InitializeNvidiaStatus()
    {
        try
        {
            var name = new System.Text.StringBuilder(256);
            var isNvidia = 0;
            var result = NvidiaGpuBridge.Initialize(name, name.Capacity, out isNvidia);
            if (result == 0)
            {
                _gpuInitialized = true;
                ApplyAdvancedVisualSettings();
                GpuStatusText.Text = isNvidia == 1 ? $"NVIDIA GPU · {name}" : $"Direct3D GPU · {name}";
                GpuStatusDot.Fill = isNvidia == 1 ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 118, 207, 155)) : new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 185, 171, 255));
            }
            else
            {
                GpuStatusText.Text = "系统图形加速";
            }
        }
        catch (DllNotFoundException)
        {
            GpuStatusText.Text = "Direct3D · GPU 后端待构建";
        }
        catch (EntryPointNotFoundException)
        {
            GpuStatusText.Text = "Direct3D · GPU 后端版本不匹配";
        }
    }

    private void UpdateGenerateAvailability()
    {
        var hasText = _isArticleMode ? !string.IsNullOrWhiteSpace(ArticleTextBox.Text) : _cues.Count > 0;
        GenerateButton.IsEnabled = _backgroundAssets.Count > 0 && _audioAsset is not null && hasText;
    }

    private void SetStatus(string message)
    {
        PreviewStatusText.Text = message;
    }

    private static string FormatTime(TimeSpan value) => $"{(int)value.TotalMinutes:00}:{value.Seconds:00}";

    private static readonly string[] SupportedExtensions =
    [
        ".jpg", ".jpeg", ".png", ".heic", ".mp4", ".mov", ".m4v",
        ".wav", ".mp3", ".m4a", ".aac", ".aiff", ".flac",
        ".lrc", ".srt", ".txt", ".md", ".markdown"
    ];
}

internal readonly record struct BackgroundPreviewState(
    int CurrentIndex, int? NextIndex, double CurrentLocalTime, double NextLocalTime,
    double SegmentDuration, float TransitionProgress, int TransitionKind);

internal static class BackgroundPreviewTimeline
{
    internal static BackgroundPreviewState At(double time, double duration, int itemCount,
        int transition, double transitionDuration, double singleVideoDuration, bool loopSingleVideo)
    {
        if (itemCount <= 0) return new BackgroundPreviewState(0, null, 0, 0, 0, 0, 0);
        if (itemCount == 1 && !loopSingleVideo) singleVideoDuration = 0;
        if (itemCount == 1 && singleVideoDuration > 0)
        {
            var blend = Math.Min(Math.Max(0.2, transitionDuration), singleVideoDuration * 0.25);
            var cycle = Math.Max(0.001, singleVideoDuration - blend);
            var safeTime = Math.Max(0, time);
            var playhead = safeTime < singleVideoDuration
                ? safeTime
                : (safeTime - singleVideoDuration) % cycle + blend;
            if (playhead >= singleVideoDuration - blend)
            {
                var nextTime = Math.Max(0, playhead - (singleVideoDuration - blend));
                return new BackgroundPreviewState(0, 0, playhead, nextTime,
                    singleVideoDuration, (float)Math.Clamp(nextTime / blend, 0, 1), 1);
            }
            return new BackgroundPreviewState(0, null, playhead, 0, singleVideoDuration, 0, 0);
        }

        if (itemCount == 1 || duration <= 0)
            return new BackgroundPreviewState(0, null, Math.Max(0, time), 0, Math.Max(duration, 1), 0, 0);

        var segment = duration / itemCount;
        var clamped = Math.Clamp(time, 0, Math.Max(0, duration - 0.000001));
        var active = Math.Min(itemCount - 1, (int)(clamped / segment));
        var local = clamped - active * segment;
        var blendDuration = Math.Min(Math.Max(0.05, transitionDuration), segment * 0.45);
        if (transition != 3 && active > 0 && local < blendDuration)
            return new BackgroundPreviewState(active - 1, active, segment, local,
                segment, (float)Math.Clamp(local / blendDuration, 0, 1), Math.Clamp(transition + 1, 1, 3));
        return new BackgroundPreviewState(active, null, local, 0, segment, 0, 0);
    }
}

public enum MediaKind { Image, Video, Audio, Subtitle }

public sealed class MediaEntry(StorageFile file, MediaKind kind)
{
    public StorageFile File { get; } = file;
    public MediaKind Kind { get; } = kind;
    public string Name => File.Name;
    public string TypeLabel => Kind switch
    {
        MediaKind.Image => "图片背景",
        MediaKind.Video => "视频背景",
        MediaKind.Audio => "音乐",
        _ => Path.GetExtension(Name).TrimStart('.').ToUpperInvariant() + " 字幕"
    };
    public string IconGlyph => Kind switch
    {
        MediaKind.Image => "\uEB9F",
        MediaKind.Video => "\uE714",
        MediaKind.Audio => "\uE8D6",
        _ => "\uE8A5"
    };

    public static MediaKind? Classify(string extension) => extension.ToLowerInvariant() switch
    {
        ".jpg" or ".jpeg" or ".png" or ".heic" => MediaKind.Image,
        ".mp4" or ".mov" or ".m4v" => MediaKind.Video,
        ".wav" or ".mp3" or ".m4a" or ".aac" or ".aiff" or ".flac" => MediaKind.Audio,
        ".lrc" or ".srt" or ".txt" or ".md" or ".markdown" => MediaKind.Subtitle,
        _ => null
    };
}

internal static class NvidiaGpuBridge
{
    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_InitializeGpu", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    internal static extern int Initialize([Out] System.Text.StringBuilder adapterName, int capacity, out int isNvidia);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_AttachSwapChainPanel", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int AttachPanel(nint panel, uint width, uint height);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_ResizeSwapChainPanel", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int ResizePanel(uint width, uint height);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetBackgroundImage", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SetBackgroundImage([In] byte[] pixels, uint width, uint height, uint stride);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetBackgroundImageSecondary", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SetBackgroundImageSecondary([In] byte[] pixels, uint width, uint height, uint stride);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetSubjectMask", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SetSubjectMask([In] byte[] pixels, uint width, uint height, uint stride, int secondary);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetBackgroundTransition", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SetBackgroundTransition(float progress, int transitionKind);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetBackgroundMotionTimeline", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SetBackgroundMotionTimeline(float currentProgress, float currentReactivity,
        float nextProgress, float nextReactivity);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetScenePalette", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SetScenePalette(float primaryRed, float primaryGreen, float primaryBlue,
        float secondaryRed, float secondaryGreen, float secondaryBlue);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_ClearBackgroundImage", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void ClearBackgroundImage();

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetAdvancedVisualSettings", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SetAdvancedVisualSettings([In] float[] settings, int count);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_RenderVisualizer", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int Render(float timeSeconds, uint visualizerKind, float intensity, float blur, float vignette, float saturation, float slowZoom, float visualizerScale, float rainbow, [In] float[] bands, int bandCount);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_UpdatePreviewBackgroundVideo", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    internal static extern int UpdatePreviewBackgroundVideo([MarshalAs(UnmanagedType.LPWStr)] string path, double timeSeconds, int loop);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_UpdatePreviewBackgroundCarousel", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    internal static extern int UpdatePreviewBackgroundCarousel(
        [MarshalAs(UnmanagedType.LPWStr)] string primaryVideoPath, double primaryTime,
        [MarshalAs(UnmanagedType.LPWStr)] string secondaryVideoPath, double secondaryTime,
        int loop, float transitionProgress, int transitionKind);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_StopPreviewBackgroundVideo", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void StopPreviewBackgroundVideo();

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_StartVideoExport", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    internal static extern int StartVideoExport(
        [MarshalAs(UnmanagedType.LPWStr)] string backgroundVideoPath,
        [MarshalAs(UnmanagedType.LPWStr)] string audioPath,
        [MarshalAs(UnmanagedType.LPWStr)] string outputPath,
        [MarshalAs(UnmanagedType.LPWStr)] string textTimeline,
        [MarshalAs(UnmanagedType.LPWStr)] string title,
        [MarshalAs(UnmanagedType.LPWStr)] string author,
        [MarshalAs(UnmanagedType.LPWStr)] string date,
        [MarshalAs(UnmanagedType.LPWStr)] string fontFamily,
        double audioDurationSeconds,
        double outputDurationSeconds,
        uint width,
        uint height,
        uint visualizerKind,
        float intensity,
        float blur,
        float vignette,
        float saturation,
        float slowZoom,
        float visualizerScale,
        float rainbow,
        float visualizerSmoothing,
        float lyricFontSize,
        float lyricPosition,
        float lyricWidth,
        float lyricLineSpacing,
        float lyricInactiveOpacity,
        float lyricGlow,
        float lyricAnimationDuration,
        int lyricAlignment,
        int lyricWindowCount,
        int lyricAnimation,
        int articleMode,
        float articleFontSize,
        float articleLineSpacing,
        float introDuration,
        float introTitleSize,
        float introAnimationDuration,
        int introEnabled,
        int showIntroDate,
        int introAnimation,
        int loopBackgroundVideo,
        int backgroundTransition,
        float backgroundTransitionDuration,
        int backgroundAudioEnabled,
        float backgroundAudioVolume);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_GetVideoExportProgress", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void GetVideoExportProgress(out float progress, out int isRunning, out int result);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_CancelVideoExport", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void CancelVideoExport();

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetAudioSource", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    internal static extern void SetAudioSource(string? path);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetAudioPlaybackState", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SetAudioPlaybackState(double positionSeconds, int isPlaying);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_SetAudioSmoothing", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SetAudioSmoothing(float amount);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_CopyAudioBands", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void CopyAudioBands([Out] float[] bands, int capacity);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_GetFontFamily", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    internal static extern int GetFontFamily(string path, [Out] System.Text.StringBuilder familyName, int capacity);

    [DllImport("SikaMTV.Gpu.dll", EntryPoint = "SikaMTV_ShutdownGpu", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void Shutdown();
}

internal static class PrivateFontRegistrar
{
    private const uint PrivateFont = 0x10;

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int AddFontResourceEx(string fileName, uint flags, nint reserved);

    internal static bool TryRegister(string path, out string error)
    {
        if (AddFontResourceEx(path, PrivateFont, 0) > 0)
        {
            error = string.Empty;
            return true;
        }

        error = Marshal.GetLastWin32Error().ToString(System.Globalization.CultureInfo.InvariantCulture);
        return false;
    }
}
