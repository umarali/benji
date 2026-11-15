import Foundation

/// Log files only this user can read. Swift twin of `benji/private_file.py`: a file is
/// created mode 0600, one that already exists with a wider mode is tightened the first time it is
/// written, a folder this creates is 0700 and one that exists is left alone, and rotation keeps
/// `keep` older copies (`name.1` newest), each 0600, so a log stays bounded.
public enum PrivateFile {
    public static let fileMode: mode_t = 0o600
    public static let folderMode: mode_t = 0o700

    /// The permission bits of a file, or nil when it isn't there.
    public static func mode(of url: URL) -> mode_t? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_mode & 0o7777 : nil
    }

    /// Make an existing plain file 0600 if it is wider. Never follows a symlink, never touches a
    /// folder. True when it changed.
    @discardableResult
    public static func tighten(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o077 != 0 else { return false }
        return chmod(url.path, fileMode) == 0
    }

    private static func size(_ url: URL) -> Int {
        var st = stat()
        return lstat(url.path, &st) == 0 ? Int(st.st_size) : 0
    }

    /// name -> name.1 -> name.2 ... name.<keep>; the oldest goes. Each copy is 0600.
    public static func rotate(_ url: URL, keep: Int) {
        let fm = FileManager.default
        func copy(_ i: Int) -> URL { url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(i)") }
        try? fm.removeItem(at: copy(keep))
        for i in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: copy(i).path) {
            try? fm.removeItem(at: copy(i + 1))
            try? fm.moveItem(at: copy(i), to: copy(i + 1))
            tighten(copy(i + 1))
        }
        try? fm.removeItem(at: copy(1))
        try? fm.moveItem(at: url, to: copy(1))
        tighten(copy(1))
    }

    /// Append `data` to `url` (created 0600), rotating first when it would pass `maxBytes`. One
    /// `write` on an `O_APPEND` descriptor, so the engine and the app can both append to one file.
    public static func append(_ data: Data, to url: URL, maxBytes: Int? = nil, keep: Int = 1) throws {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: Int(folderMode)])
        }
        for i in 1...max(keep, 1) {
            tighten(folder.appendingPathComponent("\(url.lastPathComponent).\(i)"))
        }
        let current = size(url)
        if let maxBytes, current > 0, current + data.count > maxBytes { rotate(url, keep: keep) }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, fileMode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_mode & 0o077 != 0 { fchmod(fd, fileMode) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += n
            }
        }
    }
}
