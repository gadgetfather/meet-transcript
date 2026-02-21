import Foundation

struct WhisperWord: Decodable {
    let start: Double
    let end: Double
    let word: String
}

struct WhisperSegment: Decodable {
    let start: Double
    let end: Double
    let text: String
    let words: [WhisperWord]?
}

struct WhisperTranscriptionResult: Decodable {
    let text: String
    let segments: [WhisperSegment]
}

final class WhisperTranscriberService: @unchecked Sendable {
    enum WhisperError: Error {
        case scriptNotFound(String)
        case pythonNotFound(String)
        case nonZeroExit(code: Int32, stderr: String, stdout: String)
        case invalidJSON(String)
    }

    private let fileManager = FileManager.default

    func transcribe(
        audioURL: URL,
        model: String = "base.en",
        language: String = "en"
    ) async throws -> WhisperTranscriptionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: WhisperError.invalidJSON("service deallocated"))
                    return
                }

                do {
                    let result = try self.runProcess(
                        audioURL: audioURL,
                        model: model,
                        language: language
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runProcess(
        audioURL: URL,
        model: String,
        language: String
    ) throws -> WhisperTranscriptionResult {
        let runtimeRoot = runtimeRootDirectory()
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

        let scriptCandidates = [
            runtimeRoot.appendingPathComponent("scripts/whisper_transcribe.py").path,
            cwd.appendingPathComponent("scripts/whisper_transcribe.py").path
        ]
        guard let scriptPath = scriptCandidates.first(where: { fileManager.fileExists(atPath: $0) }) else {
            throw WhisperError.scriptNotFound(scriptCandidates.first ?? "scripts/whisper_transcribe.py")
        }

        let pythonCandidates = [
            runtimeRoot.appendingPathComponent(".venv/bin/python3").path,
            cwd.appendingPathComponent(".venv/bin/python3").path,
            "/usr/bin/python3"
        ]
        guard let pythonPath = pythonCandidates.first(where: { fileManager.fileExists(atPath: $0) }) else {
            throw WhisperError.pythonNotFound(pythonCandidates.joined(separator: ", "))
        }

        let process = Process()
        process.currentDirectoryURL = runtimeRoot
        process.executableURL = URL(fileURLWithPath: pythonPath)
        let modelArgument = resolvedModelArgument(defaultModel: model)
        process.arguments = [
            scriptPath,
            "--audio", audioURL.path,
            "--model", modelArgument,
            "--language", language,
            "--device", "cpu",
            "--compute-type", "int8"
        ]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONIOENCODING"] = "utf-8"
        env["HF_HOME"] = runtimeRoot.appendingPathComponent(".cache/huggingface").path
        process.environment = env

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stdoutURL = temporaryDirectory.appendingPathComponent("meet-transcript-whisper-stdout-\(UUID().uuidString).txt")
        let stderrURL = temporaryDirectory.appendingPathComponent("meet-transcript-whisper-stderr-\(UUID().uuidString).txt")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()

        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw WhisperError.nonZeroExit(
                code: process.terminationStatus,
                stderr: stderr,
                stdout: stdout
            )
        }

        guard let jsonData = stdout.data(using: .utf8) else {
            throw WhisperError.invalidJSON(stdout)
        }

        do {
            return try JSONDecoder().decode(WhisperTranscriptionResult.self, from: jsonData)
        } catch {
            throw WhisperError.invalidJSON(stdout)
        }
    }

    private func runtimeRootDirectory() -> URL {
        if let configured = ProcessInfo.processInfo.environment["MEET_TRANSCRIPT_RUNTIME_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }

        return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    }

    private func resolvedModelArgument(defaultModel: String) -> String {
        if let configuredModelPath = ProcessInfo.processInfo.environment["MEET_TRANSCRIPT_WHISPER_MODEL_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredModelPath.isEmpty,
           fileManager.fileExists(atPath: configuredModelPath)
        {
            return configuredModelPath
        }

        return defaultModel
    }
}
