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
