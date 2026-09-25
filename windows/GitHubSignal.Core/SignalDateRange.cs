namespace GitHubSignal.Core;

public static class SignalDateRange
{
    // Calendar days in the user's timezone, including today.
    public static bool Includes(DateTimeOffset date, int days, DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        if (days is not (1 or 7 or 30)) return true;
        zone ??= TimeZoneInfo.Local;
        var start = TimeZoneInfo.ConvertTime(now, zone).Date.AddDays(1 - days);
        var localDate = TimeZoneInfo.ConvertTime(date, zone).DateTime;
        return localDate >= start && localDate < TimeZoneInfo.ConvertTime(now, zone).Date.AddDays(1);
    }
}
