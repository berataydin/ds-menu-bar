// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Builds the supported local Metal `ds4-server` invocation.
///
/// Keeping this separate from `ProcessManager` makes the exact argument set
/// visible to Settings and unit-testable without launching a model process.
enum DS4ServerCommand {
    static let managedQwenEnvironmentKeys = [
        "DS4_QWEN4_MTP_DEPTH",
        "DS4_QWEN4_YARN_FACTOR",
        "DS4_QWEN4_IMAGE_MAX_TOKENS"
    ]

    static func environmentOverrides(
        configuration: ServerConfiguration.Config,
        modelProfile: DS4ModelProfile = .unknown
    ) -> [String: String] {
        guard modelProfile.family == .qwen38 else { return [:] }
        var environment: [String: String] = [:]
        if configuration.mtpMode == .embedded && modelProfile.supportsEmbeddedMTP {
            environment["DS4_QWEN4_MTP_DEPTH"] = configuration.qwenMTPDepth.environmentValue
        }
        if let value = configuration.qwenYarnFactor.environmentValue {
            environment["DS4_QWEN4_YARN_FACTOR"] = value
        }
        if configuration.visionEnabled && modelProfile.supportsVision {
            environment["DS4_QWEN4_IMAGE_MAX_TOKENS"] = "\(configuration.qwenImageMaxTokens)"
        }
        return environment
    }

    static func launchEnvironment(
        configuration: ServerConfiguration.Config,
        modelProfile: DS4ModelProfile = .unknown,
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for key in managedQwenEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment.merge(environmentOverrides(
            configuration: configuration,
            modelProfile: modelProfile
        )) { _, configured in configured }
        return environment
    }

    static func arguments(
        configuration: ServerConfiguration.Config,
        resolvedModelPath: String,
        resolvedMTPPath: String,
        resolvedVisionPath: String = "",
        modelProfile: DS4ModelProfile = .unknown,
        supportProfile: DS4SupportProfile = .unavailable,
        visionProfile: DS4VisionProfile? = nil
    ) -> [String] {
        var args: [String] = [
            "--metal",
            "--model", resolvedModelPath
        ]
        args += [
            "--ctx", "\(configuration.ctxSize)",
            "--host", configuration.host,
            "--port", "\(configuration.port)",
            "--power", "\(configuration.powerPercent)"
        ]

        if configuration.defaultTokens > 0 {
            args += ["--tokens", "\(configuration.defaultTokens)"]
        }
        if configuration.threads > 0 {
            args += ["--threads", "\(configuration.threads)"]
        }
        if modelProfile.supportsManualPrefill && configuration.prefillChunk > 0 {
            args += ["--prefill-chunk", "\(configuration.prefillChunk)"]
        }
        if configuration.warmWeights {
            args.append("--warm-weights")
        }
        if configuration.quality {
            args.append("--quality")
        }

        if configuration.corsEnabled {
            args.append("--cors")
        }
        if configuration.traceEnabled,
           configuration.tracePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--trace", expandingTilde(configuration.tracePath)]
        }
        if configuration.batchedSessions > 0 {
            args += ["--batched-session", "\(configuration.batchedSessions)"]
            if configuration.mixedPrefillQuantum > 0 {
                args += ["--mixed-prefill-quantum", "\(configuration.mixedPrefillQuantum)"]
            }
        }

        if configuration.ssdStreamingEnabled && modelProfile.supportsSSDStreaming {
            args.append("--ssd-streaming")
            if configuration.ssdStreamingCold {
                args.append("--ssd-streaming-cold")
            }
            let cacheExperts = configuration.ssdStreamingCacheExperts
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cacheExperts.isEmpty {
                args += ["--ssd-streaming-cache-experts", cacheExperts]
            }
            if modelProfile.isFullGLM && configuration.ssdStreamingFullLayers >= 0 {
                args += ["--ssd-streaming-full-layers", "\(configuration.ssdStreamingFullLayers)"]
            }
            if configuration.ssdStreamingPreloadExperts > 0 {
                args += ["--ssd-streaming-preload-experts", "\(configuration.ssdStreamingPreloadExperts)"]
            }
        }

        if configuration.kvDiskEnabled {
            args += [
                "--kv-disk-dir", expandingTilde(configuration.kvDiskDir),
                "--kv-disk-space-mb", "\(configuration.kvDiskSpaceMB)",
                "--kv-cache-min-tokens", "\(configuration.kvCacheMinTokens)",
                "--kv-cache-cold-max-tokens", "\(configuration.kvCacheColdMaxTokens)",
                "--kv-cache-continued-interval-tokens", "\(configuration.kvCacheContinuedIntervalTokens)",
                "--kv-cache-boundary-trim-tokens", "\(configuration.kvCacheBoundaryTrimTokens)",
                "--kv-cache-boundary-align-tokens", "\(configuration.kvCacheBoundaryAlignTokens)",
                "--tool-memory-max-ids", "\(configuration.toolMemoryMaxIDs)"
            ]
            if configuration.kvCacheRejectDifferentQuant {
                args.append("--kv-cache-reject-different-quant")
            }
            if configuration.disableExactDSMLToolReplay {
                args.append("--disable-exact-dsml-tool-replay")
            }
        }

        if configuration.simulateUsedMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--simulate-used-memory", configuration.simulateUsedMemory.trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        if modelProfile.supportsVision && configuration.visionEnabled && !resolvedVisionPath.isEmpty &&
            (visionProfile?.isCompatible(with: modelProfile) ?? true) {
            args += ["--vision", resolvedVisionPath]
        }

        switch configuration.mtpMode {
        case .off:
            break
        case .embedded where modelProfile.supportsEmbeddedMTP:
            args.append("--mtp")
            if configuration.mtpTiming { args.append("--mtp-timing") }
            if configuration.mtpExactSampling { args.append("--mtp-exact-sampling") }
        case .external where modelProfile.supportsExternalMTP && supportProfile.kind == .legacyMTP:
            args += [
                "--mtp-model", resolvedMTPPath,
                "--mtp-draft", "\(configuration.mtpDraft)",
                "--mtp-margin", format(configuration.mtpMargin)
            ]
        case .dspark where modelProfile.supportsDSpark && supportProfile.kind == .dspark:
            args += ["--mtp-model", resolvedMTPPath, "--dspark"]
            if let confidence = configuration.dsparkConfidence {
                args += ["--dspark-confidence", format(confidence)]
            }
            if configuration.mtpExactSampling { args.append("--mtp-exact-sampling") }
            if configuration.dsparkStrict { args.append("--dspark-strict") }
        default:
            // An unknown or incompatible profile must never receive flags for
            // another model family. ds4-server remains free to decide whether
            // the base model itself is supported.
            break
        }

        return args
    }

    /// Human-readable shell-style preview used by Settings. This is a display
    /// string, not a shell command executed by the app.
    static func preview(
        configuration: ServerConfiguration.Config,
        modelProfile: DS4ModelProfile = .unknown,
        supportProfile: DS4SupportProfile = .unavailable,
        visionProfile: DS4VisionProfile? = nil
    ) -> String {
        let serverPath = expandingTilde(configuration.serverPath)
        let directory = serverDirectory(for: configuration.serverPath)
        let args = arguments(
            configuration: configuration,
            resolvedModelPath: resolving(configuration.modelPath, relativeTo: directory),
            resolvedMTPPath: resolving(configuration.mtpPath, relativeTo: directory),
            resolvedVisionPath: resolving(configuration.visionPath, relativeTo: directory),
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionProfile: visionProfile
        )
        let environment = environmentOverrides(
            configuration: configuration,
            modelProfile: modelProfile
        )
        let assignments = managedQwenEnvironmentKeys.compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(shellQuote(value))"
        }
        // Keep the shell preview's environment aligned with Process.environment:
        // managed Qwen variables are removed even when the selected model is not
        // Qwen, and only Qwen models receive configured assignments.
        var environmentPrefix = ["/usr/bin/env"]
        for key in managedQwenEnvironmentKeys where environment[key] == nil {
            environmentPrefix += ["-u", key]
        }
        environmentPrefix += assignments
        let command = (environmentPrefix + ([serverPath] + args).map(shellQuote)).joined(separator: " ")
        let log = shellQuote(expandingTilde(configuration.logPath))
        return "\(command) > \(log) 2>&1"
    }

    static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// The working directory a launched ds4-server inherits: the folder holding
    /// the executable.
    static func serverDirectory(for serverPath: String) -> String {
        (expandingTilde(serverPath) as NSString).deletingLastPathComponent
    }

    /// Resolve a configured resource path the way the launched server sees it.
    /// ds4-server runs with `serverDirectory` as its working directory, so a
    /// relative configuration path means "relative to that directory" — the
    /// shipped default `mtpPath` relies on this. Launch and the Settings
    /// preview both resolve here so the previewed command is the command that
    /// runs. An empty path stays empty; callers treat that as "not configured".
    static func resolving(_ path: String, relativeTo directory: String) -> String {
        let expanded = expandingTilde(path)
        guard !expanded.isEmpty, !expanded.hasPrefix("/"), !directory.isEmpty else {
            return expanded
        }
        return (directory as NSString).appendingPathComponent(expanded)
    }

    /// Render a Double for the command line. `arguments` is also called on
    /// unvalidated Settings drafts (the live command preview), so this has to
    /// survive non-finite and out-of-Int-range values rather than trapping in
    /// `Int(_:)`. Such a value is shown as-is rather than substituted: the
    /// preview's job is to reflect what the draft says, and a rejected margin
    /// rendered as a plausible "0" would read as if it were fine. Validation
    /// stops it from reaching an actual launch.
    static func format(_ value: Double) -> String {
        guard value.isFinite, value.magnitude < 1e15, value.rounded() == value else {
            return String(value)
        }
        return String(Int(value))
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n'\"\\$`|;&<>*?!()[]{}")) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
