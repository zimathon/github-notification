using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using GitHubSignal.Core;

namespace GitHubSignal.Windows;

public partial class App : Application
{
    private Mutex? singleInstance;
    private TrayService? tray;
    private DispatcherTimer? timer;
    private readonly CancellationTokenSource lifetime = new();
    private bool ownsMutex;
    private bool quitting;
    private InboxEngine? inbox;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        bool smoke = e.Args.Contains("--smoke-test");
        bool demo = smoke || e.Args.Contains("--demo");
        if (!demo) {
            singleInstance = new Mutex(true, "Local\\GitHubSignal.Windows", out ownsMutex);
            if (!ownsMutex) { MessageBox.Show("GitHub Signalは起動済みです。タスクトレイのアイコンから開いてください。", "GitHub Signal"); Shutdown(); return; }
        }
        string folder = demo ? Path.Combine(Path.GetTempPath(), "GitHubSignal-demo-" + Guid.NewGuid()) :
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GitHubSignal");
        var engine = new InboxEngine(new StateStore(Path.Combine(folder, "inbox.json")), new GhTransport());
        if (demo) {
            engine.State.Signals.Add(new Signal { Id = "demo-1", Kind = SignalKind.Mention, Repository = "octo-org/example", Title = "通知画面をコンパクトにする", Actor = "octocat", Excerpt = "@you 変更を確認してください。", Url = "https://github.com/octo-org/example/pull/1#issuecomment-1", Date = DateTimeOffset.UtcNow });
            engine.State.Signals.Add(new Signal { Id = "demo-2", Kind = SignalKind.ReviewRequest, Repository = "octo-org/example", Title = "通知画面をコンパクトにする", Actor = "hubot", Excerpt = "レビューを依頼しました", Url = "https://github.com/octo-org/example/pull/1", Date = DateTimeOffset.UtcNow.AddMinutes(-5) });
        }
        inbox = engine;
        var window = new MainWindow(engine, demo, lifetime.Token);
        MainWindow = window;
        window.QuitRequested += Quit;
        window.Closing += (_, args) => { if (!quitting) { args.Cancel = true; if (demo) Quit(); else window.Hide(); } };
        if (!demo) {
            tray = new TrayService(window.ShowInbox, Quit);
            window.TestNotificationRequested += () => tray.Notify("テスト通知", "GitHub Signalからの通知です。クリックすると通知一覧を開きます。");
            engine.Changed += () => tray.SetCount(engine.PendingCount);
            tray.SetCount(engine.PendingCount);
            timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            timer.Tick += async (_, _) => {
                await engine.SyncAsync(lifetime.Token);
                if (lifetime.IsCancellationRequested) return;
                var now = DateTimeOffset.UtcNow;
                var due = engine.Due(now);
                if (due.Count > 0) {
                    int count = due.Select(x => x.ThreadKey).Distinct().Count();
                    if (tray.Notify($"未確認の通知：{count}件", count == 1 ? $"@{due[0].Actor} · {due[0].Title}" : "メンションやレビュー依頼などが届いています。クリックして確認してください。"))
                        engine.MarkNotified(due, now);
                }
            };
            timer.Start();
        }
        if (smoke) {
            window.Loaded += (_, _) => Dispatcher.BeginInvoke(() => {
                try {
                    window.UpdateLayout();
                    if (window.VisibleThreadCount != 1 || engine.PendingCount != 1) throw new InvalidOperationException("PR grouping smoke test failed");
                    window.CheckSmokeBindings();
                    using (var smokeTray = new TrayService(() => { }, () => { })) {
                        smokeTray.SetCount(1); smokeTray.SetCount(99); smokeTray.SetCount(100); smokeTray.SetCount(0);
                    }
                    Quit();
                } catch (Exception error) {
                    File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "smoke-error.txt"), error.ToString());
                    quitting = true; Shutdown(1);
                }
            }, DispatcherPriority.ApplicationIdle);
        }
        window.Show();
        // Demo never starts polling, update requests or native notifications; its temporary state is disposable.
        if (demo) Exit += (_, _) => { if (Directory.Exists(folder)) Directory.Delete(folder, true); };
    }
    private async void Quit()
    {
        if (quitting) return;
        quitting = true;
        lifetime.Cancel();
        timer?.Stop();
        if (inbox is not null) await inbox.WaitForIdleAsync();
        tray?.Dispose();
        Shutdown();
    }
    protected override void OnExit(ExitEventArgs e)
    {
        lifetime.Cancel();
        timer?.Stop();
        tray?.Dispose();
        if (ownsMutex) singleInstance?.ReleaseMutex();
        singleInstance?.Dispose();
        lifetime.Dispose();
        base.OnExit(e);
    }
}
