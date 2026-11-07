import Foundation

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    public static func string(_ bytes: UInt64) -> String { string(Int64(clamping: bytes)) }
    public static func string(_ bytes: Int) -> String { string(Int64(bytes)) }
}

/// Dates in plan copy (labels, banners, Readiness, the issuer's errors). Pinned to one locale so every surface and
/// every test machine reads the same "1 Nov 2026".
public enum DayFormat {
    static let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_GB"))
    public static func string(_ date: Date) -> String { date.formatted(style) }
}

public enum DurationFormat {
    public static func string(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
