import Foundation
import Testing
@testable import HDMCore

@Suite struct ComponentLocatorTests {
    @Test func searchOrderPrefersAppBinThenExtraDirsThenPath() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdm-locator-\(UUID().uuidString)", isDirectory: true)
        let appBin = temp.appendingPathComponent("appbin", isDirectory: true)
        let brewBin = temp.appendingPathComponent("brew", isDirectory: true)
        let localBin = temp.appendingPathComponent("local", isDirectory: true)
        let pathDir = temp.appendingPathComponent("pathdir", isDirectory: true)
        for dir in [appBin, brewBin, localBin, pathDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func makeTool(_ dir: URL, _ name: String) throws {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try makeTool(brewBin, "yt-dlp")
        try makeTool(localBin, "yt-dlp")
        try makeTool(pathDir, "yt-dlp")
        try makeTool(appBin, "yt-dlp")
        try makeTool(appBin, "ffmpeg")
        try makeTool(pathDir, "deno")

        let paths = ComponentLocator.locate(appBin: appBin, extraDirectories: [brewBin, localBin],
                                            pathEnv: [pathDir.path, "/nonexistent"].joined(separator: ":"))
        #expect(paths.ytDLP == appBin.appendingPathComponent("yt-dlp"))   // app bin wins
        #expect(paths.ffmpeg == appBin.appendingPathComponent("ffmpeg"))
        #expect(paths.deno == pathDir.appendingPathComponent("deno"))     // only PATH has it
        try? FileManager.default.removeItem(at: temp)
    }

    @Test func skipsNonExecutableFiles() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdm-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let plain = temp.appendingPathComponent("yt-dlp")
        try "not executable".write(to: plain, atomically: true, encoding: .utf8)
        let paths = ComponentLocator.locate(appBin: temp, extraDirectories: [], pathEnv: "")
        #expect(paths.ytDLP == nil)
        try? FileManager.default.removeItem(at: temp)
    }
}
