import Foundation

protocol AntigravityServing: Sendable {
    func fetchQuota() async throws -> AntigravityQuota
}

/// Reads quota from the Antigravity app's running language server. This does
/// not read or copy Antigravity's account credentials; it only talks to the
/// already-authenticated local service.
struct AntigravityLocalClient: AntigravityServing {
    private static let quotaPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration,
                          delegate: AntigravityLocalhostDelegate.shared, delegateQueue: nil)
    }()

    func fetchQuota() async throws -> AntigravityQuota {
        let connection = try await Task.detached(priority: .utility) {
            try Self.discoverConnection()
        }.value
        var lastError: Error = AntigravityQuotaError.noPort
        for port in connection.ports {
            do {
                return try await fetch(port: port, csrfToken: connection.csrfToken)
            } catch let error as AntigravityQuotaError {
                lastError = error
                if case .authorization = error { break }
                continue
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func fetch(port: Int, csrfToken: String) async throws -> AntigravityQuota {
        guard let url = URL(string: "https://127.0.0.1:\(port)\(Self.quotaPath)") else {
            throw AntigravityQuotaError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["forceRefresh": true])
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityQuotaError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return try AntigravityQuotaParser.parse(data)
        case 401, 403:
            throw AntigravityQuotaError.authorization
        default:
            throw AntigravityQuotaError.http(http.statusCode)
        }
    }

    // MARK: - Process discovery

    private struct Connection {
        let csrfToken: String
        let ports: [Int]
    }

    private static func discoverConnection() throws -> Connection {
        let processes = try run("/bin/ps", ["-axo", "pid=,command="])
        for line in processes.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[1])
            guard command.contains("language_server"),
                  command.contains("Antigravity.app") || command.contains("--override_ide_name antigravity"),
                  let csrfToken = flag("--csrf_token", in: command) else { continue }
            let ports = try listeningPorts(pid: pid)
            if !ports.isEmpty {
                return Connection(csrfToken: csrfToken, ports: ports)
            }
        }
        throw AntigravityQuotaError.notRunning
    }

    private static func flag(_ name: String, in command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        guard let index = parts.firstIndex(of: name), parts.indices.contains(index + 1) else { return nil }
        return parts[index + 1]
    }

    private static func listeningPorts(pid: Int32) throws -> [Int] {
        let output = try run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)])
        let regex = try NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports: Set<Int> = []
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: output),
                  let port = Int(output[range]) else { return }
            ports.insert(port)
        }
        return ports.sorted()
    }

    private static func run(_ binary: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class AntigravityLocalhostDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = AntigravityLocalhostDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        self.resolve(challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        self.resolve(challenge)
    }

    private func resolve(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let host = challenge.protectionSpace.host.lowercased()
        guard (host == "127.0.0.1" || host == "localhost"),
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}