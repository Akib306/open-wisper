import Darwin
import Foundation

/// One GUI process per user, even when launched from different bundle copies.
/// Keep the descriptor open for the app lifetime. Never unlink the lock file:
/// stale files are harmless, while unlinking would allow two different owners.
public final class ApplicationInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(at url: URL = SettingsStore().fileURL.deletingLastPathComponent()
        .appendingPathComponent("instance.lock")) throws -> ApplicationInstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WisperError.message("Couldn’t open the app instance lock.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else {
            close(fd)
            throw WisperError.message("The app instance lock must be a regular file owned by this user.")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK { return nil }
            throw WisperError.message("Couldn’t acquire the app instance lock.")
        }
        guard fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw WisperError.message("Couldn’t protect the app instance lock.")
        }
        return ApplicationInstanceLock(descriptor: fd)
    }

    deinit { close(descriptor) }
}
