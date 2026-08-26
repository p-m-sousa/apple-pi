import Foundation

public enum DiagnosticsRedactor {
    private static let sensitiveKeyPattern = try! NSRegularExpression(
        pattern: #"(?i)(api[_-]?key|auth[_-]?token|bearer|password|secret)\s*[:=]\s*([^\s,;]+)"#
    )
    private static let bearerPattern = try! NSRegularExpression(
        pattern: #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#
    )

    public static func redact(_ text: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        var result = sensitiveKeyPattern.stringByReplacingMatches(
            in: text,
            range: fullRange,
            withTemplate: "$1=<redacted>"
        )
        result = bearerPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "Bearer <redacted>"
        )
        return result.replacingOccurrences(of: homeDirectory.path, with: "~")
    }
}
