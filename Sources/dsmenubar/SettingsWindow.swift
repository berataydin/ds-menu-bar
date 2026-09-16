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

    /// The pane that renders a field's row. Apply switches to this pane when a
    /// field refuses the draft, so a message is never attached to a control on
    /// a pane the user cannot see. Exhaustive on purpose: a new field has to
    /// say where it is shown rather than silently landing on General.
    static func containing(_ field: ServerConfiguration.Config.Field) -> SettingsPane {
        switch field {
        case .serverPath, .modelPath, .visionPath, .qwenImageMaxTokens:
            return .model
        case .host, .port, .defaultTokens, .batchedSessions, .mixedPrefillQuantum:
            return .server
        case .ctxSize, .prefillChunk, .threads, .powerPercent, .ssdStreamingEnabled,
             .ssdStreamingCacheExperts, .ssdStreamingFullLayers, .ssdStreamingPreloadExperts:
            return .performance
        case .kvDiskDir, .kvDiskSpaceMB, .kvCacheMinTokens, .kvCacheColdMaxTokens,
             .kvCacheContinuedIntervalTokens, .kvCacheBoundaryTrimTokens,
             .kvCacheBoundaryAlignTokens, .toolMemoryMaxIDs:
            return .kvCache
        case .mtpMode, .mtpPath, .mtpDraft, .mtpMargin, .dsparkConfidence:
            return .mtp
        case .logPath, .logMaxSizeMB, .tracePath, .simulateUsedMemory:
            return .diagnostics
        }
    }
}

private struct SettingsDerivedInputs: Equatable, Hashable {
    // Resource paths in the draft are absolute. Editor text remains separate
    // until Apply, so changing the server directory cannot reinterpret an
    // untouched relative display string.
    let modelPath: String
    let mtpPath: String
    let visionPath: String

    init(_ config: ServerConfiguration.Config) {
        modelPath = config.modelPath
        mtpPath = config.mtpPath
        visionPath = config.visionPath
    }

    func modelDiffers(from other: Self) -> Bool {
        modelPath != other.modelPath
    }

    func supportDiffers(from other: Self) -> Bool {
        mtpPath != other.mtpPath
    }

    func visionDiffers(from other: Self) -> Bool {
        visionPath != other.visionPath
    }
}

private struct SettingsFileIdentity: Equatable, Sendable {
    let size: UInt64?
    let modificationDate: Date?

    init(path: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        size = (attributes?[.size] as? NSNumber)?.uint64Value
        modificationDate = attributes?[.modificationDate] as? Date
    }

    private init(size: UInt64?, modificationDate: Date?) {
        self.size = size
        self.modificationDate = modificationDate
    }

    static let unavailable = Self(size: nil, modificationDate: nil)
}

private struct SettingsDerivedFileIdentities: Equatable, Sendable {
    let model: SettingsFileIdentity
    let support: SettingsFileIdentity
    let vision: SettingsFileIdentity

    static let unavailable = Self(
        model: .unavailable,
        support: .unavailable,
        vision: .unavailable
    )

    static func inspecting(_ config: ServerConfiguration.Config) -> Self {
        let directory = DS4ServerCommand.serverDirectory(for: config.serverPath)
        return Self(
            model: SettingsFileIdentity(path: DS4ServerCommand.resolving(
                config.modelPath,
                relativeTo: directory
            )),
            support: SettingsFileIdentity(path: DS4ServerCommand.resolving(
                config.mtpPath,
                relativeTo: directory
            )),
            vision: SettingsFileIdentity(path: DS4ServerCommand.resolving(
                config.visionPath,
                relativeTo: directory
            ))
        )
    }
}

/// What one Apply learned about the selected files. Gathered off the main
/// thread in a single pass so the checks, the profiles they produced, and the
/// file identities they were read from cannot drift apart.
private struct SettingsApplyChecks {
    let serverError: String?
    let serverIdentity: SettingsFileIdentity
    let modelError: String?
    let model: DS4ModelProfile
    let support: DS4SupportProfile
    let vision: DS4VisionProfile
    let identities: SettingsDerivedFileIdentities
    let mtpIsReadable: Bool
    let visionIsReadable: Bool
}

private struct SettingsDerivedTaskID: Hashable {
    let inputs: SettingsDerivedInputs
    let refreshRevision: Int
}

/// A row that selects a path through a panel. Every path in the draft comes
/// from one of these, so a stored path is always something that existed when
/// it was chosen.
private enum SettingsPathField: Hashable {
    case server
    case model
    case vision
    case kvDiskDirectory
    case mtp
    case logDirectory
    case traceDirectory

    var choosesDirectory: Bool {
        switch self {
        case .server, .model, .vision, .mtp:
            return false
        case .kvDiskDirectory, .logDirectory, .traceDirectory:
            return true
        }
    }

    var choosesGGUF: Bool {
        switch self {
        case .model, .vision, .mtp:
            return true
        case .server, .kvDiskDirectory, .logDirectory, .traceDirectory:
            return false
        }
    }
}

/// The two paths naming a file the app creates rather than one the user owns.
/// A panel cannot select a file that does not exist, so the folder is picked
/// and the name is typed.
private enum SettingsFileNameField: Hashable, CaseIterable {
    case log
    case trace

    var errorKey: ServerConfiguration.Config.Field {
        switch self {
        case .log: return .logPath
        case .trace: return .tracePath
        }
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
    @State private var derivedFileIdentities: SettingsDerivedFileIdentities
    @State private var derivedRefreshRevision: Int
    @State private var completedDerivedRefreshRevision: Int
    /// Cached rather than recomputed per row: every row reads this, and
    /// `validationErrors()` walks the whole configuration, so recomputing it
    /// per row meant dozens of full passes per keystroke.
    @State private var validationErrors: [ServerConfiguration.Config.Field: String]
    @State private var serverValidationError: String?
    @State private var modelValidationError: String?
    @State private var validatedServerPath: String
    @State private var validatedServerIdentity: SettingsFileIdentity?
    @State private var validatedModelPath: String
    @State private var applyValidationID: UUID?
    @State private var isApplyingSettings = false
    @State private var isRefreshingDerivedState = false
    @State private var logNameText: String
    @State private var traceNameText: String
    @State private var statusNotice = ""
    @State private var statusNoticeIsFailure = false
    @State private var deleteLogsDisabled = false
    @State private var deleteTraceDisabled = false
    @State private var logDeletionError = ""
    @State private var traceDeletionError = ""
    @State private var layoutRevision = 0
    @State private var isSettingsVisible = false
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
        _derivedFileIdentities = State(initialValue: .unavailable)
        _derivedRefreshRevision = State(initialValue: 0)
        _completedDerivedRefreshRevision = State(initialValue: 0)
        _validationErrors = State(initialValue: snapshot.validationErrors(
            modelProfile: derived.model,
            supportProfile: derived.support,
            visionProfile: derived.vision
        ))
        _serverValidationError = State(initialValue: nil)
        _modelValidationError = State(initialValue: nil)
        _validatedServerPath = State(initialValue: snapshot.serverPath)
        _validatedServerIdentity = State(initialValue: nil)
        _validatedModelPath = State(initialValue: snapshot.modelPath)
        _applyValidationID = State(initialValue: nil)
        _logNameText = State(initialValue: DS4ServerCommand.fileName(of: snapshot.logPath))
        _traceNameText = State(initialValue: DS4ServerCommand.fileName(of: snapshot.tracePath))
    }

    private var activePane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    private var hasChanges: Bool {
        draft != server.configurationSnapshot()
    }

    private var canApply: Bool {
        hasChanges && !isApplyingSettings &&
            SettingsFileNameField.allCases.allSatisfy { fileNameError(for: $0) == nil }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { draft.launchAtLogin },
            set: { requested in
                let update = server.setLaunchAtLogin(requested)
                draft.launchAtLogin = update.isEnabled
                showNotice(update.warning ?? (
                    update.isEnabled ? "Launch at login enabled." : "Launch at login disabled."
                ), isFailure: update.warning != nil)
            }
        )
    }

    private var performanceDisplayBinding: Binding<Bool> {
        Binding(
            get: { server.showsPerformanceInMenuBar },
            set: { server.setShowsPerformanceInMenuBar($0) }
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

    /// Says what did not happen, not just what to do about it. A running
    /// server stays green while a refused apply changes nothing, so the notice
    /// has to rule out the reading that it took effect.
    private var applyRefusedNotice: String {
        switch server.status {
        case .starting, .running, .restarting:
            return "Settings not applied, server not restarted. "
                + "Fix the highlighted settings, then Apply & Restart."
        case .stopped, .stopping, .error:
            return "Settings not applied. Fix the highlighted settings, then Apply."
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
                    restoreActiveDraft(refreshDerived: true)
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
                // The notice line holds its height no matter what it contains.
                // A banner that grows and shrinks moves every control below it,
                // and a row can slide out from under a click already on its
                // way. Reserving lines on the notice itself is not enough: with
                // no notice there is no text to reserve them for. A hidden
                // two-line sizer fixes the height instead, and the notice
                // truncates into it and stays readable in the tooltip.
                ZStack(alignment: .topLeading) {
                    Text("A\nA")
                        .font(.callout)
                        .lineLimit(2, reservesSpace: true)
                        .hidden()
                        .accessibilityHidden(true)
                    HStack(spacing: 6) {
                        if isApplyingSettings {
                            ProgressView()
                                .controlSize(.small)
                        } else if statusNoticeIsFailure {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        Text(isApplyingSettings ? "Checking selected files…" : statusNotice)
                            .font(.callout)
                            .fontWeight(statusNoticeIsFailure ? .medium : .regular)
                            .foregroundStyle(statusNoticeIsFailure ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help(statusNotice)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHidden(statusNotice.isEmpty && !isApplyingSettings)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .background(SettingsWindowSizer(revision: layoutRevision))
        .onChange(of: draft) { _, newValue in
            let inputs = SettingsDerivedInputs(newValue)
            let errors = settingsValidationErrors(for: newValue)
            if errors != validationErrors {
                validationErrors = errors
                layoutRevision += 1
            }
            // A refusal names settings to fix and an Apply to press. Once
            // nothing is highlighted, or the draft matches what is already
            // running, it is telling the user to do something that is no
            // longer there.
            if statusNoticeIsFailure,
               errors.isEmpty || newValue == server.configurationSnapshot() {
                showNotice("")
            }
            isRefreshingDerivedState = inputs != derivedInputs ||
                derivedRefreshRevision != completedDerivedRefreshRevision
        }
        .task(id: SettingsDerivedTaskID(
            inputs: SettingsDerivedInputs(draft),
            refreshRevision: derivedRefreshRevision
        )) {
            await refreshDerivedStateAfterEditing(
                for: draft,
                refreshRevision: derivedRefreshRevision
            )
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            guard isSettingsVisible else { return }
            requestDerivedRefresh()
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
        .onAppear {
            isSettingsVisible = true
            resetDraft()
        }
        .onDisappear {
            isSettingsVisible = false
            resetDraft(refreshDerived: false)
        }
    }

    private func resetDraft(refreshDerived: Bool = true) {
        restoreActiveDraft(refreshDerived: refreshDerived)
        if let destination = SettingsNavigation.consumePendingPane() {
            selectedPaneRaw = destination.rawValue
        }
    }

    private func restoreActiveDraft(refreshDerived: Bool) {
        let snapshot = server.configurationSnapshot()
        draft = snapshot
        syncFileNameText(for: snapshot)
        loadedModelKey = ServerConfiguration.Config.modelKey(
            for: snapshot.modelPath,
            serverPath: snapshot.serverPath
        )
        resetSelectionValidation(for: snapshot)
        // Opening or reverting starts a new session: the first Apply checks the
        // executable again rather than trusting a check from the last one.
        validatedServerIdentity = nil
        validationErrors = settingsValidationErrors(for: snapshot)
        if refreshDerived {
            requestDerivedRefresh()
        } else {
            isRefreshingDerivedState = false
        }
        showNotice("")
    }

    private func resetSelectionValidation(for config: ServerConfiguration.Config) {
        serverValidationError = nil
        modelValidationError = nil
        validatedServerPath = config.serverPath
        validatedModelPath = config.modelPath
        applyValidationID = nil
        isApplyingSettings = false
    }

    /// One place sets both halves of the notice, so a failure can never keep
    /// the informational styling of whatever was shown before it.
    private func showNotice(_ text: String, isFailure: Bool = false) {
        statusNotice = text
        statusNoticeIsFailure = isFailure && !text.isEmpty
    }

    private func requestDerivedRefresh() {
        isRefreshingDerivedState = true
        derivedRefreshRevision &+= 1
    }

    private func syncFileNameText(for config: ServerConfiguration.Config) {
        logNameText = DS4ServerCommand.fileName(of: config.logPath)
        traceNameText = DS4ServerCommand.fileName(of: config.tracePath)
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

    private func settingsValidationErrors(
        for config: ServerConfiguration.Config,
        model: DS4ModelProfile? = nil,
        support: DS4SupportProfile? = nil,
        vision: DS4VisionProfile? = nil
    ) -> [ServerConfiguration.Config.Field: String] {
        var errors = config.validationErrors(
            modelProfile: model ?? modelProfile,
            supportProfile: support ?? supportProfile,
            visionProfile: vision ?? visionProfile
        )
        if config.serverPath == validatedServerPath, let serverValidationError {
            errors[.serverPath] = serverValidationError
        }
        if config.modelPath == validatedModelPath, let modelValidationError {
            errors[.modelPath] = modelValidationError
        }
        for field in SettingsFileNameField.allCases {
            if let error = fileNameError(for: field) {
                errors[field.errorKey] = error
            }
        }
        return errors
    }

    /// A name the app will turn into a file it creates, so it has to be one
    /// path component. The draft keeps the last usable value while the field
    /// says why the current text is not one. The trace name is only required
    /// when tracing is on, matching `validationErrors` — a disabled row must
    /// not be able to block Apply.
    private func fileNameError(for field: SettingsFileNameField) -> String? {
        if field == .trace, !draft.traceEnabled { return nil }
        let text = fileNameText(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "Enter a file name"
        }
        if text.contains("/") {
            return "A file name cannot contain a slash"
        }
        if text == "." || text == ".." {
            return "Enter a file name"
        }
        return nil
    }

    private func fileNameText(for field: SettingsFileNameField) -> String {
        switch field {
        case .log: return logNameText
        case .trace: return traceNameText
        }
    }

    private func refreshDerivedStateAfterEditing(
        for config: ServerConfiguration.Config,
        refreshRevision: Int
    ) async {
        let inputs = SettingsDerivedInputs(config)
        let forceRefresh = refreshRevision != completedDerivedRefreshRevision
        guard inputs != derivedInputs || forceRefresh else {
            isRefreshingDerivedState = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        guard !isApplyingSettings else {
            isRefreshingDerivedState = false
            return
        }

        let previousInputs = derivedInputs
        let previousModel = modelProfile
        let previousSupport = supportProfile
        let previousVision = visionProfile
        let previousModelError = modelValidationError
        let previousIdentities = derivedFileIdentities
        let derived = await Task.detached(priority: .userInitiated) {
            let directory = DS4ServerCommand.serverDirectory(for: config.serverPath)
            let identities = SettingsDerivedFileIdentities.inspecting(config)
            // Validate rather than only inspect, so a model that is missing,
            // unreadable, a directory, or a support GGUF is reported when
            // Settings opens instead of waiting for Apply to refuse it. An
            // empty path is not a bad selection: `validationErrors` already
            // asks for one, and that message is the clearer of the two.
            let modelResult: (profile: DS4ModelProfile, error: String?)
            if config.modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modelResult = (.unknown, nil)
            } else if forceRefresh || inputs.modelDiffers(from: previousInputs) ||
                identities.model != previousIdentities.model {
                let resolved = DS4ServerCommand.resolving(config.modelPath, relativeTo: directory)
                switch DS4SelectionValidation.modelValidation(for: resolved) {
                case .success(let profile):
                    modelResult = (profile, nil)
                case .failure(.supportArtifact):
                    // Keep the real profile: `validationErrors` names which
                    // support GGUF was chosen, and the detected-model section
                    // shows it. Apply still refuses the selection.
                    modelResult = (GGUFModelInspector.profile(for: resolved), nil)
                case .failure(let error):
                    modelResult = (.unknown, error.message)
                }
            } else {
                modelResult = (previousModel, previousModelError)
            }
            return (
                model: modelResult.profile,
                modelError: modelResult.error,
                support: forceRefresh || inputs.supportDiffers(from: previousInputs) ||
                    identities.support != previousIdentities.support
                    ? GGUFModelInspector.supportProfile(for: config.mtpPath, relativeTo: directory)
                    : previousSupport,
                vision: forceRefresh || inputs.visionDiffers(from: previousInputs) ||
                    identities.vision != previousIdentities.vision
                    ? GGUFModelInspector.visionProfile(for: config.visionPath, relativeTo: directory)
                    : previousVision,
                identities: identities
            )
        }.value

        guard !Task.isCancelled,
              SettingsDerivedInputs(draft) == inputs,
              derivedRefreshRevision == refreshRevision
        else { return }

        // A non-path setting may have changed while inspection was running.
        // Apply model defaults to the latest draft so the background result
        // never restores an older copy of those edits.
        let currentConfig = draft
        var refreshedConfig = currentConfig
        let key = ServerConfiguration.Config.modelKey(
            for: currentConfig.modelPath,
            serverPath: currentConfig.serverPath
        )
        let directory = DS4ServerCommand.serverDirectory(for: currentConfig.serverPath)
        let candidate = DS4ServerCommand.resolving(currentConfig.modelPath, relativeTo: directory)
        if derived.modelError == nil, key != loadedModelKey,
           FileManager.default.isReadableRegularFile(atPath: candidate) {
            refreshedConfig = currentConfig.selectingModel(
                path: currentConfig.modelPath,
                serverPath: currentConfig.serverPath,
                profile: derived.model,
                storingCurrentAs: loadedModelKey
            )
            loadedModelKey = key
        }

        modelProfile = derived.model
        supportProfile = derived.support
        visionProfile = derived.vision
        modelValidationError = derived.modelError
        validatedModelPath = inputs.modelPath
        derivedInputs = inputs
        derivedFileIdentities = derived.identities
        completedDerivedRefreshRevision = refreshRevision
        if refreshedConfig != draft {
            draft = refreshedConfig
        }
        validationErrors = settingsValidationErrors(
            for: refreshedConfig,
            model: derived.model,
            support: derived.support,
            vision: derived.vision
        )
        isRefreshingDerivedState = false
        layoutRevision += 1
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
        .defaultScrollAnchor(.center, for: .alignment)
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
                Toggle(
                    "Show Prefill and Generation speeds in menu bar",
                    isOn: performanceDisplayBinding
                )
                .help("Displays P for Prefill and G for Generation token rates.")
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    // Selectable text here goes blank after the selection
                    // loses focus, so the command is copied whole instead.
                    .contextMenu {
                        Button("Copy Command") { copyCommandPreview() }
                    }
            }

            Section {
                Button("Restore All Tuning Defaults", role: .destructive) {
                    draft = draft.restoringTuningDefaults(for: modelProfile)
                    showNotice("Tuning defaults restored for \(modelProfile.displayName) in this draft. Apply to use them.")
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
                pathRow(
                    "ds4-server",
                    field: .server,
                    errorKey: .serverPath,
                    help: "The ds4-server executable"
                )
                pathRow("Model", field: .model, errorKey: .modelPath, help: "The main GGUF model")
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
                    pathRow("Vision encoder", field: .vision, errorKey: .visionPath, help: visionHelp)
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
                    note: "0 disables session batching. Each session keeps its own caches, so more sessions multiply context memory; supported models share one prefill workspace."
                )
                if draft.batchedSessions > 0 {
                    integerRow(
                        "Mixed prefill quantum",
                        value: $draft.mixedPrefillQuantum,
                        errorKey: .mixedPrefillQuantum,
                        note: "The amount of prompt work allowed between active generations."
                    )
                    if mayExceedBatchedMTPDecodeWidth {
                        Text("ds4-server speculates across at most \(ServerConfiguration.Config.maxBatchedEmbeddedMTPDecodeWidth) sessions decoding at once. MTP still applies beyond that, one session at a time.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                    pathRow("Cache directory", field: .kvDiskDirectory, errorKey: .kvDiskDir, help: "DS Menu Bar creates this private directory if needed")
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
                        pathRow("Legacy MTP model", field: .mtp, errorKey: .mtpPath, help: "A legacy DeepSeek MTP support GGUF")
                        supportModelStatus(expected: .legacyMTP)
                        mtpDraftRows
                    } else if draft.mtpMode == .dspark {
                        pathRow("DSpark model", field: .mtp, errorKey: .mtpPath, help: "The DSpark support GGUF")
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

            if hasBatchedMTPConflict {
                Section {
                    Label("Set Resident sessions to 0 in the Server pane, or turn MTP off — this model cannot use both.",
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

    private var hasBatchedMTPConflict: Bool {
        draft.hasBatchedSessionMTPConflict(modelProfile: modelProfile)
    }

    /// Enough resident slots that a decode cycle can outgrow the batched
    /// speculative path. Whether it actually does depends on how many sessions
    /// are live at once, so the note describes the cap rather than predicting it.
    private var mayExceedBatchedMTPDecodeWidth: Bool {
        draft.usesBatchedEmbeddedMTP(modelProfile: modelProfile) &&
            draft.batchedSessions > ServerConfiguration.Config.maxBatchedEmbeddedMTPDecodeWidth
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

            Section("Server log") {
                pathRow(
                    "Log folder",
                    field: .logDirectory,
                    help: "Where DS Menu Bar keeps the captured server output"
                )
                fileNameRow(
                    "Log file name",
                    field: .log,
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
            }

            Section("Request trace") {
                Toggle("Record request trace", isOn: $draft.traceEnabled)
                // Where the trace goes only means something while it is being
                // recorded, so those rows follow the toggle the way the disk
                // cache rows follow theirs. Deleting acts on a file that is
                // already on disk, so it stays: a trace holds prompt text, and
                // turning recording off must not be the thing that strands it.
                if draft.traceEnabled {
                    pathRow(
                        "Trace folder",
                        field: .traceDirectory,
                        help: "Where ds4-server writes the request trace"
                    )
                    fileNameRow(
                        "Trace file name",
                        field: .trace,
                        help: "The ds4-server request trace"
                    )
                }
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
                                : "Delete the request trace at \(DS4ServerCommand.presentingPath(draft.tracePath))"
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

    /// Paths are chosen, never typed: a panel returns something that exists,
    /// which removes a whole class of unusable values before they reach the
    /// draft. The path is plain text rather than selectable text, which does
    /// not survive a truncating fixed-width frame in a form row; Copy Path and
    /// the tooltip carry the full value instead.
    @ViewBuilder
    private func pathRow(
        _ title: String,
        field: SettingsPathField,
        errorKey: ServerConfiguration.Config.Field? = nil,
        help: String
    ) -> some View {
        let path = presentedPath(for: field)
        let directory = field.choosesDirectory
        VStack(alignment: .leading, spacing: 4) {
            // The path sits on its own line rather than in the value slot: a
            // row that has to divide its width between a label, a path, and a
            // button gives the path whatever is left, which for the first row
            // of a section is nothing at all. On its own line it gets the full
            // width, which these paths need anyway.
            LabeledContent(title) {
                Button(directory ? "Choose Folder…" : "Choose…") {
                    choosePath(field: field)
                }
                .accessibilityLabel(
                    directory ? "Choose folder for \(title)" : "Choose file for \(title)"
                )
            }
            // A filled monospaced field, like the command preview in General:
            // plain text on the card reads as more label, and a path has to be
            // scannable as the row's value. The leading glyph separates a row
            // that picks a folder from one that picks a file.
            HStack(spacing: 6) {
                Image(systemName: directory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(path.isEmpty ? "None selected" : path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .help(path)
                .accessibilityLabel("\(title) path")
                .accessibilityValue(path.isEmpty ? "None selected" : path)
                .contextMenu {
                    if !path.isEmpty {
                        Button("Copy Path") { copyPath(for: field) }
                    }
                }
            Text(help).font(.footnote).foregroundStyle(.secondary)
            if let errorKey, let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    /// The name half of a file the app creates. Paired with the folder row
    /// above it, which is a panel like every other path.
    @ViewBuilder
    private func fileNameRow(
        _ title: String,
        field: SettingsFileNameField,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", text: fileNameBinding(for: field))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 260, maxWidth: 420)
                    .accessibilityLabel(title)
            }
            Text(help).font(.footnote).foregroundStyle(.secondary)
            if let error = validationErrors[field.errorKey] {
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

    private func fileNameBinding(for field: SettingsFileNameField) -> Binding<String> {
        Binding(
            get: { fileNameText(for: field) },
            set: { newValue in
                switch field {
                case .log: logNameText = newValue
                case .trace: traceNameText = newValue
                }
                fileNameDidChange(field)
            }
        )
    }

    private func fileNameDidChange(_ field: SettingsFileNameField) {
        if isApplyingSettings {
            applyValidationID = nil
            isApplyingSettings = false
        }
        // Hold the draft at its last usable value while the text is not a
        // name, so Apply can never write a path built from a rejected one.
        if fileNameError(for: field) == nil {
            let name = fileNameText(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case .log:
                draft.logPath = DS4ServerCommand.storingFilePath(
                    directory: DS4ServerCommand.fileDirectory(of: draft.logPath),
                    name: name
                )
            case .trace:
                draft.tracePath = DS4ServerCommand.storingFilePath(
                    directory: DS4ServerCommand.fileDirectory(of: draft.tracePath),
                    name: name
                )
            }
        }
        validationErrors = settingsValidationErrors(for: draft)
    }

    /// What a row shows for its selection: `~` for the home directory, and a
    /// GGUF inside ds4-server's folder relative to it.
    private func presentedPath(for field: SettingsPathField) -> String {
        let directory = DS4ServerCommand.serverDirectory(for: draft.serverPath)
        switch field {
        case .server:
            return DS4ServerCommand.presentingPath(draft.serverPath)
        case .model:
            return DS4ServerCommand.presentingResourcePath(draft.modelPath, relativeTo: directory)
        case .mtp:
            return DS4ServerCommand.presentingResourcePath(draft.mtpPath, relativeTo: directory)
        case .vision:
            return DS4ServerCommand.presentingResourcePath(draft.visionPath, relativeTo: directory)
        case .kvDiskDirectory:
            return DS4ServerCommand.presentingPath(draft.kvDiskDir)
        case .logDirectory:
            return DS4ServerCommand.presentingPath(DS4ServerCommand.fileDirectory(of: draft.logPath))
        case .traceDirectory:
            return DS4ServerCommand.presentingPath(
                DS4ServerCommand.fileDirectory(of: draft.tracePath)
            )
        }
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

    private func choosePath(field: SettingsPathField) {
        let directory = field.choosesDirectory
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = directory
        // The log, trace, and cache directories default inside ~/Library and
        // /tmp, neither of which Finder lists, so the panel has to show them.
        panel.showsHiddenFiles = directory
        if field.choosesGGUF,
           let ggufType = UTType(filenameExtension: "gguf", conformingTo: .data) {
            panel.allowedContentTypes = [ggufType]
        }
        if let startDirectory = panelStartDirectory(for: field) {
            panel.directoryURL = startDirectory
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyPickedPath(field, path: url.path)
    }

    /// Open the panel where the current selection lives. A configured folder
    /// that has yet to be created falls back to its nearest existing parent
    /// rather than dropping the user somewhere unrelated.
    private func panelStartDirectory(for field: SettingsPathField) -> URL? {
        let current = DS4ServerCommand.expandingTilde(storedPath(for: field))
        guard !current.isEmpty else { return nil }
        var candidate = field.choosesDirectory
            ? current
            : (current as NSString).deletingLastPathComponent
        while !candidate.isEmpty, candidate != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: candidate)
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func copyCommandPreview() {
        let command = DS4ServerCommand.preview(
            configuration: draft,
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionProfile: visionProfile
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Copy what a terminal would accept, not the compact form the row shows.
    private func copyPath(for field: SettingsPathField) {
        let stored = storedPath(for: field)
        let resolved = field.choosesDirectory
            ? DS4ServerCommand.expandingTilde(stored)
            : DS4ServerCommand.resolving(
                stored,
                relativeTo: DS4ServerCommand.serverDirectory(for: draft.serverPath)
            )
        guard !resolved.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resolved, forType: .string)
    }

    private func storedPath(for field: SettingsPathField) -> String {
        switch field {
        case .server: return draft.serverPath
        case .model: return draft.modelPath
        case .mtp: return draft.mtpPath
        case .vision: return draft.visionPath
        case .kvDiskDirectory: return draft.kvDiskDir
        case .logDirectory: return DS4ServerCommand.fileDirectory(of: draft.logPath)
        case .traceDirectory: return DS4ServerCommand.fileDirectory(of: draft.tracePath)
        }
    }

    private func applyPickedPath(_ field: SettingsPathField, path: String) {
        if isApplyingSettings {
            applyValidationID = nil
            isApplyingSettings = false
        }
        let serverDirectory = DS4ServerCommand.serverDirectory(for: draft.serverPath)
        switch field {
        case .server:
            draft.serverPath = DS4ServerCommand.storingAbsolutePath(path)
            serverValidationError = nil
        case .model:
            draft.modelPath = DS4ServerCommand.storingResourcePath(
                path,
                relativeTo: serverDirectory
            )
            modelValidationError = nil
            requestDerivedRefresh()
        case .mtp:
            draft.mtpPath = DS4ServerCommand.storingResourcePath(
                path,
                relativeTo: serverDirectory
            )
            requestDerivedRefresh()
        case .vision:
            draft.visionPath = DS4ServerCommand.storingResourcePath(
                path,
                relativeTo: serverDirectory
            )
            requestDerivedRefresh()
        case .kvDiskDirectory:
            draft.kvDiskDir = DS4ServerCommand.storingAbsolutePath(path)
        case .logDirectory:
            draft.logPath = DS4ServerCommand.storingFilePath(
                directory: path,
                name: logNameText
            )
        case .traceDirectory:
            draft.tracePath = DS4ServerCommand.storingFilePath(
                directory: path,
                name: traceNameText
            )
        }
    }

    private func applySettings() {
        let candidate = draft
        let validationID = UUID()
        applyValidationID = validationID
        isApplyingSettings = true
        showNotice("")

        let previousServerPath = validatedServerPath
        let previousServerError = serverValidationError
        let previousServerIdentity = validatedServerIdentity

        Task {
            let checked = await Task.detached(priority: .userInitiated) {
                let directory = DS4ServerCommand.serverDirectory(for: candidate.serverPath)
                let resolvedModel = DS4ServerCommand.resolving(
                    candidate.modelPath,
                    relativeTo: directory
                )
                let modelResult = DS4SelectionValidation.modelValidation(for: resolvedModel)
                let profile: DS4ModelProfile
                let modelError: String?
                switch modelResult {
                case .success(let detected):
                    profile = detected
                    modelError = nil
                case .failure(let error):
                    profile = .unknown
                    modelError = error.message
                }
                // Running the executable is the only expensive check here, so
                // repeat it only when this is not the executable already
                // checked in this session: same path, same size, same
                // modification date. A replaced binary fails that test.
                let serverIdentity = SettingsFileIdentity(
                    path: DS4ServerCommand.expandingTilde(candidate.serverPath)
                )
                let serverError: String?
                if candidate.serverPath == previousServerPath,
                   previousServerIdentity == serverIdentity {
                    serverError = previousServerError
                } else {
                    serverError = DS4SelectionValidation.serverError(for: candidate.serverPath)
                }
                return SettingsApplyChecks(
                    serverError: serverError,
                    serverIdentity: serverIdentity,
                    modelError: modelError,
                    model: profile,
                    support: GGUFModelInspector.supportProfile(
                        for: candidate.mtpPath,
                        relativeTo: directory
                    ),
                    vision: GGUFModelInspector.visionProfile(
                        for: candidate.visionPath,
                        relativeTo: directory
                    ),
                    identities: SettingsDerivedFileIdentities.inspecting(candidate),
                    mtpIsReadable: FileManager.default.isReadableRegularFile(atPath:
                        DS4ServerCommand.resolving(candidate.mtpPath, relativeTo: directory)
                    ),
                    visionIsReadable: FileManager.default.isReadableRegularFile(atPath:
                        DS4ServerCommand.resolving(candidate.visionPath, relativeTo: directory)
                    )
                )
            }.value

            guard applyValidationID == validationID, draft == candidate else {
                // Picking a path or editing a file name already cancelled this
                // pass. Anything else means another control moved while the
                // checks ran, and the click needs to say so rather than look
                // like it did nothing.
                if applyValidationID == validationID {
                    applyValidationID = nil
                    isApplyingSettings = false
                    showNotice(
                        "Settings changed while the files were checked. Apply again.",
                        isFailure: true
                    )
                }
                return
            }

            var checkedConfig = candidate
            let key = ServerConfiguration.Config.modelKey(
                for: candidate.modelPath,
                serverPath: candidate.serverPath
            )
            if checked.modelError == nil, key != loadedModelKey {
                checkedConfig = candidate.selectingModel(
                    path: candidate.modelPath,
                    serverPath: candidate.serverPath,
                    profile: checked.model,
                    storingCurrentAs: loadedModelKey
                )
            }

            var errors = checkedConfig.validationErrors(
                modelProfile: checked.model,
                supportProfile: checked.support,
                visionProfile: checked.vision
            )
            if let error = checked.serverError {
                errors[.serverPath] = error
            }
            if let error = checked.modelError {
                errors[.modelPath] = error
            }

            let usesExternalSupport =
                (checkedConfig.mtpMode == .external && checked.model.supportsExternalMTP) ||
                (checkedConfig.mtpMode == .dspark && checked.model.supportsDSpark)
            if usesExternalSupport, !checked.mtpIsReadable {
                errors[.mtpPath] = "Choose a readable MTP support GGUF."
            }
            if checked.model.supportsVision && checkedConfig.visionEnabled,
               !checked.visionIsReadable {
                errors[.visionPath] = "Choose a readable compatible vision GGUF."
            }

            serverValidationError = checked.serverError
            modelValidationError = checked.modelError
            validatedServerPath = candidate.serverPath
            validatedServerIdentity = checked.serverIdentity
            validatedModelPath = candidate.modelPath
            modelProfile = checked.model
            supportProfile = checked.support
            visionProfile = checked.vision
            if checked.modelError == nil {
                loadedModelKey = key
            }
            draft = checkedConfig
            validationErrors = errors
            applyValidationID = nil
            isApplyingSettings = false
            layoutRevision += 1

            guard errors.isEmpty else {
                revealFirstValidationError(in: errors)
                showNotice(applyRefusedNotice, isFailure: true)
                return
            }

            finishApplying(checkedConfig, identities: checked.identities)
        }
    }

    /// Move to the pane holding the first field that refused the draft. The
    /// order matches `firstValidationError`, so the pane shown is the one
    /// naming the error a launch would report first. Returns false when the
    /// refusal has no field to show.
    @discardableResult
    private func revealFirstValidationError(
        in errors: [ServerConfiguration.Config.Field: String]
    ) -> Bool {
        guard let field = ServerConfiguration.Config.Field.allCases.first(where: {
            errors[$0] != nil
        }) else { return false }
        selectedPaneRaw = SettingsPane.containing(field).rawValue
        return true
    }

    private func finishApplying(
        _ config: ServerConfiguration.Config,
        identities: SettingsDerivedFileIdentities
    ) {
        // Report what the manager actually did — a .starting status whose
        // process never came up is applied, not restarted.
        let result = server.applyConfiguration(config)
        switch result.kind {
        case .invalid:
            // The manager inspects the selected files again, so it can still
            // refuse a draft this view just validated — a model replaced
            // between the two passes, for example. Show the field rather than
            // leaving Apply looking like it did nothing.
            let errors = settingsValidationErrors(for: config)
            validationErrors = errors
            showNotice(
                revealFirstValidationError(in: errors)
                    ? applyRefusedNotice
                    : "Settings not applied. Re-check the selected files.",
                isFailure: true
            )
            layoutRevision += 1
            return
        case .applied, .appliedAndRestarting:
            break
        }
        // Without this the launch-at-login read-back below would flip the toggle
        // back with no explanation of why.
        showNotice(result.warning ?? "", isFailure: result.warning != nil)
        let snapshot = server.configurationSnapshot()
        draft = snapshot
        syncFileNameText(for: snapshot)
        loadedModelKey = ServerConfiguration.Config.modelKey(
            for: snapshot.modelPath,
            serverPath: snapshot.serverPath
        )
        resetSelectionValidation(for: snapshot)
        validationErrors = settingsValidationErrors(for: snapshot)
        // Apply just inspected these files, so seed the derived state from that
        // pass instead of scheduling a second one. A snapshot the manager
        // rewrote to different paths still has to be inspected.
        let appliedInputs = SettingsDerivedInputs(snapshot)
        if appliedInputs == SettingsDerivedInputs(config) {
            derivedInputs = appliedInputs
            derivedFileIdentities = identities
            completedDerivedRefreshRevision = derivedRefreshRevision
            isRefreshingDerivedState = false
        } else {
            requestDerivedRefresh()
        }
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
