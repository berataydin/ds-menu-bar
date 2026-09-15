// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings panes

private enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general
    case model
    case server
    case performance
    case kvCache
    case mtp
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .model: return "Model"
        case .server: return "Server"
        case .performance: return "Performance"
        case .kvCache: return "KV Cache"
        case .mtp: return "MTP"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .model: return "cube"
        case .server: return "network"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .kvCache: return "internaldrive"
        case .mtp: return "bolt"
        case .diagnostics: return "stethoscope"
        }
    }
}

private struct SettingsDerivedInputs: Equatable {
    private struct FileIdentity: Equatable {
        let size: UInt64?
        let modificationDate: Date?

        init(path: String) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            size = (attributes?[.size] as? NSNumber)?.uint64Value
            modificationDate = attributes?[.modificationDate] as? Date
        }
    }

    let serverPath: String
    let modelPath: String
    let mtpPath: String
    let visionPath: String
    private let modelIdentity: FileIdentity
    private let mtpIdentity: FileIdentity
    private let visionIdentity: FileIdentity

    init(_ config: ServerConfiguration.Config) {
        serverPath = config.serverPath
        modelPath = config.modelPath
        mtpPath = config.mtpPath
        visionPath = config.visionPath
        let directory = DS4ServerCommand.serverDirectory(for: config.serverPath)
        modelIdentity = FileIdentity(path: DS4ServerCommand.resolving(config.modelPath, relativeTo: directory))
        mtpIdentity = FileIdentity(path: DS4ServerCommand.resolving(config.mtpPath, relativeTo: directory))
        visionIdentity = FileIdentity(path: DS4ServerCommand.resolving(config.visionPath, relativeTo: directory))
    }
}

// MARK: - Settings view

/// Hosted by the app's `Settings` scene. The pane controls use native macOS
/// buttons while the active server configuration remains unchanged until the
/// user applies a valid draft.
struct SettingsView: View {
    @ObservedObject var server: ServerManager
    @State private var draft: ServerConfiguration.Config
    @State private var modelProfile: DS4ModelProfile
    @State private var supportProfile: DS4SupportProfile
    @State private var visionProfile: DS4VisionProfile
    @State private var loadedModelKey: String
    @State private var derivedInputs: SettingsDerivedInputs
    /// Cached rather than recomputed per row: every row reads this, and
    /// `validationErrors()` walks the whole configuration (including two path
    /// resolutions), so recomputing it per row meant dozens of full passes per
    /// keystroke.
    @State private var validationErrors: [ServerConfiguration.Config.Field: String]
    @State private var statusNotice = ""
    @State private var deleteLogsDisabled = false
    @State private var deleteTraceDisabled = false
    @State private var logDeletionError = ""
    @State private var traceDeletionError = ""
    @State private var layoutRevision = 0
    @SceneStorage("dsmenubar.settingsPane") private var selectedPaneRaw = SettingsPane.general.rawValue

    init(server: ServerManager) {
        _server = ObservedObject(wrappedValue: server)
        let snapshot = server.configurationSnapshot()
        _draft = State(initialValue: snapshot)
        let derived = Self.derivedProfiles(for: snapshot)
        _modelProfile = State(initialValue: derived.model)
        _supportProfile = State(initialValue: derived.support)
        _visionProfile = State(initialValue: derived.vision)
        _loadedModelKey = State(initialValue: ServerConfiguration.Config.modelKey(
            for: snapshot.modelPath,
            serverPath: snapshot.serverPath
        ))
        _derivedInputs = State(initialValue: SettingsDerivedInputs(snapshot))
        _validationErrors = State(initialValue: snapshot.validationErrors(
            modelProfile: derived.model,
            supportProfile: derived.support,
            visionProfile: derived.vision
        ))
    }

    private var activePane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    private var hasChanges: Bool {
        draft != server.configurationSnapshot()
    }

    private var canApply: Bool {
        hasChanges && validationErrors.isEmpty
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { draft.launchAtLogin },
            set: { requested in
                let update = server.setLaunchAtLogin(requested)
                draft.launchAtLogin = update.isEnabled
                statusNotice = update.warning ?? (
                    update.isEnabled ? "Launch at login enabled." : "Launch at login disabled."
                )
            }
        )
    }

    private var applyTitle: String {
        switch server.status {
        case .starting, .running, .restarting:
            return "Apply & Restart"
        case .stopped, .stopping, .error:
            return "Apply"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            paneNavigation
            Divider()
            activePaneContent
        }
        .formStyle(.grouped)
        .navigationTitle(activePane.title)
        .frame(minWidth: 640, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Revert") {
                    restoreActiveDraft()
                }
                .disabled(!hasChanges)
                .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(server.status.actionTitle, action: performServerAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(applyTitle, action: applySettings)
                    .disabled(!canApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("Server status: ")
                    Text(server.status.menuText)
                        .foregroundStyle(server.statusColor)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Server status: \(server.status.menuText)")
                if !statusNotice.isEmpty {
                    Text(statusNotice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .background(SettingsWindowSizer(revision: layoutRevision))
        .onChange(of: draft) { _, newValue in
            refreshDerivedState(for: newValue)
            layoutRevision += 1
        }
        .onChange(of: statusNotice) {
            layoutRevision += 1
        }
        .task(id: deleteLogsDisabled) {
            guard deleteLogsDisabled else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            deleteLogsDisabled = false
        }
        .task(id: deleteTraceDisabled) {
            guard deleteTraceDisabled else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            deleteTraceDisabled = false
        }
        .alert("Unable to Delete Logs", isPresented: Binding(
            get: { !logDeletionError.isEmpty },
            set: { if !$0 { logDeletionError = "" } }
        )) {
            Button("OK") { logDeletionError = "" }
        } message: {
            Text(logDeletionError)
        }
        .alert("Unable to Delete Trace", isPresented: Binding(
            get: { !traceDeletionError.isEmpty },
            set: { if !$0 { traceDeletionError = "" } }
        )) {
            Button("OK") { traceDeletionError = "" }
        } message: {
            Text(traceDeletionError)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: SettingsNavigation.destinationNotification
        )) { notification in
            guard let rawValue = notification.object as? String,
                  let destination = ServerSettingsDestination(rawValue: rawValue)
            else { return }
            selectedPaneRaw = destinationPaneRaw(destination)
            UserDefaults.standard.removeObject(forKey: SettingsNavigation.pendingPaneKey)
        }
        // Closing Settings without applying is equivalent to cancelling a draft,
        // so the next opening starts from the active configuration. Both hooks
        // are wired: the view is long-lived, and a Settings window that is closed
        // rather than destroyed does not reliably deliver onDisappear.
        .onAppear(perform: resetDraft)
        .onDisappear(perform: resetDraft)
    }

    private func resetDraft() {
        restoreActiveDraft()
        if let destination = SettingsNavigation.consumePendingPane() {
            selectedPaneRaw = destination.rawValue
        }
    }

    private func restoreActiveDraft() {
        let snapshot = server.configurationSnapshot()
        draft = snapshot
        loadedModelKey = ServerConfiguration.Config.modelKey(
            for: snapshot.modelPath,
            serverPath: snapshot.serverPath
        )
        refreshDerivedState(for: snapshot)
        statusNotice = ""
    }

    private static func derivedProfiles(for config: ServerConfiguration.Config) -> (
        model: DS4ModelProfile,
        support: DS4SupportProfile,
        vision: DS4VisionProfile
    ) {
        let serverDirectory = DS4ServerCommand.serverDirectory(for: config.serverPath)
        return (
            GGUFModelInspector.profile(for: config.modelPath, relativeTo: serverDirectory),
            GGUFModelInspector.supportProfile(for: config.mtpPath, relativeTo: serverDirectory),
            GGUFModelInspector.visionProfile(for: config.visionPath, relativeTo: serverDirectory)
        )
    }

    private func refreshDerivedState(for config: ServerConfiguration.Config) {
        let inputs = SettingsDerivedInputs(config)
        if inputs != derivedInputs {
            let derived = Self.derivedProfiles(for: config)
            modelProfile = derived.model
            supportProfile = derived.support
            visionProfile = derived.vision
            derivedInputs = inputs
        }
        validationErrors = config.validationErrors(
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionProfile: visionProfile
        )
    }

    private func destinationPaneRaw(_ destination: ServerSettingsDestination) -> String {
        switch destination {
        case .general: return SettingsPane.general.rawValue
        case .model: return SettingsPane.model.rawValue
        case .mtp: return SettingsPane.mtp.rawValue
        }
    }

    private var paneNavigation: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPaneRaw = pane.rawValue
                    } label: {
                        Label(pane.title, systemImage: pane.systemImage)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(pane == activePane ? .accentColor : .secondary)
                    .background(
                        pane == activePane ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .accessibilityAddTraits(pane == activePane ? [.isSelected] : [])
                    .accessibilityLabel(pane.title)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var activePaneContent: some View {
        ZStack {
            paneLayer(.general) { generalPane }
            paneLayer(.model) { modelPane }
            paneLayer(.server) { serverPane }
            paneLayer(.performance) { performancePane }
            paneLayer(.kvCache) { kvCachePane }
            paneLayer(.mtp) { mtpPane }
            paneLayer(.diagnostics) { diagnosticsPane }
        }
    }

    private func paneLayer<Content: View>(
        _ pane: SettingsPane,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(activePane == pane ? 1 : 0)
            .disabled(activePane != pane)
            .allowsHitTesting(activePane == pane)
            .accessibilityHidden(activePane != pane)
            .zIndex(activePane == pane ? 1 : 0)
    }

    // MARK: Panes

    private var generalPane: some View {
        Form {
            paneIntro(
                "DS Menu Bar",
                "Configure the local Apple silicon Metal server managed by this app."
            )

            Section("Application") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .help("Changes take effect immediately.")
                LabeledContent("Platform") {
                    Text("macOS • Apple silicon • Metal")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Command preview") {
                Text(DS4ServerCommand.preview(
                    configuration: draft,
                    modelProfile: modelProfile,
                    supportProfile: supportProfile,
                    visionProfile: visionProfile
                ))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Section {
                Button("Restore Tuning Defaults", role: .destructive) {
                    draft = draft.restoringTuningDefaults(for: modelProfile)
                    statusNotice = "Tuning defaults restored for \(modelProfile.displayName) in this draft. Apply to use them."
                }
            } footer: {
                Text("Restores tuning and feature settings for the selected model while preserving its model paths and the app's General, Server, and Diagnostics settings. Changes take effect only after Apply.")
            }
        }
    }

    private var modelPane: some View {
        Form {
            paneIntro(
                "Model",
                "Choose the executable and main GGUF for one local Metal ds4-server on this Mac."
            )

            Section("Files") {
                pathRow("ds4-server", text: serverPathBinding, help: "The ds4-server executable")
                pathRow("Model", text: modelPathBinding, extensions: ["gguf"], errorKey: .modelPath, help: "The main GGUF model")
            }

            Section("Detected model") {
                LabeledContent("Type") {
                    Text(modelProfile.displayName)
                        .foregroundStyle(modelProfile.isKnown ? Color.secondary : Color.orange)
                }
                if let architecture = modelProfile.architecture {
                    LabeledContent("GGUF architecture") {
                        Text(architecture).font(.system(.body, design: .monospaced))
                    }
                }
                if modelProfile.isSupportArtifact {
                    Label("\(modelProfile.displayName) is not a main model. Choose the main model GGUF here and use this file in its appropriate settings pane.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if !modelProfile.isKnown {
                    Label("Model-specific options are unavailable until the GGUF architecture is recognized. Common server options remain usable.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if modelProfile.supportsVision {
                    Toggle("Use vision encoder", isOn: $draft.visionEnabled)
                    pathRow("Vision encoder", text: $draft.visionPath, extensions: ["gguf"], errorKey: .visionPath, help: visionHelp)
                    if modelProfile.family == .qwen38 && draft.visionEnabled {
                        integerRow(
                            "Maximum image tokens",
                            value: $draft.qwenImageMaxTokens,
                            errorKey: .qwenImageMaxTokens,
                            note: "DS4_QWEN4_IMAGE_MAX_TOKENS controls the Qwen vision resize budget."
                        )
                    }
                }
                if modelProfile.family == .qwen38 {
                    LabeledContent("Original BF16 n-grams") {
                        Text(modelProfile.hasNativeQwenNGrams == true ? "Included in model" : "Not detected")
                            .foregroundStyle(modelProfile.hasNativeQwenNGrams == true ? Color.secondary : Color.orange)
                    }
                    Text(modelProfile.hasNativeQwenNGrams == true
                         ? "Current ds4 reads the n-gram table directly from the self-contained GGUF. Keep the model on a fast local SSD."
                         : "ds4-server will validate the selected Qwen GGUF when it starts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if modelProfile.family == .deepSeek41 {
                    Text("Engram is included in the main GGUF and remains disk backed. Keep the model on a fast local SSD.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Working directory") {
                Text("The server runs with the executable's directory as its working directory. Relative vision and MTP paths resolve from there.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serverPane: some View {
        Form {
            paneIntro(
                "Server",
                "Configure the local HTTP endpoint and how many independent clients can be resident."
            )

            Section("HTTP endpoint") {
                textRow("Host", text: $draft.host, errorKey: .host)
                integerRow("Port", value: $draft.port, errorKey: .port, grouped: false)
                Toggle("Allow browser clients (CORS)", isOn: $draft.corsEnabled)
            }

            Section("Requests") {
                integerRow(
                    "Default output tokens",
                    value: $draft.defaultTokens,
                    errorKey: .defaultTokens,
                    note: "0 uses ds4-server's default."
                )
                integerRow(
                    "Resident sessions",
                    value: $draft.batchedSessions,
                    errorKey: .batchedSessions,
                    note: "0 disables native batching. More sessions multiply context memory."
                )
                if draft.batchedSessions > 0 {
                    integerRow(
                        "Mixed prefill quantum",
                        value: $draft.mixedPrefillQuantum,
                        errorKey: .mixedPrefillQuantum,
                        note: "The amount of prompt work allowed between active generations."
                    )
                    Text("ds4-server cannot run native session batching and MTP together. Turn MTP off in the MTP pane to use batching.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var performancePane: some View {
        Form {
            paneIntro(
                "Performance",
                "Tune the unified memory, local SSD use, throughput, and sustained power of this Mac."
            )

            Section("Context") {
                if modelProfile.family == .qwen38 {
                    Picker("Qwen YaRN extension", selection: $draft.qwenYarnFactor) {
                        ForEach(QwenYarnFactor.allCases, id: \.self) { factor in
                            Text(factor.title).tag(factor)
                        }
                    }
                    Text("DS4_QWEN4_YARN_FACTOR extends the native 262,144-token context. It can reduce quality on shorter prompts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                integerRow(
                    "Context size",
                    value: $draft.ctxSize,
                    errorKey: .ctxSize,
                    note: "Larger contexts require more memory. Think Max requires at least 393,216 tokens."
                )
                if modelProfile.supportsManualPrefill {
                    integerRow(
                        "Prefill chunk",
                        value: $draft.prefillChunk,
                        errorKey: .prefillChunk,
                        note: "0 uses the model/backend default."
                    )
                } else {
                    LabeledContent("Prefill chunk") { Text("Automatic").foregroundStyle(.secondary) }
                    Text("The selected model's Metal graph chooses its prefill capacity.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Metal") {
                LabeledContent("GPU power limit") {
                    if modelProfile.requiresFullPower {
                        HStack(spacing: 10) {
                            Text("100% required").foregroundStyle(.secondary)
                            if draft.powerPercent != 100 {
                                Button("Set to 100%") { draft.powerPercent = 100 }
                            }
                        }
                    } else {
                        let constraint = draft.integerConstraint(for: .powerPercent, modelProfile: modelProfile)
                        HStack(spacing: 10) {
                            Slider(
                                value: powerBinding,
                                in: Double(constraint?.minimum ?? 1)...Double(constraint?.maximum ?? 100),
                                step: Double(constraint?.step ?? 1)
                            )
                                .frame(minWidth: 180)
                            Text("\(draft.powerPercent)%")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
                if let error = validationErrors[.powerPercent] {
                    validationLabel(error)
                }
                integerRow(
                    "CPU helper threads",
                    value: $draft.threads,
                    errorKey: .threads,
                    note: "0 uses automatic behavior. This affects host-side/reference work, not Metal shader parallelism."
                )
                Toggle("Warm model weights at startup", isOn: $draft.warmWeights)
                Toggle("Prefer exact kernels", isOn: $draft.quality)
            }

            Section {
                if modelProfile.supportsSSDStreaming {
                    Toggle("Use SSD-backed model streaming", isOn: $draft.ssdStreamingEnabled)
                } else {
                    LabeledContent("SSD-backed model streaming") {
                        Text("Unavailable for \(modelProfile.displayName)").foregroundStyle(.secondary)
                    }
                    if draft.ssdStreamingEnabled {
                        Button("Turn Off SSD Streaming") { draft.ssdStreamingEnabled = false }
                    }
                }
                if let error = validationErrors[.ssdStreamingEnabled] {
                    validationLabel(error)
                }
                if draft.ssdStreamingEnabled {
                    Toggle("Skip the default expert-cache preload", isOn: $draft.ssdStreamingCold)
                    textRow(
                        "Expert cache override",
                        text: $draft.ssdStreamingCacheExperts,
                        errorKey: .ssdStreamingCacheExperts,
                        note: ssdCacheHelp
                    )
                    if modelProfile.isFullGLM {
                        integerRow(
                            "Full resident layers",
                            value: $draft.ssdStreamingFullLayers,
                            errorKey: .ssdStreamingFullLayers,
                            note: "-1 uses Automatic; 0 disables full-layer residency."
                        )
                    }
                    integerRow(
                        "Preloaded experts",
                        value: $draft.ssdStreamingPreloadExperts,
                        errorKey: .ssdStreamingPreloadExperts,
                        note: "0 uses Automatic."
                    )
                }
            } header: {
                Text("SSD streaming")
            } footer: {
                Text(modelProfile.isFullGLM
                     ? "Automatic SSD streaming is the recommended starting point for full GLM on a 128 GB Mac. Context and expert caches share unified memory with macOS and other processes."
                     : "SSD streaming uses this Mac's local storage for models that do not fit comfortably in available unified memory.")
            }
        }
    }

    private var kvCachePane: some View {
        Form {
            paneIntro(
                "KV Cache",
                "Disk KV checkpoints let later prompts and restarted sessions reuse compatible prefixes."
            )

            Section("Disk cache") {
                Toggle("Enable disk KV cache", isOn: $draft.kvDiskEnabled)
                if draft.kvDiskEnabled {
                    pathRow("Cache directory", text: $draft.kvDiskDir, directory: true, help: "The server creates this directory if needed")
                    integerRow("Disk budget (MB)", value: $draft.kvDiskSpaceMB, errorKey: .kvDiskSpaceMB)
                }
            }

            if draft.kvDiskEnabled {
                Section("Checkpoint policy") {
                    integerRow(
                        "Minimum cache tokens",
                        value: $draft.kvCacheMinTokens,
                        errorKey: .kvCacheMinTokens,
                        note: "Checkpoints shorter than this are not saved or loaded."
                    )
                    integerRow(
                        "Cold-cache maximum tokens",
                        value: $draft.kvCacheColdMaxTokens,
                        errorKey: .kvCacheColdMaxTokens,
                        note: "0 disables cold first-prompt saves; otherwise it must be at least the minimum."
                    )
                    integerRow(
                        "Continued interval tokens",
                        value: $draft.kvCacheContinuedIntervalTokens,
                        errorKey: .kvCacheContinuedIntervalTokens,
                        note: "0 disables aligned continued-frontier saves."
                    )
                    integerRow(
                        "Boundary trim tokens",
                        value: $draft.kvCacheBoundaryTrimTokens,
                        errorKey: .kvCacheBoundaryTrimTokens
                    )
                    integerRow(
                        "Boundary alignment tokens",
                        value: $draft.kvCacheBoundaryAlignTokens,
                        errorKey: .kvCacheBoundaryAlignTokens,
                        note: "0 disables boundary alignment."
                    )
                }

                Section("Compatibility") {
                    Toggle("Reject checkpoints from a different quantization", isOn: $draft.kvCacheRejectDifferentQuant)
                    Toggle("Disable exact DSML tool replay", isOn: $draft.disableExactDSMLToolReplay)
                    integerRow(
                        "Tool-memory limit",
                        value: $draft.toolMemoryMaxIDs,
                        errorKey: .toolMemoryMaxIDs,
                        note: "Maximum exact tool-call IDs retained in memory."
                    )
                }
            }
        }
    }

    private var mtpPane: some View {
        Form {
            paneIntro(
                "MTP",
                "MTP is optional speculative decoding. The available controls follow the selected GGUF's capabilities."
            )

            if modelProfile.supportsEmbeddedMTP {
                Section("Embedded MTP") {
                    Toggle("Enable embedded MTP", isOn: embeddedMTPBinding)
                    if draft.mtpMode == .embedded {
                        Text(embeddedMTPDraftDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if modelProfile.family == .qwen38 {
                            Picker("Draft depth", selection: $draft.qwenMTPDepth) {
                                ForEach(QwenMTPDepth.allCases, id: \.self) { depth in
                                    Text(depth.title).tag(depth)
                                }
                            }
                            Text("Sets DS4_QWEN4_MTP_DEPTH to 0, 2, or 3. Automatic selects one or two draft tokens from recent acceptance.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Record MTP timing", isOn: $draft.mtpTiming)
                        Toggle("Use exact sampling", isOn: $draft.mtpExactSampling)
                    }
                }
            } else if modelProfile.supportsExternalMTP {
                Section("Speculative decoding") {
                    Picker("Mode", selection: $draft.mtpMode) {
                        Text(MTPMode.off.title).tag(MTPMode.off)
                        Text(MTPMode.dspark.title).tag(MTPMode.dspark)
                        Text(MTPMode.external.title).tag(MTPMode.external)
                    }
                    if draft.mtpMode == .external {
                        pathRow("Legacy MTP model", text: $draft.mtpPath, extensions: ["gguf"], errorKey: .mtpPath, help: "A legacy DeepSeek MTP support GGUF")
                        supportModelStatus(expected: .legacyMTP)
                        mtpDraftRows
                    } else if draft.mtpMode == .dspark {
                        pathRow("DSpark model", text: $draft.mtpPath, extensions: ["gguf"], errorKey: .mtpPath, help: "The DSpark support GGUF")
                        supportModelStatus(expected: .dspark)
                        Toggle("Automatic confidence threshold", isOn: dsparkAutomaticConfidenceBinding)
                        if draft.dsparkConfidence == nil {
                            Text("ds4-server selects 0.6 for greedy decoding and 0.8 for stochastic exact sampling.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            decimalRow(
                                "Confidence threshold",
                                value: dsparkConfidenceBinding,
                                errorKey: .dsparkConfidence,
                                note: "An explicit override from 0 through 1."
                            )
                        }
                        Toggle("Use exact sampling", isOn: $draft.mtpExactSampling)
                        Toggle("Strict DSpark mode", isOn: $draft.dsparkStrict)
                    }
                    if let error = validationErrors[.mtpMode] {
                        validationLabel(error)
                    }
                }
            } else {
                Section("Speculative decoding") {
                    Label(modelProfile.isSupportArtifact
                          ? "This is a support GGUF and cannot be used as the main model."
                          : modelProfile.isKnown
                            ? "MTP is unavailable for \(modelProfile.displayName)."
                            : "MTP controls are unavailable because this GGUF model type is not recognized by DS Menu Bar.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(modelProfile.isSupportArtifact ? Color.red : Color.orange)
                }
            }

            if draft.batchedSessions > 0 && draft.mtpMode != .off && modelProfile.isKnown {
                Section {
                    Label("Set Resident sessions to 0 in the Server pane, or turn MTP off — ds4-server cannot run both.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var embeddedMTPDraftDescription: String {
        if modelProfile.family == .qwen38 {
            return "Qwen supports one or two embedded draft tokens. --mtp-draft controls legacy external MTP."
        }
        return "GLM uses its fixed built-in MTP cycle. --mtp-draft controls legacy external MTP."
    }

    @ViewBuilder
    private var mtpDraftRows: some View {
        let constraint = draft.integerConstraint(for: .mtpDraft, modelProfile: modelProfile)
        let values = (constraint?.minimum ?? DS4ConfigurationLimits.minMTPDraft)...(constraint?.maximum ?? DS4ConfigurationLimits.maxMTPDraft)
        LabeledContent("Draft tokens") {
            Picker("Draft tokens", selection: $draft.mtpDraft) {
                ForEach(values, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
        if let constraint {
            Text("Valid range: \(constraint.minimum.formatted())–\(constraint.maximum.formatted())")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        decimalRow(
            "Confidence margin",
            value: $draft.mtpMargin,
            errorKey: .mtpMargin,
            note: "0 disables the confidence margin; the server accepts 0 through 1,000."
        )
    }

    private var diagnosticsPane: some View {
        Form {
            paneIntro(
                "Diagnostics",
                "Server output is captured in the log. Optional tracing records prompts, cache decisions, output, and tool calls."
            )

            Section("Files") {
                pathRow(
                    "Server log",
                    text: $draft.logPath,
                    errorKey: .logPath,
                    help: "stdout and stderr captured by DS Menu Bar"
                )
                integerRow(
                    "Maximum size per log (MB)",
                    value: $draft.logMaxSizeMB,
                    errorKey: .logMaxSizeMB,
                    note: "One rotated backup is retained; total log storage may reach twice this size."
                )
                LabeledContent("Log files") {
                    HStack {
                        Button("Open Log in Console") {
                            ServerLogActions.openInConsole(logPath: server.logPath)
                        }
                        Button("Delete Logs", role: .destructive, action: deleteLogs)
                            .disabled(deleteLogsDisabled)
                    }
                }
                Toggle("Record request trace", isOn: $draft.traceEnabled)
                pathRow(
                    "Trace file",
                    text: $draft.tracePath,
                    errorKey: .tracePath,
                    help: "The ds4-server request trace"
                )
                .disabled(!draft.traceEnabled)
                LabeledContent("Trace data") {
                    Button("Delete Trace", role: .destructive, action: deleteTrace)
                        .disabled(
                            deleteTraceDisabled ||
                            draft.tracePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            server.isWritingTrace(at: draft.tracePath)
                        )
                        .help(
                            server.isWritingTrace(at: draft.tracePath)
                                ? "Stop the server or apply tracing off before deleting the active trace."
                                : "Delete the request trace at the path above."
                        )
                }
            }

            Section("Server diagnostics") {
                textRow(
                    "Simulate used memory",
                    text: simulateUsedMemoryTextBinding,
                    errorKey: .simulateUsedMemory,
                    note: numericTextHelp(
                        for: .simulateUsedMemory,
                        prefix: "Optional GiB value, such as 8 or 40GB, for testing memory-pressure behavior."
                    )
                )
            }

        }
    }

    // MARK: Shared rows and helpers

    @ViewBuilder
    private func paneIntro(_ title: String, _ description: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func textRow(
        _ title: String,
        text: Binding<String>,
        errorKey: ServerConfiguration.Config.Field? = nil,
        note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 260)
                    .accessibilityLabel(title)
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if let errorKey, let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    @ViewBuilder
    private func integerRow(
        _ title: String,
        value: Binding<Int>,
        errorKey: ServerConfiguration.Config.Field,
        note: String? = nil,
        // Token counts read better grouped; identifiers like a port number do
        // not — "8,000" is not how anyone writes a port.
        grouped: Bool = true
    ) -> some View {
        let constraint = draft.integerConstraint(for: errorKey, modelProfile: modelProfile)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", value: value,
                          format: .number.grouping(grouped ? .automatic : .never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 150)
                    .accessibilityLabel(title)
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if let constraint {
                let range = constraint.minimum == constraint.maximum
                    ? "Required value: \(constraint.minimum.formatted())"
                    : "Valid range: \(constraint.minimum.formatted())–\(constraint.maximum.formatted())"
                let recommended = constraint.recommendedValue.map { "New-profile value: \($0.formatted())" }
                Text([range, constraint.sentinelDescription, recommended].compactMap { $0 }.joined(separator: ". "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    @ViewBuilder
    private func decimalRow(
        _ title: String,
        value: Binding<Double>,
        errorKey: ServerConfiguration.Config.Field,
        note: String? = nil
    ) -> some View {
        let constraint = draft.decimalConstraint(for: errorKey)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 150)
                    .accessibilityLabel(title)
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if let constraint {
                Text("Valid range: \(constraint.minimum.formatted())–\(constraint.maximum.formatted())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    @ViewBuilder
    private func pathRow(
        _ title: String,
        text: Binding<String>,
        directory: Bool = false,
        extensions: [String] = [],
        errorKey: ServerConfiguration.Config.Field? = nil,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    TextField("", text: text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260, maxWidth: 420)
                        .accessibilityLabel(title)
                    Button {
                        choosePath(into: text, directory: directory, extensions: extensions)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(directory ? "Choose folder…" : "Choose file…")
                    .accessibilityLabel(directory ? "Choose folder" : "Choose file")
                }
            }
            Text(help).font(.footnote).foregroundStyle(.secondary)
            if let errorKey, let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    @ViewBuilder
    private func validationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }

    private var powerBinding: Binding<Double> {
        Binding(
            get: { Double(draft.powerPercent) },
            set: { draft.powerPercent = Int($0.rounded()) }
        )
    }

    private var visionHelp: String {
        switch modelProfile.family {
        case .glm53Flash: return "Optional GLM 5.3 Flash vision encoder GGUF; required when enabled"
        case .deepSeek41: return "Matching DeepSeek V4.1 Flash vision encoder GGUF; required when enabled"
        case .qwen38: return "Qwen3-VL mmproj GGUF (clip / qwen3vl_merger); required when enabled"
        default: return "Compatible vision GGUF; required when enabled"
        }
    }

    private var ssdCacheHelp: String {
        numericTextHelp(
            for: .ssdStreamingCacheExperts,
            prefix: "A GiB budget such as 40GB is also accepted."
        )
    }

    private func numericTextHelp(
        for field: ServerConfiguration.Config.Field,
        prefix: String
    ) -> String {
        guard let constraint = draft.numericTextConstraint(for: field, modelProfile: modelProfile) else {
            return prefix
        }
        return "\(prefix) \(constraint.rangeDescription). \(constraint.sentinelDescription)."
    }

    private var modelPathBinding: Binding<String> {
        Binding(
            get: { draft.modelPath },
            set: modelPathChanged
        )
    }

    private var serverPathBinding: Binding<String> {
        Binding(
            get: { draft.serverPath },
            set: serverPathChanged
        )
    }

    @ViewBuilder
    private func supportModelStatus(expected: DS4SupportKind) -> some View {
        if !draft.mtpPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LabeledContent("Detected support type") {
                Text(supportProfile.kind.title)
                    .foregroundStyle(supportProfile.kind == expected ? Color.secondary : Color.red)
            }
        }
    }

    private var embeddedMTPBinding: Binding<Bool> {
        Binding(
            get: { draft.mtpMode == .embedded },
            set: { draft.mtpMode = $0 ? .embedded : .off }
        )
    }

    private var dsparkConfidenceBinding: Binding<Double> {
        Binding(
            get: { draft.dsparkConfidence ?? draft.automaticDSparkConfidence },
            set: { draft.dsparkConfidence = $0 }
        )
    }

    private var dsparkAutomaticConfidenceBinding: Binding<Bool> {
        Binding(
            get: { draft.dsparkConfidence == nil },
            set: { automatic in
                if automatic {
                    draft.dsparkConfidence = nil
                } else if draft.dsparkConfidence == nil {
                    draft.dsparkConfidence = draft.automaticDSparkConfidence
                }
            }
        )
    }

    private var simulateUsedMemoryTextBinding: Binding<String> {
        Binding(
            get: { draft.simulateUsedMemory },
            set: { draft.simulateUsedMemory = $0 }
        )
    }

    private func modelPathChanged(_ path: String) {
        var candidateConfig = draft
        candidateConfig.modelPath = path
        selectModelIfAvailable(in: candidateConfig)
    }

    private func serverPathChanged(_ path: String) {
        var candidateConfig = draft
        candidateConfig.serverPath = path
        selectModelIfAvailable(in: candidateConfig)
    }

    private func selectModelIfAvailable(in candidateConfig: ServerConfiguration.Config) {
        let key = ServerConfiguration.Config.modelKey(
            for: candidateConfig.modelPath,
            serverPath: candidateConfig.serverPath
        )
        guard key != loadedModelKey else {
            draft = candidateConfig
            return
        }

        let directory = DS4ServerCommand.serverDirectory(for: candidateConfig.serverPath)
        let candidate = DS4ServerCommand.resolving(candidateConfig.modelPath, relativeTo: directory)
        guard FileManager.default.isReadableRegularFile(atPath: candidate)
        else {
            // Keep the last valid model loaded while allowing an incomplete
            // manually-entered path to remain visible and invalid in the draft.
            // Mutating draft triggers .onChange, which refreshes derived state.
            draft = candidateConfig
            return
        }
        let profile = GGUFModelInspector.profile(
            for: candidateConfig.modelPath,
            relativeTo: directory
        )
        draft = candidateConfig.selectingModel(
            path: candidateConfig.modelPath,
            serverPath: candidateConfig.serverPath,
            profile: profile,
            storingCurrentAs: loadedModelKey
        )
        loadedModelKey = key
    }

    private func choosePath(into text: Binding<String>, directory: Bool, extensions: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = directory
        if !directory, !extensions.isEmpty {
            let types = extensions.compactMap { UTType(filenameExtension: $0) }
            if !types.isEmpty { panel.allowedContentTypes = types }
        }

        let current = DS4ServerCommand.expandingTilde(text.wrappedValue)
        if !current.isEmpty {
            let startDir = directory ? current : (current as NSString).deletingLastPathComponent
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: startDir, isDirectory: &isDirectory), isDirectory.boolValue {
                panel.directoryURL = URL(fileURLWithPath: startDir)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            text.wrappedValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func applySettings() {
        // Report what the manager actually did — a .starting status whose
        // process never came up is applied, not restarted.
        let result = server.applyConfiguration(draft)
        switch result.kind {
        case .invalid:
            return
        case .applied, .appliedAndRestarting:
            break
        }
        // Without this the launch-at-login read-back below would flip the toggle
        // back with no explanation of why.
        statusNotice = result.warning ?? ""
        let snapshot = server.configurationSnapshot()
        draft = snapshot
        loadedModelKey = ServerConfiguration.Config.modelKey(
            for: snapshot.modelPath,
            serverPath: snapshot.serverPath
        )
        refreshDerivedState(for: snapshot)
    }

    private func performServerAction() {
        switch server.status {
        case .stopped, .error:
            server.start()
        case .starting, .running, .restarting, .stopping:
            server.stop()
        }
    }

    private func deleteLogs() {
        do {
            try server.clearLog()
            deleteLogsDisabled = true
        } catch {
            logDeletionError = error.localizedDescription
        }
    }

    private func deleteTrace() {
        do {
            try server.deleteTrace(at: draft.tracePath)
            deleteTraceDisabled = true
        } catch {
            traceDeletionError = error.localizedDescription
        }
    }
}

private struct SettingsWindowSizer: NSViewRepresentable {
    let revision: Int

    func makeNSView(context: Context) -> SettingsWindowSizingView {
        SettingsWindowSizingView()
    }

    func updateNSView(_ nsView: SettingsWindowSizingView, context: Context) {
        nsView.scheduleResize()
    }
}

@MainActor
private final class SettingsWindowSizingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleResize()
    }

    func scheduleResize() {
        DispatchQueue.main.async { [weak self] in
            self?.resizeToFitTallestPane()
        }
    }

    private func resizeToFitTallestPane() {
        guard let window,
              window.isVisible,
              !window.inLiveResize,
              let screen = window.screen ?? NSScreen.main,
              let contentView = window.contentView
        else { return }

        let largestOverflow = scrollViews(in: contentView).reduce(CGFloat.zero) { result, scrollView in
            guard let documentView = scrollView.documentView else { return result }
            let overflow = documentView.bounds.height - scrollView.contentView.bounds.height
            return max(result, overflow)
        }
        guard largestOverflow > 1 else { return }

        let availableFrame = screen.visibleFrame.insetBy(dx: 0, dy: 16)
        let targetHeight = min(
            ceil(window.frame.height + largestOverflow),
            availableFrame.height
        )
        guard targetHeight > window.frame.height + 1 else { return }

        var frame = window.frame
        let top = min(frame.maxY, availableFrame.maxY)
        frame.size.height = targetHeight
        frame.origin.y = max(availableFrame.minY, top - targetHeight)
        window.setFrame(frame, display: true, animate: true)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var result = view.subviews.flatMap(scrollViews)
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        return result
    }
}

private extension ServerManager {
    var statusColor: Color {
        switch status {
        case .running: return .green
        case .error: return .red
        case .starting, .restarting, .stopping: return .orange
        case .stopped: return .secondary
        }
    }
}
