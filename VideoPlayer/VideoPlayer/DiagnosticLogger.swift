import Foundation

/// Writes timestamped diagnostic lines to a plain text file so the network
/// stall bug can be pinpointed from a real device without Xcode attached.
/// View/copy/share it from Settings → PikPak → Auto Download → Diagnostics Log.
enum DiagnosticLogger {
    private static let queue = DispatchQueue(label: "com.mortaza.minoz.VideoPlayer.diagnostics", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("network_diagnostics.log")
    }

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            let url = fileURL
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(no log entries yet)"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
