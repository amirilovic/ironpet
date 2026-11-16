---
name: swift
description: Swift for the ironpet macOS app (AppKit + SwiftUI, macOS 14+, SwiftPM, Swift 5 language mode). Use when writing, reviewing, or structuring Swift in Sources/IronPet, Tests/IronPetTests, or tools/, including concurrency, SwiftUI views, AppKit panels, Codable config and JSON-RPC, Keychain, URLSession, notifications, accessibility, and profiling. Before writing Swift, read the ironpet conventions below, then open the matching guide under skills/.
---

# Swift for ironpet

Guides from [swift-ios-skills](https://github.com/dpearson2699/swift-ios-skills), vendored under `skills/`. Licensed under PolyForm Perimeter 1.0.0 (see `LICENSE`). The guides are written for iOS first. ironpet is a **macOS** app, so translate as you read: `UIView` / `UIHostingController` become `NSView` / `NSHostingView` / `NSPanel`, and iOS-only APIs (BGTaskScheduler, UIApplication, Dynamic Type sizes, haptics) do not apply.

Only the guides ironpet needs are vendored. If a task needs a framework that is not in the table, add that guide from the upstream repository in the same pull request.

## ironpet conventions (these win over the guides)

When a guide disagrees with the code, follow the code around your change, as `CONTRIBUTING.md` asks. In particular:

| Topic | What ironpet does | Do not |
| --- | --- | --- |
| Package | One SwiftPM executable target `IronPet` (`Sources/IronPet`) and one test target (`Tests/IronPetTests`), `swift-tools-version:5.10`, `.macOS(.v14)`. No Xcode project, no third-party Swift dependencies | Add a package dependency, an Xcode project, or a second target without discussing it first |
| Language mode | Swift 5 mode (from the tools version), so strict concurrency is not enforced by the compiler | Assume Swift 6 diagnostics will catch a data race; reason about isolation yourself |
| Observation | `ObservableObject` with `@Published` (`ConfigStore`, `BubbleStore`, `SignalStore`, `VoiceController`, `MeetingController`), held by AppKit owners and handed to SwiftUI | Migrate a store to `@Observable` as a side effect of a feature. The `@Observable` advice in `swiftui-patterns` applies only to brand-new, self-contained state |
| UI | AppKit owns windows, panels, menus, the status item and hotkeys (`AppDelegate`, `IronPetPanel`, `SettingsWindow`, `Bubbles`, `SetupWindow`). SwiftUI renders the content inside them through `NSHostingView` | Replace an `NSPanel` with a SwiftUI `Window` / `MenuBarExtra`; the panels are non-activating, clamped to the pet's screen, and positioned by hand on purpose (SPEC.md › ironpet window) |
| Main actor | UI types and stores are `@MainActor`. Timers that call back into them use `MainActor.assumeIsolated` because the run-loop timer already fires on the main thread | Add `assumeIsolated` on a callback that is not guaranteed to run on the main thread |
| Escape hatches | `@unchecked Sendable` exists only on audio sources and `StatusSnapshot`, where a serial queue or lock protects the state | Add `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency` without a comment on that line saying what protects the state |
| Background work | Audio capture, chunking and the local server run on their own serial queues (`TrackRecorder`, `SystemAudioSource`, `EventServer`); networking uses `async` URLSession calls | Block the main thread with file, process or network I/O |
| Processes | Agents run as child processes over stdio (`ACPClient`, newline-delimited JSON-RPC). The agent process stays alive between messages | Spawn a fresh agent per message, or read its stdout on the main thread |
| Config | Every setting lives in `Config` (`Support/Config.swift`) with a safe default, decoded by laying `~/.ironpet/config.json` over the encoded defaults, and clamped | Read a new setting from UserDefaults or an environment variable. UserDefaults is only for UI state (window size, recent folders, chat backend) |
| Secrets | API keys and tokens live in the Keychain (`ironpet.voice`, `ironpet.sentry`), never in `~/.ironpet` | Write a token to `config.json`, a log or a thread file |
| Tests | XCTest (`final class …Tests: XCTestCase`, `XCTAssert…`), with temp directories created in `setUpWithError` and removed in `tearDownWithError` | Add Swift Testing (`import Testing`) next to XCTest; keep one framework |
| Lint | No SwiftLint or swift-format is configured | Raise style findings that only a linter config would decide |
| Comments | Explain *why*, not *what* (`CONTRIBUTING.md`) | Narrate the change in a comment |

## Guides

Before writing or reviewing Swift, read the `SKILL.md` for the topic you are touching and follow it, within the conventions above. Load one guide at a time, plus its `references/` only when that guide points there.

| Guide | Covers | Where it applies in ironpet |
| --- | --- | --- |
| `swift-language` | Modern Swift idioms outside concurrency and SwiftUI: if/switch expressions, result builders, property wrappers, pattern matching, collections | Any Swift. Skip Swift 6-only features (typed throws, `~Copyable` generics) unless the toolchain in CI supports them in Swift 5 mode |
| `swift-api-design-guidelines` | Naming, argument labels, mutating pairs, doc comments | Any new type, function or public-to-the-module API |
| `swift-concurrency` | Actor isolation, `Sendable`, structured concurrency, `TaskGroup`, background offloading | `Chat/ACP/`, `Meeting/`, `Voice/`, `Signals/`, `Bridge/EventServer.swift`, anything with `Task {}` or a queue |
| `swift-codable` | `JSONDecoder` / `JSONEncoder`, `CodingKeys`, custom `init(from:)`, heterogeneous payloads | `Support/Config.swift`, ACP JSON-RPC messages (`ACPClient`, `ACPToolCall`), hook payloads (`SessionStore`), `ThreadStore`, transcription responses |
| `swift-security` | Keychain `SecItem` queries, `OSStatus` errors, credential storage | `Voice/VoiceKey.swift`, `Signals/SentryWatcher.swift`, the local server token |
| `ios-networking` | `URLSession` with async/await, uploads, retries, error handling | `Voice/Transcriber.swift` (multipart upload), `Signals/SentryWatcher.swift`, the Bun download in `Chat/ACP/ACPRuntime.swift`. `GitHubWatcher` goes through the `gh` CLI, not URLSession. `Bridge/EventServer.swift` uses Network.framework (`NWListener`); see `references/network-framework.md` |
| `swiftui-patterns` | View composition, state ownership, `@State` / `@Binding` / `@Environment`, `.task` | Views in `Chat/ChatView.swift`, `Pet/`, `App/SettingsWindow.swift`, `Meeting/MeetingPanel.swift`, `Meeting/TranscriptsView.swift`, `Voice/VoiceBar.swift` |
| `swiftui-layout-components` | Stacks, grids, `ScrollView`, `List`, `Form`, controls | Settings and setup forms, the agents list, chat transcript layout |
| `swiftui-animation` | Springs, transitions, `PhaseAnimator`, `TimelineView`, reduced motion | Bubbles, the voice waveform, pet effects. The pet itself is a sprite atlas driven by `PetController` / `Atlas`; honour reduced motion (SPEC.md › Pet states) |
| `swiftui-performance` | Excess body updates, layout cost, identity churn, Instruments | The chat transcript (see the transcript-layout hang fixed in #11), the waveform (`LevelBuffer` renders on its own timeline so level updates never re-render the chat) |
| `debugging-instruments` | LLDB, Memory Graph, Instruments for CPU, memory, hangs | A long-running app that stays open all day: leaks, retain cycles in closures held by panels and timers, main-thread hangs |
| `ios-accessibility` | SwiftUI and AppKit accessibility, `NSAccessibility`, keyboard access, reduced motion | Panels, bubbles and Settings. `scripts/e2e.py` `setup` and `settings` drive the real windows through the accessibility tree, so labels and roles are also test surface |
| `push-notifications` | `UNUserNotificationCenter`, categories, actions, permission | `App/Notifier.swift`: local notifications only, with Allow / Deny and Done / Snooze actions that resolve the same approval or reminder as the bubble. Ignore APNs and remote-push sections |

Not vendored because ironpet does not need them: Swift Testing (the tests use XCTest), SwiftLint, navigation stacks, MapKit, PhotoKit, background tasks, App Store review, the iOS Simulator and Liquid Glass guides. Add one from upstream if that changes.
