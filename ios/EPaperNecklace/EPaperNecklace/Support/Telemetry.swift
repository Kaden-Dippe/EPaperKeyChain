import Foundation
import os

/// Debug logging for builds with no debugger attached.
///
/// A TestFlight build is a Release build launched by the user, so `print()`
/// goes nowhere anyone can read. This writes every line to two places:
///
/// - The unified log, always. Readable in Console.app from a Mac, and
///   retrievable on-device later via `OSLogStore` if it ever comes to that.
/// - An ntfy.sh topic, if one is configured. Lines are batched and posted as a
///   single message per operation, readable from the ntfy app on your phone or
///   from `https://ntfy.sh/<topic>` in any browser.
///
/// Configuration lives in a `Telemetry.plist` inside the app folder, which is
/// deliberately untracked: with no such file, remote posting is simply off and
/// nothing leaves the device. See `ios/README.md` for the format.
///
/// Never log the image payload here. Sizes and counts, not pixels.
final class Telemetry {

    static let shared = Telemetry()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "EPaperNecklace",
                                category: "necklace")

    /// Serialises access to the buffer. Callers are usually on the main actor,
    /// but the upload finishes on a URLSession queue.
    private let queue = DispatchQueue(label: "com.epaper.telemetry")

    private var lines: [String] = []
    private var startedAt = Date()

    /// Where to POST, or nil when no topic is configured.
    private let endpoint: URL?

    /// Stops a stuck session from growing an unbounded buffer, and keeps the
    /// batch inside ntfy's per-message size limit.
    private let lineLimit = 150

    var isRemoteEnabled: Bool { endpoint != nil }

    private init() {
        endpoint = Telemetry.configuredEndpoint()
    }

    // MARK: - Recording

    /// Starts a fresh batch. Call at the top of an operation worth reporting.
    func begin(_ title: String) {
        queue.async {
            self.lines.removeAll()
            self.startedAt = Date()
        }
        log(title)
    }

    /// Records one line. Cheap enough to call freely; the network only sees it
    /// when `flush` runs.
    func log(_ message: String) {
        // Dynamic strings in the unified log are redacted unless marked public,
        // which would make every one of these read as <private>.
        logger.log("\(message, privacy: .public)")

        queue.async {
            guard self.lines.count < self.lineLimit else { return }
            let elapsed = Date().timeIntervalSince(self.startedAt)
            self.lines.append(String(format: "%6.2fs  %@", elapsed, message))
        }
    }

    /// Ships everything recorded so far as one message, then clears the batch.
    func flush(_ summary: String) {
        log(summary)

        queue.async {
            let body = self.lines.joined(separator: "\n")
            self.lines.removeAll()

            guard let endpoint = self.endpoint, !body.isEmpty else { return }
            self.post(body, to: endpoint, title: summary)
        }
    }

    // MARK: - Delivery

    private func post(_ body: String, to endpoint: URL, title: String) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 15

        // ntfy takes the notification title from this header and the message
        // from the body. Header values have to be ASCII.
        request.setValue(String(title.filter { $0.isASCII }), forHTTPHeaderField: "Title")

        URLSession.shared.dataTask(with: request) { [logger] _, response, error in
            if let error {
                logger.error("telemetry upload failed: \(error.localizedDescription, privacy: .public)")
            } else if let http = response as? HTTPURLResponse,
                      !(200..<300).contains(http.statusCode) {
                logger.error("telemetry upload rejected: HTTP \(http.statusCode, privacy: .public)")
            }
        }.resume()
    }

    // MARK: - Configuration

    private static func configuredEndpoint() -> URL? {
        guard let url = Bundle.main.url(forResource: "Telemetry", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil)) as? [String: Any],
              let rawTopic = plist["NtfyTopic"] as? String else {
            return nil
        }

        let topic = rawTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return nil }

        var server = (plist["NtfyServer"] as? String) ?? "https://ntfy.sh"
        if server.hasSuffix("/") { server.removeLast() }

        return URL(string: "\(server)/\(topic)")
    }

    // MARK: - Formatting helpers

    /// Status bytes are far easier to recognise in hex than in decimal.
    static func hex(_ byte: UInt8) -> String {
        String(format: "0x%02X", byte)
    }
}
