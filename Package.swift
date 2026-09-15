// swift-tools-version: 5.9
// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "dsmenubar",
    platforms: [
        .macOS("26.0"),
    ],
    targets: [
        .executableTarget(
            name: "dsmenubar"
        ),
        .testTarget(
            name: "dsmenubarTests",
            dependencies: ["dsmenubar"]
        ),
    ]
)
