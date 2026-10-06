using System;
using System.IO;
using Microsoft.Win32;

namespace GitHubSignal.Windows;

internal sealed class LoginStartup(string runKey = @"Software\Microsoft\Windows\CurrentVersion\Run")
{
    public static LoginStartup Current { get; } = new();
    private const string ValueName = "GitHubSignal";

    public bool IsRegistered()
    {
        using var key = Registry.CurrentUser.OpenSubKey(runKey);
        return key?.GetValue(ValueName) is string;
    }

    public void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(runKey);
        if (!enabled) { key.DeleteValue(ValueName, throwOnMissingValue: false); return; }
        var path = Environment.ProcessPath ?? throw new IOException("アプリの起動元を確認できません。");
        var command = "\"" + path + "\" --login";
        if (command.Length > 260) throw new IOException("起動元のパスが長すぎます。短いパスへアプリを移動してください。");
        key.SetValue(ValueName, command, RegistryValueKind.String);
    }
    internal static void CheckSmoke()
    {
        var testPath = @"Software\GitHubSignal\StartupTest-" + Guid.NewGuid();
        try {
            var service = new LoginStartup(testPath);
            if (service.IsRegistered()) throw new InvalidOperationException("Startup must default to off");
            service.SetEnabled(true);
            using (var key = Registry.CurrentUser.OpenSubKey(testPath)) {
                if (!Equals(key?.GetValue(ValueName), "\"" + Environment.ProcessPath + "\" --login"))
                    throw new InvalidOperationException("Startup executable must be quoted and request background launch");
            }
            if (!service.IsRegistered()) throw new InvalidOperationException("Startup registration failed");
            service.SetEnabled(false);
            if (service.IsRegistered()) throw new InvalidOperationException("Startup removal failed");
        } finally { Registry.CurrentUser.DeleteSubKeyTree(testPath, throwOnMissingSubKey: false); }
    }
}
