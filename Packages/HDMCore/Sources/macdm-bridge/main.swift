import AppKit
import Foundation
import HDMIPC

/// Chrome/Brave native-messaging host: reads one framed message from stdin, relays it to the
/// HDM socket, writes the framed reply to stdout and exits (spec §7.2). Chrome launches this
/// binary for every `sendNativeMessage` call.
let appBundleID = "com.macdm.MacDM"

func readSTDIN() throws -> IPCMessage {
    let stdin = FileHandle.standardInput
    guard let header = try stdin.read(upToCount: 4), header.count == 4,
          let length = IPCFrame.decodeLength(header) else {
        throw IPCError.malformed("short header")
    }
    guard length > 0, Int(length) <= IPCProtocol.maxRequestBytes else { throw IPCError.tooLarge(Int(length)) }
    var body = Data()
    while body.count < Int(length) {
        guard let chunk = try stdin.read(upToCount: Int(length) - body.count) else { break }
        body.append(chunk)
    }
    guard body.count == Int(length) else { throw IPCError.malformed("short body") }
    return try IPCFrame.decode(IPCMessage.self, from: body)
}

func launchAppInBackground() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
}

do {
    let message = try readSTDIN()
    let reply = try await IPCClient.request(message, timeout: 35, launchApp: launchAppInBackground)
    FileHandle.standardOutput.write(try IPCFrame.encode(reply))
    exit(0)
} catch let error as IPCError {
    let reason: String
    switch error {
    case .malformed(let message) where message == "app_unavailable": reason = "app_unavailable"
    default: reason = "bridge_error: \(error)"
    }
    FileHandle.standardOutput.write(try IPCFrame.encode(IPCResponse(id: "", ok: false, error: reason)))
    exit(0)   // the reply goes back as a normal message; a non-zero exit would just add noise
} catch {
    // Only a stdin framing failure reaches here: nothing was read, so there is no id to answer.
    FileHandle.standardError.write(Data("macdm-bridge: \(error)\n".utf8))
    exit(1)
}
