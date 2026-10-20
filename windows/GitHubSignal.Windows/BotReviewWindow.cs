using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using GitHubSignal.Core;

namespace GitHubSignal.Windows;

public sealed class BotReviewWindow : Window
{
    public BotReviewWindow(Signal[] signals, string account, Func<BotReviewRequest, Task> send)
    {
        Title = "AIレビューを依頼";
        Width = 560; Height = 560; MinWidth = 450; MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var root = new DockPanel { Margin = new Thickness(16) };
        Content = root;
        var options = new StackPanel();
        DockPanel.SetDock(options, Dock.Top); root.Children.Add(options);
        options.Children.Add(Text("投稿アカウント：@" + account));
        var codex = new CheckBox { Content = "Codex", IsChecked = true, Margin = new Thickness(0, 0, 16, 0) };
        var claude = new CheckBox { Content = "Claude", IsChecked = true };
        var bots = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        bots.Children.Add(codex); bots.Children.Add(claude); options.Children.Add(bots);
        options.Children.Add(Text("ログイン中のGitHubアカウントで、各PRに次のコメントを投稿します。両方を選ぶとPRごとに2件投稿します。"));
        var preview = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 10), Background = Brushes.WhiteSmoke };
        options.Children.Add(preview);
        var bottom = new StackPanel(); DockPanel.SetDock(bottom, Dock.Bottom); root.Children.Add(bottom);
        bottom.Children.Add(Text("対象リポジトリで各Botの連携設定が必要です。投稿済みはレビューの開始・完了を意味しません。結果が不明な場合はGitHubで確認してから再依頼してください。"));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        var close = new Button { Content = "閉じる", Margin = new Thickness(0, 0, 8, 0) };
        var submit = new Button(); actions.Children.Add(close); actions.Children.Add(submit); bottom.Children.Add(actions);
        var targets = new StackPanel();
        root.Children.Add(new ScrollViewer { Content = targets, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        BotReviewRequest[] plan = [];
        bool sending = false, attempted = false;
        void Update()
        {
            var selected = Enum.GetValues<ReviewBot>().Where(bot => bot == ReviewBot.Codex ? codex.IsChecked == true : claude.IsChecked == true);
            plan = BotReviewRequest.Plan(signals, selected);
            preview.Text = string.Join(Environment.NewLine + Environment.NewLine, plan.DistinctBy(x => x.Bot).Select(x => x.Body));
            targets.Children.Clear();
            foreach (var request in plan) targets.Children.Add(Text($"{request.Title}\n{request.Url}\n{request.Bot}：未送信\n"));
            submit.Content = $"{plan.Length}件のコメントを投稿";
            submit.IsEnabled = plan.Length > 0 && !sending && !attempted;
        }
        codex.Click += (_, _) => Update(); claude.Click += (_, _) => Update();
        close.Click += (_, _) => Close();
        Closing += (_, e) => e.Cancel = sending;
        submit.Click += async (_, _) => {
            if (sending || attempted || plan.Length == 0) return;
            var snapshot = plan.ToArray();
            sending = true; attempted = true;
            submit.IsEnabled = false; close.IsEnabled = false; codex.IsEnabled = false; claude.IsEnabled = false;
            for (int index = 0; index < snapshot.Length; index++) {
                if (index > 0) await Task.Delay(1000);
                var request = snapshot[index];
                var row = (TextBlock)targets.Children[index];
                row.Text = $"{request.Title}\n{request.Url}\n{request.Bot}：送信中…\n";
                try {
                    await send(request);
                    row.Text = $"{request.Title}\n{request.Url}\n{request.Bot}：投稿済み\n";
                } catch (ReviewAccountException error) {
                    row.Text = $"{request.Title}\n{request.Url}\n{request.Bot}：{error.Message}\n";
                } catch (Exception) {
                    row.Text = $"{request.Title}\n{request.Url}\n{request.Bot}：送信を確認できません。GitHubを確認してください。\n";
                }
            }
            sending = false; close.IsEnabled = true;
        };
        Update();
    }
    private static TextBlock Text(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6) };
}
