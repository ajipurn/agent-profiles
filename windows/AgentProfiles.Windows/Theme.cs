using Microsoft.Win32;
using System.Windows.Media;

namespace AgentProfiles.Windows;

/// <summary>Colors following Windows' light or dark app mode.</summary>
public static class Theme
{
    public static bool IsLight
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is not int value || value != 0;
        }
    }

    /// <summary>The taskbar has its own light or dark setting, which the tray icon follows.</summary>
    public static bool TaskbarIsLight
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
        }
    }

    static Brush Rgb(byte r, byte g, byte b, byte a = 255)
    {
        var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
        brush.Freeze();
        return brush;
    }

    public static Brush Window => IsLight ? Rgb(243, 243, 243) : Rgb(32, 32, 32);
    public static Brush Card => IsLight ? Rgb(255, 255, 255) : Rgb(44, 44, 44);
    public static Brush CardBorder => IsLight ? Rgb(0, 0, 0, 20) : Rgb(255, 255, 255, 18);
    public static Brush Text => IsLight ? Rgb(26, 26, 26) : Rgb(242, 242, 242);
    public static Brush Secondary => IsLight ? Rgb(96, 96, 96) : Rgb(170, 170, 170);
    public static Brush Track => IsLight ? Rgb(0, 0, 0, 22) : Rgb(255, 255, 255, 30);
    public static Brush Accent => Rgb(76, 139, 245);
    public static Brush Selected => IsLight ? Rgb(255, 255, 255) : Rgb(62, 62, 62);
    public static Brush Hover => IsLight ? Rgb(0, 0, 0, 12) : Rgb(255, 255, 255, 16);

    /// <summary>Blue while there is room, yellow at a quarter left, red at a tenth.</summary>
    public static Brush Level(double? left) => left switch
    {
        null => Rgb(140, 140, 140),
        <= 10 => Rgb(232, 72, 64),
        <= 25 => Rgb(240, 176, 40),
        _ => Accent,
    };

    public static Brush Hex(string hex)
    {
        try
        {
            var color = (Color)ColorConverter.ConvertFromString(hex);
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            return brush;
        }
        catch (System.FormatException)
        {
            return Accent;
        }
    }
}
