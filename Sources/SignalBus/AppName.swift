import Darwin

/// One name per app, however many processes it runs as.
///
/// `nettop` reports each *process* by its kernel name, cut to 15 characters, so one app shows
/// up several times: "Brave Browser H" (its helpers), "Code Helper" and "Code Helper (Pl" (VS
/// Code), "2.1.322" and "2.1.323" (two versions of a CLI installed as `versions/<n>`). Looking
/// the pid's executable up gives the full path, and the app bundle it lives in names the app.
public enum AppName {
    /// The app a process belongs to, from its pid; falls back to tidying nettop's name.
    public static func resolve(processName: String, pid: Int32) -> String {
        if let path = executablePath(pid: pid), let name = fromPath(path) { return name }
        return tidy(processName)
    }

    /// The executable of a running process, or nil if it has gone or can't be read.
    public static func executablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The app name for an executable path:
    /// - inside an app bundle, the outermost bundle ("…/Brave Browser.app/…/Brave Browser
    ///   Helper (Renderer).app/Contents/MacOS/…" → "Brave Browser"); tools that only ship inside
    ///   one (Xcode's `Contents/Developer/usr/bin/git`) keep their own name;
    /// - an XPC service, its bundle name ("com.apple.WebKit.Networking");
    /// - a binary named for its version ("…/claude/versions/2.1.322") takes the folder's name;
    /// - anything else, the file name, untruncated.
    public static func fromPath(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let file = parts.last, !file.isEmpty else { return nil }
        if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let inside = parts[(i + 1)...]
            if inside.first != "Contents" || inside.dropFirst().first != "Developer" {
                return tidy(String(parts[i].dropLast(4)))
            }
        }
        if let x = parts.lastIndex(where: { $0.hasSuffix(".xpc") }) { return String(parts[x].dropLast(4)) }
        if isVersion(file) {
            let skip: Set<String> = ["versions", "version", "bin", "current", "libexec"]
            if let named = parts.dropLast().reversed().first(where: { !isVersion($0) && !skip.contains($0.lowercased()) }) {
                return named
            }
        }
        return file
    }

    /// Best guess from nettop's (truncated) name alone: drop helper suffixes, so "Code Helper
    /// (Pl", "Spotify Helper" and "Brave Browser H" become "Code", "Spotify", "Brave Browser".
    public static func tidy(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // A trailing "(Plugin)", "(Renderer)" or a cut-off "(Pl".
        if words.count > 1, words.last?.hasPrefix("(") == true { words.removeLast() }
        guard words.count > 1, let last = words.last else { return trimmed }
        // "Helper" in full, or its start when nettop cut the name at 15 characters.
        if last == "Helper" || (trimmed.count >= 15 && last.count < 6 && "Helper".hasPrefix(last)) {
            words.removeLast()
            return words.joined(separator: " ")
        }
        return trimmed
    }

    /// Whether a name written in a scene (an ignore entry, a motif's match) means this app.
    /// Also matches names saved before apps were named in full: the truncated "identityservice"
    /// is "identityservicesd", and "Brave Browser H" is "Brave Browser".
    public static func same(_ written: String, _ app: String) -> Bool {
        let w = written.trimmingCharacters(in: .whitespaces)
        if w.caseInsensitiveCompare(app) == .orderedSame { return true }
        if tidy(w).caseInsensitiveCompare(app) == .orderedSame { return true }
        return w.count == 15 && app.count > 15 && app.lowercased().hasPrefix(w.lowercased())
    }

    private static func isVersion(_ s: String) -> Bool {
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count >= 2 && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

extension Collection where Element == String {
    /// Whether any written name (see `AppName.same`) means this app.
    public func containsApp(_ app: String) -> Bool { contains { AppName.same($0, app) } }
}
