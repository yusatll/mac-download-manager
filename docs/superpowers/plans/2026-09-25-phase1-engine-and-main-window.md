# Phase 1 — Download Engine + Main Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app, "Hiz Download Manager", that downloads HTTP(S) files over multiple parallel connections with IDM-style dynamic segmentation, pause/resume that survives relaunch, categories, a queue, speed limits, a progress window with a segment bar, and an IDM-style main window, in English and Turkish.

**Architecture:** The `HDMCore` Swift package holds the whole engine and has no UI. Its pieces are the model types, a pure `SegmentPlanner`, the `HTTPDownload` actor (one URLSession per connection), `DownloadStore` (JSON persistence) and `DownloadManager` (`@MainActor @Observable` queue and lifecycle). The app target (SwiftUI + AppKit, generated with XcodeGen) consumes `HDMCore`. It uses SwiftUI scenes for the main, settings and menu bar windows, and AppKit-hosted windows for the dialogs, which may open from anywhere.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, AppKit, Foundation URLSession, Network.framework (test server + path monitor), Swift Testing, XcodeGen. No third-party runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-09-25-hiz-download-manager-design.md` (this plan covers §5, §6 and the Phase 1 row of §14).

## Global Constraints

- Deployment target macOS 14.0; Swift language mode 6; universal build.
- App bundle id `com.hizdm.HizDownloadManager`; product name `Hiz Download Manager`; not sandboxed; hardened runtime on.
- Never use the IDM name, logo or icons; toolbar icons are SF Symbols; the app icon is our own (Task 12).
- English is the development language, and Turkish is added via `App/Resources/Localizable.xcstrings`. Every user-facing string goes through `LocalizedStringKey` or `String(localized:)`.
- Defaults (spec §5, §6): 8 connections per download (range 1–32), 4 simultaneous downloads (1–10), minimum segment 1 MiB, 10 retries, backoff 1, 2, 4 … 30 s, timeout 30 s.
- Persistence: `~/Library/Application Support/HDM/downloads.json`, saved at most 2 s after a change, immediately on pause/complete/quit, file mode `0600`, `.bak` fallback.
- Partial file: `<saveDirectory>/<fileName>.hdmpart`. Category folders: `~/Downloads/HDM/{Compressed,Documents,Music,Programs,Video,General}`.
- Every connection uses its own `URLSession` and sends `Accept-Encoding: identity`.
- The `.xcodeproj` and `Local.xcconfig` are never committed. License: MIT.

## Review Focus

1. **Tiny and empty files (0 B, 10 B):** must download with a single connection and produce an identical file. Covered by a Task 9 test.
2. **`.hdmpart` deleted while a download is paused:** resume must restart cleanly, never produce a corrupted file. Covered by a Task 9 test.
3. **Name collision at completion, including non-ASCII names:** the new file becomes `name (2).ext`, and the existing file is untouched. Covered by a Task 11 test.
4. **Quitting during an active download:** exact segments are persisted, and after relaunch the item is paused and resumes to a correct file. Covered by a Task 11 test.
5. **Server that refuses parallel connections (429 beyond N):** the download still completes with fewer connections. Covered by a Task 9 test.

---

## File Structure

```
.gitignore  LICENSE  Makefile  project.yml  Local.xcconfig.example
Config/Base.xcconfig
scripts/make-icon.swift            app icon generator
scripts/check-strings.py           finds UI strings missing from the catalog
Packages/HDMCore/
  Package.swift
  Sources/HDMCore/
    HDMCore.swift                  version constant
    Model/Segment.swift            byte range + progress of one segment
    Model/DownloadItem.swift       DownloadItem, DownloadStatus, FailureReason, CompletionAction
    Model/Category.swift           DownloadCategory, CategoryResolver
    Model/AppSettings.swift        AppSettings, ConflictPolicy (tolerant decoding)
    HTTP/SegmentPlanner.swift      pure split logic
    HTTP/FilenameResolver.swift    Content-Disposition, sanitising, unique names
    HTTP/SpeedLimiter.swift        token bucket
    HTTP/SpeedMeter.swift          moving-window speed + ETA
    HTTP/RetryPolicy.swift         backoff delays
    HTTP/HTTPHeaders.swift         ContentRange, ProbeResult
    HTTP/PartFile.swift            thread-safe pwrite file
    HTTP/SegmentTable.swift        lock-protected segments + writes
    HTTP/Connection.swift          one ranged request on its own URLSession
    HTTP/HTTPProbe.swift           header-only probe used by dialogs
    HTTP/HTTPDownload.swift        the download actor
    Store/DownloadStore.swift      JSON persistence
    Store/SettingsStore.swift      observable settings in UserDefaults
    Store/DownloadManager.swift    queue, lifecycle, finalisation
  Sources/HDMTestSupport/
    TestData.swift                 deterministic data + SHA-256
    TestHTTPServer.swift           configurable HTTP/1.1 server on 127.0.0.1
  Tests/HDMCoreTests/              one file per unit (named in tasks)
App/
  HizDownloadManagerApp.swift  AppDelegate.swift  AppModel.swift  AppModel+Actions.swift  AppModel+Events.swift
  Windows/WindowCoordinator.swift  WindowCoordinator+Dialogs.swift
  MainWindow/MainView.swift  SidebarView.swift  DownloadTable.swift  MainToolbar.swift  ItemContextMenu.swift  AppCommands.swift
  Capture/PendingDownload.swift  CaptureCoordinator.swift  AddURLView.swift  DownloadInfoView.swift  ClipboardMonitor.swift
  Progress/ProgressWindowView.swift  SegmentBar.swift  ConnectionList.swift  ProgressTabs.swift  CompletionView.swift
  Settings/SettingsView.swift  GeneralSettingsView.swift  SaveToSettingsView.swift  ConnectionSettingsView.swift
  System/MenuBarContent.swift  DockProgress.swift  Notifier.swift  SleepGuard.swift
  Util/Format.swift  Labels.swift  FileIcon.swift  WindowAccessor.swift
  Resources/Assets.xcassets  Resources/Localizable.xcstrings
```

Run core tests at any time with `make test` (= `cd Packages/HDMCore && swift test`).

---

### Task 1: Repository scaffold and HDMCore package

**Files:**
- Create: `.gitignore`, `LICENSE`, `Makefile`, `Packages/HDMCore/Package.swift`, `Packages/HDMCore/Sources/HDMCore/HDMCore.swift`, `Packages/HDMCore/Sources/HDMTestSupport/TestData.swift`
- Test: `Packages/HDMCore/Tests/HDMCoreTests/ScaffoldTests.swift`

**Interfaces:**
- Produces: `HDMCoreInfo.version: String`; `TestData.random(count:seed:) -> Data`, `TestData.sha256(_ data: Data) -> String`, `TestData.sha256(fileAt: URL) throws -> String`.

- [ ] **Step 1: Create a branch**

```bash
git checkout -b phase-1-engine
```

- [ ] **Step 2: Write root files**

`.gitignore`:
```
.DS_Store
*.xcodeproj/
build/
.build/
.swiftpm/
DerivedData/
Local.xcconfig
*.xcuserstate
```

`LICENSE`: the standard MIT license text with the line `Copyright (c) 2026 Ahmet Yuşa Telli`.

`Makefile` (recipe lines are indented with a TAB):
```make
.PHONY: bootstrap project test app run clean
APP = Hiz Download Manager

bootstrap:
	@command -v xcodegen >/dev/null || brew install xcodegen
	@test -f Local.xcconfig || cp Local.xcconfig.example Local.xcconfig

project:
	xcodegen generate

test:
	cd Packages/HDMCore && swift test

app: project
	xcodebuild -project HizDownloadManager.xcodeproj -scheme HizDownloadManager -configuration Debug -derivedDataPath build -quiet build

run: app
	open "build/Build/Products/Debug/$(APP).app"

clean:
	rm -rf build Packages/HDMCore/.build HizDownloadManager.xcodeproj
```

- [ ] **Step 3: Write the package manifest**

`Packages/HDMCore/Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HDMCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HDMCore", targets: ["HDMCore"]),
        .library(name: "HDMTestSupport", targets: ["HDMTestSupport"]),
    ],
    targets: [
        .target(name: "HDMCore"),
        .target(name: "HDMTestSupport"),
        .testTarget(name: "HDMCoreTests", dependencies: ["HDMCore", "HDMTestSupport"]),
    ]
)
```

- [ ] **Step 4: Write the failing test**

`Tests/HDMCoreTests/ScaffoldTests.swift`:
```swift
import Testing
import HDMCore
import HDMTestSupport

@Test func versionIsSet() {
    #expect(!HDMCoreInfo.version.isEmpty)
}

@Test func testDataIsDeterministic() {
    #expect(TestData.random(count: 1000) == TestData.random(count: 1000))
    #expect(TestData.random(count: 1000, seed: 1) != TestData.random(count: 1000, seed: 2))
    #expect(TestData.random(count: 0).isEmpty)
    #expect(TestData.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}
```
(Add `import Foundation` at the top.)

- [ ] **Step 5: Run and confirm it fails to compile** (`HDMCoreInfo`/`TestData` missing)

Run: `cd Packages/HDMCore && swift test`

- [ ] **Step 6: Implement**

`Sources/HDMCore/HDMCore.swift`:
```swift
public enum HDMCoreInfo {
    public static let version = "0.1.0"
}
```

`Sources/HDMTestSupport/TestData.swift`:
```swift
import CryptoKit
import Foundation

public enum TestData {
    /// Deterministic pseudo-random bytes (LCG), so failures are reproducible.
    public static func random(count: Int, seed: UInt64 = 42) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                buffer[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> String {
        sha256(try Data(contentsOf: url))
    }
}
```

- [ ] **Step 7: Run tests — expect PASS**

Run: `make test`

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "chore: scaffold repository and HDMCore package"
```

---

### Task 2: Core model types

**Files:**
- Create: `Sources/HDMCore/Model/Segment.swift`, `Model/DownloadItem.swift`, `Model/Category.swift`, `Model/AppSettings.swift`
- Test: `Tests/HDMCoreTests/ModelTests.swift`

**Interfaces:**
- Produces:
  - `Segment(start:end:received:)`, with `cursor`, `remaining`, `isComplete`, `isOpenEnded` (`end == .max` means the size is unknown).
  - `DownloadStatus`: `.queued`, `.connecting`, `.downloading`, `.paused`, `.merging`, `.completed`, `.failed(FailureReason)`, `.needsRefresh`, with `isRunning` and `canResume`.
  - `FailureReason`: `.network(String)`, `.http(Int)`, `.authRequired`, `.serverFileChanged`, `.diskFull`, `.fileSystem(String)`.
  - `CompletionAction`: `.nothing`, `.open`, `.revealInFinder`.
  - `DownloadItem` (fields below), with `fileURL`, `partURL`, `fractionCompleted` and `resetTransfer()`.
  - `DownloadCategory` (`compressed documents music programs video general`) with `folderName` and `defaultExtensions`; `CategoryResolver.category(forFileName:)`.
  - `AppSettings` (fields below), with `folder(for:)`, `categoryResolver`, `shouldCapture(fileName:)`; `ConflictPolicy`: `.rename`, `.overwrite`, `.ask`.

- [ ] **Step 1: Write the failing tests**

`Tests/HDMCoreTests/ModelTests.swift`:
```swift
import Foundation
import Testing
@testable import HDMCore

@Suite struct ModelTests {
    @Test func segmentMath() {
        let s = Segment(start: 100, end: 200, received: 30)
        #expect(s.cursor == 130)
        #expect(s.remaining == 70)
        #expect(!s.isComplete)
        #expect(Segment(start: 0, end: 10, received: 10).isComplete)
        let open = Segment(start: 0, end: .max, received: 5)
        #expect(open.isOpenEnded && !open.isComplete && open.remaining == .max)
    }

    @Test func categoriesResolveByExtension() {
        let r = CategoryResolver()
        #expect(r.category(forFileName: "a.ZIP") == .compressed)
        #expect(r.category(forFileName: "setup.dmg") == .programs)
        #expect(r.category(forFileName: "film.mkv") == .video)
        #expect(r.category(forFileName: "notes.pdf") == .documents)
        #expect(r.category(forFileName: "song.flac") == .music)
        #expect(r.category(forFileName: "README") == .general)
        #expect(r.category(forFileName: "x.unknown") == .general)
    }

    @Test func settingsDecodeMissingKeysAsDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s == AppSettings())
        #expect(s.maxConnections == 8 && s.maxConcurrentDownloads == 4 && s.retryCount == 10)
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"maxConnections":16}"#.utf8))
        #expect(partial.maxConnections == 16 && partial.preventSleep)
    }

    @Test func settingsRoundTripWithCategoryFolders() throws {
        var s = AppSettings()
        s.categoryFolders[.video] = URL(fileURLWithPath: "/tmp/v")
        s.conflictPolicy = .ask
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.folder(for: .video).path == "/tmp/v")
        #expect(back.folder(for: .music).lastPathComponent == "Music")
        #expect(back.folder(for: .music).deletingLastPathComponent().lastPathComponent == "HDM")
    }

    @Test func captureExtensionsAreCaseInsensitive() {
        let s = AppSettings()
        #expect(s.shouldCapture(fileName: "Big.ISO"))
        #expect(!s.shouldCapture(fileName: "page.html"))
        #expect(!s.shouldCapture(fileName: "noext"))
    }

    @Test func itemRoundTripsAndDerivesPaths() throws {
        var item = DownloadItem(url: URL(string: "https://e.com/a.zip")!, fileName: "a.zip",
                                saveDirectory: URL(fileURLWithPath: "/tmp/d"), category: .compressed)
        item.status = .failed(.network("offline"))
        item.segments = [Segment(start: 0, end: 10, received: 4)]
        item.totalBytes = 10
        item.receivedBytes = 4
        let back = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(back == item)
        #expect(item.partURL.path == "/tmp/d/a.zip.hdmpart")
        #expect(item.fileURL.path == "/tmp/d/a.zip")
        #expect(item.fractionCompleted == 0.4)
        #expect(item.status.canResume && !item.status.isRunning)
        item.resetTransfer()
        #expect(item.segments.isEmpty && item.receivedBytes == 0 && item.totalBytes == nil)
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

Run: `make test`

- [ ] **Step 3: Implement `Model/Segment.swift`**

```swift
/// A byte range `[start, end)` of the target file and how much of it has been written.
/// `end == Int64.max` marks an open-ended range (server did not report a size).
public struct Segment: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var received: Int64

    public init(start: Int64, end: Int64, received: Int64 = 0) {
        self.start = start
        self.end = end
        self.received = received
    }

    public var cursor: Int64 { start + received }
    public var isOpenEnded: Bool { end == .max }
    public var remaining: Int64 { isOpenEnded ? .max : max(0, end - cursor) }
    public var isComplete: Bool { !isOpenEnded && cursor >= end }
}
```

- [ ] **Step 4: Implement `Model/DownloadItem.swift`**

```swift
import Foundation

public enum DownloadKind: String, Codable, Sendable { case http, media }

public enum CompletionAction: String, Codable, Sendable, CaseIterable { case nothing, open, revealInFinder }

public enum FailureReason: Codable, Hashable, Sendable {
    case network(String)
    case http(Int)
    case authRequired
    case serverFileChanged
    case diskFull
    case fileSystem(String)
}

public enum DownloadStatus: Codable, Hashable, Sendable {
    case queued, connecting, downloading, paused, merging, completed
    case failed(FailureReason)
    case needsRefresh

    public var isRunning: Bool {
        switch self {
        case .connecting, .downloading, .merging: true
        default: false
        }
    }

    public var canResume: Bool {
        switch self {
        case .paused, .failed, .needsRefresh: true
        default: false
        }
    }
}

/// One entry of the download list. New fields must be optional (or have custom decoding)
/// so that `downloads.json` written by older versions keeps loading.
public struct DownloadItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: DownloadKind
    public var url: URL
    public var finalURL: URL?
    public var pageURL: URL?
    public var referrer: URL?
    public var headers: [String: String]
    public var fileName: String
    public var saveDirectory: URL
    public var category: DownloadCategory
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var resumable: Bool?
    public var etag: String?
    public var lastModified: String?
    public var segments: [Segment]
    public var status: DownloadStatus
    public var autoStart: Bool
    public var maxConnections: Int?
    public var speedLimit: Int64?
    public var onComplete: CompletionAction
    public var createdAt: Date
    public var lastTryAt: Date?
    public var completedAt: Date?
    public var userDescription: String
    public var awaitingRefresh: Bool

    public init(id: UUID = UUID(), url: URL, fileName: String, saveDirectory: URL, category: DownloadCategory,
                headers: [String: String] = [:], pageURL: URL? = nil, referrer: URL? = nil,
                totalBytes: Int64? = nil, userDescription: String = "", autoStart: Bool = true,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = .http
        self.url = url
        self.pageURL = pageURL
        self.referrer = referrer
        self.headers = headers
        self.fileName = fileName
        self.saveDirectory = saveDirectory
        self.category = category
        self.totalBytes = totalBytes
        self.receivedBytes = 0
        self.segments = []
        self.status = .queued
        self.autoStart = autoStart
        self.onComplete = .nothing
        self.createdAt = createdAt
        self.userDescription = userDescription
        self.awaitingRefresh = false
    }

    public var fileURL: URL { saveDirectory.appendingPathComponent(fileName, isDirectory: false) }
    public var partURL: URL { saveDirectory.appendingPathComponent(fileName + ".hdmpart", isDirectory: false) }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    /// Forget everything learned about the transfer so it starts from byte 0.
    public mutating func resetTransfer() {
        segments = []
        receivedBytes = 0
        totalBytes = nil
        resumable = nil
        etag = nil
        lastModified = nil
        completedAt = nil
    }
}
```

- [ ] **Step 5: Implement `Model/Category.swift`**

```swift
import Foundation

public enum DownloadCategory: String, Codable, CaseIterable, Sendable, Identifiable, CodingKeyRepresentable {
    case compressed, documents, music, programs, video, general

    public var id: String { rawValue }

    /// Folder names are not localised so paths never change with the UI language.
    public var folderName: String {
        switch self {
        case .compressed: "Compressed"
        case .documents: "Documents"
        case .music: "Music"
        case .programs: "Programs"
        case .video: "Video"
        case .general: "General"
        }
    }

    public static let defaultExtensions: [DownloadCategory: [String]] = [
        .compressed: ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "iso"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "txt", "rtf", "epub", "csv"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma"],
        .programs: ["dmg", "pkg", "app", "exe", "msi", "apk", "deb", "rpm", "appimage"],
        .video: ["mp4", "mkv", "webm", "mov", "avi", "m4v", "flv", "wmv", "ts", "3gp"],
        .general: [],
    ]
}

public struct CategoryResolver: Sendable {
    public var extensions: [DownloadCategory: [String]]

    public init(extensions: [DownloadCategory: [String]] = DownloadCategory.defaultExtensions) {
        self.extensions = extensions
    }

    /// First category in `allCases` order that lists the extension wins.
    public func category(forFileName name: String) -> DownloadCategory {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .general }
        for category in DownloadCategory.allCases where category != .general {
            if extensions[category]?.contains(ext) == true { return category }
        }
        return .general
    }
}
```

- [ ] **Step 6: Implement `Model/AppSettings.swift`**

```swift
import Foundation

public enum ConflictPolicy: String, Codable, Sendable, CaseIterable { case rename, overwrite, ask }

public struct AppSettings: Codable, Equatable, Sendable {
    public var maxConnections = 8
    public var maxConcurrentDownloads = 4
    /// Bytes per second; 0 means unlimited.
    public var globalSpeedLimit: Int64 = 0
    public var retryCount = 10
    public var timeoutSeconds: Double = 30
    public var baseFolder: URL = AppSettings.defaultBaseFolder
    public var categoryFolders: [DownloadCategory: URL] = [:]
    public var categoryExtensions: [DownloadCategory: [String]] = DownloadCategory.defaultExtensions
    public var captureExtensions: [String] = AppSettings.defaultCaptureExtensions
    public var clipboardMonitoring = true
    public var startWithoutDialog = false
    public var showProgressWindow = true
    public var showCompletionDialog = true
    public var keepInMenuBar = true
    public var preventSleep = true
    public var conflictPolicy: ConflictPolicy = .rename

    public static let defaultBaseFolder = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HDM", isDirectory: true)

    public static let defaultCaptureExtensions = [
        "3gp", "7z", "aac", "apk", "avi", "bz2", "dmg", "doc", "docx", "epub", "exe", "flac", "flv", "gz",
        "iso", "m4a", "m4v", "mkv", "mov", "mp3", "mp4", "mpeg", "mpg", "msi", "ogg", "opus", "pdf", "pkg",
        "ppt", "pptx", "rar", "tar", "tgz", "wav", "webm", "wma", "wmv", "xls", "xlsx", "xz", "zip",
    ]

    public init() {}

    public func folder(for category: DownloadCategory) -> URL {
        categoryFolders[category] ?? baseFolder.appendingPathComponent(category.folderName, isDirectory: true)
    }

    public var categoryResolver: CategoryResolver { CategoryResolver(extensions: categoryExtensions) }

    public func shouldCapture(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return !ext.isEmpty && captureExtensions.contains(ext)
    }

    // Missing keys fall back to defaults so settings from older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? d.maxConnections
        maxConcurrentDownloads = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? d.maxConcurrentDownloads
        globalSpeedLimit = try c.decodeIfPresent(Int64.self, forKey: .globalSpeedLimit) ?? d.globalSpeedLimit
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? d.retryCount
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        baseFolder = try c.decodeIfPresent(URL.self, forKey: .baseFolder) ?? d.baseFolder
        categoryFolders = try c.decodeIfPresent([DownloadCategory: URL].self, forKey: .categoryFolders) ?? d.categoryFolders
        categoryExtensions = try c.decodeIfPresent([DownloadCategory: [String]].self, forKey: .categoryExtensions) ?? d.categoryExtensions
        captureExtensions = try c.decodeIfPresent([String].self, forKey: .captureExtensions) ?? d.captureExtensions
        clipboardMonitoring = try c.decodeIfPresent(Bool.self, forKey: .clipboardMonitoring) ?? d.clipboardMonitoring
        startWithoutDialog = try c.decodeIfPresent(Bool.self, forKey: .startWithoutDialog) ?? d.startWithoutDialog
        showProgressWindow = try c.decodeIfPresent(Bool.self, forKey: .showProgressWindow) ?? d.showProgressWindow
        showCompletionDialog = try c.decodeIfPresent(Bool.self, forKey: .showCompletionDialog) ?? d.showCompletionDialog
        keepInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .keepInMenuBar) ?? d.keepInMenuBar
        preventSleep = try c.decodeIfPresent(Bool.self, forKey: .preventSleep) ?? d.preventSleep
        conflictPolicy = try c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? d.conflictPolicy
    }
}
```

- [ ] **Step 7: Run tests — expect PASS**

Run: `make test`

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(core): add download, segment, category and settings models"
```

---

### Task 3: SegmentPlanner

**Files:**
- Create: `Sources/HDMCore/HTTP/SegmentPlanner.swift`
- Test: `Tests/HDMCoreTests/SegmentPlannerTests.swift`

**Interfaces:**
- Consumes: `Segment` (Task 2).
- Produces: `SegmentPlanner(minSegment: Int64 = 1 << 20)`, which provides:
  - `initialSegments(total: Int64, connections: Int) -> [Segment]`
  - `nextAssignment(segments: inout [Segment], busy: Set<Int>) -> Int?` (returns the index of a segment to download; may append a new one by splitting).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import HDMCore

@Suite struct SegmentPlannerTests {
    let mib: Int64 = 1 << 20
    var planner: SegmentPlanner { SegmentPlanner(minSegment: mib) }

    @Test func splitsEvenlyUpToConnectionCount() {
        let s = planner.initialSegments(total: 8 * mib, connections: 8)
        #expect(s.count == 8)
        #expect(s.first?.start == 0)
        #expect(s.last?.end == 8 * mib)
        #expect(zip(s, s.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func respectsMinimumSegmentSize() {
        #expect(planner.initialSegments(total: mib + mib / 2, connections: 8).count == 1)
        let three = planner.initialSegments(total: 3 * mib + 5, connections: 8)
        #expect(three.count == 3)
        #expect(three.last?.end == 3 * mib + 5)
    }

    @Test func emptyFileIsOneCompleteSegment() {
        let s = planner.initialSegments(total: 0, connections: 8)
        #expect(s == [Segment(start: 0, end: 0)])
        #expect(s[0].isComplete)
    }

    @Test func prefersIdleIncompleteSegment() {
        var s = [Segment(start: 0, end: mib, received: mib),
                 Segment(start: mib, end: 2 * mib),
                 Segment(start: 2 * mib, end: 3 * mib)]
        #expect(planner.nextAssignment(segments: &s, busy: [2]) == 1)
        #expect(s.count == 3)
    }

    @Test func splitsLargestBusySegment() {
        var s = [Segment(start: 0, end: 10 * mib, received: mib),
                 Segment(start: 10 * mib, end: 12 * mib)]
        let index = planner.nextAssignment(segments: &s, busy: [0, 1])
        #expect(index == 2)
        #expect(s[0].end == mib + 9 * mib / 2)
        #expect(s[2] == Segment(start: mib + 9 * mib / 2, end: 10 * mib))
    }

    @Test func refusesToSplitSmallRemainders() {
        var s = [Segment(start: 0, end: 2 * mib, received: mib + 1)]
        #expect(planner.nextAssignment(segments: &s, busy: [0]) == nil)
        #expect(s.count == 1)
    }

    @Test func neverSplitsOpenEndedSegment() {
        var s = [Segment(start: 0, end: .max, received: 100)]
        #expect(planner.nextAssignment(segments: &s, busy: [0]) == nil)
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement**

```swift
/// Pure segmentation decisions (spec §5.3). No I/O, so every rule is unit-testable.
public struct SegmentPlanner: Sendable {
    public let minSegment: Int64

    public init(minSegment: Int64 = 1 << 20) {
        self.minSegment = max(1, minSegment)
    }

    public func initialSegments(total: Int64, connections: Int) -> [Segment] {
        guard total > 0 else { return [Segment(start: 0, end: 0)] }
        let count = max(1, min(Int64(max(1, connections)), total / minSegment))
        let size = total / count
        return (0..<count).map { i in
            Segment(start: i * size, end: i == count - 1 ? total : (i + 1) * size)
        }
    }

    /// Picks work for a free connection: an unclaimed incomplete segment first, otherwise the
    /// busy segment with the most bytes left is cut in half and the upper half is appended.
    public func nextAssignment(segments: inout [Segment], busy: Set<Int>) -> Int? {
        if let idle = segments.indices.first(where: { !segments[$0].isComplete && !busy.contains($0) }) {
            return idle
        }
        let candidates = busy.filter { $0 < segments.count && !segments[$0].isComplete && !segments[$0].isOpenEnded }
        guard let victim = candidates.max(by: { segments[$0].remaining < segments[$1].remaining }) else { return nil }
        let segment = segments[victim]
        guard segment.remaining >= 2 * minSegment else { return nil }
        let middle = segment.cursor + segment.remaining / 2
        segments[victim].end = middle
        segments.append(Segment(start: middle, end: segment.end))
        return segments.count - 1
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add dynamic SegmentPlanner"
```

---

### Task 4: FilenameResolver

**Files:**
- Create: `Sources/HDMCore/HTTP/FilenameResolver.swift`
- Test: `Tests/HDMCoreTests/FilenameResolverTests.swift`

**Interfaces:**
- Produces: `FilenameResolver.resolve(userProvided:contentDisposition:suggested:url:mimeType:) -> String` (every parameter except `url` defaults to `nil`), `parseContentDisposition(_:) -> String?`, `sanitize(_:) -> String`, `uniqueName(_:in:) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import HDMCore

@Suite struct FilenameResolverTests {
    @Test func parsesContentDisposition() {
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="report.pdf""#) == "report.pdf")
        #expect(FilenameResolver.parseContentDisposition("attachment; filename*=UTF-8''%C3%BCcret.txt") == "ücret.txt")
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="plain.txt"; filename*=UTF-8''fancy%20name.txt"#) == "fancy name.txt")
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="a;b.zip""#) == "a;b.zip")
        #expect(FilenameResolver.parseContentDisposition("inline") == nil)
    }

    @Test func resolvesInPriorityOrder() {
        let url = URL(string: "https://x.com/files/My%20File.zip?token=1")!
        #expect(FilenameResolver.resolve(userProvided: "mine.zip", contentDisposition: #"attachment; filename="cd.zip""#, url: url) == "mine.zip")
        #expect(FilenameResolver.resolve(contentDisposition: #"attachment; filename="cd.zip""#, suggested: "s.zip", url: url) == "cd.zip")
        #expect(FilenameResolver.resolve(suggested: "s.zip", url: url) == "s.zip")
        #expect(FilenameResolver.resolve(url: url) == "My File.zip")
        #expect(FilenameResolver.resolve(url: URL(string: "https://x.com/")!, mimeType: "application/pdf") == "index.pdf")
        #expect(FilenameResolver.resolve(url: URL(string: "https://x.com/get")!, mimeType: "application/octet-stream") == "get")
    }

    @Test func sanitizesDangerousNames() {
        #expect(FilenameResolver.sanitize("../../etc/passwd") == "_.._etc_passwd")
        #expect(FilenameResolver.sanitize("a\u{0}b:c") == "ab_c")
        #expect(FilenameResolver.sanitize("   ") == "download")
        #expect(FilenameResolver.sanitize(".hidden") == "hidden")
        let long = FilenameResolver.sanitize(String(repeating: "a", count: 300) + ".zip")
        #expect(long.utf8.count == 255 && long.hasSuffix(".zip"))
    }

    @Test func makesUniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(FilenameResolver.uniqueName("a.zip", in: dir) == "a.zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.zip").path, contents: Data())
        #expect(FilenameResolver.uniqueName("a.zip", in: dir) == "a (2).zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a (2).zip").path, contents: Data())
        #expect(FilenameResolver.uniqueName("a.zip", in: dir) == "a (3).zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("b.zip.hdmpart").path, contents: Data())
        #expect(FilenameResolver.uniqueName("b.zip", in: dir) == "b (2).zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("readme").path, contents: Data())
        #expect(FilenameResolver.uniqueName("readme", in: dir) == "readme (2)")
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement**

```swift
import Foundation
import UniformTypeIdentifiers

/// Chooses and cleans the on-disk file name (spec §5.6).
public enum FilenameResolver {
    public static func resolve(userProvided: String? = nil, contentDisposition: String? = nil,
                               suggested: String? = nil, url: URL, mimeType: String? = nil) -> String {
        if let user = userProvided?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return sanitize(user)
        }
        if let header = contentDisposition, let name = parseContentDisposition(header), !name.isEmpty {
            return sanitize(name)
        }
        if let suggested = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty {
            return sanitize(suggested)
        }
        let last = url.lastPathComponent
        var name = (last.isEmpty || last == "/") ? "index" : last
        if (name as NSString).pathExtension.isEmpty, let ext = fileExtension(forMIMEType: mimeType) {
            name += "." + ext
        }
        return sanitize(name)
    }

    public static func parseContentDisposition(_ header: String) -> String? {
        var params: [String: String] = [:]
        for part in splitParameters(header).dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            params[key] = value
        }
        if let extended = params["filename*"], let marker = extended.range(of: "''"),
           let decoded = extended[marker.upperBound...].removingPercentEncoding, !decoded.isEmpty {
            return decoded
        }
        if let plain = params["filename"], !plain.isEmpty {
            return plain.removingPercentEncoding ?? plain
        }
        return nil
    }

    public static func sanitize(_ name: String) -> String {
        var s = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        for bad in ["/", ":", "\\"] { s = s.replacingOccurrences(of: bad, with: "_") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "download" }
        if s.utf8.count > 255 {
            let ext = (s as NSString).pathExtension
            var base = (s as NSString).deletingPathExtension
            let limit = 255 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
            while base.utf8.count > limit { base.removeLast() }
            s = ext.isEmpty ? base : base + "." + ext
        }
        return s
    }

    /// `name`, or `name (2)`, `name (3)` … whichever has neither a file nor a `.hdmpart` in `directory`.
    public static func uniqueName(_ name: String, in directory: URL) -> String {
        let fm = FileManager.default
        func taken(_ candidate: String) -> Bool {
            let path = directory.appendingPathComponent(candidate).path
            return fm.fileExists(atPath: path) || fm.fileExists(atPath: path + ".hdmpart")
        }
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    private static func fileExtension(forMIMEType mime: String?) -> String? {
        guard let mime, !mime.hasPrefix("application/octet-stream"), let type = UTType(mimeType: mime) else { return nil }
        return type.preferredFilenameExtension
    }

    private static func splitParameters(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in header {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        return parts
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add FilenameResolver"
```

---

### Task 5: SpeedLimiter, SpeedMeter, RetryPolicy

**Files:**
- Create: `Sources/HDMCore/HTTP/SpeedLimiter.swift`, `HTTP/SpeedMeter.swift`, `HTTP/RetryPolicy.swift`
- Test: `Tests/HDMCoreTests/RateTests.swift`

**Interfaces:**
- Produces:
  - `SpeedLimiter(bytesPerSecond: Int64, now: @escaping @Sendable () -> TimeInterval = …)` with `setRate(_:)` and `consume(_ bytes: Int) -> TimeInterval` (the time to pause). A final class that is `Sendable`.
  - `SpeedMeter(window: TimeInterval = 3)` with `add(bytes:at:)`, `bytesPerSecond`, `secondsRemaining(total:received:)` and `reset()`.
  - `RetryPolicy.delay(forAttempt: Int) -> TimeInterval`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import os
@testable import HDMCore

final class FakeClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0.0)
    var now: TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@Suite struct RateTests {
    @Test func unlimitedNeverPauses() {
        let limiter = SpeedLimiter(bytesPerSecond: 0)
        #expect(limiter.consume(10_000_000) == 0)
    }

    @Test func tokenBucketComputesPause() {
        let clock = FakeClock()
        let limiter = SpeedLimiter(bytesPerSecond: 1000, now: { clock.now })
        #expect(limiter.consume(1000) == 0)
        #expect(abs(limiter.consume(500) - 0.5) < 0.0001)
        clock.advance(1)
        #expect(limiter.consume(400) == 0)
        limiter.setRate(0)
        #expect(limiter.consume(1_000_000) == 0)
    }

    @Test func meterAveragesOverWindow() {
        var meter = SpeedMeter(window: 3)
        meter.add(bytes: 0, at: 0)
        meter.add(bytes: 1000, at: 1)
        meter.add(bytes: 2000, at: 2)
        #expect(meter.bytesPerSecond == 1000)
        #expect(meter.secondsRemaining(total: 5000, received: 2000) == 3)
        #expect(meter.secondsRemaining(total: nil, received: 2000) == nil)
        meter.add(bytes: 12000, at: 10)
        #expect(meter.bytesPerSecond == 1250)
        meter.reset()
        #expect(meter.bytesPerSecond == 0)
    }

    @Test func backoffDoublesAndCaps() {
        #expect(RetryPolicy.delay(forAttempt: 1) == 1)
        #expect(RetryPolicy.delay(forAttempt: 2) == 2)
        #expect(RetryPolicy.delay(forAttempt: 3) == 4)
        #expect(RetryPolicy.delay(forAttempt: 6) == 30)
        #expect(RetryPolicy.delay(forAttempt: 40) == 30)
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement**

`HTTP/SpeedLimiter.swift`:
```swift
import Foundation

/// Token bucket shared by connections (spec §5.7). Capacity equals one second of traffic.
public final class SpeedLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var rate: Int64
    private var tokens: Double
    private var last: TimeInterval

    public init(bytesPerSecond: Int64, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.rate = max(0, bytesPerSecond)
        self.tokens = Double(max(0, bytesPerSecond))
        self.last = now()
    }

    public func setRate(_ bytesPerSecond: Int64) {
        lock.withLock {
            refill()
            rate = max(0, bytesPerSecond)
            tokens = min(tokens, Double(rate))
        }
    }

    /// Records `bytes` as transferred and returns how long the caller should stop reading.
    public func consume(_ bytes: Int) -> TimeInterval {
        lock.withLock {
            guard rate > 0 else { return 0 }
            refill()
            tokens -= Double(bytes)
            return tokens >= 0 ? 0 : -tokens / Double(rate)
        }
    }

    private func refill() {
        let t = now()
        tokens = min(Double(rate), tokens + (t - last) * Double(rate))
        last = t
    }
}
```

`HTTP/SpeedMeter.swift`:
```swift
import Foundation

public struct SpeedMeter: Sendable {
    private struct Sample: Sendable { var time: TimeInterval; var bytes: Int64 }
    private var samples: [Sample] = []
    public let window: TimeInterval

    public init(window: TimeInterval = 3) { self.window = window }

    public mutating func add(bytes: Int64, at time: TimeInterval) {
        samples.append(Sample(time: time, bytes: bytes))
        while samples.count > 2, let first = samples.first, time - first.time > window {
            samples.removeFirst()
        }
    }

    public var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return max(0, Double(last.bytes - first.bytes) / (last.time - first.time))
    }

    public func secondsRemaining(total: Int64?, received: Int64) -> TimeInterval? {
        guard let total, bytesPerSecond > 0 else { return nil }
        return Double(max(0, total - received)) / bytesPerSecond
    }

    public mutating func reset() { samples.removeAll() }
}
```

`HTTP/RetryPolicy.swift`:
```swift
import Foundation

public enum RetryPolicy {
    /// 1, 2, 4, 8, 16, 30, 30 … seconds.
    @Sendable public static func delay(forAttempt attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, attempt - 1))))
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add speed limiter, speed meter and retry policy"
```

---

### Task 6: Header parsing, PartFile, SegmentTable

**Files:**
- Create: `Sources/HDMCore/HTTP/HTTPHeaders.swift`, `HTTP/PartFile.swift`, `HTTP/SegmentTable.swift`
- Test: `Tests/HDMCoreTests/HeaderAndFileTests.swift`

**Interfaces:**
- Consumes: `Segment`, `SegmentPlanner`.
- Produces:
  - `ContentRange(header: String?)` with `start`, `end` and `total: Int64?`.
  - `ProbeResult(response: HTTPURLResponse)` with `statusCode`, `totalBytes`, `resumable`, `etag` (strong ETags only), `lastModified`, `contentDisposition`, `mimeType`, `finalURL`, `ifRangeValidator`.
  - `PartFile(url:) throws` with `resize(atLeast:) throws`, `write(_:at:) throws` and `close()`; `PartFileError`: `.diskFull`, `.closed`, `.io(Int32)`.
  - `SegmentTable(segments:planner:file:)` with:
    - `write(_:segment:) throws -> WriteOutcome` (`.more` or `.segmentDone`)
    - `claimNext() -> Int?`, `claim(_:)`, `release(_:)`
    - `replace(with:)`, `segment(_:) -> Segment`, `closeOpenEnded(_:)`, `snapshot() -> [Segment]`
    - `receivedBytes`, `allComplete`
    - `resize(atLeast:) throws`, `closeFile()`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import HDMCore

@Suite struct HeaderAndFileTests {
    func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hdm-\(UUID().uuidString).hdmpart") }

    @Test func parsesContentRange() {
        #expect(ContentRange(header: "bytes 0-99/1000") == ContentRange(start: 0, end: 99, total: 1000))
        #expect(ContentRange(header: "bytes 5-9/*")?.total == nil)
        #expect(ContentRange(header: "bytes 9-5/10") == nil)
        #expect(ContentRange(header: "items 0-1/2") == nil)
        #expect(ContentRange(header: nil) == nil)
    }

    @Test func probeResultReadsHeaders() {
        let url = URL(string: "https://e.com/f")!
        let partial = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Range": "bytes 0-9/5000", "ETag": "\"abc\"", "Last-Modified": "Mon, 01 Jan 2024 00:00:00 GMT",
            "Content-Disposition": "attachment; filename=\"x.zip\"", "Content-Type": "application/zip"])!
        let p = ProbeResult(response: partial)
        #expect(p.totalBytes == 5000 && p.resumable && p.etag == "\"abc\"" && p.ifRangeValidator == "\"abc\"")
        #expect(p.contentDisposition == "attachment; filename=\"x.zip\"" && p.mimeType == "application/zip")

        let full = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Length": "77", "ETag": "W/\"weak\"", "Last-Modified": "Mon, 01 Jan 2024 00:00:00 GMT"])!
        let f = ProbeResult(response: full)
        #expect(f.totalBytes == 77 && !f.resumable && f.etag == nil)
        #expect(f.ifRangeValidator == "Mon, 01 Jan 2024 00:00:00 GMT")
    }

    @Test func partFileWritesAtOffsetsAndOnlyGrows() throws {
        let url = temp()
        let file = try PartFile(url: url)
        try file.resize(atLeast: 10)
        try file.write(Data([1, 2, 3]), at: 7)
        try file.write(Data([9]), at: 0)
        try file.resize(atLeast: 4)
        file.close()
        #expect(try Data(contentsOf: url) == Data([9, 0, 0, 0, 0, 0, 0, 1, 2, 3]))
        #expect(throws: PartFileError.closed) { try file.write(Data([1]), at: 0) }
    }

    @Test func segmentTableClampsAtSegmentEnd() throws {
        let url = temp()
        let table = SegmentTable(segments: [Segment(start: 0, end: 4), Segment(start: 4, end: 8)],
                                 planner: SegmentPlanner(minSegment: 1), file: try PartFile(url: url))
        #expect(try table.write(Data([1, 1]), segment: 0) == .more)
        #expect(try table.write(Data([2, 2, 2, 2]), segment: 0) == .segmentDone)
        #expect(table.segment(0).received == 4)
        #expect(try table.write(Data([5, 6, 7, 8]), segment: 1) == .segmentDone)
        #expect(table.allComplete && table.receivedBytes == 8)
        table.closeFile()
        #expect(try Data(contentsOf: url) == Data([1, 1, 2, 2, 5, 6, 7, 8]))
    }

    @Test func segmentTableClaimsAndSplits() throws {
        let table = SegmentTable(segments: [Segment(start: 0, end: 100)], planner: SegmentPlanner(minSegment: 10),
                                 file: try PartFile(url: temp()))
        #expect(table.claimNext() == 0)
        #expect(table.claimNext() == 1)
        #expect(table.snapshot() == [Segment(start: 0, end: 50), Segment(start: 50, end: 100)])
        table.release(1)
        #expect(table.claimNext() == 1)
    }

    @Test func openEndedSegmentCanBeClosed() throws {
        let table = SegmentTable(segments: [Segment(start: 0, end: .max)], planner: SegmentPlanner(),
                                 file: try PartFile(url: temp()))
        _ = try table.write(Data(count: 5), segment: 0)
        #expect(!table.allComplete)
        table.closeOpenEnded(0)
        #expect(table.allComplete && table.segment(0) == Segment(start: 0, end: 5, received: 5))
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement `HTTP/HTTPHeaders.swift`**

```swift
import Foundation

public struct ContentRange: Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var total: Int64?

    public init(start: Int64, end: Int64, total: Int64?) {
        self.start = start
        self.end = end
        self.total = total
    }

    /// Parses `bytes a-b/total` or `bytes a-b/*`.
    public init?(header: String?) {
        guard let raw = header?.trimmingCharacters(in: .whitespaces).lowercased(), raw.hasPrefix("bytes") else { return nil }
        let body = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let halves = body.split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let a = Int64(bounds[0]), let b = Int64(bounds[1]), b >= a else { return nil }
        let total: Int64?
        if halves[1] == "*" { total = nil } else if let t = Int64(halves[1]) { total = t } else { return nil }
        self.init(start: a, end: b, total: total)
    }
}

/// What the first response of a download tells us about the file.
public struct ProbeResult: Equatable, Sendable {
    public var statusCode: Int
    public var totalBytes: Int64?
    public var resumable: Bool
    public var etag: String?
    public var lastModified: String?
    public var contentDisposition: String?
    public var mimeType: String?
    public var finalURL: URL?

    public init(response: HTTPURLResponse) {
        statusCode = response.statusCode
        if response.statusCode == 206 {
            let range = ContentRange(header: response.value(forHTTPHeaderField: "Content-Range"))
            totalBytes = range?.total
            resumable = range?.total != nil
        } else {
            totalBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            resumable = false
        }
        let tag = response.value(forHTTPHeaderField: "ETag")
        etag = (tag?.hasPrefix("W/") ?? true) ? nil : tag   // weak ETags are not valid in If-Range
        lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition")
        mimeType = response.mimeType
        finalURL = response.url
    }

    public var ifRangeValidator: String? { etag ?? lastModified }
}
```

- [ ] **Step 4: Implement `HTTP/PartFile.swift`**

```swift
import Darwin
import Foundation

public enum PartFileError: Error, Equatable, Sendable {
    case diskFull
    case closed
    case io(Int32)
}

/// Positional writer for a `.hdmpart` file; safe to call from several threads.
public final class PartFile: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var fd: Int32

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = Darwin.open(url.path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 { throw PartFileError.io(errno) }
    }

    deinit { close() }

    /// Grows the file to `size` (sparse on APFS); never shrinks it.
    public func resize(atLeast size: Int64) throws {
        try lock.withLock {
            guard fd >= 0 else { throw PartFileError.closed }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw PartFileError.io(errno) }
            if info.st_size < size, ftruncate(fd, off_t(size)) != 0 {
                throw errno == ENOSPC ? PartFileError.diskFull : PartFileError.io(errno)
            }
        }
    }

    public func write(_ data: Data, at offset: Int64) throws {
        try lock.withLock {
            guard fd >= 0 else { throw PartFileError.closed }
            guard !data.isEmpty else { return }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var written = 0
                while written < raw.count {
                    let n = Darwin.pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(offset) + off_t(written))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw errno == ENOSPC ? PartFileError.diskFull : PartFileError.io(errno)
                    }
                    written += n
                }
            }
        }
    }

    public func close() {
        lock.withLock {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }
}
```

- [ ] **Step 5: Implement `HTTP/SegmentTable.swift`**

```swift
import Foundation

/// The live segment list of one download. Writes and split decisions happen under one lock,
/// so a split can never hand out bytes that another connection is writing.
public final class SegmentTable: @unchecked Sendable {
    public enum WriteOutcome: Equatable, Sendable { case more, segmentDone }

    private let lock = NSLock()
    private var segments: [Segment]
    private var busy: Set<Int> = []
    private let planner: SegmentPlanner
    private let file: PartFile

    public init(segments: [Segment], planner: SegmentPlanner, file: PartFile) {
        self.segments = segments
        self.planner = planner
        self.file = file
    }

    /// Writes as much of `data` as fits in the segment; bytes past its end are dropped.
    public func write(_ data: Data, segment index: Int) throws -> WriteOutcome {
        try lock.withLock {
            var segment = segments[index]
            if segment.isComplete { return .segmentDone }
            let allowed = segment.isOpenEnded ? data.count : Int(min(Int64(data.count), segment.end - segment.cursor))
            if allowed > 0 { try file.write(data.prefix(allowed), at: segment.cursor) }
            segment.received += Int64(allowed)
            segments[index] = segment
            return segment.isComplete ? .segmentDone : .more
        }
    }

    public func claimNext() -> Int? {
        lock.withLock {
            let index = planner.nextAssignment(segments: &segments, busy: busy)
            if let index { busy.insert(index) }
            return index
        }
    }

    public func claim(_ index: Int) { lock.withLock { _ = busy.insert(index) } }
    public func release(_ index: Int) { lock.withLock { _ = busy.remove(index) } }
    public func replace(with new: [Segment]) { lock.withLock { segments = new } }
    public func segment(_ index: Int) -> Segment { lock.withLock { segments[index] } }
    public func closeOpenEnded(_ index: Int) { lock.withLock { segments[index].end = segments[index].cursor } }
    public func snapshot() -> [Segment] { lock.withLock { segments } }
    public var receivedBytes: Int64 { lock.withLock { segments.reduce(0) { $0 + $1.received } } }
    public var allComplete: Bool { lock.withLock { segments.allSatisfy(\.isComplete) } }
    public func resize(atLeast size: Int64) throws { try file.resize(atLeast: size) }
    public func closeFile() { lock.withLock { file.close() } }
}
```

- [ ] **Step 6: Run tests — expect PASS**

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(core): add header parsing, PartFile and SegmentTable"
```

---

### Task 7: TestHTTPServer

**Files:**
- Create: `Sources/HDMTestSupport/TestHTTPServer.swift`
- Test: `Tests/HDMCoreTests/TestHTTPServerTests.swift`

**Interfaces:**
- Produces:
  - `TestHTTPServer(_ config: Config) throws`, with `start() async throws`, `stop()`, `url: URL`, `update(_:)`, `requests: [RecordedRequest]` and `maxObservedConcurrency: Int`.
  - `Config` fields: `body`, `supportsRange`, `etag`, `lastModified`, `contentDisposition`, `contentType`, `sendContentLength`, `bytesPerSecondPerConnection`, `maxConcurrentConnections`, `dropOnceAfterBytes`, `statusSequence`.
  - `RecordedRequest`: `method`, `path`, `headers` (lower-cased names).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import HDMTestSupport

@Suite struct TestHTTPServerTests {
    func session() -> URLSession { URLSession(configuration: .ephemeral) }

    @Test func servesRangesAndHonoursIfRange() async throws {
        let body = TestData.random(count: 1000)
        let server = try TestHTTPServer(.init(body: body))
        try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: server.url)
        request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (data, response) = try await session().data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 10-19/1000")
        #expect(data == body.subdata(in: 10..<20))

        request.setValue("\"other\"", forHTTPHeaderField: "If-Range")
        let (full, fullResponse) = try await session().data(for: request)
        #expect((fullResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(full == body)
        #expect(server.requests.last?.headers["if-range"] == "\"other\"")
    }

    @Test func forcedStatusesComeFirst() async throws {
        let server = try TestHTTPServer({ var c = TestHTTPServer.Config(body: Data("ok".utf8)); c.statusSequence = [403]; return c }())
        try await server.start()
        defer { server.stop() }
        let (_, first) = try await session().data(from: server.url)
        let (second, _) = try await session().data(from: server.url)
        #expect((first as? HTTPURLResponse)?.statusCode == 403)
        #expect(second == Data("ok".utf8))
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement**

```swift
import Foundation
import Network
import os

public struct RecordedRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
}

/// Minimal HTTP/1.1 server on 127.0.0.1 for engine tests. Every response closes its connection,
/// so each client request is its own TCP connection, just like HDM's segment connections.
public final class TestHTTPServer: @unchecked Sendable {
    public struct Config: Sendable {
        public var body: Data
        public var supportsRange = true
        public var etag: String? = "\"v1\""
        public var lastModified: String? = "Wed, 21 Oct 2015 07:28:00 GMT"
        public var contentDisposition: String?
        public var contentType = "application/octet-stream"
        public var sendContentLength = true
        public var bytesPerSecondPerConnection: Int?
        /// Requests beyond this many in flight get 429.
        public var maxConcurrentConnections: Int?
        /// The first body response is cut after this many bytes.
        public var dropOnceAfterBytes: Int?
        /// Statuses returned (with a tiny body) before normal responses resume.
        public var statusSequence: [Int] = []

        public init(body: Data) { self.body = body }
    }

    private let lock = NSLock()
    private var config: Config
    private var active = 0
    private var observedMax = 0
    private var recorded: [RecordedRequest] = []
    private var didDrop = false
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hdm.testserver")

    public init(_ config: Config) throws {
        self.config = config
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    public var url: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/files/test.bin")! }
    public var requests: [RecordedRequest] { lock.withLock { recorded } }
    public var maxObservedConcurrency: Int { lock.withLock { observedMax } }
    public func update(_ change: (inout Config) -> Void) { lock.withLock { change(&config) } }

    public func start() async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume() }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                Task { await self.serve(connection, head: head) }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.readHead(connection, buffer: buffer)
            }
        }
    }

    private func serve(_ connection: NWConnection, head: String) async {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = RecordedRequest(method: requestLine.first.map(String.init) ?? "",
                                      path: requestLine.count > 1 ? String(requestLine[1]) : "", headers: headers)
        let (cfg, forced, dropAfter) = lock.withLock { () -> (Config, Int?, Int?) in
            recorded.append(request)
            active += 1
            observedMax = max(observedMax, active)
            var forced: Int? = config.statusSequence.isEmpty ? nil : config.statusSequence.removeFirst()
            if forced == nil, let limit = config.maxConcurrentConnections, active > limit { forced = 429 }
            var drop: Int?
            if forced == nil, let bytes = config.dropOnceAfterBytes, !didDrop { didDrop = true; drop = bytes }
            return (config, forced, drop)
        }
        defer { lock.withLock { active -= 1 } }

        if let forced {
            let body = Data("error \(forced)".utf8)
            await send(connection, head: responseHead(forced, ["Content-Length": "\(body.count)", "Connection": "close"]),
                       body: body, rate: nil, dropAfter: nil)
            return
        }

        var status = 200
        var slice = cfg.body
        var fields: [String: String] = ["Content-Type": cfg.contentType, "Connection": "close"]
        if cfg.supportsRange, let rangeHeader = headers["range"], ifRangeMatches(headers["if-range"], cfg),
           let range = parseRange(rangeHeader, total: cfg.body.count) {
            status = 206
            slice = cfg.body.subdata(in: range.lowerBound..<(range.upperBound + 1))
            fields["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(cfg.body.count)"
        }
        if cfg.sendContentLength { fields["Content-Length"] = "\(slice.count)" }
        if cfg.supportsRange { fields["Accept-Ranges"] = "bytes" }
        if let etag = cfg.etag { fields["ETag"] = etag }
        if let modified = cfg.lastModified { fields["Last-Modified"] = modified }
        if let disposition = cfg.contentDisposition { fields["Content-Disposition"] = disposition }
        await send(connection, head: responseHead(status, fields), body: slice,
                   rate: cfg.bytesPerSecondPerConnection, dropAfter: dropAfter)
    }

    private func parseRange(_ value: String, total: Int) -> ClosedRange<Int>? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2, let start = Int(spec[0]), start < total else { return nil }
        let end = spec[1].isEmpty ? total - 1 : min(Int(spec[1]) ?? total - 1, total - 1)
        return end >= start ? start...end : nil
    }

    private func ifRangeMatches(_ value: String?, _ cfg: Config) -> Bool {
        guard let value else { return true }
        return value == cfg.etag || value == cfg.lastModified
    }

    private func send(_ connection: NWConnection, head: String, body: Data, rate: Int?, dropAfter: Int?) async {
        await write(connection, Data(head.utf8))
        let chunk = rate.map { max(1024, min(16 * 1024, $0 / 20)) } ?? 64 * 1024
        var offset = 0
        while offset < body.count {
            if let dropAfter, offset >= dropAfter { connection.cancel(); return }
            let count = min(chunk, body.count - offset)
            await write(connection, body.subdata(in: offset..<(offset + count)))
            offset += count
            if let rate { try? await Task.sleep(nanoseconds: UInt64(Double(count) / Double(rate) * 1_000_000_000)) }
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func write(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private func responseHead(_ status: Int, _ fields: [String: String]) -> String {
        let reasons = [200: "OK", 206: "Partial Content", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       410: "Gone", 416: "Range Not Satisfiable", 429: "Too Many Requests",
                       500: "Internal Server Error", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        for (name, value) in fields { head += "\(name): \(value)\r\n" }
        return head + "\r\n"
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "test: add configurable TestHTTPServer"
```

---

### Task 8: Connection and HTTPProbe

**Files:**
- Create: `Sources/HDMCore/HTTP/Connection.swift`, `HTTP/HTTPProbe.swift`
- Test: `Tests/HDMCoreTests/ConnectionTests.swift`, and the shared helpers in `Tests/HDMCoreTests/TestHelpers.swift`

**Interfaces:**
- Consumes: `SpeedLimiter`, `SegmentTable`, `ProbeResult`, `FailureReason`.
- Produces (internal):
  - `ConnectionResult`: `.segmentDone`, `.endOfStream`, `.cancelled`, `.rejected`, `.fatal(FailureReason)`, `.failed(String)`.
  - `DataOutcome`: `.more`, `.done`, `.failed(FailureReason)`.
  - `ConnectionHandlers(onResponse:onData:onComplete:)`.
  - `Connection(request:timeout:limiters:handlers:)` with `start()` and `cancel()`.
- Produces (public): `HTTPProbe.probe(url:headers:timeout:) async throws -> ProbeResult`; `ProbeError`: `.http(Int)`, `.notHTTP`.
- Produces (tests): `tempDirectory() -> URL`, `fastBackoff`.

- [ ] **Step 1: Write the test helpers and failing tests**

`Tests/HDMCoreTests/TestHelpers.swift`:
```swift
import Foundation

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hdm-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let fastBackoff: @Sendable (Int) -> TimeInterval = { _ in 0.05 }

struct WaitTimeout: Error {}

@MainActor
func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw WaitTimeout() }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
```

`Tests/HDMCoreTests/ConnectionTests.swift`:
```swift
import Foundation
import Testing
@testable import HDMCore
import HDMTestSupport

@Suite struct ConnectionTests {
    @Test func streamsRangeIntoSegmentTable() async throws {
        let body = TestData.random(count: 256 * 1024)
        let server = try TestHTTPServer(.init(body: body))
        try await server.start()
        defer { server.stop() }
        let url = tempDirectory().appendingPathComponent("c.hdmpart")
        let table = SegmentTable(segments: [Segment(start: 0, end: 131_072)], planner: SegmentPlanner(minSegment: 65_536),
                                 file: try PartFile(url: url))
        var request = URLRequest(url: server.url)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")

        let result: ConnectionResult = await withCheckedContinuation { continuation in
            let connection = Connection(request: request, timeout: 10, limiters: [], handlers: ConnectionHandlers(
                onResponse: { $0.statusCode == 206 },
                onData: { data in (try? table.write(data, segment: 0)) == .segmentDone ? .done : .more },
                onComplete: { continuation.resume(returning: $0) }))
            connection.start()
        }
        #expect(result == .segmentDone)
        table.closeFile()
        #expect(try Data(contentsOf: url) == body.prefix(131_072))
    }

    @Test func rejectedResponseReportsRejected() async throws {
        let server = try TestHTTPServer(.init(body: Data(count: 10)))
        try await server.start()
        defer { server.stop() }
        let result: ConnectionResult = await withCheckedContinuation { continuation in
            let connection = Connection(request: URLRequest(url: server.url), timeout: 10, limiters: [], handlers: ConnectionHandlers(
                onResponse: { _ in false }, onData: { _ in .more }, onComplete: { continuation.resume(returning: $0) }))
            connection.start()
        }
        #expect(result == .rejected)
    }

    @Test func probeReadsHeadersWithoutDownloadingBody() async throws {
        var config = TestHTTPServer.Config(body: TestData.random(count: 500_000))
        config.contentDisposition = #"attachment; filename="probe.bin""#
        let server = try TestHTTPServer(config)
        try await server.start()
        defer { server.stop() }
        let result = try await HTTPProbe.probe(url: server.url)
        #expect(result.totalBytes == 500_000 && result.resumable && result.etag == "\"v1\"")
        #expect(result.contentDisposition == #"attachment; filename="probe.bin""#)
        #expect(server.requests.first?.headers["range"] == "bytes=0-")
        #expect(server.requests.first?.headers["accept-encoding"] == "identity")
    }

    @Test func probeWithoutRangeSupport() async throws {
        var config = TestHTTPServer.Config(body: Data(count: 1234))
        config.supportsRange = false
        let server = try TestHTTPServer(config)
        try await server.start()
        defer { server.stop() }
        let result = try await HTTPProbe.probe(url: server.url)
        #expect(result.totalBytes == 1234 && !result.resumable)
    }

    @Test func probeThrowsOnHTTPError() async throws {
        var config = TestHTTPServer.Config(body: Data(count: 1))
        config.statusSequence = [404]
        let server = try TestHTTPServer(config)
        try await server.start()
        defer { server.stop() }
        await #expect(throws: ProbeError.http(404)) { try await HTTPProbe.probe(url: server.url) }
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement `HTTP/Connection.swift`**

```swift
import Foundation
import os

enum DataOutcome: Sendable {
    case more
    case done
    case failed(FailureReason)
}

enum ConnectionResult: Sendable, Equatable {
    case segmentDone
    case endOfStream
    case cancelled
    case rejected
    case fatal(FailureReason)
    case failed(String)
}

struct ConnectionHandlers: Sendable {
    /// Decides whether to accept the response. Data only starts flowing after this returns.
    var onResponse: @Sendable (HTTPURLResponse) async -> Bool
    /// Called serially on the connection's queue for every received chunk.
    var onData: @Sendable (Data) -> DataOutcome
    var onComplete: @Sendable (ConnectionResult) -> Void
}

/// One ranged HTTP request on its **own** URLSession, so every connection is a separate TCP connection
/// (a shared session would multiplex them over one HTTP/2 connection and nothing would get faster).
final class Connection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "hdm.connection")
    private let handlers: ConnectionHandlers
    private let limiters: [SpeedLimiter]
    private let stopReason = OSAllocatedUnfairLock<ConnectionResult?>(initialState: nil)
    private var session: URLSession!
    private var task: URLSessionDataTask!

    init(request: URLRequest, timeout: TimeInterval, limiters: [SpeedLimiter], handlers: ConnectionHandlers) {
        self.handlers = handlers
        self.limiters = limiters
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        task = session.dataTask(with: request)
    }

    func start() { task.resume() }

    func cancel() {
        markStopped(.cancelled)
        task.cancel()
    }

    private func markStopped(_ reason: ConnectionResult) {
        stopReason.withLock { if $0 == nil { $0 = reason } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            markStopped(.failed("Not an HTTP response"))
            return .cancel
        }
        if stopReason.withLock({ $0 }) != nil { return .cancel }
        let accepted = await handlers.onResponse(http)
        if !accepted { markStopped(.rejected) }
        return accepted ? .allow : .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard stopReason.withLock({ $0 }) == nil else { return }
        switch handlers.onData(data) {
        case .more:
            let pause = limiters.map { $0.consume(data.count) }.max() ?? 0
            if pause > 0.005 {
                dataTask.suspend()
                queue.asyncAfter(deadline: .now() + pause) { dataTask.resume() }
            }
        case .done:
            markStopped(.segmentDone)
            dataTask.cancel()
        case .failed(let reason):
            markStopped(.fatal(reason))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: ConnectionResult
        if let stopped = stopReason.withLock({ $0 }) {
            result = stopped
        } else if let error {
            result = .failed(error.localizedDescription)
        } else {
            result = .endOfStream
        }
        session.finishTasksAndInvalidate()
        handlers.onComplete(result)
    }
}
```

- [ ] **Step 4: Implement `HTTP/HTTPProbe.swift`**

```swift
import Foundation

public enum ProbeError: Error, Equatable, Sendable {
    case http(Int)
    case notHTTP
}

/// Reads only the response headers of a download (for dialogs), then cancels the body.
public enum HTTPProbe {
    public static func probe(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> ProbeResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw ProbeError.notHTTP }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw ProbeError.http(http.statusCode) }
        return ProbeResult(response: http)
    }
}
```

- [ ] **Step 5: Run tests — expect PASS**

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(core): add per-session Connection and HTTPProbe"
```

---

### Task 9: HTTPDownload actor

**Files:**
- Create: `Sources/HDMCore/HTTP/HTTPDownload.swift`
- Test: `Tests/HDMCoreTests/HTTPDownloadTests.swift`

**Interfaces:**
- Consumes: `SegmentPlanner`, `SegmentTable`, `PartFile`, `Connection`, `ConnectionHandlers`, `ProbeResult`, `ContentRange`, `SpeedLimiter`, `RetryPolicy`.
- Produces:
  - `ResumeState(segments:totalBytes:etag:lastModified:)`.
  - `DownloadRequest(url:headers:partURL:resume:maxConnections:retryLimit:timeout:minSegment:)`, with defaults `[:]`, `nil`, `8`, `10`, `30`, `1 << 20`.
  - `ConnectionInfo`: `id`, `segmentIndex`, `receivedInSegment`, `isReceiving`.
  - `DownloadSnapshot`: `segments`, `receivedBytes`, `totalBytes`, `connections`.
  - `DownloadEvent`: `.probed(ProbeResult)`, `.progress(DownloadSnapshot)`, `.finished(totalBytes: Int64)`, `.failed(FailureReason)`, `.needsRefresh(statusCode: Int)`.
  - `actor HTTPDownload(request:limiters:backoff:)`, with `events: AsyncStream<DownloadEvent>` (nonisolated), `start()`, `pause() async -> [Segment]` and `cancel()`. The stream finishes after the terminal event, after `pause()` or after `cancel()`. Progress is emitted every 0.5 s.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import HDMCore
import HDMTestSupport

extension DownloadEvent {
    var isFinished: Bool { if case .finished = self { true } else { false } }
    var failure: FailureReason? { if case .failed(let reason) = self { reason } else { nil } }
    var refreshStatus: Int? { if case .needsRefresh(let code) = self { code } else { nil } }
    var probe: ProbeResult? { if case .probed(let p) = self { p } else { nil } }
}

func collect(_ download: HTTPDownload) async -> [DownloadEvent] {
    var events: [DownloadEvent] = []
    for await event in download.events { events.append(event) }
    return events
}

@Suite(.serialized) struct HTTPDownloadTests {
    let kib = 1024

    func serve(_ body: Data, _ configure: (inout TestHTTPServer.Config) -> Void = { _ in }) async throws -> TestHTTPServer {
        var config = TestHTTPServer.Config(body: body)
        configure(&config)
        let server = try TestHTTPServer(config)
        try await server.start()
        return server
    }

    func download(_ server: TestHTTPServer, part: URL, resume: ResumeState? = nil, connections: Int = 8,
                  retries: Int = 10, limiters: [SpeedLimiter] = []) -> HTTPDownload {
        HTTPDownload(request: DownloadRequest(url: server.url, partURL: part, resume: resume, maxConnections: connections,
                                              retryLimit: retries, timeout: 10, minSegment: 64 * 1024),
                     limiters: limiters, backoff: fastBackoff)
    }

    @Test func downloadsWithMultipleConnections() async throws {
        let body = TestData.random(count: 3 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 2 * 1024 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(events.compactMap(\.probe).first?.resumable == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
        #expect(server.maxObservedConcurrency >= 2)
    }

    @Test func parallelConnectionsAreFaster() async throws {
        let body = TestData.random(count: 2 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 256 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        let started = Date()
        await dl.start()
        let events = await collect(dl)
        let elapsed = Date().timeIntervalSince(started)
        #expect(events.last?.isFinished == true)
        #expect(elapsed < 2.5, "one connection would need 8 s, took \(elapsed)")
        #expect(server.maxObservedConcurrency >= 6)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func fallsBackToOneConnectionWithoutRanges() async throws {
        let body = TestData.random(count: 700 * 1024)
        let server = try await serve(body) { $0.supportsRange = false }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(events.compactMap(\.probe).first?.resumable == false)
        #expect(server.requests.count == 1)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func downloadsUnknownLength() async throws {
        let body = TestData.random(count: 300 * 1024)
        let server = try await serve(body) { $0.supportsRange = false; $0.sendContentLength = false }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        guard case .finished(let total) = events.last else { Issue.record("not finished: \(events.last as Any)"); return }
        #expect(total == Int64(body.count))
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test(arguments: [0, 10])
    func downloadsTinyFiles(size: Int) async throws {   // Review Focus 1
        let body = TestData.random(count: size)
        let server = try await serve(body)
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(try Data(contentsOf: part) == body)
    }

    @Test func respectsSpeedLimit() async throws {
        let body = TestData.random(count: 1024 * 1024)
        let server = try await serve(body)
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part, limiters: [SpeedLimiter(bytesPerSecond: 512 * 1024)])
        let started = Date()
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(Date().timeIntervalSince(started) > 0.8)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    /// Starts a throttled download and pauses it once some data has arrived.
    func startAndPause(_ server: TestHTTPServer, part: URL) async -> (segments: [Segment], probe: ProbeResult?) {
        let first = download(server, part: part, connections: 4)
        await first.start()
        var probe: ProbeResult?
        for await event in first.events {
            if case .probed(let p) = event { probe = p }
            if case .progress(let snapshot) = event, snapshot.receivedBytes > 256 * 1024 { break }
        }
        return (await first.pause(), probe)
    }

    @Test func resumesFromSavedSegments() async throws {
        let body = TestData.random(count: 2 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 256 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let (segments, probe) = await startAndPause(server, part: part)
        let received = segments.reduce(0) { $0 + $1.received }
        #expect(received > 0 && received < Int64(body.count))

        server.update { $0.bytesPerSecondPerConnection = nil }
        let before = server.requests.count
        let resume = ResumeState(segments: segments, totalBytes: Int64(body.count), etag: probe?.etag, lastModified: probe?.lastModified)
        let second = download(server, part: part, resume: resume, connections: 4)
        await second.start()
        let events = await collect(second)
        #expect(events.last?.isFinished == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
        #expect(server.requests.dropFirst(before).allSatisfy { $0.headers["if-range"] == "\"v1\"" })
    }

    @Test func detectsChangedFileOnResume() async throws {
        let body = TestData.random(count: 2 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 256 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let (segments, probe) = await startAndPause(server, part: part)
        server.update { $0.etag = "\"v2\""; $0.body = TestData.random(count: 2 * 1024 * 1024, seed: 7); $0.bytesPerSecondPerConnection = nil }
        let resume = ResumeState(segments: segments, totalBytes: Int64(body.count), etag: probe?.etag, lastModified: probe?.lastModified)
        let second = download(server, part: part, resume: resume, connections: 4)
        await second.start()
        let events = await collect(second)
        #expect(events.last?.failure == .serverFileChanged)
    }

    @Test func restartsWhenPartFileIsMissing() async throws {   // Review Focus 2
        let body = TestData.random(count: 512 * 1024)
        let server = try await serve(body)
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("gone.hdmpart")
        let resume = ResumeState(segments: [Segment(start: 0, end: 262_144, received: 262_144), Segment(start: 262_144, end: 524_288)],
                                 totalBytes: 524_288, etag: "\"v1\"", lastModified: nil)
        let dl = download(server, part: part, resume: resume)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func retriesDroppedConnection() async throws {
        let body = TestData.random(count: 1024 * 1024)
        let server = try await serve(body) { $0.dropOnceAfterBytes = 100_000 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func reportsNeedsRefreshOn403() async throws {
        let server = try await serve(TestData.random(count: 1000)) { $0.statusSequence = [403] }
        defer { server.stop() }
        let dl = download(server, part: tempDirectory().appendingPathComponent("f.hdmpart"))
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.refreshStatus == 403)
    }

    @Test func completesWhenServerLimitsConnections() async throws {   // Review Focus 5
        let body = TestData.random(count: 1024 * 1024)
        let server = try await serve(body) { $0.maxConcurrentConnections = 2; $0.bytesPerSecondPerConnection = 1024 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func failsAfterRetryLimit() async throws {
        let server = try await serve(Data(count: 10)) { $0.statusSequence = [500, 500, 500, 500] }
        defer { server.stop() }
        let dl = download(server, part: tempDirectory().appendingPathComponent("f.hdmpart"), retries: 2)
        await dl.start()
        let events = await collect(dl)
        guard case .network = events.last?.failure else { Issue.record("expected network failure, got \(events.last as Any)"); return }
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement `HTTP/HTTPDownload.swift`**

```swift
import Foundation

public struct ResumeState: Sendable, Equatable {
    public var segments: [Segment]
    public var totalBytes: Int64
    public var etag: String?
    public var lastModified: String?

    public init(segments: [Segment], totalBytes: Int64, etag: String?, lastModified: String?) {
        self.segments = segments
        self.totalBytes = totalBytes
        self.etag = etag
        self.lastModified = lastModified
    }
}

public struct DownloadRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var partURL: URL
    public var resume: ResumeState?
    public var maxConnections: Int
    public var retryLimit: Int
    public var timeout: TimeInterval
    public var minSegment: Int64

    public init(url: URL, headers: [String: String] = [:], partURL: URL, resume: ResumeState? = nil,
                maxConnections: Int = 8, retryLimit: Int = 10, timeout: TimeInterval = 30, minSegment: Int64 = 1 << 20) {
        self.url = url
        self.headers = headers
        self.partURL = partURL
        self.resume = resume
        self.maxConnections = maxConnections
        self.retryLimit = retryLimit
        self.timeout = timeout
        self.minSegment = minSegment
    }
}

public struct ConnectionInfo: Sendable, Hashable, Identifiable {
    public var id: Int
    public var segmentIndex: Int
    public var receivedInSegment: Int64
    public var isReceiving: Bool
}

public struct DownloadSnapshot: Sendable {
    public var segments: [Segment]
    public var receivedBytes: Int64
    public var totalBytes: Int64?
    public var connections: [ConnectionInfo]
}

public enum DownloadEvent: Sendable {
    case probed(ProbeResult)
    case progress(DownloadSnapshot)
    case finished(totalBytes: Int64)
    case failed(FailureReason)
    case needsRefresh(statusCode: Int)
}

/// Transfers one URL into its `.hdmpart` file using dynamic segmentation (spec §5.3–5.5).
/// Renaming the finished file is the caller's job.
public actor HTTPDownload {
    private enum State { case idle, running, stopping, finished }

    public nonisolated let events: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation
    private let request: DownloadRequest
    private let planner: SegmentPlanner
    private let limiters: [SpeedLimiter]
    private let backoff: @Sendable (Int) -> TimeInterval

    private var state = State.idle
    private var table: SegmentTable?
    private var connections: [Int: Connection] = [:]
    private var slotSegment: [Int: Int] = [:]
    private var receiving: Set<Int> = []
    private var retryCounted: Set<Int> = []
    private var nextSlot = 1
    private var probeSlot: Int?
    private var probed = false
    private var total: Int64?
    private var resumable = false
    private var ifRange: String?
    private var isResume = false
    private var resumeConfirmed = false
    private var maxConnections: Int
    private var failures: [Int: Int] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var ticker: Task<Void, Never>?

    public init(request: DownloadRequest, limiters: [SpeedLimiter] = [],
                backoff: @escaping @Sendable (Int) -> TimeInterval = RetryPolicy.delay(forAttempt:)) {
        self.request = request
        self.planner = SegmentPlanner(minSegment: request.minSegment)
        self.limiters = limiters
        self.backoff = backoff
        self.maxConnections = max(1, request.maxConnections)
        let pair = AsyncStream.makeStream(of: DownloadEvent.self, bufferingPolicy: .unbounded)
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func start() {
        guard state == .idle else { return }
        state = .running
        do {
            let fm = FileManager.default
            if let resume = request.resume, !resume.segments.isEmpty, fm.fileExists(atPath: request.partURL.path) {
                let file = try PartFile(url: request.partURL)
                try file.resize(atLeast: resume.totalBytes)
                table = SegmentTable(segments: resume.segments, planner: planner, file: file)
                total = resume.totalBytes
                resumable = true
                probed = true
                isResume = true
                ifRange = resume.etag ?? resume.lastModified
            } else {
                try? fm.removeItem(at: request.partURL)
                table = SegmentTable(segments: [Segment(start: 0, end: .max)], planner: planner,
                                     file: try PartFile(url: request.partURL))
            }
        } catch {
            fail(.fileSystem(error.localizedDescription))
            return
        }
        startTicker()
        if table?.allComplete == true { finish(); return }
        fillConnections()
    }

    /// Stops all connections and returns the exact segment state for persistence.
    public func pause() async -> [Segment] {
        if state == .running {
            state = .stopping
            ticker?.cancel()
            connections.values.forEach { $0.cancel() }
            if !connections.isEmpty {
                await withCheckedContinuation { drainWaiters.append($0) }
            }
            state = .finished
            table?.closeFile()
            continuation.finish()
        }
        return table?.snapshot() ?? []
    }

    public func cancel() {
        guard state == .running || state == .idle else { return }
        state = .finished
        ticker?.cancel()
        connections.values.forEach { $0.cancel() }
        if connections.isEmpty { table?.closeFile() }
        continuation.finish()
    }

    // MARK: - Connections

    private func fillConnections() {
        guard state == .running, let table else { return }
        if !probed {
            if connections.isEmpty {
                table.claim(0)
                probeSlot = open(segment: 0, from: 0, to: .max)
            }
            return
        }
        if !resumable {
            // A non-resumable transfer can only restart from byte 0 with a single connection.
            if connections.isEmpty {
                table.replace(with: [Segment(start: 0, end: total ?? .max)])
                probed = false
                fillConnections()
            }
            return
        }
        while connections.count < maxConnections, let index = table.claimNext() {
            let segment = table.segment(index)
            open(segment: index, from: segment.cursor, to: segment.end)
        }
    }

    @discardableResult
    private func open(segment index: Int, from start: Int64, to end: Int64) -> Int {
        let slot = nextSlot
        nextSlot += 1
        guard let table else { return slot }
        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue(end == .max ? "bytes=\(start)-" : "bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if probed, let ifRange { urlRequest.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        let handlers = ConnectionHandlers(
            onResponse: { [weak self] response in
                await self?.handleResponse(slot: slot, response: response) ?? false
            },
            onData: { data in
                do {
                    return try table.write(data, segment: index) == .segmentDone ? .done : .more
                } catch PartFileError.diskFull {
                    return .failed(.diskFull)
                } catch {
                    return .failed(.fileSystem(String(describing: error)))
                }
            },
            onComplete: { [weak self] result in
                Task { await self?.connectionFinished(slot: slot, result: result) }
            })
        let connection = Connection(request: urlRequest, timeout: request.timeout, limiters: limiters, handlers: handlers)
        connections[slot] = connection
        slotSegment[slot] = index
        connection.start()
        return slot
    }

    private func handleResponse(slot: Int, response: HTTPURLResponse) -> Bool {
        guard state == .running, let table, let index = slotSegment[slot] else { return false }
        let status = response.statusCode
        let isProbe = slot == probeSlot
        switch status {
        case 206:
            if isProbe {
                let info = ProbeResult(response: response)
                probed = true
                total = info.totalBytes
                resumable = info.resumable
                ifRange = info.ifRangeValidator
                if let total {
                    do { try table.resize(atLeast: total) } catch {
                        fail(.fileSystem(error.localizedDescription))
                        return false
                    }
                    table.replace(with: planner.initialSegments(total: total, connections: maxConnections))
                }
                continuation.yield(.probed(info))
                receiving.insert(slot)
                fillConnections()
                return true
            }
            let range = ContentRange(header: response.value(forHTTPHeaderField: "Content-Range"))
            guard let range, range.start == table.segment(index).cursor, range.total == nil || range.total == total else {
                fail(.serverFileChanged)
                return false
            }
            resumeConfirmed = true
            receiving.insert(slot)
            return true
        case 200:
            if isProbe {
                let info = ProbeResult(response: response)
                probed = true
                resumable = false
                total = info.totalBytes
                ifRange = nil
                table.replace(with: [Segment(start: 0, end: total ?? .max)])
                if let total { try? table.resize(atLeast: total) }
                continuation.yield(.probed(info))
                receiving.insert(slot)
                return true
            }
            if isResume && !resumeConfirmed {
                fail(.serverFileChanged)   // If-Range did not match: the file changed on the server
                return false
            }
            if connections.count <= 1 { retryCounted.insert(slot) }
            maxConnections = max(1, connections.count - 1)
            return false
        case 401:
            fail(.authRequired)
            return false
        case 403, 404, 410:
            stopForRefresh(status)
            return false
        case 416:
            fail(.serverFileChanged)
            return false
        case 429, 503:
            if connections.count > 1 {
                maxConnections = max(1, connections.count - 1)
            } else {
                retryCounted.insert(slot)
            }
            return false
        case 500...599:
            retryCounted.insert(slot)
            return false
        default:
            fail(.http(status))
            return false
        }
    }

    private func connectionFinished(slot: Int, result: ConnectionResult) {
        guard let index = slotSegment.removeValue(forKey: slot) else { return }
        connections.removeValue(forKey: slot)
        receiving.remove(slot)
        let countsAsFailure = retryCounted.remove(slot) != nil
        if slot == probeSlot { probeSlot = nil }
        table?.release(index)
        defer { if connections.isEmpty { drain() } }
        guard state == .running, let table else { return }

        switch result {
        case .segmentDone:
            failures[index] = 0
        case .endOfStream:
            if table.segment(index).isOpenEnded {
                table.closeOpenEnded(index)
                total = table.receivedBytes
            } else if !table.segment(index).isComplete {
                registerFailure(index, message: "The server closed the connection early.")
                return
            }
        case .cancelled:
            break
        case .rejected:
            if countsAsFailure {
                registerFailure(index, message: "The server is busy.")
                return
            }
        case .fatal(let reason):
            fail(reason)
            return
        case .failed(let message):
            registerFailure(index, message: message)
            return
        }
        if table.allComplete { finish() } else { fillConnections() }
    }

    private func registerFailure(_ index: Int, message: String) {
        let attempt = (failures[index] ?? 0) + 1
        failures[index] = attempt
        guard attempt <= request.retryLimit else {
            fail(.network(message))
            return
        }
        let delay = backoff(attempt)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.retryAfterBackoff()
        }
    }

    private func retryAfterBackoff() { fillConnections() }

    private func drain() {
        if state != .running { table?.closeFile() }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: - Terminal states

    private func finish() {
        guard state == .running else { return }
        stopEverything()
        continuation.yield(.finished(totalBytes: total ?? table?.receivedBytes ?? 0))
        continuation.finish()
    }

    private func fail(_ reason: FailureReason) {
        guard state == .running else { return }
        stopEverything()
        continuation.yield(.failed(reason))
        continuation.finish()
    }

    private func stopForRefresh(_ status: Int) {
        guard state == .running else { return }
        stopEverything()
        continuation.yield(.needsRefresh(statusCode: status))
        continuation.finish()
    }

    /// Emits a last snapshot (so the caller can persist it) and tears down connections.
    /// The file is closed once every connection has reported back (see `drain`).
    private func stopEverything() {
        state = .finished
        ticker?.cancel()
        emitProgress()
        connections.values.forEach { $0.cancel() }
        if connections.isEmpty { table?.closeFile() }
    }

    // MARK: - Progress

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                await self.emitProgress()
            }
        }
    }

    private func emitProgress() {
        guard let table else { return }
        let segments = table.snapshot()
        let infos = slotSegment.sorted { $0.key < $1.key }.map { slot, index in
            ConnectionInfo(id: slot, segmentIndex: index,
                           receivedInSegment: index < segments.count ? segments[index].received : 0,
                           isReceiving: receiving.contains(slot))
        }
        continuation.yield(.progress(DownloadSnapshot(segments: segments, receivedBytes: segments.reduce(0) { $0 + $1.received },
                                                      totalBytes: total, connections: infos)))
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `make test`. If a timing assertion is flaky on a loaded machine, re-run once. If it still fails, investigate; do not loosen the limits.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add HTTPDownload with dynamic segmentation, resume and retries"
```

---

### Task 10: DownloadStore and SettingsStore

**Files:**
- Create: `Sources/HDMCore/Store/DownloadStore.swift`, `Store/SettingsStore.swift`
- Test: `Tests/HDMCoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `DownloadItem`, `AppSettings`.
- Produces:
  - `DownloadStore(fileURL: URL = DownloadStore.defaultFileURL)` with `load() -> [DownloadItem]` and `save(_:) throws`. It writes atomically, keeps a `.bak`, and sets file mode `0600`.
  - `@MainActor @Observable SettingsStore(defaults: UserDefaults = .standard)` with `settings: AppSettings` (get/set; it persists on change) and `onChange: ((AppSettings) -> Void)?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import HDMCore

@Suite struct StoreTests {
    func sample() -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://e.com/a.zip")!, fileName: "a.zip",
                                saveDirectory: URL(fileURLWithPath: "/tmp"), category: .compressed,
                                headers: ["Cookie": "s=1"])
        item.segments = [Segment(start: 0, end: 100, received: 50)]
        item.status = .paused
        return item
    }

    @Test func roundTripsAndProtectsFile() throws {
        let url = tempDirectory().appendingPathComponent("downloads.json")
        let store = DownloadStore(fileURL: url)
        #expect(store.load().isEmpty)
        let items = [sample(), sample()]
        try store.save(items)
        #expect(store.load() == items)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func fallsBackToBackupWhenMainFileIsCorrupt() throws {
        let url = tempDirectory().appendingPathComponent("downloads.json")
        let store = DownloadStore(fileURL: url)
        let first = [sample()]
        try store.save(first)
        try store.save(first + [sample()])      // first save becomes the .bak
        try Data("{broken".utf8).write(to: url)
        #expect(store.load() == first)
    }

    @MainActor @Test func settingsPersistAndNotify() {
        let suite = "hdm-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var seen: [Int] = []
        store.onChange = { seen.append($0.maxConnections) }
        store.settings.maxConnections = 16
        store.settings.maxConnections = 16      // unchanged, no second notification
        #expect(seen == [16])
        #expect(SettingsStore(defaults: defaults).settings.maxConnections == 16)
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement**

`Store/DownloadStore.swift`:
```swift
import Foundation

/// Persists the download list as JSON (spec §5.2).
public final class DownloadStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = DownloadStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HDM", isDirectory: true)
            .appendingPathComponent("downloads.json")
    }

    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    public func load() -> [DownloadItem] {
        for url in [fileURL, backupURL] {
            if let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([DownloadItem].self, from: data) {
                return items
            }
        }
        return []
    }

    public func save(_ items: [DownloadItem]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)   // may contain cookies
    }
}
```

`Store/SettingsStore.swift`:
```swift
import Foundation
import Observation

@MainActor @Observable
public final class SettingsStore {
    private var stored: AppSettings
    @ObservationIgnored public var onChange: ((AppSettings) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "HDM.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            stored = decoded
        } else {
            stored = AppSettings()
        }
    }

    public var settings: AppSettings {
        get { stored }
        set {
            guard newValue != stored else { return }
            stored = newValue
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) }
            onChange?(newValue)
        }
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add DownloadStore and SettingsStore"
```

---

### Task 11: DownloadManager

**Files:**
- Create: `Sources/HDMCore/Store/DownloadManager.swift`
- Test: `Tests/HDMCoreTests/DownloadManagerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–10.
- Produces:
  - `NewDownload(url:fileName:directory:category:headers:pageURL:referrer:totalBytes:description:autoStart:)`, with defaults for everything after `category` (`[:]`, `nil`, `nil`, `nil`, `""`, `true`).
  - `LiveStats`: `bytesPerSecond`, `secondsRemaining`, `connections`.
  - `ManagerEvent`: `.started(UUID)`, `.completed(UUID)`, `.failed(UUID)`, `.needsRefresh(UUID)`.
  - `@MainActor @Observable DownloadManager(store:settings:minSegment:backoff:)`:
    - Read-only state: `items`, `live: [UUID: LiveStats]`, `queueRunning`, `settings`, `onEvent`.
    - Queries: `item(_:)`, `totalBytesPerSecond`, `activeCount`, `overallFraction`, `refreshCandidate(fileName:totalBytes:)`.
    - Adding and controlling: `add(_:) -> UUID`, `resume(_:)`, `pause(_:) async`, `pauseAll() async`, `prepareForTermination() async`, `addToQueue(_:)`, `startQueue()`, `stopQueue()`, `redownload(_:)`.
    - Removing: `remove(_: Set<UUID>, deleteFiles:)`, `removeCompleted()`.
    - Per-item options: `setSpeedLimit(_:bytesPerSecond:)`, `setOnComplete(_:_:)`.
    - Link refresh: `markAwaitingRefresh(_:)`, `applyRefreshedLink(_:url:headers:pageURL:referrer:)`.
    - `flush()`.

- [ ] **Step 1: Write the failing tests**

```swift
import CoreServices
import Foundation
import Testing
@testable import HDMCore
import HDMTestSupport

@MainActor @Suite(.serialized) struct DownloadManagerTests {
    func makeManager(dir: URL, suite: String, configure: (inout AppSettings) -> Void = { _ in }) -> DownloadManager {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        var s = settings.settings
        s.baseFolder = dir
        configure(&s)
        settings.settings = s
        return DownloadManager(store: DownloadStore(fileURL: dir.appendingPathComponent("downloads.json")),
                               settings: settings, minSegment: 64 * 1024, backoff: fastBackoff)
    }

    func serve(_ body: Data, _ configure: (inout TestHTTPServer.Config) -> Void = { _ in }) async throws -> TestHTTPServer {
        var config = TestHTTPServer.Config(body: body)
        configure(&config)
        let server = try TestHTTPServer(config)
        try await server.start()
        return server
    }

    @Test func completesMovesAndQuarantinesFile() async throws {
        let body = TestData.random(count: 1024 * 1024)
        let server = try await serve(body)
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "test.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .completed }
        let item = try #require(manager.item(id))
        #expect(try TestData.sha256(fileAt: item.fileURL) == TestData.sha256(body))
        #expect(!FileManager.default.fileExists(atPath: item.partURL.path))
        let quarantine = try item.fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Hiz Download Manager")
    }

    @Test func respectsConcurrencyLimit() async throws {
        let server = try await serve(TestData.random(count: 1024 * 1024)) { $0.bytesPerSecondPerConnection = 32 * 1024 }
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString) { $0.maxConcurrentDownloads = 1 }
        let a = manager.add(NewDownload(url: server.url, fileName: "a.bin", directory: dir, category: .general))
        let b = manager.add(NewDownload(url: server.url, fileName: "b.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(a)?.status == .downloading }
        #expect(manager.item(b)?.status == .queued)
        #expect(manager.activeCount == 1)
        await manager.pauseAll()
    }

    @Test func laterItemsWaitForQueueStart() async throws {
        let server = try await serve(TestData.random(count: 100_000))
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "later.bin", directory: dir, category: .general, autoStart: false))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(manager.item(id)?.status == .queued)
        manager.startQueue()
        try await waitUntil { manager.item(id)?.status == .completed }
    }

    @Test func resumesAfterRelaunch() async throws {   // Review Focus 4
        let body = TestData.random(count: 4 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 128 * 1024 }
        defer { server.stop() }
        let dir = tempDirectory()
        let suite = UUID().uuidString
        let first = makeManager(dir: dir, suite: suite)
        let id = first.add(NewDownload(url: server.url, fileName: "big.bin", directory: dir, category: .general))
        try await waitUntil { (first.item(id)?.receivedBytes ?? 0) > 100_000 }
        await first.prepareForTermination()
        #expect(first.item(id)?.status == .paused)

        let second = makeManager(dir: dir, suite: suite)
        let restored = try #require(second.item(id))
        #expect(restored.status == .paused)
        #expect(restored.receivedBytes > 0 && !restored.segments.isEmpty)
        server.update { $0.bytesPerSecondPerConnection = nil }
        second.resume([id])
        try await waitUntil { second.item(id)?.status == .completed }
        #expect(try TestData.sha256(fileAt: try #require(second.item(id)).fileURL) == TestData.sha256(body))
    }

    @Test func runningItemsBecomePausedOnLaunch() throws {
        let dir = tempDirectory()
        var item = DownloadItem(url: URL(string: "https://e.com/x")!, fileName: "x", saveDirectory: dir, category: .general)
        item.status = .downloading
        try DownloadStore(fileURL: dir.appendingPathComponent("downloads.json")).save([item])
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        #expect(manager.item(item.id)?.status == .paused)
    }

    @Test func renamesOnNameCollision() async throws {   // Review Focus 3
        let body = TestData.random(count: 50_000)
        let server = try await serve(body)
        defer { server.stop() }
        let dir = tempDirectory()
        let existing = dir.appendingPathComponent("rapor ü.bin")
        try Data("old".utf8).write(to: existing)
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "rapor ü.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .completed }
        let item = try #require(manager.item(id))
        #expect(item.fileName == "rapor ü (2).bin")
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        #expect(try TestData.sha256(fileAt: item.fileURL) == TestData.sha256(body))
    }

    @Test func removeDeletesPartialFile() async throws {
        let server = try await serve(TestData.random(count: 1024 * 1024)) { $0.bytesPerSecondPerConnection = 32 * 1024 }
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "p.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .downloading }
        let part = try #require(manager.item(id)).partURL
        manager.remove([id], deleteFiles: false)
        #expect(manager.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func refreshedLinkContinuesDownload() async throws {
        let body = TestData.random(count: 200_000)
        let server = try await serve(body) { $0.statusSequence = [403] }
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "r.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .needsRefresh }
        #expect(manager.refreshCandidate(fileName: "r.bin", totalBytes: nil)?.id == id)
        #expect(manager.refreshCandidate(fileName: "other.bin", totalBytes: nil) == nil)
        manager.applyRefreshedLink(id, url: server.url, headers: [:], pageURL: nil, referrer: nil)
        try await waitUntil { manager.item(id)?.status == .completed }
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement `Store/DownloadManager.swift`**

```swift
import CoreServices
import Foundation
import Network
import Observation

public struct NewDownload: Sendable {
    public var url: URL
    public var fileName: String
    public var directory: URL
    public var category: DownloadCategory
    public var headers: [String: String]
    public var pageURL: URL?
    public var referrer: URL?
    public var totalBytes: Int64?
    public var description: String
    public var autoStart: Bool

    public init(url: URL, fileName: String, directory: URL, category: DownloadCategory, headers: [String: String] = [:],
                pageURL: URL? = nil, referrer: URL? = nil, totalBytes: Int64? = nil, description: String = "",
                autoStart: Bool = true) {
        self.url = url
        self.fileName = fileName
        self.directory = directory
        self.category = category
        self.headers = headers
        self.pageURL = pageURL
        self.referrer = referrer
        self.totalBytes = totalBytes
        self.description = description
        self.autoStart = autoStart
    }
}

public struct LiveStats: Sendable, Equatable {
    public var bytesPerSecond: Double = 0
    public var secondsRemaining: TimeInterval?
    public var connections: [ConnectionInfo] = []
}

public enum ManagerEvent: Sendable {
    case started(UUID)
    case completed(UUID)
    case failed(UUID)
    case needsRefresh(UUID)
}

/// Owns the download list: queueing, starting/stopping `HTTPDownload`s, persistence and finalisation.
@MainActor @Observable
public final class DownloadManager {
    public private(set) var items: [DownloadItem] = []
    public private(set) var live: [UUID: LiveStats] = [:]
    public private(set) var queueRunning = false
    public let settings: SettingsStore
    @ObservationIgnored public var onEvent: ((ManagerEvent) -> Void)?

    private struct Running {
        let download: HTTPDownload
        let limiter: SpeedLimiter
        var meter = SpeedMeter()
        var task: Task<Void, Never>?
    }

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private var running: [UUID: Running] = [:]
    @ObservationIgnored private let globalLimiter = SpeedLimiter(bytesPerSecond: 0)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasSatisfied: Bool?
    @ObservationIgnored private let minSegment: Int64
    @ObservationIgnored private let backoff: @Sendable (Int) -> TimeInterval

    public init(store: DownloadStore, settings: SettingsStore, minSegment: Int64 = 1 << 20,
                backoff: @escaping @Sendable (Int) -> TimeInterval = RetryPolicy.delay(forAttempt:)) {
        self.store = store
        self.settings = settings
        self.minSegment = minSegment
        self.backoff = backoff
        items = store.load().map { item in
            var item = item
            if item.status.isRunning { item.status = .paused }
            return item
        }
        globalLimiter.setRate(settings.settings.globalSpeedLimit)
        settings.onChange = { [weak self] new in self?.settingsChanged(new) }
        startNetworkMonitor()
        schedule()
    }

    // MARK: Queries

    public func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }
    public var totalBytesPerSecond: Double { live.values.reduce(0) { $0 + $1.bytesPerSecond } }
    public var activeCount: Int { items.filter { $0.status.isRunning }.count }

    public var overallFraction: Double? {
        let active = items.filter { $0.status.isRunning }
        let totals = active.compactMap(\.totalBytes)
        guard !active.isEmpty, totals.count == active.count else { return nil }
        let total = totals.reduce(0, +)
        return total > 0 ? Double(active.reduce(0) { $0 + $1.receivedBytes }) / Double(total) : nil
    }

    /// A download waiting for a new link whose name or size matches a newly captured one (spec §5.5).
    public func refreshCandidate(fileName: String, totalBytes: Int64?) -> DownloadItem? {
        items.first { item in
            guard item.awaitingRefresh || item.status == .needsRefresh else { return false }
            if let totalBytes, let known = item.totalBytes, totalBytes == known { return true }
            return item.fileName == fileName
        }
    }

    // MARK: Commands

    @discardableResult
    public func add(_ new: NewDownload) -> UUID {
        let item = DownloadItem(url: new.url, fileName: FilenameResolver.sanitize(new.fileName), saveDirectory: new.directory,
                                category: new.category, headers: new.headers, pageURL: new.pageURL, referrer: new.referrer,
                                totalBytes: new.totalBytes, userDescription: new.description, autoStart: new.autoStart)
        items.append(item)
        scheduleSave()
        schedule()
        return item.id
    }

    public func resume(_ ids: some Sequence<UUID>) {
        for id in ids {
            update(id) { item in
                guard item.status.canResume || item.status == .queued else { return }
                item.status = .queued
                item.autoStart = true
            }
        }
        scheduleSave()
        schedule()
    }

    public func addToQueue(_ ids: some Sequence<UUID>) {
        for id in ids {
            update(id) { item in
                guard item.status.canResume || item.status == .queued else { return }
                item.status = .queued
                item.autoStart = false
            }
        }
        scheduleSave()
    }

    public func pause(_ ids: some Sequence<UUID>) async {
        for id in Array(ids) {
            if let run = running.removeValue(forKey: id) {
                run.task?.cancel()
                live[id] = nil
                let segments = await run.download.pause()
                update(id) { item in
                    item.segments = segments
                    item.receivedBytes = segments.reduce(0) { $0 + $1.received }
                    item.status = .paused
                }
            } else {
                update(id) { if $0.status == .queued { $0.status = .paused } }
            }
        }
        flush()
        schedule()
    }

    public func pauseAll() async {
        await pause(items.filter { $0.status.isRunning || $0.status == .queued }.map(\.id))
    }

    /// Called on quit: stops running transfers and saves their exact segments. Queued items stay queued.
    public func prepareForTermination() async {
        await pause(items.filter { running[$0.id] != nil }.map(\.id))
        flush()
    }

    public func startQueue() {
        queueRunning = true
        schedule()
    }

    public func stopQueue() { queueRunning = false }

    public func remove(_ ids: Set<UUID>, deleteFiles: Bool) {
        let fm = FileManager.default
        for id in ids {
            if let run = running.removeValue(forKey: id) {
                run.task?.cancel()
                Task { await run.download.cancel() }
            }
            live[id] = nil
            guard let item = item(id) else { continue }
            try? fm.removeItem(at: item.partURL)
            if deleteFiles, item.status == .completed {
                try? fm.trashItem(at: item.fileURL, resultingItemURL: nil)
            }
        }
        items.removeAll { ids.contains($0.id) }
        flush()
        schedule()
    }

    public func removeCompleted() {
        remove(Set(items.filter { $0.status == .completed }.map(\.id)), deleteFiles: false)
    }

    public func redownload(_ id: UUID) {
        if let run = running.removeValue(forKey: id) {
            run.task?.cancel()
            Task { await run.download.cancel() }
        }
        live[id] = nil
        update(id) { item in
            try? FileManager.default.removeItem(at: item.partURL)
            item.resetTransfer()
            item.status = .queued
            item.autoStart = true
        }
        scheduleSave()
        schedule()
    }

    public func setSpeedLimit(_ id: UUID, bytesPerSecond: Int64?) {
        update(id) { $0.speedLimit = bytesPerSecond }
        running[id]?.limiter.setRate(bytesPerSecond ?? 0)
        scheduleSave()
    }

    public func setOnComplete(_ id: UUID, _ action: CompletionAction) {
        update(id) { $0.onComplete = action }
        scheduleSave()
    }

    public func markAwaitingRefresh(_ id: UUID) {
        update(id) { $0.awaitingRefresh = true }
        scheduleSave()
    }

    public func applyRefreshedLink(_ id: UUID, url: URL, headers: [String: String], pageURL: URL?, referrer: URL?) {
        if let run = running.removeValue(forKey: id) {
            run.task?.cancel()
            Task { await run.download.cancel() }
        }
        update(id) { item in
            item.url = url
            item.headers = headers
            item.pageURL = pageURL ?? item.pageURL
            item.referrer = referrer ?? item.referrer
            item.awaitingRefresh = false
            item.status = .queued
            item.autoStart = true
        }
        scheduleSave()
        schedule()
    }

    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        do { try store.save(items) } catch { NSLog("HDM: could not save downloads: \(error)") }
    }

    // MARK: Scheduling

    private func schedule() {
        let limit = max(1, settings.settings.maxConcurrentDownloads)
        for index in items.indices where running.count < limit {
            let item = items[index]
            guard item.status == .queued, item.autoStart || queueRunning, running[item.id] == nil else { continue }
            start(index)
        }
    }

    private func start(_ index: Int) {
        let item = items[index]
        let s = settings.settings
        var resume: ResumeState?
        if item.resumable == true, let total = item.totalBytes, !item.segments.isEmpty {
            resume = ResumeState(segments: item.segments, totalBytes: total, etag: item.etag, lastModified: item.lastModified)
        }
        do {
            try FileManager.default.createDirectory(at: item.saveDirectory, withIntermediateDirectories: true)
        } catch {
            items[index].status = .failed(.fileSystem(error.localizedDescription))
            return
        }
        let limiter = SpeedLimiter(bytesPerSecond: item.speedLimit ?? 0)
        let download = HTTPDownload(
            request: DownloadRequest(url: item.url, headers: item.headers, partURL: item.partURL, resume: resume,
                                     maxConnections: item.maxConnections ?? s.maxConnections, retryLimit: s.retryCount,
                                     timeout: s.timeoutSeconds, minSegment: minSegment),
            limiters: [globalLimiter, limiter], backoff: backoff)
        items[index].status = .connecting
        items[index].lastTryAt = Date()
        if resume == nil {
            items[index].segments = []
            items[index].receivedBytes = 0
        }
        let id = item.id
        var run = Running(download: download, limiter: limiter)
        run.task = Task { [weak self] in
            for await event in download.events { self?.handle(event, for: id) }
        }
        running[id] = run
        onEvent?(.started(id))
        Task { await download.start() }
    }

    private func handle(_ event: DownloadEvent, for id: UUID) {
        guard running[id] != nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .probed(let probe):
            items[index].totalBytes = probe.totalBytes
            items[index].resumable = probe.resumable
            items[index].etag = probe.etag
            items[index].lastModified = probe.lastModified
            items[index].finalURL = probe.finalURL
        case .progress(let snapshot):
            items[index].segments = snapshot.segments
            items[index].receivedBytes = snapshot.receivedBytes
            if let total = snapshot.totalBytes { items[index].totalBytes = total }
            if items[index].status == .connecting, snapshot.receivedBytes > 0 || snapshot.connections.contains(where: \.isReceiving) {
                items[index].status = .downloading
            }
            running[id]?.meter.add(bytes: snapshot.receivedBytes, at: ProcessInfo.processInfo.systemUptime)
            let meter = running[id]?.meter ?? SpeedMeter()
            live[id] = LiveStats(bytesPerSecond: meter.bytesPerSecond,
                                 secondsRemaining: meter.secondsRemaining(total: items[index].totalBytes, received: snapshot.receivedBytes),
                                 connections: snapshot.connections)
            scheduleSave()
        case .finished(let total):
            running[id] = nil
            live[id] = nil
            items[index].totalBytes = total
            items[index].receivedBytes = total
            finalize(index)
            schedule()
        case .failed(let reason):
            running[id] = nil
            live[id] = nil
            items[index].status = .failed(reason)
            flush()
            onEvent?(.failed(id))
            schedule()
        case .needsRefresh:
            running[id] = nil
            live[id] = nil
            items[index].status = .needsRefresh
            flush()
            onEvent?(.needsRefresh(id))
            schedule()
        }
    }

    private func finalize(_ index: Int) {
        var item = items[index]
        let fm = FileManager.default
        if fm.fileExists(atPath: item.fileURL.path) {
            if settings.settings.conflictPolicy == .overwrite {
                try? fm.removeItem(at: item.fileURL)
            } else {
                item.fileName = FilenameResolver.uniqueName(item.fileName, in: item.saveDirectory)
            }
        }
        do {
            try fm.moveItem(at: item.partURL, to: item.fileURL)
            Self.markQuarantined(item.fileURL, source: item.url, page: item.pageURL ?? item.referrer)
            item.status = .completed
            item.completedAt = Date()
            item.awaitingRefresh = false
        } catch {
            item.status = .failed(.fileSystem(error.localizedDescription))
        }
        items[index] = item
        flush()
        onEvent?(item.status == .completed ? .completed(item.id) : .failed(item.id))
    }

    /// Same Gatekeeper treatment browsers give downloaded files (spec §10).
    private static func markQuarantined(_ url: URL, source: URL, page: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Hiz Download Manager",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: source,
        ]
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = url
        try? target.setResourceValues(values)
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func settingsChanged(_ new: AppSettings) {
        globalLimiter.setRate(new.globalSpeedLimit)
        schedule()
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "hdm.path"))
    }

    /// When the network comes back, downloads that failed with a network error are retried.
    private func networkChanged(satisfied: Bool) {
        defer { networkWasSatisfied = satisfied }
        guard satisfied, networkWasSatisfied == false else { return }
        var changed = false
        for index in items.indices {
            if case .failed(.network) = items[index].status {
                items[index].status = .queued
                items[index].autoStart = true
                changed = true
            }
        }
        if changed {
            scheduleSave()
            schedule()
        }
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `make test`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): add DownloadManager with queue, persistence and finalisation"
```

---

### Task 12: App project, shell, main window (sidebar + table)

**Files:**
- Create: `project.yml`, `Config/Base.xcconfig`, `Local.xcconfig.example`, `scripts/make-icon.swift`
- Create: `App/HizDownloadManagerApp.swift`, `App/AppDelegate.swift`, `App/AppModel.swift`, `App/Windows/WindowCoordinator.swift`
- Create: `App/Util/Format.swift`, `App/Util/Labels.swift`, `App/Util/FileIcon.swift`, `App/Util/WindowAccessor.swift`
- Create: `App/MainWindow/MainView.swift`, `App/MainWindow/SidebarView.swift`, `App/MainWindow/DownloadTable.swift`
- Create: `App/Resources/Assets.xcassets/Contents.json`, `App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`, and `AppIcon.appiconset` (generated)

**Interfaces:**
- Consumes: `DownloadManager`, `SettingsStore`, `DownloadStore`, `DownloadItem`, `DownloadStatus`, `FailureReason`, `DownloadCategory`.
- Produces:
  - `AppModel` (`@MainActor @Observable`): `settings`, `manager`, `windows`, `openMainWindowAction`, `start()`, `showMainWindow()`.
  - `WindowCoordinator`:
    - `show(key:title:content:)` opens an AppKit-hosted window; one window per key.
    - `close(key:)`, `window(for:)`.
    - `static progressKey(_:)`.
  - `Format.bytes(_:)`, `speed(_:)`, `duration(_:)`, `percent(_:)`, `date(_:)`.
  - Localised labels: `DownloadCategory.title`/`symbol`, `DownloadStatus.text(fraction:)`, `FailureReason.message`.
  - `FileIcon.icon(for:)`.
  - `WindowAccessor(configure:)`, `WindowTitle(title:)`.
  - `SidebarSelection` with `includes(_:)`; `SidebarView(selection:)`; `DownloadTable(filter:search:selection:)`.

- [ ] **Step 1: Write the XcodeGen project and configs**

`project.yml`:
```yaml
name: HizDownloadManager
options:
  bundleIdPrefix: com.hizdm
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
configFiles:
  Debug: Config/Base.xcconfig
  Release: Config/Base.xcconfig
packages:
  HDMCore:
    path: Packages/HDMCore
settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    SWIFT_EMIT_LOC_STRINGS: YES
    LOCALIZATION_PREFERS_STRING_CATALOGS: YES
targets:
  HizDownloadManager:
    type: application
    platform: macOS
    sources:
      - path: App
    dependencies:
      - package: HDMCore
        product: HDMCore
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: Hiz Download Manager
        CFBundleName: Hiz Download Manager
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        CFBundleDevelopmentRegion: en
        CFBundleLocalizations: [en, tr]
        LSApplicationCategoryType: public.app-category.utilities
        LSMinimumSystemVersion: "14.0"
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.hizdm.HizDownloadManager
        PRODUCT_NAME: Hiz Download Manager
        ENABLE_HARDENED_RUNTIME: YES
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        CODE_SIGN_STYLE: Automatic
```

`Config/Base.xcconfig`:
```
// Shared build settings. Put your own DEVELOPMENT_TEAM in Local.xcconfig (never committed).
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM =
#include? "../Local.xcconfig"
```

`Local.xcconfig.example`:
```
// Copy to Local.xcconfig and set your Apple Developer team ID.
DEVELOPMENT_TEAM = ABCDE12345
```

- [ ] **Step 2: Create your own `Local.xcconfig`**

Run: `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`
The `OU=` value is the team ID. Write `DEVELOPMENT_TEAM = <that value>` to `Local.xcconfig`.

- [ ] **Step 3: Write and run the icon generator**

`scripts/make-icon.swift`:
```swift
#!/usr/bin/env swift
// Draws the HDM app icon (our own design: a download arrow with speed lines) into an .appiconset.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.05, green: 0.66, blue: 0.56, alpha: 1),
                        NSColor(red: 0.07, green: 0.32, blue: 0.82, alpha: 1)])!.draw(in: tile, angle: -90)
    NSColor.white.setFill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 560 * s, y: 770 * s))
    arrow.line(to: NSPoint(x: 670 * s, y: 770 * s))
    arrow.line(to: NSPoint(x: 670 * s, y: 490 * s))
    arrow.line(to: NSPoint(x: 790 * s, y: 490 * s))
    arrow.line(to: NSPoint(x: 615 * s, y: 285 * s))
    arrow.line(to: NSPoint(x: 440 * s, y: 490 * s))
    arrow.line(to: NSPoint(x: 560 * s, y: 490 * s))
    arrow.close()
    arrow.fill()
    for (i, y) in [660, 550, 440].enumerated() {
        let width = CGFloat(210 - i * 50) * s
        NSBezierPath(roundedRect: NSRect(x: 400 * s - width, y: CGFloat(y) * s, width: width, height: 46 * s), xRadius: 23 * s, yRadius: 23 * s).fill()
    }
    NSBezierPath(roundedRect: NSRect(x: 445 * s, y: 205 * s, width: 340 * s, height: 44 * s), xRadius: 22 * s, yRadius: 22 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
```

Run: `swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset`

Then write `App/Resources/Assets.xcassets/Contents.json`:
```json
{ "info" : { "author" : "xcode", "version" : 1 } }
```

and `App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`:
```json
{
  "colors" : [ { "idiom" : "universal", "color" : { "color-space" : "srgb", "components" : { "red" : "0.070", "green" : "0.420", "blue" : "0.780", "alpha" : "1.000" } } } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

Open `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png` and check that it looks right (a teal-to-blue tile with a white arrow).

- [ ] **Step 4: Write the utilities**

`App/Util/Format.swift`:
```swift
import Foundation

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter.string(from: seconds.rounded()) ?? ""
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "" }
        return fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    static func date(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }
}
```

`App/Util/Labels.swift`:
```swift
import Foundation
import HDMCore

extension DownloadCategory {
    var title: String {
        switch self {
        case .compressed: String(localized: "Compressed")
        case .documents: String(localized: "Documents")
        case .music: String(localized: "Music")
        case .programs: String(localized: "Programs")
        case .video: String(localized: "Video")
        case .general: String(localized: "General")
        }
    }

    var symbol: String {
        switch self {
        case .compressed: "doc.zipper"
        case .documents: "doc.text"
        case .music: "music.note"
        case .programs: "app.badge"
        case .video: "film"
        case .general: "doc"
        }
    }
}

extension DownloadStatus {
    func text(fraction: Double?) -> String {
        switch self {
        case .queued: String(localized: "Queued")
        case .connecting: String(localized: "Connecting…")
        case .downloading: fraction.map { Format.percent($0) } ?? String(localized: "Downloading")
        case .paused: fraction.map { String(localized: "Paused (\(Format.percent($0)))") } ?? String(localized: "Paused")
        case .merging: String(localized: "Merging…")
        case .completed: String(localized: "Complete")
        case .failed: String(localized: "Error")
        case .needsRefresh: String(localized: "Link expired")
        }
    }
}

extension FailureReason {
    var message: String {
        switch self {
        case .network(let detail): String(localized: "Network error: \(detail)")
        case .http(let code): String(localized: "Server returned HTTP \(code).")
        case .authRequired: String(localized: "The server requires a user name and password.")
        case .serverFileChanged: String(localized: "The file on the server has changed. Restart the download.")
        case .diskFull: String(localized: "There is not enough disk space.")
        case .fileSystem(let detail): String(localized: "File error: \(detail)")
        }
    }
}
```

`App/Util/FileIcon.swift`:
```swift
import AppKit
import UniformTypeIdentifiers

@MainActor
enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(for fileName: String) -> NSImage {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = image
        return image
    }
}
```

`App/Util/WindowAccessor.swift`:
```swift
import AppKit
import SwiftUI

/// Gives SwiftUI content access to its hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let configure = configure
        Task { @MainActor in
            if let window = view.window { configure(window) }
        }
    }
}

/// Keeps the hosting window's title in sync (used by AppKit-hosted windows).
struct WindowTitle: View {
    let title: String
    var body: some View {
        WindowAccessor { window in
            if window.title != title { window.title = title }
        }
        .frame(width: 0, height: 0)
    }
}
```

- [ ] **Step 5: Write the window coordinator, model, delegate and app**

`App/Windows/WindowCoordinator.swift`:
```swift
import AppKit
import HDMCore
import SwiftUI

/// Opens AppKit-hosted SwiftUI windows (dialogs), one per key, from anywhere in the app.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    unowned let model: AppModel
    private var windows: [String: NSWindow] = [:]

    init(model: AppModel) {
        self.model = model
    }

    static func progressKey(_ id: UUID) -> String { "progress-\(id.uuidString)" }

    func show<Content: View>(key: String, title: String, @ViewBuilder content: () -> Content) {
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = content().environment(model).environment(model.manager)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.delegate = self
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(key: String) { windows[key]?.close() }
    func window(for key: String) -> NSWindow? { windows[key] }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let key = window.identifier?.rawValue else { return }
        windows[key] = nil
    }
}
```

`App/AppModel.swift`:
```swift
import AppKit
import HDMCore
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let manager: DownloadManager
    @ObservationIgnored private(set) var windows: WindowCoordinator!
    @ObservationIgnored var openMainWindowAction: OpenWindowAction?

    init() {
        settings = SettingsStore()
        manager = DownloadManager(store: DownloadStore(), settings: settings)
        windows = WindowCoordinator(model: self)
    }

    func start() {}

    func showMainWindow() {
        openMainWindowAction?(id: "main")
        NSApp.activate()
    }
}
```

`App/AppDelegate.swift`:
```swift
import AppKit
import HDMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Saves exact segment state of running downloads before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.manager.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showMainWindow() }
        return true
    }
}
```

`App/HizDownloadManagerApp.swift`:
```swift
import HDMCore
import SwiftUI

@main
struct HizDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model
        Window("Hiz Download Manager", id: "main") {
            MainView()
                .environment(model)
                .environment(model.manager)
                .frame(minWidth: 900, minHeight: 480)
        }
        .windowToolbarStyle(.expanded)
    }
}
```

- [ ] **Step 6: Write the main window views**

`App/MainWindow/SidebarView.swift`:
```swift
import HDMCore
import SwiftUI

enum SidebarSelection: Hashable {
    case all(DownloadCategory?)
    case unfinished(DownloadCategory?)
    case finished(DownloadCategory?)
    case queues
    case mainQueue

    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all(let category): category == nil || item.category == category
        case .unfinished(let category): item.status != .completed && (category == nil || item.category == category)
        case .finished(let category): item.status == .completed && (category == nil || item.category == category)
        case .queues, .mainQueue: item.status == .queued
        }
    }
}

struct SidebarNode: Identifiable, Hashable {
    let id: SidebarSelection
    let title: String
    let symbol: String
    var children: [SidebarNode]?
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?

    private var nodes: [SidebarNode] {
        func categories(_ make: (DownloadCategory) -> SidebarSelection) -> [SidebarNode] {
            DownloadCategory.allCases.map { SidebarNode(id: make($0), title: $0.title, symbol: $0.symbol) }
        }
        return [
            SidebarNode(id: .all(nil), title: String(localized: "All Downloads"), symbol: "tray.full", children: categories { .all($0) }),
            SidebarNode(id: .unfinished(nil), title: String(localized: "Unfinished"), symbol: "arrow.down.circle", children: categories { .unfinished($0) }),
            SidebarNode(id: .finished(nil), title: String(localized: "Finished"), symbol: "checkmark.circle", children: categories { .finished($0) }),
            SidebarNode(id: .queues, title: String(localized: "Queues"), symbol: "list.number",
                        children: [SidebarNode(id: .mainQueue, title: String(localized: "Main Queue"), symbol: "list.bullet")]),
        ]
    }

    var body: some View {
        List(nodes, children: \.children, selection: $selection) { node in
            Label(node.title, systemImage: node.symbol)
        }
        .listStyle(.sidebar)
    }
}
```

`App/MainWindow/DownloadTable.swift`:
```swift
import HDMCore
import SwiftUI

extension DownloadItem {
    var sortableSize: Int64 { totalBytes ?? -1 }
    var sortableLastTry: Date { lastTryAt ?? .distantPast }
}

struct DownloadTable: View {
    @Environment(DownloadManager.self) private var manager
    let filter: SidebarSelection
    let search: String
    @Binding var selection: Set<UUID>
    @State private var sortOrder = [KeyPathComparator(\DownloadItem.createdAt)]

    private var rows: [DownloadItem] {
        manager.items
            .filter { filter.includes($0) && (search.isEmpty || $0.fileName.localizedCaseInsensitiveContains(search)) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("File Name", value: \.fileName) { item in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcon.icon(for: item.fileName)).resizable().frame(width: 16, height: 16)
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Size", value: \.sortableSize) { item in
                Text(Format.bytes(item.totalBytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Status") { item in
                StatusCell(item: item)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Time Left") { item in
                Text(item.status == .downloading ? Format.duration(manager.live[item.id]?.secondsRemaining) : "").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Transfer Rate") { item in
                Text(Format.speed(manager.live[item.id]?.bytesPerSecond ?? 0)).monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn("Last Try", value: \.sortableLastTry) { item in
                Text(Format.date(item.lastTryAt))
            }
            .width(min: 120, ideal: 150)
            TableColumn("Description", value: \.userDescription)
        }
    }
}

struct StatusCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.status.text(fraction: item.fractionCompleted)).lineLimit(1)
            if item.status == .downloading || item.status == .paused, let fraction = item.fractionCompleted {
                ProgressView(value: fraction).controlSize(.mini)
            }
        }
    }
}
```

`App/MainWindow/MainView.swift`:
```swift
import HDMCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var sidebar: SidebarSelection? = .all(nil)
    @State private var selection = Set<UUID>()
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            DownloadTable(filter: sidebar ?? .all(nil), search: search, selection: $selection)
        }
        .searchable(text: $search, placement: .toolbar)
        .onAppear { model.openMainWindowAction = openWindow }
    }
}
```

- [ ] **Step 7: Build and run**

Run: `make project && make app`
Expected: `** BUILD SUCCEEDED **` (with `-quiet`, the absence of errors).

Run: `make run`. Check that the window opens with the sidebar tree (All Downloads, Unfinished, Finished, Queues, with their category children) and an empty table with 7 columns. Take a screenshot to confirm (`screencapture -x /tmp/hdm-main.png`), then quit the app.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(app): add Xcode project, app shell and main window"
```

---

### Task 13: Adding downloads, toolbar, context menu, clipboard, drag & drop

**Files:**
- Create: `App/Capture/PendingDownload.swift`, `App/Capture/CaptureCoordinator.swift`, `App/Capture/AddURLView.swift`, `App/Capture/DownloadInfoView.swift`, `App/Capture/ClipboardMonitor.swift`
- Create: `App/Windows/WindowCoordinator+Dialogs.swift`, `App/AppModel+Actions.swift`
- Create: `App/MainWindow/MainToolbar.swift`, `App/MainWindow/ItemContextMenu.swift`, `App/MainWindow/AppCommands.swift`
- Modify: `App/AppModel.swift` (full replacement below), `App/MainWindow/MainView.swift`, `App/MainWindow/DownloadTable.swift`, `App/HizDownloadManagerApp.swift`

**Interfaces:**
- Consumes: Task 12 types; `HTTPProbe`, `FilenameResolver`, `NewDownload`, `DownloadManager` commands.
- Produces:
  - `PendingDownload(url:headers:pageURL:referrer:suggestedName:totalBytes:source:)`, with `Source`: `.manual`, `.clipboard`, `.drop`, `.browser`.
  - `CaptureCoordinator`:
    - `handle(_:)` is the single entry point for new links. Phase 2 IPC will call it.
    - `offerRefresh(_:fileName:totalBytes:) -> Bool`.
    - `handleDrop(_:) -> Bool`.
  - `WindowCoordinator.showAddURL()`, `showDownloadInfo(_:)`.
  - `AppModel` actions: `open(_:)`, `openWith(_:)`, `reveal(_:)`, `stop(_:)`, `stopAll()`, `confirmDelete(_:)`, `confirmDeleteCompleted()`, `refreshAddress(_:)`.
  - `AppModel.capture`; `ClipboardMonitor(isEnabled:shouldCapture:onURL:)` with `start()`.

- [ ] **Step 1: Write the capture types**

`App/Capture/PendingDownload.swift`:
```swift
import Foundation

/// A link that is about to become a download (from Add URL, clipboard, drag & drop or, later, a browser).
struct PendingDownload: Identifiable, Sendable {
    enum Source: Sendable { case manual, clipboard, drop, browser }

    let id = UUID()
    var url: URL
    var headers: [String: String] = [:]
    var pageURL: URL?
    var referrer: URL?
    var suggestedName: String?
    var totalBytes: Int64?
    var source: Source
}
```

`App/Capture/CaptureCoordinator.swift`:
```swift
import AppKit
import HDMCore

@MainActor
final class CaptureCoordinator {
    unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ pending: PendingDownload) {
        guard ["http", "https"].contains(pending.url.scheme?.lowercased() ?? "") else { return }
        if model.settings.settings.startWithoutDialog {
            Task { await startImmediately(pending) }
        } else {
            model.windows.showDownloadInfo(pending)
        }
    }

    /// If `pending` looks like the new address of a download that is waiting for one, asks the user and applies it.
    func offerRefresh(_ pending: PendingDownload, fileName: String, totalBytes: Int64?) -> Bool {
        guard let candidate = model.manager.refreshCandidate(fileName: fileName, totalBytes: totalBytes) else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Is this the new address for “\(candidate.fileName)”?")
        alert.informativeText = String(localized: "HDM is waiting for a new link for this download. Use this address and continue where it left off?")
        alert.addButton(withTitle: String(localized: "Use New Address"))
        alert.addButton(withTitle: String(localized: "New Download"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        model.manager.applyRefreshedLink(candidate.id, url: pending.url, headers: pending.headers,
                                         pageURL: pending.pageURL, referrer: pending.referrer)
        return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if let link = Self.resolveDroppedURL(url) {
                        self.handle(PendingDownload(url: link, source: .drop))
                    }
                }
            }
        }
        return accepted
    }

    /// Web links pass through; `.webloc` files are unwrapped to the link they contain.
    private static func resolveDroppedURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return url }
        guard url.pathExtension.lowercased() == "webloc",
              let plist = NSDictionary(contentsOf: url), let string = plist["URL"] as? String else { return nil }
        return URL(string: string)
    }

    private func startImmediately(_ pending: PendingDownload) async {
        let probe = try? await HTTPProbe.probe(url: pending.url, headers: pending.headers)
        let name = FilenameResolver.resolve(contentDisposition: probe?.contentDisposition, suggested: pending.suggestedName,
                                            url: probe?.finalURL ?? pending.url, mimeType: probe?.mimeType)
        if offerRefresh(pending, fileName: name, totalBytes: probe?.totalBytes ?? pending.totalBytes) { return }
        let s = model.settings.settings
        let category = s.categoryResolver.category(forFileName: name)
        let directory = s.folder(for: category)
        let finalName = s.conflictPolicy == .overwrite ? name : FilenameResolver.uniqueName(name, in: directory)
        model.manager.add(NewDownload(url: pending.url, fileName: finalName, directory: directory, category: category,
                                      headers: pending.headers, pageURL: pending.pageURL, referrer: pending.referrer,
                                      totalBytes: probe?.totalBytes ?? pending.totalBytes))
    }
}
```

`App/Capture/ClipboardMonitor.swift`:
```swift
import AppKit

/// Polls the pasteboard once a second (spec §6.5). On macOS 15.4+ it first asks the system whether a
/// web URL is present, without reading the contents, so no privacy alert appears for ordinary copies.
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastURL: URL?
    private let isEnabled: () -> Bool
    private let shouldCapture: (URL) -> Bool
    private let onURL: (URL) -> Void

    init(isEnabled: @escaping () -> Bool, shouldCapture: @escaping (URL) -> Bool, onURL: @escaping (URL) -> Void) {
        self.isEnabled = isEnabled
        self.shouldCapture = shouldCapture
        self.onURL = onURL
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard isEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if #available(macOS 15.4, *) {
            let changeCount = lastChangeCount
            Task {
                guard let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]),
                      patterns.contains(\.probableWebURL), pasteboard.changeCount == changeCount else { return }
                self.readURL(from: pasteboard)
            }
        } else {
            readURL(from: pasteboard)
        }
    }

    private func readURL(from pasteboard: NSPasteboard) {
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: \.isWhitespace), let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url != lastURL, shouldCapture(url) else { return }
        lastURL = url
        onURL(url)
    }
}
```

- [ ] **Step 2: Write the Add URL and Download File Info views**

`App/Capture/AddURLView.swift`:
```swift
import AppKit
import SwiftUI

struct AddURLView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var address = AddURLView.clipboardLink() ?? ""
    @State private var useAuthorization = false
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("Address:", text: $address)
                Toggle("Use authorization", isOn: $useAuthorization)
                if useAuthorization {
                    TextField("User name:", text: $user)
                    SecureField("Password:", text: $password)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("OK") { submit() }.keyboardShortcut(.defaultAction).disabled(parsedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var parsedURL: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private func submit() {
        guard let url = parsedURL else { return }
        var headers: [String: String] = [:]
        if useAuthorization, !user.isEmpty {
            headers["Authorization"] = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
        close()
        model.capture.handle(PendingDownload(url: url, headers: headers, source: .manual))
    }

    /// The user opened this window themselves, so reading the clipboard here is user-initiated.
    private static func clipboardLink() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return text
    }
}
```

`App/Capture/DownloadInfoView.swift`:
```swift
import AppKit
import HDMCore
import SwiftUI

/// IDM's "Download File Info" dialog (spec §6.2).
struct DownloadInfoView: View {
    @Environment(AppModel.self) private var model
    let pending: PendingDownload
    let close: () -> Void

    @State private var didAppear = false
    @State private var category: DownloadCategory = .general
    @State private var fileName = ""
    @State private var directory: URL = AppSettings.defaultBaseFolder
    @State private var userEditedName = false
    @State private var userChoseFolder = false
    @State private var rememberFolder = false
    @State private var note = ""
    @State private var size: Int64?
    @State private var probing = true
    @State private var probeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: FileIcon.icon(for: fileName)).resizable().frame(width: 48, height: 48)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("URL:").gridColumnAlignment(.trailing)
                        Text(pending.url.absoluteString).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            .frame(maxWidth: 460, alignment: .leading)
                    }
                    GridRow {
                        Text("Category:")
                        Picker("", selection: $category) {
                            ForEach(DownloadCategory.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    GridRow {
                        Text("Save As:")
                        TextField("", text: nameBinding)
                    }
                    GridRow {
                        Text("Folder:")
                        HStack {
                            Text(directory.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
                                .foregroundStyle(.secondary).frame(maxWidth: 360, alignment: .leading)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Toggle("Remember this folder for this category", isOn: $rememberFolder).disabled(!userChoseFolder)
                    }
                    GridRow {
                        Text("Description:")
                        TextField("", text: $note)
                    }
                    GridRow {
                        Text("Size:")
                        Text(sizeText).foregroundStyle(.secondary)
                    }
                }
            }
            if let probeError {
                Label(probeError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Download Later") { submit(start: false) }.disabled(fileName.isEmpty)
                Button("Start Download") { submit(start: true) }.keyboardShortcut(.defaultAction).disabled(fileName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: prepare)
        .onChange(of: category) { _, new in
            if !userChoseFolder { directory = model.settings.settings.folder(for: new) }
        }
        .task { await probe() }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { fileName }, set: { fileName = $0; userEditedName = true })
    }

    private var sizeText: String {
        if let size { return Format.bytes(size) }
        return probing ? String(localized: "Getting file size…") : String(localized: "Unknown")
    }

    private func prepare() {
        guard !didAppear else { return }
        didAppear = true
        let name = FilenameResolver.resolve(suggested: pending.suggestedName, url: pending.url)
        fileName = name
        size = pending.totalBytes
        applyCategory(for: name)
        directory = model.settings.settings.folder(for: category)
    }

    private func applyCategory(for name: String) {
        category = model.settings.settings.categoryResolver.category(forFileName: name)
    }

    private func probe() async {
        defer { probing = false }
        do {
            let result = try await HTTPProbe.probe(url: pending.url, headers: pending.headers)
            if let total = result.totalBytes { size = total }
            let name = FilenameResolver.resolve(contentDisposition: result.contentDisposition, suggested: pending.suggestedName,
                                                url: result.finalURL ?? pending.url, mimeType: result.mimeType)
            if !userEditedName {
                fileName = name
                applyCategory(for: name)
            }
            if model.capture.offerRefresh(pending, fileName: name, totalBytes: result.totalBytes) { close() }
        } catch ProbeError.http(let code) {
            probeError = String(localized: "The server returned HTTP \(code). You can still try to download.")
        } catch {
            probeError = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
            userChoseFolder = true
        }
    }

    private func submit(start: Bool) {
        let fm = FileManager.default
        var name = FilenameResolver.sanitize(fileName)
        let target = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path + ".hdmpart") {
            name = FilenameResolver.uniqueName(name, in: directory)   // never share a part file with another download
        } else if fm.fileExists(atPath: target.path) {
            switch model.settings.settings.conflictPolicy {
            case .rename:
                name = FilenameResolver.uniqueName(name, in: directory)
            case .overwrite:
                break
            case .ask:
                let alert = NSAlert()
                alert.messageText = String(localized: "“\(name)” already exists.")
                alert.informativeText = String(localized: "Do you want to save the new file with a different name or replace the existing one?")
                alert.addButton(withTitle: String(localized: "Rename"))
                alert.addButton(withTitle: String(localized: "Replace"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn: name = FilenameResolver.uniqueName(name, in: directory)
                case .alertSecondButtonReturn: try? fm.trashItem(at: target, resultingItemURL: nil)
                default: return
                }
            }
        }
        if rememberFolder, userChoseFolder { model.settings.settings.categoryFolders[category] = directory }
        _ = model.manager.add(NewDownload(url: pending.url, fileName: name, directory: directory, category: category,
                                          headers: pending.headers, pageURL: pending.pageURL, referrer: pending.referrer,
                                          totalBytes: size, description: note, autoStart: start))
        close()
    }
}
```

`App/Windows/WindowCoordinator+Dialogs.swift`:
```swift
import SwiftUI

extension WindowCoordinator {
    func showAddURL() {
        let key = "add-url"
        show(key: key, title: String(localized: "Enter New Address to Download")) {
            AddURLView(close: { [weak self] in self?.close(key: key) })
        }
    }

    func showDownloadInfo(_ pending: PendingDownload) {
        let key = "info-\(pending.id.uuidString)"
        show(key: key, title: String(localized: "Download File Info")) {
            DownloadInfoView(pending: pending, close: { [weak self] in self?.close(key: key) })
        }
    }
}
```

- [ ] **Step 3: Write model actions and replace `AppModel.swift`**

`App/AppModel+Actions.swift`:
```swift
import AppKit
import HDMCore

extension AppModel {
    func open(_ item: DownloadItem) { NSWorkspace.shared.open(item.fileURL) }

    func reveal(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.status == .completed ? item.fileURL : item.saveDirectory])
    }

    func openWith(_ item: DownloadItem) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Open")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([item.fileURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Stops downloads, warning first when a download cannot be resumed (spec §5.4).
    func stop(_ ids: Set<UUID>) {
        let risky = ids.compactMap(manager.item).filter { $0.status.isRunning && $0.resumable == false }
        if !risky.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "This download cannot be resumed")
            alert.informativeText = String(localized: "The server does not support resuming. If you stop now, the download will start over from the beginning.")
            alert.addButton(withTitle: String(localized: "Stop Anyway"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await manager.pause(ids) }
    }

    func stopAll() { Task { await manager.pauseAll() } }

    func confirmDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(ids.count) download(s)?")
        alert.informativeText = String(localized: "Unfinished parts are always removed.")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Also move downloaded files to the Trash")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.remove(ids, deleteFiles: alert.suppressionButton?.state == .on)
    }

    func confirmDeleteCompleted() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove all completed downloads from the list?")
        alert.informativeText = String(localized: "The files stay on your disk.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.removeCompleted()
    }

    /// IDM's "Refresh download address": open the page so the user can click the link again (spec §5.5).
    func refreshAddress(_ item: DownloadItem) {
        manager.markAwaitingRefresh(item.id)
        NSWorkspace.shared.open(item.pageURL ?? item.referrer ?? item.url)
        let alert = NSAlert()
        alert.messageText = String(localized: "Waiting for a new link")
        alert.informativeText = String(localized: "Open the page in your browser and click or copy the download link again. HDM will use the new address and continue where it left off.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
```

Replace `App/AppModel.swift` with:
```swift
import AppKit
import HDMCore
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let manager: DownloadManager
    @ObservationIgnored private(set) var windows: WindowCoordinator!
    @ObservationIgnored private(set) var capture: CaptureCoordinator!
    @ObservationIgnored var openMainWindowAction: OpenWindowAction?
    @ObservationIgnored private var clipboard: ClipboardMonitor?

    init() {
        settings = SettingsStore()
        manager = DownloadManager(store: DownloadStore(), settings: settings)
        windows = WindowCoordinator(model: self)
        capture = CaptureCoordinator(model: self)
    }

    func start() {
        clipboard = ClipboardMonitor(
            isEnabled: { [unowned self] in settings.settings.clipboardMonitoring },
            shouldCapture: { [unowned self] url in settings.settings.shouldCapture(fileName: url.lastPathComponent) },
            onURL: { [unowned self] url in capture.handle(PendingDownload(url: url, source: .clipboard)) })
        clipboard?.start()
    }

    func showMainWindow() {
        openMainWindowAction?(id: "main")
        NSApp.activate()
    }
}
```

- [ ] **Step 4: Write the toolbar, context menu and commands**

`App/MainWindow/MainToolbar.swift`:
```swift
import HDMCore
import SwiftUI

struct MainToolbar: ToolbarContent {
    let model: AppModel
    let manager: DownloadManager
    let selection: Set<UUID>

    private var selected: [DownloadItem] { selection.compactMap(manager.item) }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.windows.showAddURL() } label: { Label("Add URL", systemImage: "plus.circle") }
            Button { manager.resume(selection) } label: { Label("Resume", systemImage: "play.fill") }
                .disabled(!selected.contains { $0.status.canResume })
            Button { model.stop(selection) } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!selected.contains { $0.status.isRunning || $0.status == .queued })
            Button { model.stopAll() } label: { Label("Stop All", systemImage: "stop.circle") }
            Button { model.confirmDelete(selection) } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
            Button { model.confirmDeleteCompleted() } label: { Label("Delete Completed", systemImage: "checkmark.rectangle.stack") }
            SettingsLink { Label("Options", systemImage: "gearshape") }
            Button { manager.startQueue() } label: { Label("Start Queue", systemImage: "forward.end.fill") }
            Button { manager.stopQueue() } label: { Label("Stop Queue", systemImage: "pause.rectangle") }
        }
    }
}
```

`App/MainWindow/ItemContextMenu.swift`:
```swift
import HDMCore
import SwiftUI

struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var manager
    let ids: Set<UUID>

    var body: some View {
        let items = ids.compactMap(manager.item)
        let single = items.count == 1 ? items.first : nil
        if let single, single.status == .completed {
            Button("Open") { model.open(single) }
            Button("Open With…") { model.openWith(single) }
            Button("Show in Finder") { model.reveal(single) }
            Divider()
        }
        Button("Resume") { manager.resume(ids) }
            .disabled(!items.contains { $0.status.canResume })
        Button("Stop") { model.stop(ids) }
            .disabled(!items.contains { $0.status.isRunning || $0.status == .queued })
        Button("Redownload") { ids.forEach { manager.redownload($0) } }
        if let single, single.status != .completed {
            Button("Refresh Download Address") { model.refreshAddress(single) }
        }
        Button("Add to Queue") { manager.addToQueue(ids) }
        Divider()
        Button("Delete…") { model.confirmDelete(ids) }
    }
}
```

`App/MainWindow/AppCommands.swift`:
```swift
import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add URL…") { model.windows.showAddURL() }.keyboardShortcut("n")
        }
        CommandMenu("Downloads") {
            Button("Stop All") { model.stopAll() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Button("Start Queue") { model.manager.startQueue() }
            Button("Stop Queue") { model.manager.stopQueue() }
        }
    }
}
```

- [ ] **Step 5: Wire everything into the main window and app**

In `App/MainWindow/MainView.swift`, add `@Environment(DownloadManager.self) private var manager`. Then replace the modifier chain after the `NavigationSplitView { … } detail: { … }` block with:
```swift
        .searchable(text: $search, placement: .toolbar)
        .toolbar { MainToolbar(model: model, manager: manager, selection: selection) }
        .background(WindowAccessor { window in window.toolbar?.displayMode = .iconAndLabel })
        .onDrop(of: [.url], isTargeted: nil) { providers in model.capture.handleDrop(providers) }
        .onAppear { model.openMainWindowAction = openWindow }
```

In `App/MainWindow/DownloadTable.swift`, after the closing brace of `Table(...) { … }`, add:
```swift
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemContextMenu(ids: ids)
        }
```

In `App/HizDownloadManagerApp.swift`, add `.commands { AppCommands(model: model) }` after `.windowToolbarStyle(.expanded)`.

- [ ] **Step 6: Build and verify by hand**

Run: `make app && make run`.

Test with a local server. Run `python3 -m http.server 8765 --directory /tmp` in another terminal, after `mkfile -n 50m /tmp/hdm-test.bin`. Note: Python's server has no Range support, so this also exercises the single-connection path.

Check each of these:
1. The toolbar shows icons with labels.
2. ⌘N opens "Enter New Address to Download". Enter `http://127.0.0.1:8765/hdm-test.bin` and press OK. The Download File Info dialog shows the size and category General. Click Start Download: the row appears and completes. The file is in `~/Downloads/HDM/General/`.
3. Run `cp /tmp/hdm-test.bin /tmp/hdm-test.zip`, then copy the text `http://127.0.0.1:8765/hdm-test.zip` in TextEdit. The Download File Info dialog opens, because `zip` is in the capture list.
4. Drag a link from Safari onto the window. The dialog opens.
5. Right-click a row: the context menu entries work. Delete asks for confirmation.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(app): add URL entry, download info dialog, toolbar, context menu, clipboard and drop capture"
```

---

### Task 14: Progress window, segment bar, completion dialog

**Files:**
- Create: `App/Progress/ProgressWindowView.swift`, `App/Progress/SegmentBar.swift`, `App/Progress/ConnectionList.swift`, `App/Progress/ProgressTabs.swift`, `App/Progress/CompletionView.swift`, `App/AppModel+Events.swift`
- Modify: `App/Windows/WindowCoordinator+Dialogs.swift` (add two methods), `App/AppModel.swift` (`start()`), `App/AppModel+Actions.swift` (add `primaryAction`), `App/MainWindow/DownloadTable.swift` (primary action), `App/MainWindow/ItemContextMenu.swift` (Properties), `App/Capture/DownloadInfoView.swift` and `App/Capture/CaptureCoordinator.swift` (open progress window)

**Interfaces:**
- Consumes: `DownloadManager.live`, `ConnectionInfo`, `Segment`, `CompletionAction`, and the `setSpeedLimit` and `setOnComplete` commands.
- Produces:
  - `WindowCoordinator.showProgress(_:)`, `showCompletion(_:)`.
  - `AppModel.handle(_ event: ManagerEvent)`, `AppModel.primaryAction(for:)`.
  - Views: `SegmentBar(segments:total:activeSegments:)`, `ConnectionList(connections:)`, `SpeedLimitTab(item:)`, `CompletionOptionsTab(item:)`, `CompletionView(item:close:)`.

- [ ] **Step 1: Write the progress views**

`App/Progress/SegmentBar.swift`:
```swift
import HDMCore
import SwiftUI

/// The file as one bar: each segment's downloaded part is filled; segments with a live connection are brighter.
struct SegmentBar: View {
    let segments: [Segment]
    let total: Int64?
    let activeSegments: Set<Int>

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.secondary.opacity(0.15)))
            guard let total, total > 0 else { return }
            let scale = size.width / CGFloat(total)
            for (index, segment) in segments.enumerated() where !segment.isOpenEnded {
                let x = CGFloat(segment.start) * scale
                let filled = CGRect(x: x, y: 0, width: CGFloat(segment.received) * scale, height: size.height)
                context.fill(Path(filled), with: .color(activeSegments.contains(index) ? Color.accentColor : Color.accentColor.opacity(0.55)))
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.3)))
            }
        }
        .accessibilityLabel(Text("Segments"))
    }
}
```

`App/Progress/ConnectionList.swift`:
```swift
import HDMCore
import SwiftUI

struct ConnectionList: View {
    let connections: [ConnectionInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("N.").frame(width: 30, alignment: .leading)
                Text("Downloaded").frame(width: 120, alignment: .leading)
                Text("Info")
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            ForEach(Array(connections.enumerated()), id: \.element.id) { offset, connection in
                HStack {
                    Text(verbatim: "\(offset + 1)").frame(width: 30, alignment: .leading)
                    Text(Format.bytes(connection.receivedInSegment)).frame(width: 120, alignment: .leading)
                    Text(connection.isReceiving ? "Receiving data…" : "Connecting…")
                }
                .font(.caption.monospacedDigit())
            }
            if connections.isEmpty {
                Text("No active connections").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
```

`App/Progress/ProgressTabs.swift`:
```swift
import HDMCore
import SwiftUI

struct SpeedLimitTab: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem
    @State private var enabled = false
    @State private var kilobytes = 500

    var body: some View {
        Form {
            Toggle("Use speed limiter", isOn: $enabled)
            TextField("Maximum download speed (KB/s):", value: $kilobytes, format: .number).disabled(!enabled)
        }
        .onAppear {
            enabled = item.speedLimit != nil
            kilobytes = Int((item.speedLimit ?? 512_000) / 1024)
        }
        .onChange(of: enabled) { apply() }
        .onChange(of: kilobytes) { apply() }
    }

    private func apply() {
        manager.setSpeedLimit(item.id, bytesPerSecond: enabled ? Int64(max(1, kilobytes)) * 1024 : nil)
    }
}

struct CompletionOptionsTab: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem

    var body: some View {
        Form {
            Picker("When the download finishes:", selection: Binding(get: { item.onComplete }, set: { manager.setOnComplete(item.id, $0) })) {
                Text("Do nothing").tag(CompletionAction.nothing)
                Text("Open the file").tag(CompletionAction.open)
                Text("Show in Finder").tag(CompletionAction.revealInFinder)
            }
            .pickerStyle(.radioGroup)
        }
    }
}
```

`App/Progress/ProgressWindowView.swift`:
```swift
import HDMCore
import SwiftUI

/// IDM's per-download status window (spec §6.3).
struct ProgressWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var manager
    let id: UUID
    @State private var tab = 0
    @State private var showDetails = false

    var body: some View {
        if let item = manager.item(id) {
            content(item)
                .background(WindowTitle(title: title(item)))
        } else {
            Text("This download was removed.").padding(40)
        }
    }

    private func title(_ item: DownloadItem) -> String {
        guard let fraction = item.fractionCompleted else { return item.fileName }
        return "\(Int((fraction * 100).rounded(.down)))% \(item.fileName)"
    }

    private func content(_ item: DownloadItem) -> some View {
        let stats = manager.live[id]
        return VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("Download status").tag(0)
                Text("Speed Limiter").tag(1)
                Text("Options on completion").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case 0: statusTab(item, stats)
            case 1: SpeedLimitTab(item: item)
            default: CompletionOptionsTab(item: item)
            }

            HStack {
                if tab == 0 {
                    Button(showDetails ? "Hide details" : "Show details") { showDetails.toggle() }
                }
                Spacer()
                if item.status.isRunning || item.status == .queued {
                    Button("Pause") { model.stop([id]) }
                } else if item.status.canResume {
                    Button("Resume") { manager.resume([id]) }
                }
                Button("Cancel") {
                    if item.status.isRunning || item.status == .queued { model.stop([id]) }
                    model.windows.close(key: WindowCoordinator.progressKey(id))
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 580)
    }

    private func statusTab(_ item: DownloadItem, _ stats: LiveStats?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Status:", statusLine(item))
                row("File size:", item.totalBytes.map { Format.bytes($0) } ?? String(localized: "Unknown"))
                row("Downloaded:", downloaded(item))
                row("Transfer rate:", Format.speed(stats?.bytesPerSecond ?? 0))
                row("Time left:", Format.duration(stats?.secondsRemaining))
                row("Resume capability:", resumeText(item))
            }
            ProgressView(value: item.fractionCompleted ?? 0)
            SegmentBar(segments: item.segments, total: item.totalBytes,
                       activeSegments: Set(stats?.connections.map(\.segmentIndex) ?? []))
                .frame(height: 14)
            if showDetails {
                ConnectionList(connections: stats?.connections ?? [])
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospacedDigit()
        }
    }

    private func statusLine(_ item: DownloadItem) -> String {
        if case .failed(let reason) = item.status { return reason.message }
        return item.status.text(fraction: item.fractionCompleted)
    }

    private func downloaded(_ item: DownloadItem) -> String {
        let bytes = Format.bytes(item.receivedBytes)
        guard let fraction = item.fractionCompleted else { return bytes }
        return "\(bytes) (\(Format.percent(fraction)))"
    }

    private func resumeText(_ item: DownloadItem) -> String {
        switch item.resumable {
        case true?: String(localized: "Yes")
        case false?: String(localized: "No")
        case nil: String(localized: "Unknown")
        }
    }
}
```

`App/Progress/CompletionView.swift`:
```swift
import HDMCore
import SwiftUI

struct CompletionView: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem
    let close: () -> Void
    @State private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: FileIcon.icon(for: item.fileName)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download complete").font(.headline)
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                    Text(Format.bytes(item.totalBytes)).foregroundStyle(.secondary)
                }
            }
            Text(item.fileURL.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Toggle("Don't show this dialog again", isOn: $dontShowAgain)
            HStack {
                Button("Open") { model.open(item); done() }.keyboardShortcut(.defaultAction)
                Button("Open With…") { model.openWith(item); done() }
                Button("Open Folder") { model.reveal(item); done() }
                Spacer()
                Button("Close") { done() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func done() {
        if dontShowAgain { model.settings.settings.showCompletionDialog = false }
        close()
    }
}
```

- [ ] **Step 2: Add the window methods and event handling**

Append to `App/Windows/WindowCoordinator+Dialogs.swift`, inside the extension:
```swift
    func showProgress(_ id: UUID) {
        show(key: Self.progressKey(id), title: model.manager.item(id)?.fileName ?? "") {
            ProgressWindowView(id: id)
        }
    }

    func showCompletion(_ id: UUID) {
        guard let item = model.manager.item(id) else { return }
        let key = "done-\(id.uuidString)"
        show(key: key, title: String(localized: "Download complete")) {
            CompletionView(item: item, close: { [weak self] in self?.close(key: key) })
        }
    }
```

Create `App/AppModel+Events.swift`:
```swift
import AppKit
import HDMCore

extension AppModel {
    func handle(_ event: ManagerEvent) {
        switch event {
        case .completed(let id):
            guard let item = manager.item(id) else { return }
            windows.close(key: WindowCoordinator.progressKey(id))
            switch item.onComplete {
            case .open: open(item)
            case .revealInFinder: reveal(item)
            case .nothing: if settings.settings.showCompletionDialog { windows.showCompletion(id) }
            }
        case .started, .failed, .needsRefresh:
            break
        }
    }
}
```

In `App/AppModel.swift`, add this as the first line of `start()`:
```swift
        manager.onEvent = { [weak self] event in self?.handle(event) }
```

Append to the `AppModel` extension in `App/AppModel+Actions.swift`:
```swift
    /// Double-click: open finished files, show the progress window for everything else.
    func primaryAction(for ids: Set<UUID>) {
        guard ids.count == 1, let id = ids.first, let item = manager.item(id) else { return }
        if item.status == .completed { open(item) } else { windows.showProgress(id) }
    }
```

- [ ] **Step 3: Open the progress window from the right places**

- In `App/MainWindow/DownloadTable.swift`, add `@Environment(AppModel.self) private var model`. Then replace the `.contextMenu(forSelectionType:)` modifier with:
```swift
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemContextMenu(ids: ids)
        } primaryAction: { ids in
            model.primaryAction(for: ids)
        }
```
- In `App/MainWindow/ItemContextMenu.swift`, add at the end of `body`:
```swift
        if let single {
            Divider()
            Button("Properties…") { model.windows.showProgress(single.id) }
        }
```
- In `App/Capture/DownloadInfoView.swift`, `submit(start:)`: replace `_ = model.manager.add(` with `let id = model.manager.add(`. Then insert this before the final `close()`:
```swift
        if start && model.settings.settings.showProgressWindow { model.windows.showProgress(id) }
```
- In `App/Capture/CaptureCoordinator.swift`, `startImmediately`: replace `model.manager.add(` with `let id = model.manager.add(`. Then append this after that statement:
```swift
        if s.showProgressWindow { model.windows.showProgress(id) }
```

- [ ] **Step 4: Build and verify by hand**

Run: `make app && make run`. Test against a public, Range-capable test file: `https://proof.ovh.net/files/100Mb.dat`. If that is unreachable, use any large file on a CDN.

Check each of these:
1. Start the download. The progress window opens with the title `N% 100MB.bin`. Several segments fill in the segment bar. "Show details" lists up to 8 connections.
2. Click Pause. The status becomes Paused. Quit the app (⌘Q) and relaunch. The item is Paused at the same percentage. Resume continues from there; watch the segment bar.
3. On completion, the progress window closes and the "Download complete" dialog appears. Open Folder reveals the file in `~/Downloads/HDM/General/`.
4. Speed Limiter tab: enable 500 KB/s on a running download. The rate settles near 500 KB/s.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(app): add progress window with segment bar and completion dialog"
```

---

### Task 15: Settings window (General, Save To, Connection)

**Files:**
- Create: `App/Settings/SettingsView.swift`, `App/Settings/GeneralSettingsView.swift`, `App/Settings/SaveToSettingsView.swift`, `App/Settings/ConnectionSettingsView.swift`
- Modify: `App/HizDownloadManagerApp.swift` (add the `Settings` scene)

**Interfaces:**
- Consumes: `SettingsStore.settings` and every field of `AppSettings`.
- Produces: `SettingsView`; `GeneralSettingsView.parseExtensions(_:) -> [String]`.

- [ ] **Step 1: Write the settings views**

`App/Settings/SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            SaveToSettingsView().tabItem { Label("Save To", systemImage: "folder") }
            ConnectionSettingsView().tabItem { Label("Connection", systemImage: "network") }
        }
        .frame(width: 600, height: 520)
    }
}
```

`App/Settings/GeneralSettingsView.swift`:
```swift
import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var captureText = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var store = model.settings
        Form {
            Section("Capture") {
                Toggle("Watch the clipboard for download links", isOn: $store.settings.clipboardMonitoring)
                Toggle("Start downloads without showing the Download File Info dialog", isOn: $store.settings.startWithoutDialog)
                LabeledContent("File types to capture:") {
                    TextField("", text: $captureText, axis: .vertical).lineLimit(3...6)
                }
            }
            Section("Windows") {
                Toggle("Show the download progress window", isOn: $store.settings.showProgressWindow)
                Toggle("Show the download complete dialog", isOn: $store.settings.showCompletionDialog)
                Toggle("Keep HDM in the menu bar", isOn: $store.settings.keepInMenuBar)
            }
            Section("System") {
                Toggle("Launch HDM when I log in", isOn: $launchAtLogin)
                Toggle("Prevent sleep while downloading", isOn: $store.settings.preventSleep)
            }
        }
        .formStyle(.grouped)
        .onAppear { captureText = model.settings.settings.captureExtensions.joined(separator: " ") }
        .onChange(of: captureText) { _, new in model.settings.settings.captureExtensions = Self.parseExtensions(new) }
        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
    }

    static func parseExtensions(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Could not change the login item")
            alert.runModal()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
```

`App/Settings/SaveToSettingsView.swift`:
```swift
import AppKit
import HDMCore
import SwiftUI

struct SaveToSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settings
        Form {
            Section {
                LabeledContent("Base folder:") {
                    FolderField(url: store.settings.baseFolder, onChange: { store.settings.baseFolder = $0 })
                }
            } footer: {
                Text("Categories without their own folder use a subfolder here.")
            }
            Section("Categories") {
                ForEach(DownloadCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent {
                            FolderField(url: store.settings.folder(for: category),
                                        onChange: { store.settings.categoryFolders[category] = $0 },
                                        onReset: store.settings.categoryFolders[category] == nil ? nil : { store.settings.categoryFolders[category] = nil })
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                        }
                        if category != .general { ExtensionsField(category: category) }
                    }
                }
            }
            Section {
                Picker("If the file already exists:", selection: $store.settings.conflictPolicy) {
                    Text("Rename the new file").tag(ConflictPolicy.rename)
                    Text("Replace the existing file").tag(ConflictPolicy.overwrite)
                    Text("Ask me").tag(ConflictPolicy.ask)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FolderField: View {
    let url: URL
    let onChange: (URL) -> Void
    var onReset: (() -> Void)?

    var body: some View {
        HStack {
            Text(url.path(percentEncoded: false)).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
            Button("Choose…") { choose() }
            if let onReset { Button("Reset") { onReset() } }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = url
        if panel.runModal() == .OK, let chosen = panel.url { onChange(chosen) }
    }
}

struct ExtensionsField: View {
    @Environment(AppModel.self) private var model
    let category: DownloadCategory
    @State private var text = ""

    var body: some View {
        TextField("Extensions", text: $text, prompt: Text(verbatim: "zip rar 7z"))
            .font(.caption)
            .onAppear { text = (model.settings.settings.categoryExtensions[category] ?? []).joined(separator: " ") }
            .onChange(of: text) { _, new in
                model.settings.settings.categoryExtensions[category] = GeneralSettingsView.parseExtensions(new)
            }
    }
}
```

`App/Settings/ConnectionSettingsView.swift`:
```swift
import SwiftUI

struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settings
        Form {
            Picker("Connections per download:", selection: $store.settings.maxConnections) {
                ForEach([1, 2, 4, 8, 16, 24, 32], id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            Stepper(value: $store.settings.maxConcurrentDownloads, in: 1...10) {
                LabeledContent("Simultaneous downloads:", value: "\(store.settings.maxConcurrentDownloads)")
            }
            Toggle("Limit total download speed", isOn: Binding(
                get: { store.settings.globalSpeedLimit > 0 },
                set: { store.settings.globalSpeedLimit = $0 ? 1024 * 1024 : 0 }))
            if store.settings.globalSpeedLimit > 0 {
                TextField("Maximum speed (KB/s):", value: Binding(
                    get: { Int(store.settings.globalSpeedLimit / 1024) },
                    set: { store.settings.globalSpeedLimit = Int64(max(1, $0)) * 1024 }), format: .number)
            }
            Stepper(value: $store.settings.retryCount, in: 0...50) {
                LabeledContent("Retries per connection:", value: "\(store.settings.retryCount)")
            }
            Stepper(value: $store.settings.timeoutSeconds, in: 5...300, step: 5) {
                LabeledContent("Timeout (seconds):", value: "\(Int(store.settings.timeoutSeconds))")
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Add the scene**

In `App/HizDownloadManagerApp.swift`, after the `Window` scene (and its modifiers), add:
```swift
        Settings {
            SettingsView()
                .environment(model)
                .environment(model.manager)
        }
```

- [ ] **Step 3: Build and verify by hand**

Run: `make app && make run`. Press ⌘, (or the Options toolbar button). Check each of these:
1. All three tabs render.
2. Changing "Connections per download" to 2 and starting a download results in at most 2 connections in "Show details".
3. Setting a category folder via Choose… and starting a download of that type saves the file there.
4. Settings survive a relaunch.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(app): add settings window"
```

---

### Task 16: Menu bar extra, Dock progress, notifications, sleep prevention

**Files:**
- Create: `App/System/MenuBarContent.swift`, `App/System/DockProgress.swift`, `App/System/Notifier.swift`, `App/System/SleepGuard.swift`
- Modify: `App/AppModel.swift` (full replacement), `App/AppModel+Events.swift` (full replacement), `App/AppDelegate.swift` (notification delegate), `App/HizDownloadManagerApp.swift` (`MenuBarExtra`)

**Interfaces:**
- Consumes: `DownloadManager.totalBytesPerSecond`, `activeCount`, `overallFraction`, `items`.
- Produces: `MenuBarContent`, `MenuBarLabel(manager:)`, `DockProgress.update(fraction:activeCount:)`, `Notifier.requestAuthorization()`/`post(title:body:)`, `SleepGuard.update(active:)`.

- [ ] **Step 1: Write the system helpers**

`App/System/MenuBarContent.swift`:
```swift
import AppKit
import HDMCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = manager.items.filter { $0.status.isRunning }
        if active.isEmpty {
            Text("No active downloads")
        } else {
            ForEach(active) { item in
                Button(item.fileName + "  " + Format.percent(item.fractionCompleted)) { model.windows.showProgress(item.id) }
            }
        }
        Divider()
        Button("Add URL…") { model.windows.showAddURL() }
        Button("Stop All") { model.stopAll() }.disabled(active.isEmpty)
        Divider()
        Button("Open Hiz Download Manager") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Hiz Download Manager") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    let manager: DownloadManager

    var body: some View {
        let speed = manager.totalBytesPerSecond
        if manager.activeCount > 0, speed > 0 {
            Label(Format.speed(speed), systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}
```

`App/System/DockProgress.swift`:
```swift
import AppKit

@MainActor
final class DockProgress {
    private let view = DockTileProgressView()

    func update(fraction: Double?, activeCount: Int) {
        let tile = NSApp.dockTile
        tile.badgeLabel = activeCount > 0 ? "\(activeCount)" : nil
        if let fraction, activeCount > 0 {
            if tile.contentView !== view {
                view.frame = NSRect(origin: .zero, size: tile.size)
                tile.contentView = view
            }
            view.fraction = fraction
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

final class DockTileProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: bounds.height * 0.1)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        var fill = bar.insetBy(dx: 2, dy: 2)
        fill.size.width = max(fill.height, fill.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }
}
```

`App/System/Notifier.swift`:
```swift
import UserNotifications

@MainActor
final class Notifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
```

`App/System/SleepGuard.swift`:
```swift
import Foundation

/// Keeps the Mac awake while downloads run (spec §6.4).
@MainActor
final class SleepGuard {
    private var activity: NSObjectProtocol?

    func update(active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Downloading files")
        } else if !active, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}
```

- [ ] **Step 2: Replace `App/AppModel.swift`**

```swift
import AppKit
import HDMCore
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let manager: DownloadManager
    @ObservationIgnored private(set) var windows: WindowCoordinator!
    @ObservationIgnored private(set) var capture: CaptureCoordinator!
    @ObservationIgnored var openMainWindowAction: OpenWindowAction?
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let dock = DockProgress()
    @ObservationIgnored private let sleepGuard = SleepGuard()
    @ObservationIgnored private var clipboard: ClipboardMonitor?
    @ObservationIgnored private var ticker: Timer?

    init() {
        settings = SettingsStore()
        manager = DownloadManager(store: DownloadStore(), settings: settings)
        windows = WindowCoordinator(model: self)
        capture = CaptureCoordinator(model: self)
    }

    func start() {
        manager.onEvent = { [weak self] event in self?.handle(event) }
        notifier.requestAuthorization()
        clipboard = ClipboardMonitor(
            isEnabled: { [unowned self] in settings.settings.clipboardMonitoring },
            shouldCapture: { [unowned self] url in settings.settings.shouldCapture(fileName: url.lastPathComponent) },
            onURL: { [unowned self] url in capture.handle(PendingDownload(url: url, source: .clipboard)) })
        clipboard?.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemIndicators() }
        }
    }

    func showMainWindow() {
        openMainWindowAction?(id: "main")
        NSApp.activate()
    }

    private func refreshSystemIndicators() {
        dock.update(fraction: manager.overallFraction, activeCount: manager.activeCount)
        sleepGuard.update(active: settings.settings.preventSleep && manager.activeCount > 0)
    }
}
```

- [ ] **Step 3: Replace `App/AppModel+Events.swift`**

```swift
import AppKit
import HDMCore

extension AppModel {
    func handle(_ event: ManagerEvent) {
        switch event {
        case .completed(let id):
            guard let item = manager.item(id) else { return }
            windows.close(key: WindowCoordinator.progressKey(id))
            notifier.post(title: String(localized: "Download complete"), body: item.fileName)
            switch item.onComplete {
            case .open: open(item)
            case .revealInFinder: reveal(item)
            case .nothing: if settings.settings.showCompletionDialog { windows.showCompletion(id) }
            }
        case .failed(let id):
            guard let item = manager.item(id), case .failed(let reason) = item.status else { return }
            notifier.post(title: String(localized: "Download failed"), body: item.fileName + " — " + reason.message)
        case .needsRefresh(let id):
            guard let item = manager.item(id) else { return }
            notifier.post(title: String(localized: "Link expired"),
                          body: String(localized: "\(item.fileName) needs a new download link. Right-click it and choose Refresh Download Address."))
        case .started:
            break
        }
    }
}
```

- [ ] **Step 4: Show banners while the app is frontmost; add the menu bar scene**

Replace `App/AppDelegate.swift` with:
```swift
import AppKit
import HDMCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        model.start()
    }

    /// Saves exact segment state of running downloads before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.manager.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showMainWindow() }
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
```

In `App/HizDownloadManagerApp.swift`, after the `Settings` scene, add:
```swift
        MenuBarExtra(isInserted: Binding(get: { model.settings.settings.keepInMenuBar },
                                         set: { model.settings.settings.keepInMenuBar = $0 })) {
            MenuBarContent()
                .environment(model)
                .environment(model.manager)
        } label: {
            MenuBarLabel(manager: model.manager)
        }
```

- [ ] **Step 5: Build and verify by hand**

Run: `make app && make run`. Start a large download, then check each of these:
1. The menu bar shows an arrow with the live speed. Its menu lists the download, and "Open Hiz Download Manager" reopens a closed main window.
2. The Dock icon shows a badge "1" and a progress bar.
3. Closing the main window keeps the app running in the menu bar.
4. On completion, a notification banner appears. Allow notifications when first asked.
5. While downloading, `pmset -g assertions | grep -i "Downloading files"` shows the assertion.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(app): add menu bar extra, dock progress, notifications and sleep prevention"
```

---

### Task 17: Turkish localisation and Phase 1 acceptance

**Files:**
- Create: `App/Resources/Localizable.xcstrings` (generated once by the snippet below, then committed)
- Create: `scripts/check-strings.py`

**Interfaces:**
- Consumes: every UI string key used in Tasks 12–16.
- Produces: the EN+TR string catalog, and a checker that lists any compiler-extracted key missing a Turkish translation.

- [ ] **Step 1: Write the checker**

`scripts/check-strings.py`:
```python
#!/usr/bin/env python3
"""Lists localisable keys the compiler extracted (from .stringsdata files in build/) that have no
Turkish translation in App/Resources/Localizable.xcstrings. Run after `make app`. Exit 1 if any are missing."""
import json, pathlib, plistlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
catalog = json.loads((root / "App/Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]
translated = {k for k, v in catalog.items() if "tr" in v.get("localizations", {}) or v.get("shouldTranslate") is False}

def load(path):
    raw = path.read_bytes()
    try:
        return json.loads(raw)
    except ValueError:
        return plistlib.loads(raw)

extracted = set()
for path in (root / "build").rglob("*.stringsdata"):
    data = load(path)
    for table, entries in data.get("tables", {}).items():
        if table == "Localizable":
            extracted.update(entry["key"] for entry in entries)

missing = sorted(extracted - translated)
for key in missing:
    print(f"missing tr: {key!r}")
print(f"{len(extracted)} extracted, {len(missing)} missing")
sys.exit(1 if missing else 0)
```

- [ ] **Step 2: Generate the catalog**

Run this once from the repo root:
```bash
python3 - <<'PY'
import json, pathlib
tr = {
 "Compressed": "Arşiv", "Documents": "Belgeler", "Music": "Müzik", "Programs": "Programlar", "Video": "Video", "General": "Genel",
 "Queued": "Sırada", "Connecting…": "Bağlanıyor…", "Downloading": "İndiriliyor", "Paused (%@)": "Duraklatıldı (%@)",
 "Paused": "Duraklatıldı", "Merging…": "Birleştiriliyor…", "Complete": "Tamamlandı", "Error": "Hata", "Link expired": "Link süresi doldu",
 "Network error: %@": "Ağ hatası: %@", "Server returned HTTP %lld.": "Sunucu HTTP %lld döndürdü.",
 "The server requires a user name and password.": "Sunucu kullanıcı adı ve şifre istiyor.",
 "The file on the server has changed. Restart the download.": "Sunucudaki dosya değişmiş. İndirmeyi yeniden başlatın.",
 "There is not enough disk space.": "Yeterli disk alanı yok.", "File error: %@": "Dosya hatası: %@",
 "All Downloads": "Tüm İndirmeler", "Unfinished": "Bitmemiş", "Finished": "Bitmiş", "Queues": "Kuyruklar", "Main Queue": "Ana Kuyruk",
 "File Name": "Dosya Adı", "Size": "Boyut", "Status": "Durum", "Time Left": "Kalan Süre", "Transfer Rate": "Hız",
 "Last Try": "Son Deneme", "Description": "Açıklama",
 "Open": "Aç", "Open With…": "Birlikte Aç…", "Show in Finder": "Finder'da Göster", "Resume": "Devam", "Stop": "Durdur",
 "Redownload": "Yeniden İndir", "Refresh Download Address": "Linki Yenile", "Add to Queue": "Kuyruğa Ekle",
 "Delete…": "Sil…", "Properties…": "Özellikler…",
 "Add URL": "URL Ekle", "Stop All": "Tümünü Durdur", "Delete": "Sil", "Delete Completed": "Bitenleri Sil", "Options": "Ayarlar",
 "Start Queue": "Kuyruğu Başlat", "Stop Queue": "Kuyruğu Durdur", "Add URL…": "URL Ekle…", "Downloads": "İndirmeler",
 "This download cannot be resumed": "Bu indirme devam ettirilemez",
 "The server does not support resuming. If you stop now, the download will start over from the beginning.":
   "Sunucu devam ettirmeyi desteklemiyor. Şimdi durdurursanız indirme baştan başlar.",
 "Stop Anyway": "Yine de Durdur", "Cancel": "İptal", "Delete %lld download(s)?": "%lld indirme silinsin mi?",
 "Unfinished parts are always removed.": "Bitmemiş parçalar her zaman silinir.",
 "Also move downloaded files to the Trash": "İndirilen dosyaları da Çöp Sepeti'ne taşı",
 "Remove all completed downloads from the list?": "Tamamlanan tüm indirmeler listeden kaldırılsın mı?",
 "The files stay on your disk.": "Dosyalar diskinizde kalır.", "Remove": "Kaldır",
 "Waiting for a new link": "Yeni link bekleniyor",
 "Open the page in your browser and click or copy the download link again. HDM will use the new address and continue where it left off.":
   "Sayfayı tarayıcınızda açın ve indirme linkine tekrar tıklayın ya da linki kopyalayın. HDM yeni adresi kullanıp kaldığı yerden devam edecek.",
 "OK": "Tamam", "Is this the new address for “%@”?": "Bu, “%@” için yeni adres mi?",
 "HDM is waiting for a new link for this download. Use this address and continue where it left off?":
   "HDM bu indirme için yeni bir link bekliyor. Bu adres kullanılıp kaldığı yerden devam edilsin mi?",
 "Use New Address": "Yeni Adresi Kullan", "New Download": "Yeni İndirme", "“%@” already exists.": "“%@” zaten var.",
 "Do you want to save the new file with a different name or replace the existing one?":
   "Yeni dosya farklı bir adla mı kaydedilsin, yoksa mevcut dosyanın yerine mi yazılsın?",
 "Rename": "Yeniden Adlandır", "Replace": "Değiştir",
 "Enter New Address to Download": "İndirilecek Yeni Adresi Girin", "Address:": "Adres:", "Use authorization": "Yetkilendirme kullan",
 "User name:": "Kullanıcı adı:", "Password:": "Şifre:",
 "Download File Info": "Dosya İndirme Bilgisi", "URL:": "URL:", "Category:": "Kategori:", "Save As:": "Farklı Kaydet:",
 "Folder:": "Klasör:", "Choose…": "Seç…", "Remember this folder for this category": "Bu klasörü bu kategori için hatırla",
 "Description:": "Açıklama:", "Size:": "Boyut:", "Getting file size…": "Dosya boyutu alınıyor…", "Unknown": "Bilinmiyor",
 "The server returned HTTP %lld. You can still try to download.": "Sunucu HTTP %lld döndürdü. Yine de indirmeyi deneyebilirsiniz.",
 "Download Later": "Sonra İndir", "Start Download": "İndirmeyi Başlat",
 "Segments": "Segmentler", "N.": "No", "Downloaded": "İnen", "Info": "Bilgi", "Receiving data…": "Veri alınıyor…",
 "No active connections": "Aktif bağlantı yok", "Use speed limiter": "Hız sınırlayıcıyı kullan",
 "Maximum download speed (KB/s):": "En yüksek indirme hızı (KB/sn):", "When the download finishes:": "İndirme bitince:",
 "Do nothing": "Hiçbir şey yapma", "Open the file": "Dosyayı aç", "This download was removed.": "Bu indirme kaldırıldı.",
 "Download status": "İndirme durumu", "Speed Limiter": "Hız Sınırı", "Options on completion": "Bitince",
 "Hide details": "Detayları gizle", "Show details": "Detayları göster", "Pause": "Duraklat",
 "Status:": "Durum:", "File size:": "Dosya boyutu:", "Downloaded:": "İnen:", "Transfer rate:": "Hız:", "Time left:": "Kalan süre:",
 "Resume capability:": "Devam desteği:", "Yes": "Evet", "No": "Hayır",
 "Download complete": "İndirme tamamlandı", "Don't show this dialog again": "Bu pencereyi bir daha gösterme",
 "Open Folder": "Klasörü Aç", "Close": "Kapat",
 "Save To": "Kayıt Yerleri", "Connection": "Bağlantı", "Capture": "Yakalama",
 "Watch the clipboard for download links": "Panodaki indirme linklerini izle",
 "Start downloads without showing the Download File Info dialog": "İndirmeleri Dosya İndirme Bilgisi penceresini göstermeden başlat",
 "File types to capture:": "Yakalanacak dosya türleri:", "Windows": "Pencereler",
 "Show the download progress window": "İndirme ilerleme penceresini göster",
 "Show the download complete dialog": "İndirme tamamlandı penceresini göster", "Keep HDM in the menu bar": "HDM'yi menü çubuğunda tut",
 "System": "Sistem", "Launch HDM when I log in": "Giriş yapınca HDM'yi başlat",
 "Prevent sleep while downloading": "İndirme sırasında uykuyu engelle", "Could not change the login item": "Giriş öğesi değiştirilemedi",
 "Base folder:": "Ana klasör:", "Categories without their own folder use a subfolder here.": "Kendi klasörü olmayan kategoriler burada bir alt klasör kullanır.",
 "Categories": "Kategoriler", "Extensions": "Uzantılar", "If the file already exists:": "Dosya zaten varsa:",
 "Rename the new file": "Yeni dosyayı yeniden adlandır", "Replace the existing file": "Mevcut dosyanın yerine yaz", "Ask me": "Bana sor",
 "Reset": "Sıfırla", "Connections per download:": "İndirme başına bağlantı:", "Simultaneous downloads:": "Eşzamanlı indirme:",
 "Limit total download speed": "Toplam indirme hızını sınırla", "Maximum speed (KB/s):": "En yüksek hız (KB/sn):",
 "Retries per connection:": "Bağlantı başına deneme:", "Timeout (seconds):": "Zaman aşımı (saniye):",
 "No active downloads": "Aktif indirme yok", "Open Hiz Download Manager": "Hiz Download Manager'ı Aç", "Settings…": "Ayarlar…",
 "Quit Hiz Download Manager": "Hiz Download Manager'dan Çık", "Download failed": "İndirme başarısız",
 "%@ needs a new download link. Right-click it and choose Refresh Download Address.":
   "%@ için yeni bir indirme linki gerekiyor. Sağ tıklayıp Linki Yenile'yi seçin.",
}
catalog = {"sourceLanguage": "en", "version": "1.0", "strings": {
    key: {"localizations": {"tr": {"stringUnit": {"state": "translated", "value": value}}}} for key, value in sorted(tr.items())}}
catalog["strings"]["Hiz Download Manager"] = {"shouldTranslate": False}
path = pathlib.Path("App/Resources/Localizable.xcstrings")
path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"wrote {len(catalog['strings'])} keys")
PY
```

- [ ] **Step 3: Build and check coverage**

Run: `make project && make app && python3 scripts/check-strings.py`
Expected: `… 0 missing`. If keys are listed, add each one with its Turkish translation to `Localizable.xcstrings`. Keep the same JSON shape. Then re-run until it prints 0 missing.

- [ ] **Step 4: Verify the Turkish UI**

Run: `open "build/Build/Products/Debug/Hiz Download Manager.app" --args -AppleLanguages "(tr)"`. Check that:
- The toolbar reads URL Ekle, Devam, Durdur …
- The sidebar reads Tüm İndirmeler, Bitmemiş …
- The settings tabs read Genel, Kayıt Yerleri, Bağlantı.

Screenshot the main window (`screencapture -x /tmp/hdm-tr.png`), then quit.

- [ ] **Step 5: Phase 1 acceptance run (spec §14, Aşama 1)**

1. `make test`: all HDMCore tests pass.
2. Adding downloads: URL Ekle, drag & drop and the clipboard each start a download. A Range-capable file uses multiple connections (the details list shows more than one).
3. Pause, quit (⌘Q), relaunch, Resume: the download continues from the saved percentage and the finished file is intact. Compare a checksum, e.g. `shasum -a 256` against the source's published hash, or download the same file twice and compare.
4. Categories: a `.zip` goes to `~/Downloads/HDM/Compressed`, a `.pdf` to `…/Documents`.
5. Queue: with "Simultaneous downloads: 1", a second download waits as Queued. "Sonra İndir" items start only after Kuyruğu Başlat.
6. The speed limit (global and per download) is honoured.
7. The progress window, segment bar, completion dialog, menu bar speed, Dock badge/progress and notification all work.
8. The English and Turkish UIs are both complete.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(app): add Turkish localisation and string coverage check"
```

---

## Self-Review Notes

- **Spec coverage:**

| Spec section | Task(s) |
|---|---|
| §5.1 model | 2 |
| §5.2 persistence | 10, 11 |
| §5.3 segmentation | 3, 6, 9 |
| §5.4 resume | 9, 11 |
| §5.5 errors, link refresh | 9, 11, 13 |
| §5.6 names | 4 |
| §5.7 speed limit, queue | 5, 11 |
| §5.8 categories | 2, 15 |
| §6.1 main window | 12, 13 |
| §6.2 dialogs | 13 |
| §6.3 progress | 14 |
| §6.4 Mac extras | 16 |
| §6.5 clipboard | 13 |
| §6.6 settings (Phase 1 tabs) | 15 |
| §10 quarantine, 0600, no shell | 10, 11 |
| §11 unit and integration tests | 2–11 |

- **Deferred to their phases, per spec §14:**
  - §6.7 first-run browser screen: Phase 2.
  - Settings tabs Browsers and Exceptions: Phase 2. Video: Phase 3.
  - IPC (`HDMIPC`): Phase 2.
  - `media` kind: Phase 3.
  - CI and release: Phase 4.
- **Type consistency:** `DownloadManager.pause(_:)` is async everywhere, and callers wrap it in `Task`. `remove(_:deleteFiles:)` takes a `Set<UUID>`. `WindowCoordinator.progressKey` is used in Tasks 14 and 16. `ManagerEvent` cases match `AppModel+Events`.
