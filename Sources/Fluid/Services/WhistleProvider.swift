import Foundation

/// Speech-to-text provider backed by Cactus Compute's Whistle engine.
///
/// Whistle ships as a 16.9 MB `.cact` model plus a small static binary (`needle`)
/// that runs it on the CPU with no GPU and no dependencies. This provider keeps
/// both files in Caches, downloads them on `prepare`, and shells out to the
/// binary per transcription: samples are written to a temporary 16 kHz mono WAV
/// and the JSON reply on stdout is parsed into an `ASRTranscriptionResult`.
final class WhistleProvider: TranscriptionProvider {
    let name = "Whistle (Cactus)"

    var isAvailable: Bool {
        CPUArchitecture.isAppleSilicon
    }

    private let lock = NSLock()
    private var ready = false

    private let overriddenModelDirectory: URL?
    private let urlSession: URLSession
    /// Accepted for parity with the other providers; Whistle has a single model size.
    private let modelOverride: SettingsStore.SpeechModel?

    init(
        modelDirectory: URL? = nil,
        urlSession: URLSession = .shared,
        modelOverride: SettingsStore.SpeechModel? = nil
    ) {
        self.overriddenModelDirectory = modelDirectory
        self.urlSession = urlSession
        self.modelOverride = modelOverride
    }

    var isReady: Bool {
        self.lock.withLock { self.ready }
    }

    var selectedModel: SettingsStore.SpeechModel {
        self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
    }

    // MARK: - Files on disk

    private var modelDirectory: URL {
        if let overriddenModelDirectory {
            return overriddenModelDirectory
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return (caches ?? FileManager.default.temporaryDirectory).appendingPathComponent("WhistleEngine")
    }

    private var engineURL: URL {
        self.modelDirectory.appendingPathComponent(WhistleProvider.engineFileName)
    }

    private var modelURL: URL {
        self.modelDirectory.appendingPathComponent(WhistleProvider.modelFileName)
    }

    private static let engineFileName = "needle"
    private static let modelFileName = "whistle.cact"

    static let engineDownloadURL = URL(
        string: "https://huggingface.co/Cactus-Compute/needle3/resolve/main/macos-arm64/needle"
    )!
    static let modelDownloadURL = URL(
        string: "https://huggingface.co/Cactus-Compute/whistle/resolve/main/whistle.cact"
    )!
    static let expectedEngineBytes: Int64 = 1_107_096
    static let expectedModelBytes: Int64 = 16_919_407

    private func fileHasExpectedSize(_ url: URL, _ expectedBytes: Int64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value == expectedBytes
    }

    // MARK: - TranscriptionProvider

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)

        // Two downloads; the engine is ~6% of the bytes, so weight progress accordingly.
        let engineFraction = Double(WhistleProvider.expectedEngineBytes)
            / Double(WhistleProvider.expectedEngineBytes + WhistleProvider.expectedModelBytes)

        if !self.fileHasExpectedSize(self.engineURL, WhistleProvider.expectedEngineBytes) {
            progressHandler?(.preparingDownload)
            try? manager.removeItem(at: self.engineURL)
            try await self.downloadFile(
                from: WhistleProvider.engineDownloadURL,
                to: self.engineURL,
                urlSession: self.urlSession
            ) { fraction in
                progressHandler?(.downloading(fraction * engineFraction))
            }
            try manager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: self.engineURL.path
            )
        }

        if !self.fileHasExpectedSize(self.modelURL, WhistleProvider.expectedModelBytes) {
            progressHandler?(.preparingDownload)
            try? manager.removeItem(at: self.modelURL)
            try await self.downloadFile(
                from: WhistleProvider.modelDownloadURL,
                to: self.modelURL,
                urlSession: self.urlSession
            ) { fraction in
                progressHandler?(.downloading(engineFraction + fraction * (1 - engineFraction)))
            }
        }

        progressHandler?(.loading)
        _ = try await self.transcribe([Float](repeating: 0, count: 8000))
        self.lock.withLock { self.ready = true }
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard samples.count >= 16 else {
            return ASRTranscriptionResult(text: "", confidence: 1.0)
        }
        guard FileManager.default.isExecutableFile(atPath: self.engineURL.path),
              self.fileHasExpectedSize(self.modelURL, WhistleProvider.expectedModelBytes)
        else {
            throw NSError(
                domain: "WhistleProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Whistle engine or model is missing. Download it in Settings first."]
            )
        }

        let audioURL = self.modelDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        try WhistleAudio.writeWAV(samples: samples, sampleRate: 16000, to: audioURL)

        let process = Process()
        process.executableURL = self.engineURL
        process.arguments = [
            "--model", self.modelURL.path,
            "--audio", audioURL.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        // The engine is deterministic and fast, but never trust an external
        // process to terminate: cap the wait.
        await withTaskGroup(of: Int32.self) { group in
            group.addTask { await self.waitForExit(process) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
                return -1
            }
            _ = await group.next()!
            group.cancelAll()
        }

        let pipe = process.standardOutput as? Pipe
        let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()

        let transcription = try WhistleAudio.parseResult(data)
        return ASRTranscriptionResult(text: transcription.text, confidence: 1.0)
    }

    private func waitForExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    func modelsExistOnDisk() -> Bool {
        self.fileHasExpectedSize(self.engineURL, WhistleProvider.expectedEngineBytes)
            && self.fileHasExpectedSize(self.modelURL, WhistleProvider.expectedModelBytes)
    }

    func clearCache() async throws {
        let directory = self.modelDirectory
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            if manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
            }
        }.value
        self.lock.withLock { self.ready = false }
    }

    // MARK: - Download

    private func downloadFile(
        from url: URL,
        to destination: URL,
        urlSession: URLSession,
        progressHandler: ((Double) -> Void)?
    ) async throws {
        var temporaryURL: URL?
        do {
            let (downloadedURL, response) = try await ProgressiveFileDownloader.download(
                from: url,
                configuration: urlSession.configuration
            ) { totalBytesWritten, totalBytesExpectedToWrite in
                guard totalBytesExpectedToWrite > 0 else { return }
                progressHandler?(min(0.999, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            }
            temporaryURL = downloadedURL
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(
                    domain: "WhistleProvider",
                    code: status,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to download Whistle (HTTP \(status))."]
                )
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
            let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard actualBytes > 0 else {
                throw NSError(
                    domain: "WhistleProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded file is empty. Please try again."]
                )
            }
            if httpResponse.expectedContentLength > 0, actualBytes != httpResponse.expectedContentLength {
                throw NSError(
                    domain: "WhistleProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded file size mismatch. Please try again."]
                )
            }

            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
            temporaryURL = nil
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            throw error
        }
        progressHandler?(1.0)
    }
}

