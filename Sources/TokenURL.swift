import Foundation

/// Parse the launcher's saved `http://127.0.0.1:<port>/?token=…` URL.
enum TokenURL {
    static func parse(_ text: String, port: Int) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http",
              url.port == port,
              url.host == "127.0.0.1" || url.host == "localhost" else { return nil }
        return url
    }
}
