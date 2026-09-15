// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum InitialSetupValidation {
    static func serverError(for path: String) -> String? {
        let candidate = expanded(path)
        guard FileManager.default.isExecutableRegularFile(atPath: candidate) else {
            return "Choose an executable ds4-server file."
        }
        guard executableIdentifiesAsDS4Server(at: candidate) else {
            return "Choose ds4-server, not another executable."
        }
        return nil
    }

    static func modelError(for path: String) -> String? {
        let candidate = expanded(path)
        guard FileManager.default.isReadableRegularFile(atPath: candidate) else {
            return "Choose a readable GGUF model file."
        }
        do {
            let profile = try GGUFModelInspector.profile(at: candidate)
            guard !profile.isSupportArtifact else {
                return "Choose a main model GGUF, not a support GGUF."
            }
        } catch {
            return "Choose a valid GGUF model file."
        }
        return nil
    }

    static func preferredModelDirectory(forServerPath path: String) -> URL {
        let serverDirectory = URL(fileURLWithPath: expanded(path))
            .deletingLastPathComponent()
        let ggufDirectory = serverDirectory.appendingPathComponent("gguf", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: ggufDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return ggufDirectory
        }
        return serverDirectory
    }

    private static func executableIdentifiesAsDS4Server(at path: String) -> Bool {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-help-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL)
        else { return false }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        process.standardOutput = output
        process.standardError = output

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return false
        }

        guard finished.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return false
        }
        guard process.terminationStatus == 0 else { return false }

        try? output.synchronize()
        guard let reader = try? FileHandle(forReadingFrom: outputURL) else { return false }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: 64 * 1_024)) ?? Data()
        let help = String(decoding: data, as: UTF8.self)
        return help.contains("Usage: ds4-server")
    }

    private static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

struct InitialSetupView: View {
    let onContinue: (_ serverPath: String, _ modelPath: String) -> Void

    @State private var serverPath = ""
    @State private var modelPath = ""
    @State private var serverError: String?
    @State private var modelError: String?

    private var canContinue: Bool {
        return !serverPath.isEmpty && serverError == nil &&
            !modelPath.isEmpty && modelError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up DS Menu Bar")
                    .font(.title2.bold())
                Text(
                    "Choose the ds4-server executable and a DwarfStar-specific " +
                        "main GGUF model to begin."
                )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                selectionRow(
                    title: "ds4-server",
                    path: serverPath,
                    error: serverError,
                    action: chooseServer
                )
                Divider()
                    .padding(.leading, 16)
                selectionRow(
                    title: "Main GGUF model",
                    path: modelPath,
                    error: modelError,
                    action: chooseModel
                )
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                Text(
                    "DwarfStar requires DwarfStar-specific GGUF model files. " +
                        "See the DwarfStar GitHub page for installation instructions and model details."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(
                    "Open DwarfStar on GitHub",
                    destination: URL(string: "https://github.com/antirez/ds4")!
                )
            }

            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Button("Continue", action: continueSetup)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func selectionRow(
        title: String,
        path: String,
        error: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .fontWeight(.medium)
                    if !path.isEmpty && error == nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(path.isEmpty ? "Required" : path)
                    .font(.callout)
                    .foregroundStyle(path.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 12)
            Button("Choose…", action: action)
        }
        .padding(16)
    }

    private func chooseServer() {
        let panel = NSOpenPanel()
        panel.title = "Choose ds4-server"
        panel.message = "Select the ds4-server executable."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = startingDirectory(for: serverPath)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        serverPath = abbreviated(url.path)
        serverError = InitialSetupValidation.serverError(for: serverPath)
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Main GGUF Model"
        panel.message = "Select the DwarfStar-specific main GGUF model ds4-server should load."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [gguf]
        }
        if !serverPath.isEmpty, serverError == nil {
            panel.directoryURL = InitialSetupValidation.preferredModelDirectory(
                forServerPath: serverPath
            )
        } else {
            panel.directoryURL = startingDirectory(for: modelPath)
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelPath = abbreviated(url.path)
        modelError = InitialSetupValidation.modelError(for: modelPath)
    }

    private func continueSetup() {
        serverError = InitialSetupValidation.serverError(for: serverPath)
        modelError = InitialSetupValidation.modelError(for: modelPath)
        guard canContinue else { return }
        onContinue(serverPath, modelPath)
    }

    private func startingDirectory(for path: String) -> URL {
        guard !path.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: expanded(path)).deletingLastPathComponent()
    }

    private func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

@MainActor
final class InitialSetupWindowController: NSWindowController {
    init(
        onContinue: @escaping (
            _ serverPath: String,
            _ modelPath: String
        ) -> Void
    ) {
        let view = InitialSetupView(onContinue: onContinue)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Set Up DS Menu Bar"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
