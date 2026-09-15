// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

// MARK: - Status presentation

extension ServerStatus {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// States where the server is mid-transition — the menubar glyph blinks here.
    var isTransitional: Bool {
        switch self {
        case .starting, .stopping, .restarting: return true
        case .stopped, .running, .error: return false
        }
    }

    /// Menubar glyph when not transitioning: filled star = on, open star = off.
    var steadyGlyph: String {
        if case .running = self { return "✦" }   // U+2726 BLACK FOUR POINTED STAR
        return "✧"                                // U+2727 WHITE FOUR POINTED STAR
    }

    /// Human-readable run state shown in the menu.
    var menuText: String {
        switch self {
        case .stopped:          return "Stopped"
        case .starting:         return "Starting…"
        case .restarting:       return "Restarting…"
        case .running(let pid): return "Running (PID \(pid))"
        case .stopping:         return "Stopping…"
        case .error(let msg):   return "Error: \(msg)"
        }
    }

    /// Title of the start/stop/cancel action item.
    var actionTitle: String {
        switch self {
        case .stopped, .error:    return "Start Server"
        case .starting:           return "Cancel Start"
        case .restarting:         return "Cancel Restart"
        case .running, .stopping: return "Stop Server"
        }
    }
}

// MARK: - Menubar icon

/// The MenuBarExtra label: a star glyph reflecting server state. Rendered as text
/// so it stays monochrome and adapts to the menubar's light/dark appearance.
/// While the server is starting/stopping/restarting it alternates ✧↔✦ on a timer.
struct StatusIcon: View {
    @ObservedObject var server: ServerManager
    @Environment(\.openSettings) private var openSettings
    @State private var blinkOn = false
    private let blink = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(glyph)
            .onAppear {
                SettingsNavigation.install { openSettings() }
            }
            .onReceive(blink) { _ in blinkOn.toggle() }
    }

    private var glyph: String {
        guard server.status.isTransitional else { return server.status.steadyGlyph }
        return blinkOn ? "✦" : "✧"
    }
}

// MARK: - Menubar menu

/// Dropdown contents for the MenuBarExtra. Plain `Text` rows render as disabled
/// (informational) items; `Button`s are the clickable actions.
struct MenuContent: View {
    @ObservedObject var server: ServerManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text("ds4-server")
            Text("Status: \(server.status.menuText)")
                .foregroundStyle(
                    server.status.isError ? Color(nsColor: .systemRed) : Color.primary
                )

            Divider()

            Button(server.status.actionTitle, action: toggle)
                .keyboardShortcut("s")

            Button("Open Log in Console") {
                ServerLogActions.openInConsole(logPath: server.logPath)
            }

            Divider()

            Button("Settings…") {
                openSettings()
                AppActivation.windowOpened()
            }
            .keyboardShortcut(",")

            Divider()

            Button("About DS Menu Bar") {
                openWindow(id: "about")
                AppActivation.windowOpened()
            }

            Divider()

            Button("Quit DS Menu Bar") {
                server.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onAppear {
            SettingsNavigation.install { openSettings() }
        }
    }

    /// Mirrors the old MenuBarManager.toggleServer: start from a stopped/errored
    /// state, otherwise stop (which also cancels an in-progress start/restart).
    private func toggle() {
        switch server.status {
        case .running, .starting, .restarting, .stopping:
            server.stop()
        case .stopped, .error:
            // A MenuBarExtra does not necessarily activate its accessory app
            // while tracking the menu. Activate during the user's Start action
            // so a subsequent modal failure alert has an active owner.
            NSApp.activate()
            server.start()
        }
    }
}

@MainActor
enum ServerLogActions {
    /// Open the server log in Console.app. If it doesn't exist yet, create it
    /// with the same owner-only permissions used by ProcessManager.
    static func openInConsole(logPath: String) {
        let path = (logPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            ProcessManager.createOwnerOnlyDirectory(
                (path as NSString).deletingLastPathComponent, fm: fm)
            fm.createFile(atPath: path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}
