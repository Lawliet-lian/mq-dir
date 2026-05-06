import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Modal sheet for "Help → Send Feedback".
///
/// POSTs the message + optional image attachments straight to a Discord
/// webhook (URL lives in the gitignored `FeedbackSecrets.swift`). The
/// user never leaves the app — no mailto: handoff, no browser. Webhook
/// leakage is rotated channel-side, not by code change.
struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var message: String = ""
    @State private var attachments: [URL] = []
    @State private var sendState: FeedbackSendState = .editing

    private let recipient = "business@mindfullabs.ai"
    private let messageLimit = 4000
    private let attachmentLimit = 10

    var body: some View {
        Group {
            switch sendState {
            case .sent:
                successBody
            default:
                editingBody
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: Editing state

    @ViewBuilder
    private var editingBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            emailField
            messageField
            attachmentRow
            if case .failed(let msg) = sendState {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            buttonRow
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Send Feedback")
                .font(.system(size: 16, weight: .semibold))
            Text("A human will read this! You can also reach us at \(recipient).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Email")
                .font(.system(size: 12, weight: .semibold))
            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .disabled(isSending)
        }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Message")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(message.count)/\(messageLimit)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.system(size: 12))
                    .frame(minHeight: 140)
                    .padding(4)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .disabled(isSending)
                    .onChange(of: message) { _, new in
                        if new.count > messageLimit {
                            message = String(new.prefix(messageLimit))
                        }
                    }
                if message.isEmpty {
                    Text("Share feedback, feature requests, or issues.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var attachmentRow: some View {
        HStack(spacing: 8) {
            Button(action: pickImages) {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                    Text("Attach Images")
                }
            }
            .disabled(isSending)
            if attachments.isEmpty {
                Text("Up to \(attachmentLimit) images.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(attachments.count) attached")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Clear") { attachments.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .disabled(isSending)
            }
            Spacer()
        }
    }

    private var buttonRow: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSending)
            Button(isSending ? "Sending…" : "Send") {
                Task { await send() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSending || trimmedMessage.isEmpty)
        }
    }

    // MARK: Sent state

    private var successBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send Feedback")
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Thanks for the feedback.")
                    .font(.system(size: 13, weight: .semibold))
                Text("You can also reach us at \(recipient).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Helpers

    private var isSending: Bool {
        if case .sending = sendState { return true }
        return false
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            let combined = attachments + panel.urls
            attachments = Array(combined.prefix(attachmentLimit))
        }
    }

    @MainActor
    private func send() async {
        sendState = .sending
        do {
            try await postToDiscord()
            sendState = .sent
        } catch {
            sendState = .failed("Couldn't send: \(error.localizedDescription)")
        }
    }

    private func postToDiscord() async throws {
        guard let raw = FeedbackSecrets.discordWebhookURL,
              let url = URL(string: raw) else {
            throw FeedbackError.notConfigured
        }

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let header = """
        **mq-dir feedback**
        From: \(trimmedEmail.isEmpty ? "(no email)" : trimmedEmail)
        Version: \(appVersionString())
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        let content = "\(header)\n\n\(trimmedMessage)"

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        let payload: [String: Any] = ["content": content, "username": "mq-dir"]
        let payloadJSON = try JSONSerialization.data(withJSONObject: payload)
        body.appendASCII("--\(boundary)\r\n")
        body.appendASCII("Content-Disposition: form-data; name=\"payload_json\"\r\n")
        body.appendASCII("Content-Type: application/json\r\n\r\n")
        body.append(payloadJSON)
        body.appendASCII("\r\n")

        for (idx, fileURL) in attachments.enumerated() {
            guard let fileData = try? Data(contentsOf: fileURL) else { continue }
            let filename = fileURL.lastPathComponent
            body.appendASCII("--\(boundary)\r\n")
            body.appendASCII(
                "Content-Disposition: form-data; name=\"files[\(idx)]\"; filename=\"\(filename)\"\r\n"
            )
            body.appendASCII("Content-Type: \(mimeType(for: fileURL))\r\n\r\n")
            body.append(fileData)
            body.appendASCII("\r\n")
        }
        body.appendASCII("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FeedbackError.httpStatus(code)
        }
    }

    private func appVersionString() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

private enum FeedbackSendState {
    case editing
    case sending
    case sent
    case failed(String)
}

private enum FeedbackError: LocalizedError {
    case notConfigured
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Feedback channel is not configured for this build."
        case .httpStatus(let code):
            return "Server responded with HTTP \(code)."
        }
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
