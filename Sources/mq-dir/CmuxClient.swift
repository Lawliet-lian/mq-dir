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

    /// Resolves the `cmux` binary on this machine. Returns nil when cmux
    /// isn't installed — the sidebar uses that to hide the CMUX section
    /// entirely instead of surfacing an empty / broken state.
    static func locateBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["CMUX_BIN"], !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env)
        {
            return env
        }
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
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
        // reaches GUI-launched apps too. Pass it explicitly via --password
        // because cmux's auth fallback to the env var only fires when the
        // var is also visible to the cmux server's process — easier to
        // forward it on the CLI ourselves than to debug that.
        var args: [String] = []
        if let pw = ProcessInfo.processInfo.environment["CMUX_SOCKET_PASSWORD"],
           !pw.isEmpty
        {
            args += ["--password", pw]
        }
        args += ["rpc", "workspace.list", "{}"]
        process.arguments = args

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
