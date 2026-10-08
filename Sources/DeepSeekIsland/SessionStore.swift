import Darwin
import Foundation

struct SessionStore {
    static let shared = SessionStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeepSeekIsland", isDirectory: true)
    )

    let directory: URL

    private var tokenFile: URL {
        directory.appendingPathComponent("account-grant", isDirectory: false)
    }

    private var chatGPTFile: URL {
        directory.appendingPathComponent("chatgpt-grant", isDirectory: false)
    }

    func readPlatformToken() -> String? {
        readString(at: tokenFile, limit: 8192)
    }

    @discardableResult
    func savePlatformToken(_ token: String) -> Bool {
        write(Array(token.utf8), to: tokenFile, limit: 8192)
    }

    @discardableResult
    func deletePlatformToken() -> Bool {
        remove(tokenFile)
    }

    // MARK: - ChatGPT 授权

    /// 存的是自己登录拿到的那份（access + refresh），**不是** Codex CLI 的 auth.json。
    func readChatGPTGrant() -> ChatGPTGrant? {
        guard let text = readString(at: chatGPTFile, limit: 16_384),
              let data = text.data(using: .utf8),
              let grant = try? JSONDecoder().decode(ChatGPTGrant.self, from: data),
              !grant.accessToken.isEmpty, !grant.refreshToken.isEmpty else { return nil }
        return grant
    }

    @discardableResult
    func saveChatGPTGrant(_ grant: ChatGPTGrant) -> Bool {
        guard let data = try? JSONEncoder().encode(grant) else { return false }
        return write(Array(data), to: chatGPTFile, limit: 16_384)
    }

    @discardableResult
    func deleteChatGPTGrant() -> Bool {
        remove(chatGPTFile)
    }

    // MARK: - 文件读写

    /// 只认「自己的、0700 目录里的、0600 的普通文件」，符号链接一律不跟。
    private func readString(at file: URL, limit: Int) -> String? {
        let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= limit else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let readAll = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let received = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard received > 0 else { return false }
                offset += received
            }
            return true
        }
        guard readAll else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func write(_ bytes: [UInt8], to file: URL, limit: Int) -> Bool {
        guard !bytes.isEmpty, bytes.count <= limit, prepareDirectory() else { return false }
        let temporary = directory.appendingPathComponent(".grant-\(UUID().uuidString)", isDirectory: false)
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { return false }
        let wroteAll = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        let synced = Darwin.fsync(descriptor) == 0
        let closed = Darwin.close(descriptor) == 0
        guard wroteAll, synced, closed else {
            temporary.path.withCString { _ = Darwin.unlink($0) }
            return false
        }
        let replaced = temporary.path.withCString { source in
            file.path.withCString { destination in
                Darwin.rename(source, destination) == 0
            }
        }
        if !replaced { temporary.path.withCString { _ = Darwin.unlink($0) } }
        return replaced
    }

    private func remove(_ file: URL) -> Bool {
        let result = file.path.withCString { Darwin.unlink($0) }
        return result == 0 || errno == ENOENT
    }

    private func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            return false
        }
        var info = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else { return false }
        return directory.path.withCString { Darwin.chmod($0, mode_t(0o700)) == 0 }
    }
}
