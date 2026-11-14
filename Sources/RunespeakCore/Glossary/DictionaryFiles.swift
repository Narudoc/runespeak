import Foundation

/// The dictionary files the app ships (Contents/Resources/data in the bundle, generated into the
/// repository's data/ folder) and their upkeep in the user's data folder.
public enum DictionaryFiles {
    public static let nicknames = "nicknames.tsv"

    public static func names(for flavor: GameFlavor) -> (officialNames: String, abbreviations: String, chatCommands: String) {
        let suffix = flavor == .retail ? "retail" : "classic"
        return ("official_names.\(suffix).tsv", "abbreviations.\(suffix).tsv", "chat_commands.\(suffix).tsv")
    }

    /// Every file a complete data folder holds.
    public static var all: [String] {
        var out: [String] = []
        for flavor in [GameFlavor.classic, .retail] {
            let files = names(for: flavor)
            out += [files.officialNames, files.abbreviations, files.chatCommands]
        }
        return out + [nicknames]
    }

    public struct Report: Sendable, Equatable {
        /// Names of the files written or removed.
        public var changed: [String] = []
        /// "file: reason" for each one that could not be.
        public var failures: [String] = []
    }

    /// Copies each .tsv file of `bundled` that the data folder lacks or holds with other
    /// content (an older or newer build's), and removes .tsv files the bundle no longer ships.
    /// Nothing in the data folder is the user's — their entries live in my_terms.tsv and
    /// corrections.tsv next to it — so replacing is safe.
    @discardableResult
    public static func seed(from bundled: URL, to paths: AppPaths) -> Report {
        var report = Report()
        let fm = FileManager.default
        do {
            try paths.ensureDirectories()
        } catch {
            report.failures.append("data: \(error.localizedDescription)")
            return report
        }
        guard let found = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return report
        }
        var shipped = Set(all)
        for source in found.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where source.pathExtension.lowercased() == "tsv" {
            let name = source.lastPathComponent
            shipped.insert(name)
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let wanted = try? Data(contentsOf: source), !wanted.isEmpty else { continue }
            let target = paths.dataDirectory.appendingPathComponent(name)
            if let present = try? Data(contentsOf: target), present == wanted { continue }
            do {
                try wanted.write(to: target, options: .atomic)
                report.changed.append(name)
            } catch {
                report.failures.append("\(name): \(error.localizedDescription)")
            }
        }
        // A .tsv the bundle does not ship is not a dictionary file of this build.
        let present = (try? fm.contentsOfDirectory(atPath: paths.dataDirectory.path)) ?? []
        for name in present.sorted() where name.lowercased().hasSuffix(".tsv") && !shipped.contains(name) {
            do {
                try fm.removeItem(at: paths.dataDirectory.appendingPathComponent(name))
                report.changed.append(name)
            } catch {
                report.failures.append("\(name): \(error.localizedDescription)")
            }
        }
        return report
    }
}
