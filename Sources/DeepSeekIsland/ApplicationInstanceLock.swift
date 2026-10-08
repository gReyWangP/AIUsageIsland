import Darwin
import Foundation

/// Process-lifetime ownership of the shared credential directory. Never unlink the file:
/// replacing its inode would allow a second process to acquire a different lock.
final class ApplicationInstanceLock {
    enum Failure: Error, Equatable { case alreadyRunning, unavailable }
    private let descriptor: Int32

    init(directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        } catch { throw Failure.unavailable }
        var directoryInfo = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &directoryInfo) }) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid() else { throw Failure.unavailable }
        let file = directory.appendingPathComponent(".application-instance.lock")
        let fd = file.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw Failure.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            Darwin.close(fd)
            throw Failure.unavailable
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw code == EWOULDBLOCK ? Failure.alreadyRunning : Failure.unavailable
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}
