using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using GitHubSignal.Core;

namespace GitHubSignal.Windows;

public sealed record FilterOption(string Value, string Label);
public sealed record ThreadRow(string Key, List<Signal> Signals, PullRequestInfo? PullRequest = null)
{
    public Signal Latest => Signals[0];
    public string Repository => Latest.Repository;
    public string Title => Latest.Title;
    public string Url => Latest.Url;
    public string Preview => Latest.Preview;
    public bool HasPending => Signals.Any(x => !x.Acknowledged);
    public string Summary => $"@{Latest.Actor} · {Latest.TimeLabel}";
    public string PrLabel => PullRequest?.Label ?? "状態未取得";
    public Visibility PrVisibility => PullRequestInfo.ApiPath(Latest) is null ? Visibility.Collapsed : Visibility.Visible;
    public string PrHelp => PullRequest is null ? "PRの状態を順次取得します" : $"PRの状態 · 最終取得 {PullRequest.CheckedAt.ToLocalTime():g}";
    public string DetailsLabel => $"通知の詳細（{Signals.Count}件）";
}

public partial class MainWindow : Window
{
    private readonly InboxEngine engine;
    private readonly bool demo;
    private readonly CancellationToken lifetime;
    private bool refreshing;
    private DateTimeOffset nextUpdateCheck;
    private bool checkingUpdate;
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(15) };
    public static string Version => typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "0.2.0";
    public event Action? QuitRequested;
    public event Action? TestNotificationRequested;
    public event Func<string, bool>? UpdateNotificationRequested;
    public int VisibleThreadCount => ThreadList.Items.Count;
    public MainWindow(InboxEngine engine, bool demo, CancellationToken lifetime)
    {
        this.engine = engine; this.demo = demo; this.lifetime = lifetime;
        InitializeComponent();
        refreshing = true;
        KindFilter.ItemsSource = new[] { new FilterOption("", "種類：すべて") }.Concat(Enum.GetValues<SignalKind>().Select(x => new FilterOption(x.ToString(), Rules.Label(x))));
        KindFilter.SelectedValue = "";
        DateFilter.ItemsSource = new[] { new FilterOption("0", "全期間"), new FilterOption("1", "今日"), new FilterOption("7", "過去7日"), new FilterOption("30", "過去30日") };
        DateFilter.SelectedValue = engine.State.Settings.ViewDays is 1 or 7 or 30 ? engine.State.Settings.ViewDays.ToString() : "0";
        refreshing = false;
        Refresh();
        engine.Changed += Refresh;
        Closed += (_, _) => { engine.Changed -= Refresh; http.Dispose(); };
        if (!demo) Loaded += async (_, _) => await CheckUpdateAsync();
    }
    public void ShowInbox() { Show(); WindowState = WindowState.Normal; Activate(); if (!demo) _ = CheckUpdateAsync(); }
    private void Refresh()
    {
        refreshing = true;
        var signals = engine.Included.ToList();
        var owner = engine.State.Settings.ViewOrganization;
        SetOptions(OwnerFilter, signals.Select(x => x.Repository.Split('/')[0]), owner, "組織：すべて");
        owner = (string?)OwnerFilter.SelectedValue ?? "";
        SetOptions(RepositoryFilter, signals.Where(x => owner == "" || x.Repository.Split('/')[0] == owner).Select(x => x.Repository), engine.State.Settings.ViewRepository, "リポジトリ：すべて");
        CountLabel.Text = $"未確認 {engine.PendingCount}件";
        ToggleButton.Content = engine.State.Enabled ? "停止" : "開始";
        ToggleButton.IsEnabled = engine.Ready && !demo;
        StatusLabel.Text = demo ? $"デモ · v{Version}" : engine.Syncing ? "取得中…" : !engine.Ready ? "保存エラーで停止中" : !engine.State.Enabled ? "停止中 · 設定から接続方法を確認" :
            engine.LastSync is { } date ? $"最終確認 {date.ToLocalTime():HH:mm} · @{engine.State.Account}" : "開始しました。通知を確認しています。";
        ErrorLabel.Text = engine.Error;
        ErrorLabel.Visibility = string.IsNullOrEmpty(engine.Error) ? Visibility.Collapsed : Visibility.Visible;
        refreshing = false;
        RenderThreads();
    }
    private static void SetOptions(ComboBox combo, IEnumerable<string> values, string selected, string all)
    {
        var options = new[] { new FilterOption("", all) }.Concat(values.Distinct().Order().Select(x => new FilterOption(x, x))).ToList();
        combo.ItemsSource = options;
        combo.SelectedValue = options.Any(x => x.Value == selected) ? selected : "";
    }
    private void RenderThreads()
    {
        if (refreshing || !IsInitialized) return;
        var owner = (string?)OwnerFilter.SelectedValue ?? "";
        var repo = (string?)RepositoryFilter.SelectedValue ?? "";
        var kind = (string?)KindFilter.SelectedValue ?? "";
        var search = SearchBox.Text.Trim();
        var now = DateTimeOffset.UtcNow;
        int.TryParse((string?)DateFilter.SelectedValue, out var days);
        // Only show updates in the selected period; opening still acknowledges the whole PR in the engine.
        var rows = engine.Included.Where(s => SignalDateRange.Includes(s.Date, days, now)).GroupBy(x => x.ThreadKey).Select(x => new ThreadRow(x.Key, x.OrderByDescending(s => s.Date).ToList(), engine.State.PullRequests.GetValueOrDefault(x.Key)))
            .Where(x => (ShowAcknowledged.IsChecked == true || x.HasPending) && (owner == "" || x.Repository.Split('/')[0] == owner) && (repo == "" || x.Repository == repo) &&
                (kind == "" || x.Signals.Any(s => s.Kind.ToString() == kind && (ShowAcknowledged.IsChecked == true || !s.Acknowledged))) &&
                (search == "" || x.Signals.Any(s => (s.Title + " " + s.Actor + " " + s.Excerpt).Contains(search, StringComparison.OrdinalIgnoreCase))))
            .OrderByDescending(x => x.Latest.Date).ToList();
        ThreadList.ItemsSource = rows;
        AcknowledgeAllButton.IsEnabled = engine.Ready && rows.Any(x => x.HasPending);
        EmptyLabel.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void Owner_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (refreshing || !IsInitialized) return;
        engine.Mutate(x => { x.Settings.ViewOrganization = (string?)OwnerFilter.SelectedValue ?? ""; x.Settings.ViewRepository = ""; });
    }
    private void Filter_Changed(object sender, RoutedEventArgs e)
    {
        if (refreshing || !IsInitialized) return;
        if (ReferenceEquals(sender, RepositoryFilter)) engine.Mutate(x => x.Settings.ViewRepository = (string?)RepositoryFilter.SelectedValue ?? "");
        else if (ReferenceEquals(sender, DateFilter)) engine.Mutate(x => x.Settings.ViewDays = int.TryParse((string?)DateFilter.SelectedValue, out var days) ? days : 0);
        else RenderThreads();
    }
    private void Search_Changed(object sender, TextChangedEventArgs e) => RenderThreads();
    private async void Toggle_Click(object sender, RoutedEventArgs e)
    {
        if (engine.State.Enabled) engine.Pause();
        else { engine.Mutate(x => x.Enabled = true); await engine.SyncAsync(lifetime); }
    }
    private void Acknowledge_Click(object sender, RoutedEventArgs e) => engine.Mutate(x => x.AcknowledgeThread((string)((Button)sender).Tag));
    private void AcknowledgeAll_Click(object sender, RoutedEventArgs e)
    {
        var keys = ThreadList.Items.Cast<ThreadRow>().Select(x => x.Key).ToArray();
        engine.Mutate(x => x.AcknowledgeThreads(keys));
    }
    private void Snooze_Click(object sender, RoutedEventArgs e) => engine.Mutate(x => {
        foreach (var signal in x.Signals.Where(s => s.ThreadKey == (string)((Button)sender).Tag && !s.Acknowledged)) signal.SnoozedUntil = DateTimeOffset.UtcNow.AddHours(1);
    });
    private void Open_Click(object sender, RoutedEventArgs e)
    {
        switch (((Button)sender).DataContext) {
            case ThreadRow row: engine.Mutate(x => x.OpenSignal(row.Latest.Id, true, uri => OpenUrl(uri.AbsoluteUri))); break;
            case Signal signal: engine.Mutate(x => x.OpenSignal(signal.Id, false, uri => OpenUrl(uri.AbsoluteUri))); break;
        }
    }
    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        var value = (string)((Button)sender).Tag;
        if (Rules.SafeWebUrl(value) is null) return;
        try { Clipboard.SetText(value); StatusLabel.Text = "URLをコピーしました。"; }
        catch (System.Runtime.InteropServices.COMException) { StatusLabel.Text = "コピーできませんでした。もう一度お試しください。"; }
    }
    private bool OpenUrl(string value)
    {
        if (Rules.SafeWebUrl(value) is null) return false;
        try { using var process = Process.Start(new ProcessStartInfo(value) { UseShellExecute = true }); return true; }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException) { StatusLabel.Text = "ブラウザを開けませんでした。URLをコピーしてください。"; return false; }
    }
    private void Quit_Click(object sender, RoutedEventArgs e) => QuitRequested?.Invoke();
    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsWindow(engine.State.Settings, Version, demo) { Owner = this };
        dialog.TestRequested += () => TestNotificationRequested?.Invoke();
        if (dialog.ShowDialog() == true) engine.Mutate(x => x.Settings = dialog.Result);
    }
    internal async Task CheckUpdateAsync()
    {
        if (demo || checkingUpdate || DateTimeOffset.UtcNow < nextUpdateCheck || lifetime.IsCancellationRequested) return;
        checkingUpdate = true;
        nextUpdateCheck = DateTimeOffset.UtcNow.AddHours(24);
        try {
            var release = await AppRelease.FetchAsync(http, lifetime);
            if (lifetime.IsCancellationRequested) return;
            if (release.IsNewer(Version)) {
                UpdateButton.Content = $"{release.TagName} をダウンロード"; UpdateBanner.Visibility = Visibility.Visible;
                if (engine.Ready && release.ShouldNotify(Version, engine.State.LastNotifiedRelease) && UpdateNotificationRequested?.Invoke(release.TagName) == true)
                    engine.Mutate(x => x.LastNotifiedRelease = release.TagName);
            } else { UpdateBanner.Visibility = Visibility.Collapsed; }
        } catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException or System.Text.Json.JsonException or IOException or InvalidDataException) {
            nextUpdateCheck = DateTimeOffset.UtcNow.AddHours(1);
        } finally { checkingUpdate = false; }
    }
    internal void OpenRelease() => OpenUrl(AppRelease.DownloadUrl.AbsoluteUri);
    private void Update_Click(object sender, RoutedEventArgs e) => OpenRelease();
    internal void CheckSmokeBindings()
    {
        if (string.IsNullOrEmpty(CountLabel.Text) || OwnerFilter.Items.Count != 2 || RepositoryFilter.Items.Count != 2)
            throw new InvalidOperationException("WPF filter binding smoke test failed");
        if (!Descendants(this).OfType<TextBlock>().Any(x => x.Text == "通知画面をコンパクトにする"))
            throw new InvalidOperationException("WPF notification template was not rendered");
        var bitmap = new RenderTargetBitmap((int)ActualWidth, (int)ActualHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(this);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var output = File.Create(Path.Combine(AppContext.BaseDirectory, "smoke-window.png"))) encoder.Save(output);
        var details = Descendants(this).OfType<Expander>().Single();
        details.IsExpanded = true; UpdateLayout();
        if (!Descendants(this).OfType<Button>().Any(x => Equals(x.Content, "コメントを開く")))
            throw new InvalidOperationException("Individual notification template was not rendered");
        CheckSettingsSmoke();
        var oldSignal = engine.State.Signals[0] with { Id = "old-date-smoke", Url = "https://github.com/octo-org/example/pull/2", Date = DateTimeOffset.UtcNow.AddDays(-40) };
        engine.Mutate(x => x.Signals.Add(oldSignal));
        if (VisibleThreadCount != 2) throw new InvalidOperationException("All dates filter failed");
        DateFilter.SelectedValue = "7";
        if (VisibleThreadCount != 1 || engine.State.Settings.ViewDays != 7) throw new InvalidOperationException("Date filter binding failed");
        DateFilter.SelectedValue = "0";
        engine.Mutate(x => x.Signals.Remove(oldSignal));
        SearchBox.Text = "nothing-matches";
        if (VisibleThreadCount != 0) throw new InvalidOperationException("Search filter failed");
        SearchBox.Text = "";
        AcknowledgeAllButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (VisibleThreadCount != 0 || engine.PendingCount != 0) throw new InvalidOperationException("PR acknowledgement failed");
    }
    private void CheckSettingsSmoke()
    {
        var settings = new SettingsWindow(engine.State.Settings, Version, true) { Owner = this };
        settings.Show(); settings.UpdateLayout(); settings.Close();
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) {
            var child = VisualTreeHelper.GetChild(parent, i); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
