import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor let model = AppModel.shared

    func applicationWillFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "SIGNAL", actions: [
                UNNotificationAction(identifier: "ACK", title: "確認済みにする"),
                UNNotificationAction(identifier: "SNOOZE", title: "1時間後に通知")
            ], intentIdentifiers: [])
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["signalID"] as? String
        Task { @MainActor in
            defer { completionHandler() }
            if response.notification.request.content.userInfo["appUpdate"] as? Bool == true {
                if response.actionIdentifier == UNNotificationDefaultActionIdentifier { model.openRelease() }
            } else if let id {
                switch response.actionIdentifier {
                case "ACK": model.acknowledge(id)
                case "SNOOZE": model.snooze(id)
                case UNNotificationDefaultActionIdentifier:
                    if let signal = model.state.signals.first(where: { $0.id == id }) { model.open(signal) }
                default: break
                }
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                NotificationCenter.default.post(name: .showSignalInbox, object: nil)
            }
        }
    }
}

extension Notification.Name { static let showSignalInbox = Notification.Name("showSignalInbox") }

@main
struct GitHubSignalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("GitHub Signal", id: "inbox") {
            InboxView(model: model)
                .task { model.start() }
        }
        .defaultSize(width: 420, height: 360)
        MenuBarExtra {
            SignalMenu(model: model)
                .task { model.start() }
        } label: {
            Image(systemName: model.activeCount > 0 ? "bell.badge.fill" : "bell")
            Text("\(model.pendingThreadCount)").monospacedDigit()
        }
    }
}

private struct SignalMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("未確認 \(model.pendingThreadCount)件を開く") { showInbox() }
        if let account = model.state.account { Text("@\(account)") }
        if model.demo { Text("デモ表示中") }
        if model.error != nil { Text("通知を取得できません。一覧で詳細を確認できます。") }
        Divider()
        Button(model.syncing ? "確認中…" : "今すぐ確認") { Task { await model.sync() } }
            .disabled(!model.state.enabled || model.syncing || Date() < model.nextSync)
        Divider()
        if let version = model.availableRelease {
            Button("新しいバージョン \(version) をダウンロード") { model.openRelease() }
        }
        Button(model.checkingUpdate ? "アプリの更新を確認中…" : "アプリの更新を確認") {
            Task { await model.checkForUpdates(manual: true) }
        }.disabled(model.checkingUpdate || model.demo)
        if let status = model.updateStatus { Text(status) }
        Button("終了") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        // The menu remains mounted when the inbox window is closed.
        Text("GitHub Signal v" + model.appVersion)
            .onReceive(NotificationCenter.default.publisher(for: .showSignalInbox)) { _ in showInbox() }
    }
    private func showInbox() {
        openWindow(id: "inbox")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
