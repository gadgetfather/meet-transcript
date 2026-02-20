import Foundation

struct DiarizationSegment: Decodable {
    let start: Double
    let end: Double
    let speaker: String
}

struct DiarizationResult: Decodable {
    let segments: [DiarizationSegment]
    let numSpeakers: Int?

    private enum CodingKeys: String, CodingKey {
        case segments
        case numSpeakers = "num_speakers"
    }
}

final class SpeakerDiarizationService: @unchecked Sendable {
    enum DiarizationError: Error {
        case scriptNotFound(String)
        case pythonNotFound(String)
        case nonZeroExit(code: Int32, stderr: String, stdout: String)
        case invalidJSON(String)
    }

    private let fileManager = FileManager.default

    func diarize(
        audioURL: URL,
        minSpeakers: Int = 1,
        maxSpeakers: Int = 4
    ) async throws -> DiarizationResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: DiarizationError.invalidJSON("service deallocated"))
                    return
                }

                do {
                    let result = try self.runProcess(
                        audioURL: audioURL,
                        minSpeakers: minSpeakers,
                        maxSpeakers: maxSpeakers
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
        minSpeakers: Int,
        maxSpeakers: Int
    ) throws -> DiarizationResult {
        let runtimeRoot = runtimeRootDirectory()
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

        let scriptCandidates = [
            runtimeRoot.appendingPathComponent("scripts/speaker_diarize.py").path,
            cwd.appendingPathComponent("scripts/speaker_diarize.py").path
        ]
        guard let scriptPath = scriptCandidates.first(where: { fileManager.fileExists(atPath: $0) }) else {
            throw DiarizationError.scriptNotFound(scriptCandidates.first ?? "scripts/speaker_diarize.py")
        }

        let pythonCandidates = [
            runtimeRoot.appendingPathComponent(".venv/bin/python3").path,
            cwd.appendingPathComponent(".venv/bin/python3").path,
            "/usr/bin/python3"
        ]
        guard let pythonPath = pythonCandidates.first(where: { fileManager.fileExists(atPath: $0) }) else {
            throw DiarizationError.pythonNotFound(pythonCandidates.joined(separator: ", "))
        }

        let process = Process()
        process.currentDirectoryURL = runtimeRoot
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            "--audio", audioURL.path,
            "--min-speakers", String(max(1, minSpeakers)),
            "--max-speakers", String(max(max(1, minSpeakers), maxSpeakers))
        ]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw DiarizationError.nonZeroExit(
                code: process.terminationStatus,
                stderr: stderr,
                stdout: stdout
            )
        }

        guard let jsonData = stdout.data(using: .utf8) else {
            throw DiarizationError.invalidJSON(stdout)
        }

        do {
            return try JSONDecoder().decode(DiarizationResult.self, from: jsonData)
        } catch {
            throw DiarizationError.invalidJSON(stdout)
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
}
