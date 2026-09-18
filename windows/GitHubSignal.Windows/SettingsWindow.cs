using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using GitHubSignal.Core;

namespace GitHubSignal.Windows;

internal sealed class SettingsWindow : Window
{
    public Settings Result { get; private set; }
    public event Action? TestRequested;
    public SettingsWindow(Settings current, string version, bool demo)
    {
        Result = current;
        Title = "GitHub Signal の設定";
        Width = 410; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontSize = 13;
        var panel = new StackPanel { Margin = new Thickness(16) }; Content = panel;
        void Label(string text) => panel.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 5) });
        Label("GitHub CLIをインストールし、ターミナルでログインしてから「開始」を押してください。");
        var commands = new TextBox { Text = "winget install --id GitHub.cli -e\r\ngh auth login --hostname github.com --web", IsReadOnly = true, TextWrapping = TextWrapping.Wrap };
        panel.Children.Add(commands);
        Label("通知する組織・ユーザー（空欄ならすべて）");
        var owners = new TextBox { Text = string.Join(", ", current.Organizations), ToolTip = "例：zimathon, my-org" }; panel.Children.Add(owners);
        Label("取得間隔（秒・120〜600）");
        var poll = new TextBox { Text = current.PollSeconds.ToString() }; panel.Children.Add(poll);
        Label("再通知までの時間（分・0で再通知なし）");
        var reminder = new TextBox { Text = current.ReminderMinutes.ToString() }; panel.Children.Add(reminder);
        var bots = new CheckBox { Content = "Botからの通知も受け取る", IsChecked = current.IncludeBots, Margin = new Thickness(0, 10, 0, 10) }; panel.Children.Add(bots);
        var test = new Button { Content = "テスト通知を送る", IsEnabled = !demo, HorizontalAlignment = HorizontalAlignment.Left }; panel.Children.Add(test);
        test.Click += (_, _) => TestRequested?.Invoke();
        Label("Windowsの通知設定や応答不可モードにより、通知が表示されない場合があります。");
        Label($"バージョン {version}\n起動元：{AppContext.BaseDirectory}");
        var error = new TextBlock { Foreground = System.Windows.Media.Brushes.Firebrick, TextWrapping = TextWrapping.Wrap }; panel.Children.Add(error);
        var save = new Button { Content = "保存", IsDefault = true, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) }; panel.Children.Add(save);
        save.Click += (_, _) => {
            try {
                if (!int.TryParse(poll.Text, out int seconds) || seconds < 120 || seconds > 600) throw new InvalidDataException("取得間隔は120〜600秒で入力してください。");
                if (!int.TryParse(reminder.Text, out int minutes) || minutes < 0 || minutes > 1440) throw new InvalidDataException("再通知は0〜1440分で入力してください。");
                Result = new Settings { Organizations = Settings.ParseOrganizations(owners.Text), PollSeconds = seconds, ReminderMinutes = minutes, IncludeBots = bots.IsChecked == true,
                    ViewOrganization = current.ViewOrganization, ViewRepository = current.ViewRepository };
                DialogResult = true;
            } catch (InvalidDataException exception) { error.Text = exception.Message; }
        };
    }
}
