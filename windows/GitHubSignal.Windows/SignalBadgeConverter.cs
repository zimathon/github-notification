using System;
using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;
using GitHubSignal.Core;

namespace GitHubSignal.Windows;

public sealed class SignalBadgeConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var signal = value as Signal;
        var colors = (value as PullRequestInfo)?.Status switch {
            "open" => ("#176B3A", "#E7F4EA"),
            "merged" => ("#6B3FA0", "#F1EAF9"),
            "closed" => ("#A72B30", "#FBEAEC"),
            _ => signal?.ReviewState switch {
                "APPROVED" => ("#176B3A", "#E7F4EA"),
                "CHANGES_REQUESTED" => ("#965000", "#FFF1D6"),
                "DISMISSED" => ("#52606D", "#EEF1F4"),
                _ => signal?.Kind switch {
                    SignalKind.Mention => ("#6B3FA0", "#F1EAF9"),
                    SignalKind.ReviewRequest => ("#4946A6", "#EEEDFA"),
                    SignalKind.Comment => ("#1E5AA6", "#E8F0FC"),
                    _ => ("#52606D", "#EEF1F4")
                }
            }
        };
        var brush = (SolidColorBrush)new BrushConverter().ConvertFromString(
            parameter as string == "background" ? colors.Item2 : colors.Item1)!;
        brush.Freeze();
        return brush;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
