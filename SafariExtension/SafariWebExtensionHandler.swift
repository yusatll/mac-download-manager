import Foundation
import HDMIPC
import SafariServices

/// Relays `browser.runtime.sendNativeMessage` frames from the Safari extension to the app's
/// socket (spec §7.2). The wire format is the same flat JSON the app's HDMIPC speaks.
final class SafariWebExtensionHandler: SFSafariExtensionHandler {
    /// `NSExtensionContext` is main-thread-only; the box crosses the async boundary so the
    /// reply can hop back to the main actor (beginRequest itself is called on the main thread).
    private final class MainThreadBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    override func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?
            .userInfo?[SFExtensionMessageKey] as? [String: Any]

        guard let message,
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
              let request = try? JSONDecoder().decode(IPCMessage.self, from: data) else {
            reply(to: context, with: ["ok": false, "error": "bad_request"])
            return
        }

        let box = MainThreadBox(context)
        Task.detached {
            let response: IPCResponse
            do {
                response = try await IPCClient.request(request, timeout: 35)
            } catch {
                // The sandboxed appex cannot launch the app itself (spec §7.2): the extension
                // shows its "open HDM" hint instead.
                response = IPCResponse(id: request.id, ok: false, error: "app_unavailable")
            }
            let payload = Self.payload(from: response)
            await MainActor.run {
                let item = NSExtensionItem()
                item.userInfo = [SFExtensionMessageKey: payload]
                box.value.completeRequest(returningItems: [item], completionHandler: nil)
            }
        }
    }

    private func reply(to context: NSExtensionContext, with message: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    /// `sendNativeMessage` resolves with this dictionary, so it must be JSON-safe.
    private static func payload(from response: IPCResponse) -> [String: Any] {
        var payload: [String: Any] = ["v": IPCProtocol.version, "id": response.id, "ok": response.ok]
        if let error = response.error { payload["error"] = error }
        if let hello = response.hello, let json = encode(hello) { payload["hello"] = json }
        if let mediaQuery = response.mediaQuery, let json = encode(mediaQuery) { payload["mediaQuery"] = json }
        return payload
    }

    private static func encode<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
