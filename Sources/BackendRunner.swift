import Foundation

enum UserFacingText {
    case localized(LocalizedStringResource)
    case verbatim(String)
}

struct BackendFailure: Error {
    let message: UserFacingText
    let diagnostics: String
}

actor BackendRunner {
    func run<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        arguments: [String]
    ) throws -> Response {
        let script = try backendScriptURL()
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", script.path] + arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errors = standardError.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()
        if process.terminationStatus != 0 {
            let backendError = try? decoder.decode(ErrorResponse.self, from: output)
            throw BackendFailure(
                message: backendError.map { .verbatim($0.error) }
                    ?? .localized(L10n.backendFailed),
                diagnostics: String(data: errors, encoding: .utf8) ?? ""
            )
        }
        do {
            return try decoder.decode(responseType, from: output)
        } catch {
            throw BackendFailure(
                message: .localized(L10n.backendInvalidResponse),
                diagnostics: String(data: errors, encoding: .utf8) ?? ""
            )
        }
    }

    private func backendScriptURL() throws -> URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appending(path: "Backend/cards.py")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        let sourceCheckout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Backend/cards.py")
        if FileManager.default.fileExists(atPath: sourceCheckout.path) {
            return sourceCheckout
        }
        throw BackendFailure(
            message: .localized(L10n.backendMissing),
            diagnostics: ""
        )
    }
}
