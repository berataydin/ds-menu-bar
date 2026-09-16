// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import AppKit
import Combine

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

// MARK: - Menu-bar item

/// Owns the native NSStatusItem and its menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let server: ServerManager
    private let openSettings: () -> Void
    private let openAbout: () -> Void
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private var blinkOn = false
    private var menuIsOpen = false

    private let serverItem = NSMenuItem(title: "ds4-server", action: nil, keyEquivalent: "")
    private let statusTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let serverActionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "s")
    private let speedItem = NSMenuItem(
        title: "Show Speeds in Menu Bar",
        action: nil,
        keyEquivalent: ""
    )

    init(
        server: ServerManager,
        openSettings: @escaping () -> Void,
        openAbout: @escaping () -> Void
    ) {
        self.server = server
        self.openSettings = openSettings
        self.openAbout = openAbout
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.menu = makeMenu()
        observeServer()
        updateStatusButton()
        refreshMenu()

        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                blinkOn.toggle()
                if server.status.isTransitional {
                    updateStatusButton()
                }
            }
            .store(in: &cancellables)

    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        serverItem.isEnabled = false
        statusTextItem.isEnabled = false
        serverActionItem.target = self
        serverActionItem.action = #selector(toggleServer)
        serverActionItem.keyEquivalentModifierMask = .command
        serverActionItem.isEnabled = true
        speedItem.target = self
        speedItem.action = #selector(toggleSpeedDisplay)
        speedItem.isEnabled = true

        menu.addItem(serverItem)
        menu.addItem(statusTextItem)
        menu.addItem(.separator())
        menu.addItem(serverActionItem)
        menu.addItem(item("Open Log in Console", action: #selector(openLog)))
        menu.addItem(speedItem)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(item("About DS Menu Bar", action: #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit DS Menu Bar", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func item(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = .command
        item.isEnabled = true
        return item
    }

    /// This fires twice a second while the server generates. Only the status
    /// button has to keep up with that; the menu is rebuilt in menuWillOpen,
    /// and while it is open, so a status change lands under the cursor.
    private func observeServer() {
        server.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    updateStatusButton()
                    if menuIsOpen { refreshMenu() }
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let glyph: String
        if server.status.isTransitional {
            glyph = blinkOn ? "✦" : "✧"
        } else {
            glyph = server.status.steadyGlyph
        }

        if server.showsPerformanceInMenuBar {
            statusItem.length = NSStatusItem.variableLength
            button.alignment = .center
            button.attributedTitle = StatusBarTitle.make(
                glyph: glyph,
                performance: server.performance
            )
        } else {
            statusItem.length = NSStatusItem.squareLength
            button.alignment = .center
            button.title = glyph
        }
        button.lineBreakMode = .byClipping
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = "DS Menu Bar — \(server.status.menuText)"
    }

    /// Spelled out, because the rendered title is a star glyph and fields
    /// abbreviated to hold a fixed width.
    private var accessibilityLabel: String {
        let status = "DS Menu Bar — \(server.status.menuText)"
        guard server.showsPerformanceInMenuBar,
              let speed = server.performance.spokenDescription
        else { return status }
        return "\(status), \(speed)"
    }

    private func refreshMenu() {
        statusTextItem.title = "Status: \(server.status.menuText)"
        serverActionItem.title = server.status.actionTitle
        speedItem.state = server.showsPerformanceInMenuBar ? .on : .off
    }

    @objc private func toggleServer() {
        switch server.status {
        case .running, .starting, .restarting, .stopping:
            server.stop()
        case .stopped, .error:
            NSApp.activate()
            server.start()
        }
    }

    @objc private func openLog() {
        ServerLogActions.openInConsole(logPath: server.logPath)
    }

    @objc private func toggleSpeedDisplay() {
        server.setShowsPerformanceInMenuBar(!server.showsPerformanceInMenuBar)
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func showAbout() {
        openAbout()
    }

    @objc private func quit() {
        server.stop()
        NSApp.terminate(nil)
    }
}

/// Uses fixed-pitch glyphs only for fields whose contents change. The native
/// menu-bar font remains in use for the status glyph, spacing, and units.
@MainActor
enum StatusBarTitle {
    private static let menuFont = NSFont.menuBarFont(ofSize: 0)
    private static let fieldFont = NSFont.monospacedSystemFont(
        ofSize: menuFont.pointSize,
        weight: .regular
    )

    static func make(
        glyph: String,
        performance: ServerPerformance
    ) -> NSAttributedString {
        let title = NSMutableAttributedString()
        title.append(segment("\(glyph) ", font: menuFont))
        title.append(segment(performance.menuBarPhase, font: fieldFont))
        title.append(segment(" ", font: menuFont))
        title.append(segment(performance.menuBarRate, font: fieldFont))
        title.append(segment(" t/s", font: menuFont))
        return title
    }

    private static func segment(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font])
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
