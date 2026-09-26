using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using WinRT.Interop;

namespace SikaMTV.Win11;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
        var handle = WindowNative.GetWindowHandle(_window);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(handle);
        AppWindow.GetFromWindowId(windowId).Resize(new SizeInt32(1480, 960));
    }
}
