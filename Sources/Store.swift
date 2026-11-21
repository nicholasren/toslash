import Foundation

let namePattern = try! Regex("[A-Za-z0-9][A-Za-z0-9._-]*")

struct Link: Codable, Equatable {
    var url: String
    var description: String?
    var created: Date
}

func check(name: String, url: String) -> String? {
    if name.wholeMatch(of: namePattern) == nil {
        return "Bad name \"\(name)\": use letters, digits, '.', '_', '-'."
    }
    guard let scheme = URLComponents(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
        return "Bad URL \"\(url)\": it must start with http:// or https://."
    }
    return nil
}

/// Links in one JSON file, read on every access so hand edits show up at once.
/// The lock serializes read-modify-write between the server's request threads.
final class Store {
    static let shared = Store()
    let file: URL
    private let lock = NSLock()

    private init() {
        if let path = UserDefaults.standard.string(forKey: "store") {
            file = URL(fileURLWithPath: path)
        } else {
            file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ToSlash/links.json")
        }
    }

    var links: [(name: String, link: Link)] {
        lock.lock()
        defer { lock.unlock() }
        let links = (try? read()) ?? [:]
        return links.keys.sorted().map { ($0, links[$0]!) }
    }

    func link(_ name: String) -> Link? {
        lock.lock()
        defer { lock.unlock() }
        return (try? read())?[name]
    }

    /// Creates `name` or updates it in place, keeping its created date, so an agent can safely retry.
    func put(name: String, url: String, description: String?) -> String? {
        if let error = check(name: name, url: url) { return error }
        return change { links in
            links[name] = Link(url: url, description: description.flatMap(nonEmpty), created: links[name]?.created ?? Date())
            return nil
        }
    }

    /// Saves the to/ page form: adds `name`, or renames and updates `old`. Refuses to overwrite a different link.
    func save(name: String, url: String, description: String?, replacing old: String?) -> String? {
        if let error = check(name: name, url: url) { return error }
        return change { links in
            if links[name] != nil, name != old { return "\"\(name)\" already exists." }
            let created = old.flatMap { links[$0]?.created } ?? Date()
            if let old { links[old] = nil }
            links[name] = Link(url: url, description: description.flatMap(nonEmpty), created: created)
            return nil
        }
    }

    func remove(_ name: String) -> String? {
        change { links in
            links[name] = nil
            return nil
        }
    }

    private func read() throws -> [String: Link] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: Link].self, from: Data(contentsOf: file))
    }

    private func change(_ body: (inout [String: Link]) -> String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // An unreadable file is never overwritten, or one bad hand edit would erase every link.
        var links: [String: Link]
        do { links = try read() } catch { return "\(file.path) could not be read, so nothing was saved: \(error)" }
        if let error = body(&links) { return error }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(links).write(to: file, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private func nonEmpty(_ s: String) -> String? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
