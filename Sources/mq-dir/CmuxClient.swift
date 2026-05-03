import Foundation

/// Lightweight wrapper around the `cmux` CLI binary.
///
/// We talk to cmux through its `rpc` subcommand (which proxies onto cmux's
/// Unix socket), so this is a thin shell-out + JSON-decode layer rather
/// than a long-lived socket client. The sidebar's "Sync" button is the
/// only caller — manual trigger keeps the dependency cheap and avoids
/// background polling chatter when the user isn't using cmux today.
///
/// All operations are synchronous (Process.run + pipe drain) but called
/// from `Task.detached` on the UI side so the main actor never blocks
/// on cmux startup latency.
struct CmuxClient: Sendable {
    /// Common install locations. `cmux.app`'s embedded binary takes
    /// precedence so we don't accidentally hit a stale Homebrew copy.
    private static let candidatePaths: [String] = [
        "/Applications/cmux.app/Contents/Resources/bin/cmux",
        "/opt/homebrew/bin/cmux",
        "/usr/local/bin/cmux",
    ]

    /// Parent directories under which a `CMUX_BIN` override is acceptable.
    /// Without this allowlist, a hostile process that can call
    /// `launchctl setenv CMUX_BIN /tmp/evil` would get arbitrary code
    /// execution every time the user clicks Sync — non-sandboxed
    /// Developer ID builds inherit the user's full TCC grants.
    private static let trustedBinaryRoots: [String] = [
        "/Applications/cmux.app/",
        "/opt/homebrew/",
        "/usr/local/",
    ]

    /// Resolves the `cmux` binary on this machine. Returns nil when cmux
    /// isn't installed — the sidebar uses that to hide the CMUX section
    /// entirely instead of surfacing an empty / broken state.
    static func locateBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["CMUX_BIN"],
           !env.isEmpty,
           isTrustedBinary(path: env),
           FileManager.default.isExecutableFile(atPath: env)
        {
            return env
        }
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// True when `path` resolves under one of the trusted parent roots.
    /// Standardizes the path first so `..` traversal can't escape the
    /// allowlist (e.g. `/opt/homebrew/../tmp/evil`).
    private static func isTrustedBinary(path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return trustedBinaryRoots.contains { standardized.hasPrefix($0) }
    }

    /// Returns the current cmux workspace list, sorted by `index`. Throws
    /// when cmux is missing, when the rpc call fails, or when the JSON
    /// shape is unexpected — the caller surfaces a single "couldn't
    /// reach cmux" hint rather than reasoning about which step broke.
    static func listWorkspaces() throws -> [CmuxWorkspace] {
        guard let binary = locateBinary() else { throw CmuxError.notInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)

        // If the user runs cmux in Password mode (Settings → Automation),
        // they set CMUX_SOCKET_PASSWORD via `launchctl setenv` so it
        // reaches GUI-launched apps too. Forward it via the child's
        // environment rather than `--password <pw>` on argv — argv is
        // visible to every local user via `ps -ef` for the lifetime of
        // the child, env is not. cmux honors the env var when it's also
        // present in the server's environment, which the launchctl path
        // already arranges.
        var env = ProcessInfo.processInfo.environment
        if let pw = env["CMUX_SOCKET_PASSWORD"], !pw.isEmpty {
            env["CMUX_SOCKET_PASSWORD"] = pw
        }
        process.environment = env
        process.arguments = ["rpc", "workspace.list", "{}"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            // cmux 0.63.x rejects external apps when its socket is in
            // the default `cmuxOnly` mode — the symptom is a "Broken
            // pipe" mid-write. Bubble up a more actionable hint instead
            // of the raw socket error.
            if msg.contains("Broken pipe") || msg.contains("EOF") {
                throw CmuxError.accessDenied
            }
            throw CmuxError.rpcFailed(status: Int(process.terminationStatus), message: msg)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let response = try JSONDecoder().decode(WorkspaceListResponse.self, from: data)
        return response.workspaces.sorted { $0.index < $1.index }
    }
}

// MARK: - Wire types (only the fields we actually render)

struct CmuxWorkspace: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let ref: String
    let index: Int
    let title: String
    let description: String?
    let currentDirectory: String?
    let selected: Bool

    enum CodingKeys: String, CodingKey {
        case id, ref, index, title, description
        case currentDirectory = "current_directory"
        case selected
    }
}

private struct WorkspaceListResponse: Decodable {
    let workspaces: [CmuxWorkspace]
}

// MARK: - Errors

enum CmuxError: Error, LocalizedError {
    case notInstalled
    case accessDenied
    case rpcFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "cmux not found on this machine."
        case .accessDenied:
            return "cmux is set to allow only its own children. " +
                   "Open cmux → Settings → Automation and switch Socket Control Mode away from cmuxOnly."
        case .rpcFailed(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "cmux rpc failed (exit \(status))\(detail.isEmpty ? "" : ": \(detail)")"
        }
    }
}
