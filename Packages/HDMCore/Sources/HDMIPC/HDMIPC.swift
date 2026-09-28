import Foundation

/// Wire protocol shared by the app, `hdm-bridge` and the Safari extension (spec §7.1).
/// Framing matches Chrome native messaging exactly — 4-byte little-endian length + UTF-8 JSON —
/// so the bridge relays bytes without re-encoding.
public enum IPCProtocol {
    public static let version = 1
    /// Requests (extension → app) may be large (downloadLinks).
    public static let maxRequestBytes = 16 << 20
    /// Responses (app → extension) must fit Chrome's host→browser limit.
    public static let maxResponseBytes = 1 << 20

    /// Where the app listens: the app-group container when a team is configured
    /// (`HDMDevelopmentTeam` is baked into the Info.plist at build time; the sandboxed Safari
    /// appex may only reach that container). An existing `*.com.hizdm.shared` container always
    /// wins, so a bridge spawned without a bundle lands on the same path the app created.
    /// Falls back to `fallbackSocketPath()` when no team is known.
    public static func socketPath() -> URL {
        if let override = ProcessInfo.processInfo.environment["HDM_SOCKET_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let containers = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Group Containers", isDirectory: true)
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: containers.path),
           let group = names.first(where: { $0.hasSuffix(".com.hizdm.shared") }) {
            return containers.appendingPathComponent(group, isDirectory: true).appendingPathComponent("hdm.sock", isDirectory: false)
        }
        let team = (Bundle.main.object(forInfoDictionaryKey: "HDMDevelopmentTeam") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if team.range(of: "^[A-Z0-9]{8,12}$", options: .regularExpression) != nil {
            return containers.appendingPathComponent("\(team).com.hizdm.shared", isDirectory: true)
                .appendingPathComponent("hdm.sock", isDirectory: false)
        }
        return fallbackSocketPath()
    }

    /// Without a team (CI, unsigned builds) the app and the bridge still meet here.
    /// The sandboxed Safari appex cannot reach this path; it reports `app_unavailable`.
    public static func fallbackSocketPath() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HDM", isDirectory: true)
            .appendingPathComponent("hdm.sock", isDirectory: false)
    }
}

// MARK: - Envelope

/// A request from the extension. Body fields live flat at the top level of the JSON
/// next to `v`/`id`/`type`, which keeps the protocol inspectable and Chrome-friendly.
public struct IPCMessage: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var type: String
    public var payload: Payload

    public init(id: String = UUID().uuidString, type: String, payload: Payload = .none) {
        self.v = IPCProtocol.version
        self.id = id
        self.type = type
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey { case v, id, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        guard v == IPCProtocol.version else { throw IPCError.unsupportedVersion(v) }
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        payload = try Payload(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try payload.encode(to: encoder)   // body fields land flat next to the envelope keys
    }

    /// Requests only; replies always travel as `IPCResponse`.
    public enum Payload: Codable, Equatable, Sendable {
        case none
        case hello(HelloIn)
        case download(DownloadIn)
        case downloadLinks(DownloadLinksIn)
        case mediaQuery(MediaQueryIn)
        case mediaDownload(MediaDownloadIn)

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            let v = try c.decode(Int.self, forKey: .v)
            guard v == IPCProtocol.version else { throw IPCError.unsupportedVersion(v) }
            switch type {
            case "hello": self = .hello(try HelloIn(from: decoder))
            case "download": self = .download(try DownloadIn(from: decoder))
            case "downloadLinks": self = .downloadLinks(try DownloadLinksIn(from: decoder))
            case "mediaQuery": self = .mediaQuery(try MediaQueryIn(from: decoder))
            case "mediaDownload": self = .mediaDownload(try MediaDownloadIn(from: decoder))
            case "ping": self = .none
            default: throw IPCError.unknownMessageType(type)
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .none: break
            case .hello(let value): try value.encode(to: encoder)
            case .download(let value): try value.encode(to: encoder)
            case .downloadLinks(let value): try value.encode(to: encoder)
            case .mediaQuery(let value): try value.encode(to: encoder)
            case .mediaDownload(let value): try value.encode(to: encoder)
            }
        }

        enum CodingKeys: String, CodingKey { case v, type }
    }
}

public enum IPCError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case unknownMessageType(String)
    case malformed(String)
    case tooLarge(Int)
}

// MARK: - Message bodies

public struct HelloIn: Codable, Equatable, Sendable {
    public var browser: String
    public var extensionVersion: String

    public init(browser: String, extensionVersion: String) {
        self.browser = browser
        self.extensionVersion = extensionVersion
    }
}

/// The snapshot of settings the extension caches (spec §7.1 hello).
public struct HelloOut: Codable, Equatable, Sendable {
    public var appVersion: String
    public var captureEnabled: Bool
    public var fileTypes: [String]
    public var exceptions: [String]
    public var minimumSizeBytes: Int64
    public var panelEnabled: Bool
    public var defaultQualityNote: String?

    public init(appVersion: String, captureEnabled: Bool, fileTypes: [String], exceptions: [String],
                minimumSizeBytes: Int64, panelEnabled: Bool) {
        self.appVersion = appVersion
        self.captureEnabled = captureEnabled
        self.fileTypes = fileTypes
        self.exceptions = exceptions
        self.minimumSizeBytes = minimumSizeBytes
        self.panelEnabled = panelEnabled
    }
}

public struct DownloadIn: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case capture, context, click }

    public var url: URL
    public var finalUrl: URL?
    public var referrer: URL?
    public var pageUrl: URL?
    public var filename: String?
    public var mime: String?
    public var size: Int64?
    public var cookies: String?
    public var userAgent: String?
    public var source: Source

    public init(url: URL, finalUrl: URL? = nil, referrer: URL? = nil, pageUrl: URL? = nil,
                filename: String? = nil, mime: String? = nil, size: Int64? = nil,
                cookies: String? = nil, userAgent: String? = nil, source: Source) {
        self.url = url
        self.finalUrl = finalUrl
        self.referrer = referrer
        self.pageUrl = pageUrl
        self.filename = filename
        self.mime = mime
        self.size = size
        self.cookies = cookies
        self.userAgent = userAgent
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try Self.httpURL(c, .url)
        finalUrl = try Self.httpURLOrNil(c, .finalUrl)
        referrer = try Self.httpURLOrNil(c, .referrer)
        pageUrl = try Self.httpURLOrNil(c, .pageUrl)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        mime = try c.decodeIfPresent(String.self, forKey: .mime)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        cookies = try c.decodeIfPresent(String.self, forKey: .cookies)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .capture
    }

    enum CodingKeys: String, CodingKey {
        case url, finalUrl, referrer, pageUrl, filename, mime, size, cookies, userAgent, source
    }

    /// Incoming URLs must be plain http(s) (spec §10); anything else is rejected, not coerced.
    static func httpURL<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> URL {
        guard let url = try c.decodeIfPresent(URL.self, forKey: key),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw IPCError.malformed("\(key.stringValue) must be an http(s) URL")
        }
        return url
    }

    static func httpURLOrNil<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> URL? {
        guard try c.decodeIfPresent(URL.self, forKey: key) != nil else { return nil }
        return try httpURL(c, key)
    }
}

public struct DownloadLinksIn: Codable, Equatable, Sendable {
    public struct Link: Codable, Equatable, Sendable {
        public var url: URL
        public var text: String

        public init(url: URL, text: String) {
            self.url = url
            self.text = text
        }
    }

    public var links: [Link]
    public var pageUrl: URL?
    public var cookies: String?
    public var userAgent: String?

    public init(links: [Link], pageUrl: URL?, cookies: String? = nil, userAgent: String? = nil) {
        self.links = links
        self.pageUrl = pageUrl
        self.cookies = cookies
        self.userAgent = userAgent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        links = try c.decodeIfPresent([Link].self, forKey: .links) ?? []
        pageUrl = (try? DownloadIn.httpURL(c, CodingKeys.pageUrl)) ?? nil
        cookies = try c.decodeIfPresent(String.self, forKey: .cookies)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
    }

    enum CodingKeys: String, CodingKey { case links, pageUrl, cookies, userAgent }
}

public struct MediaQueryIn: Codable, Equatable, Sendable {
    public struct Stream: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case file, hls, dash }

        public var url: URL
        public var kind: Kind
        public var mime: String?

        public init(url: URL, kind: Kind, mime: String? = nil) {
            self.url = url
            self.kind = kind
            self.mime = mime
        }
    }

    public var pageUrl: URL
    public var title: String?
    public var streams: [Stream]
    public var cookies: String?
    public var userAgent: String?
    public var referrer: URL?

    public init(pageUrl: URL, title: String? = nil, streams: [Stream] = [], cookies: String? = nil,
                userAgent: String? = nil, referrer: URL? = nil) {
        self.pageUrl = pageUrl
        self.title = title
        self.streams = streams
        self.cookies = cookies
        self.userAgent = userAgent
        self.referrer = referrer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageUrl = (try? DownloadIn.httpURL(c, CodingKeys.pageUrl))
            ?? URL(string: "https://invalid.invalid")!
        title = try c.decodeIfPresent(String.self, forKey: .title)
        streams = try c.decodeIfPresent([Stream].self, forKey: .streams) ?? []
        cookies = try c.decodeIfPresent(String.self, forKey: .cookies)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        referrer = (try? DownloadIn.httpURL(c, CodingKeys.referrer)) ?? nil
    }

    enum CodingKeys: String, CodingKey { case pageUrl, title, streams, cookies, userAgent, referrer }
}

public struct MediaQueryOut: Codable, Equatable, Sendable {
    public struct Format: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var ext: String
        public var approxSize: Int64?
        public var note: String?

        public init(id: String, label: String, ext: String, approxSize: Int64?, note: String?) {
            self.id = id
            self.label = label
            self.ext = ext
            self.approxSize = approxSize
            self.note = note
        }
    }

    public var queryId: String
    public var title: String
    public var formats: [Format]
    public var drm: Bool

    public init(queryId: String, title: String, formats: [Format], drm: Bool = false) {
        self.queryId = queryId
        self.title = title
        self.formats = formats
        self.drm = drm
    }
}

public struct MediaDownloadIn: Codable, Equatable, Sendable {
    public var queryId: String
    public var formatId: String
    public var saveTo: URL?

    public init(queryId: String, formatId: String) {
        self.queryId = queryId
        self.formatId = formatId
        self.saveTo = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queryId = try c.decode(String.self, forKey: .queryId)
        formatId = try c.decode(String.self, forKey: .formatId)
        // The extension may never choose the destination (spec §10); ignore any value it sends.
        saveTo = nil
    }

    enum CodingKeys: String, CodingKey { case queryId, formatId, saveTo }
}

// MARK: - Responses

/// Every request gets exactly one reply carrying the same `id`.
public struct IPCResponse: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var ok: Bool
    public var error: String?
    public var hello: HelloOut?
    public var mediaQuery: MediaQueryOut?

    public init(id: String, ok: Bool = true, error: String? = nil,
                hello: HelloOut? = nil, mediaQuery: MediaQueryOut? = nil) {
        self.v = IPCProtocol.version
        self.id = id
        self.ok = ok
        self.error = error
        self.hello = hello
        self.mediaQuery = mediaQuery
    }
}

// MARK: - Framing

public enum IPCFrame {
    /// 4-byte little-endian length prefix + the JSON body.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        var length = UInt32(littleEndian: UInt32(body.count))
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    public static func decodeLength(_ header: Data) -> UInt32? {
        guard header.count == 4 else { return nil }
        let bytes = [UInt8](header)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}
