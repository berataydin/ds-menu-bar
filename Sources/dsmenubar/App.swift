// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UserNotifications

/// SwiftUI menubar app. The entire UI is a `MenuBarExtra`; a `Settings` scene
/// hosts the settings window, shown on demand (it does not open at launch).
@main
struct DSMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(server: appDelegate.server)
        } label: {
            StatusIcon(server: appDelegate.server)
        }

        Window("About DS Menu Bar", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        // First-ever placement, at the standard About panel's spot; every
        // later placement is handled by the close-time re-positioning in
        // AboutWindowConfigurator (same rule — see there for the details).
        .defaultWindowPlacement { content, context in
            let visible = context.defaultDisplay.visibleRect
            let size = content.sizeThatFits(.unspecified)
            return WindowPlacement(
                CGPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.minY + visible.height / 5
                ),
                size: size
            )
        }
        .restorationBehavior(.disabled)
        .commands {
            // Replace AppKit's auto-generated "About DS Menu Bar" item (which
            // opens the standard About panel) so the app-menu route and the
            // menu-bar-dropdown route both open the same custom About window.
            CommandGroup(replacing: .appInfo) {
                Button("About DS Menu Bar") {
                    openWindow(id: "about")
                    AppActivation.windowOpened()
                }
            }
        }

        Settings {
            SettingsView(server: appDelegate.server)
        }
    }

    @Environment(\.openWindow) private var openWindow
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    UNUserNotificationCenterDelegate {
    /// Owned here (not as App-struct state) so it's available to `body` and so
    /// `applicationWillTerminate` can reap the child process.
    let server = ServerManager()

    private var manualFailureAlertShowing = false
    private var initialSetupWindowController: InitialSetupWindowController?
    private var initialSetupCompleted = false
    private var notificationAuthorizationRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: no dock icon, but the app can still bring its settings
        // window to the front. (LSUIElement in Info.plist also implies this.)
        // AppActivation flips this to .regular while a window is open so
        // Cmd-Tab can find the app, and back once the last window closes.
        NSApp.setActivationPolicy(.accessory)
        AppActivation.install()

        server.onLaunchFailure = { [weak self] failure in
            guard failure.source == .manual else { return }
            self?.presentManualLaunchFailure(failure)
        }

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        let openSettings = UNNotificationAction(
            identifier: ServerNotification.openSettingsAction,
            title: "Open Settings",
            options: [.foreground]
        )
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: ServerNotification.launchFailureCategory,
                actions: [openSettings],
                intentIdentifiers: [],
                options: []
            )
        ])

        if server.needsInitialSetup {
            DispatchQueue.main.async { [weak self] in
                self?.presentInitialSetup()
            }
        } else {
            requestNotificationAuthorization()
        }
    }

    @MainActor
    private func presentInitialSetup() {
        let controller = InitialSetupWindowController { [weak self] serverPath, modelPath in
            guard let self else { return }
            self.server.completeInitialSetup(
                serverPath: serverPath,
                modelPath: modelPath
            )
            self.initialSetupCompleted = true
            self.initialSetupWindowController?.close()
        }
        controller.window?.delegate = self
        initialSetupWindowController = controller
        controller.showWindow(nil)
        AppActivation.windowOpened()
    }

    private func requestNotificationAuthorization() {
        guard !notificationAuthorizationRequested else { return }
        notificationAuthorizationRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === initialSetupWindowController?.window
        else { return }

        initialSetupWindowController = nil
        requestNotificationAuthorization()
        guard initialSetupCompleted else { return }
        initialSetupCompleted = false
        DispatchQueue.main.async { [weak self] in
            self?.openSettings(destination: .model)
        }
    }

    /// Show a launch failure the user is waiting on, as a modal alert.
    ///
    /// The staging below was arrived at empirically: earlier, simpler versions
    /// left the alert behind the previously-frontmost app, or showed it with no
    /// keyboard focus. What is *not* known is which individual steps are
    /// required — the deferrals, `unhide` before `activate`, and building the
    /// alert a turn before running it were never bisected against each other.
    /// Treat the sequence as one unit: if you simplify it, re-test surfacing
    /// with another app frontmost, not just from an idle desktop.
    ///
    /// The activation policy is deliberately left `.accessory` here. Unlike
    /// AppActivation.windowOpened, a modal alert fronts without promotion, and
    /// promoting would add a Dock icon for the alert's lifetime.
    ///
    /// Observed to work with a secure-keyboard-entry app frontmost. That was
    /// incidental rather than designed for, so it is a data point, not a
    /// guarantee this path maintains.
    private func presentManualLaunchFailure(_ failure: ServerLaunchFailure) {
        guard !manualFailureAlertShowing else { return }
        manualFailureAlertShowing = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Give the status-item menu a complete event-loop turn to finish
            // closing before preparing the alert window.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                let alert = NSAlert()
                alert.messageText = "ds4-server could not start"
                alert.informativeText = failure.message
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Dismiss")
                alert.buttons.first?.keyEquivalent = "\r"
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    NSApp.unhide(nil)
                    NSApp.activate()
                    alert.window.center()

                    if alert.runModal() == .alertFirstButtonReturn {
                        self.openSettings(destination: failure.settingsDestination)
                    }
                    self.manualFailureAlertShowing = false
                }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        guard action == ServerNotification.openSettingsAction ||
              action == UNNotificationDefaultActionIdentifier,
              let rawDestination = response.notification.request.content
                .userInfo[ServerNotification.settingsPaneKey] as? String,
              let destination = ServerSettingsDestination(rawValue: rawDestination)
        else {
            completionHandler()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.openSettings(destination: destination)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The app remains running as a menu-bar app while the server is live.
        // Explicitly request visible delivery when a failure is reported while
        // the app is considered foreground; otherwise macOS may deliver it
        // without showing a banner or playing its sound.
        completionHandler([.banner, .sound])
    }

    private func openSettings(destination: ServerSettingsDestination) {
        MainActor.assumeIsolated {
            SettingsNavigation.open(destination)
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppActivation.windowOpened()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }
}
