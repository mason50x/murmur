import Foundation

/// Last 50 transcripts, kept only on this Mac in Application Support (readable by you alone).
/// Turning history off in Settings deletes the file and keeps transcripts in memory only.
@MainActor
final class History {
    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        let text: String
        /// The same words laid out as paragraphs/lists, when that reads better.
        var layout: String?
        let date: Date
    }

    private(set) var entries: [Entry] = []
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("history.json")
    }()

    /// Whether transcripts are saved to disk (Settings › Privacy).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepHistory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepHistory") }
    }

    init() {
        guard Self.isEnabled else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        {
            entries = decoded
        }
    }

    func add(_ text: String, layout: String?) {
        entries.insert(Entry(text: text, layout: layout, date: Date()), at: 0)
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
        save()
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    /// Applies a change to `isEnabled`: off deletes the saved file (memory keeps this session's).
    func enabledChanged() {
        if Self.isEnabled { save() } else { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        guard Self.isEnabled, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
