// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

final class ServerFailureTests: XCTestCase {
    func testOnlyErrorStatusIsMarkedAsAnError() {
        XCTAssertTrue(ServerStatus.error("failed").isError)
        XCTAssertFalse(ServerStatus.stopped.isError)
        XCTAssertFalse(ServerStatus.running(pid: 1).isError)
        XCTAssertFalse(ServerStatus.starting.isError)
    }

    func testFailureDestinationFollowsCorrectiveSettingsPane() {
        XCTAssertEqual(
            ServerLaunchFailure(
                message: "Invalid server configuration: choose a DSpark support GGUF",
                source: .manual
                    ).settingsDestination,
            .mtp
        )
        XCTAssertEqual(
            ServerLaunchFailure(
                message: "vision model not readable at /tmp/vision.gguf",
                source: .manual
                    ).settingsDestination,
            .model
        )
        XCTAssertEqual(
            ServerLaunchFailure(message: "ds4-server not executable", source: .manual).settingsDestination,
            .general
        )
    }

    func testFailureTitlesDistinguishStartAndRestart() {
        let manual = ServerLaunchFailure(message: "bad configuration", source: .manual)

        XCTAssertEqual(manual.notificationTitle, "ds4-server could not start")
        XCTAssertEqual(ServerLaunchFailure(message: "bad", source: .restart).notificationTitle,
                       "ds4-server could not restart")
    }

    func testManualStartPublishesOneFailureEvent() {
        let server = ServerManager()
        var configuration = server.configurationSnapshot()
        configuration.serverPath = "/tmp/dsmenubar-missing-\(UUID().uuidString)"
        server.config.replace(with: configuration)
        var failures: [ServerLaunchFailure] = []
        server.onLaunchFailure = { failures.append($0) }

        server.start()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.source, .manual)
        XCTAssertTrue(failures.first?.message.contains("not found") == true)
    }

    func testNotificationBodyIsTruncatedForLongFailures() {
        let message = String(repeating: "x", count: 300)
        let failure = ServerLaunchFailure(message: message, source: .restart)

        XCTAssertEqual(failure.notificationBody.count, 240)
        XCTAssertTrue(failure.notificationBody.hasSuffix("…"))
    }

    @MainActor
    func testSettingsNavigationConsumesPendingDestination() {
        UserDefaults.standard.removeObject(forKey: SettingsNavigation.pendingPaneKey)
        XCTAssertNil(SettingsNavigation.consumePendingPane())

        SettingsNavigation.request(.mtp)
        XCTAssertEqual(SettingsNavigation.consumePendingPane(), .mtp)
        XCTAssertNil(SettingsNavigation.consumePendingPane())
    }
}
