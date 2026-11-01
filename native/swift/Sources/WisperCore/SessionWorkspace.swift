import Darwin
import Foundation

/// Owns exactly one private session directory, its lock/identity marker, and audio.wav.
/// Cleanup uses openat/unlinkat, never recursive deletion or symlink traversal.
final class SessionWorkspace {
    static let rootName = "open-wisper-swift-sessions-v1-\(getuid())"
    private static let markerName = ".owner"
    private static let audioName = "audio.wav"
    let directoryURL: URL
    var audioURL: URL { directoryURL.appendingPathComponent(Self.audioName) }
    private let name: String
    private let rootFD: Int32
    private let directoryFD: Int32
    private let markerFD: Int32
    private var cleaned = false

    /// rootURL is only injectable internally for isolated tests, not supplied by profile JSON.
    init(rootURL: URL = SessionWorkspace.defaultRoot) throws {
        let root = try Self.openRoot(rootURL)
        let identifier = UUID().uuidString.lowercased()
        let name = "session-" + identifier
        var directory: Int32 = -1
        var marker: Int32 = -1
        var madeDirectory = false
        do {
            guard mkdirat(root, name, 0o700) == 0 else { throw EngineError.workspaceUnavailable }
            madeDirectory = true
            directory = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0, fchmod(directory, 0o700) == 0 else { throw EngineError.workspaceUnavailable }
            marker = openat(directory, Self.markerName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard marker >= 0, fchmod(marker, 0o600) == 0,
                  flock(marker, LOCK_EX | LOCK_NB) == 0 else { throw EngineError.workspaceUnavailable }
            try Self.writeAll(Data(Self.marker(identifier).utf8), to: marker)
            self.rootFD = root
            self.directoryFD = directory
            self.markerFD = marker
            self.name = name
            self.directoryURL = rootURL.appendingPathComponent(name, isDirectory: true)
        } catch {
            if marker >= 0 { unlinkat(directory, Self.markerName, 0); close(marker) }
            if directory >= 0 { close(directory) }
            if madeDirectory { unlinkat(root, name, AT_REMOVEDIR) }
            close(root)
            throw EngineError.workspaceUnavailable
        }
    }

    deinit {
        try? cleanup()
        close(markerFD)
        close(directoryFD)
        close(rootFD)
    }

    func writeAudio(_ data: Data) throws {
        guard !cleaned else { throw EngineError.workspaceUnavailable }
        let fd = openat(directoryFD, Self.audioName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw EngineError.workspaceUnavailable }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw EngineError.workspaceUnavailable }
        try Self.writeAll(data, to: fd)
    }

    func cleanup() throws {
        guard !cleaned else { return }
        guard try Self.removeOwned(root: rootFD, name: name, directory: directoryFD, marker: markerFD) else {
            throw EngineError.cleanupFailed
        }
        cleaned = true
    }

    static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(rootName, isDirectory: true)
    }

    /// Recovery only admits UUID names, exact marker bytes, 0700 directories, 0600 regular
    /// files, the current uid, and an obtainable exclusive lock. Active sessions are skipped.
    @discardableResult
    static func recoverStale(rootURL: URL = defaultRoot, olderThan age: TimeInterval = 86_400) throws -> Int {
        guard age.isFinite, age >= 0 else { throw EngineError.workspaceUnavailable }
        let root = try openRoot(rootURL)
        defer { close(root) }
        var removed = 0
        for name in try entries(root, limit: 4_096) {
            guard validName(name) else { continue }
            let directory = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            var info = stat()
            guard fstat(directory, &info) == 0, ownedDirectory(info),
                  Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= age else { continue }
            let marker = openat(directory, markerName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard marker >= 0 else { continue }
            defer { close(marker) }
            guard flock(marker, LOCK_EX | LOCK_NB) == 0 else { continue }
            if (try? removeOwned(root: root, name: name, directory: directory, marker: marker)) == true {
                removed += 1
            }
        }
        return removed
    }

    private static func marker(_ identifier: String) -> String {
        "open-wisper-swift-session-v1\n\(identifier)\n"
    }

    private static func validName(_ name: String) -> Bool {
        guard name.hasPrefix("session-"), name.count == 44 else { return false }
        let identifier = String(name.dropFirst(8))
        return UUID(uuidString: identifier)?.uuidString.lowercased() == identifier
    }

    private static func ownedDirectory(_ info: stat) -> Bool {
        info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o7777 == 0o700
    }

    private static func ownedFile(_ info: stat) -> Bool {
        info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1
    }

    private static func openRoot(_ url: URL) throws -> Int32 {
        do {
            let parent = try EngineFiles.openDirectory(url.deletingLastPathComponent())
            defer { close(parent) }
            if mkdirat(parent, url.lastPathComponent, 0o700) != 0 && errno != EEXIST {
                throw EngineError.workspaceUnavailable
            }
            let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw EngineError.workspaceUnavailable }
            var info = stat()
            guard fstat(fd, &info) == 0, ownedDirectory(info) else {
                close(fd)
                throw EngineError.workspaceUnavailable
            }
            return fd
        } catch { throw EngineError.workspaceUnavailable }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw EngineError.workspaceUnavailable }
                written += count
            }
        }
    }

    private static func entries(_ fd: Int32, limit: Int) throws -> [String] {
        let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scan >= 0 else { throw EngineError.cleanupFailed }
        guard let stream = fdopendir(scan) else { close(scan); throw EngineError.cleanupFailed }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw EngineError.cleanupFailed }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < limit else { throw EngineError.cleanupFailed }
            names.append(name)
        }
    }

    private static func removeOwned(root: Int32, name: String, directory: Int32, marker: Int32) throws -> Bool {
        guard validName(name) else { return false }
        var actual = stat()
        var named = stat()
        var markerInfo = stat()
        guard fstat(directory, &actual) == 0, ownedDirectory(actual),
              fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_ino == actual.st_ino, named.st_dev == actual.st_dev,
              fstat(marker, &markerInfo) == 0, ownedFile(markerInfo), markerInfo.st_size <= 128,
              lseek(marker, 0, SEEK_SET) == 0,
              try EngineFiles.read(marker, limit: 128, checkCancellation: false) == Data(Self.marker(String(name.dropFirst(8))).utf8)
        else { return false }
        let names = try entries(directory, limit: 2)
        guard names.contains(markerName), Set(names).isSubset(of: [markerName, audioName]) else { return false }
        for child in names {
            var info = stat()
            guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0, ownedFile(info) else { return false }
            if child == markerName && (info.st_ino != markerInfo.st_ino || info.st_dev != markerInfo.st_dev) { return false }
        }
        if names.contains(audioName), unlinkat(directory, audioName, 0) != 0 { throw EngineError.cleanupFailed }
        guard unlinkat(directory, markerName, 0) == 0, unlinkat(root, name, AT_REMOVEDIR) == 0 else {
            throw EngineError.cleanupFailed
        }
        return true
    }
}
