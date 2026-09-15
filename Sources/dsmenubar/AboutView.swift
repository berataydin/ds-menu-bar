// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// Custom About window modeled after the standard "About Finder" panel:
/// fixed size, no minimize/zoom, centered icon and text, small system fonts.
struct AboutView: View {
    private var version: String {
        let release = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty
        else { return release }
        return "\(release) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("DS Menu Bar")
                .font(.system(size: 13, weight: .bold))

            // Markdown must stay a string literal — a variable would render as
            // plain text instead of a tappable link.
            Text("A Menu Bar Control for [DwarfStar](https://github.com/antirez/ds4)")
                .font(.system(size: 11))

            Text("DS Menu Bar version \(version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("© 2026 James Martin")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(width: 260)
        .fixedSize()
        .background(AboutWindowConfigurator())
    }
}

/// Strips the About window down to a fixed, non-resizable, non-minimizable
/// panel with no title text, matching the system About panel's chrome, and
/// keeps it permanently centered like the system About panel.
private struct AboutWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.remove([.resizable, .miniaturizable])
            window.titleVisibility = .hidden

            // The Window(id:) scene reuses this one NSWindow across
            // close/reopen, retaining whatever position the user dragged it
            // to. Re-positioning at reopen time is always one frame too late
            // — the window is already on screen, so it visibly jumps.
            // Instead, park the window back at the standard spot as it
            // closes: the move is invisible while hidden, and the next
            // opening starts out placed. (Deferred a turn — at willClose the
            // window is still on screen.)
            //
            // The spot replicates NSApp.orderFrontStandardAboutPanel():
            // horizontally centered, top edge one fifth of the visible-frame
            // height below the menu bar. Measured by probing the standard
            // panel with credits of varying length — the top offset stayed
            // fixed (visibleFrame.height / 5, to the pixel) while panel
            // heights varied, so the rule is height-independent. This is not
            // NSWindow.center(), which places the top at a quarter of the
            // *leftover* space and thus shifts with height. The scene's
            // .defaultWindowPlacement applies the same rule to the
            // first-ever appearance, so every showing lands on this spot.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak window] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let window,
                              let screen = window.screen ?? NSScreen.main else { return }
                        let area = screen.visibleFrame
                        let frame = window.frame
                        window.setFrameOrigin(NSPoint(
                            x: area.midX - frame.width / 2,
                            y: area.maxY - area.height / 5 - frame.height
                        ))
                    }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
