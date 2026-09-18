GitHub Signal for Windows

1. ZIP全体を任意のフォルダーに展開する。GitHubSignal.exeだけを移動しない。
2. PowerShellでGitHub CLIをインストールし、GitHubにログインする。
   winget install --id GitHub.cli -e
   gh auth login --hostname github.com --web
3. GitHubSignal.exeを起動し、「開始」を押す。

.NETの事前インストールは不要。Windows 11 x64向け。
ウィンドウを閉じるとトレイに常駐する。終了は画面またはトレイメニューの「終了」。
通知はWindowsのトレイ通知を使用し、応答不可モードなどで抑制される場合がある。
初回は直近24時間が対象。以降は保存した位置から再開する。
データ保存先: %LOCALAPPDATA%\GitHubSignal\inbox.json
同ファイルには非公開リポジトリの通知本文も保存される。認証トークンは保存しない。

この配布物にはコード署名を行っていない。
更新: アプリを終了し、新版ZIPを別フォルダーに展開して起動する。通知データは保持される。
Mac版とのデータファイルの直接共有には対応しない。

https://github.com/zimathon/github-notification

The GitHub mark is from Primer Octicons. See Octicons-LICENSE.
This archive includes the Microsoft .NET runtime and its license files.
