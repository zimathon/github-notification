import AppKit
import Carbon
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor let model = AppModel.shared
    private var inboxWindow: NSWindow?
    private var inboxObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        inboxObserver = NotificationCenter.default.addObserver(forName: .showSignalInbox, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showInbox() }
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            || event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
        if !loginLaunch && !ProcessInfo.processInfo.arguments.contains("--login") { showInbox() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showInbox()
        return false
    }

    private func showInbox() {
        if inboxWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "GitHub Signal"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: InboxView(model: model))
            if !window.setFrameUsingName("GitHubSignalInbox") { window.center() }
            window.setFrameAutosaveName("GitHubSignalInbox")
            inboxWindow = window
        }
        inboxWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

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
        Text("GitHub Signal v" + model.appVersion)
    }
    private func showInbox() {
        NotificationCenter.default.post(name: .showSignalInbox, object: nil)
    }
}
