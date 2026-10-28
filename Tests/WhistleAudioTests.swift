import Foundation

@main
enum WhistleAudioTests {
    static func main() {
        let directory = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("whistle-audio-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // WAV writer produces a valid 16 kHz mono PCM16 file.
        let url = directory.appendingPathComponent("test.wav")
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 2.0, -2.0]
        try! WhistleAudio.writeWAV(samples: samples, sampleRate: 16000, to: url)

        let data = try! Data(contentsOf: url)
        // 44-byte header + 7 samples * 2 bytes
        precondition(data.count == 44 + 14, "WAV size mismatch: \(data.count)")
        precondition(String(data: data.prefix(4), encoding: .ascii) == "RIFF", "missing RIFF")
        precondition(String(data: data[8 ..< 12], encoding: .ascii) == "WAVE", "missing WAVE")
        precondition(String(data: data[36 ..< 40], encoding: .ascii) == "data", "missing data chunk")

        // Header fields, little endian: channels = 1, sampleRate = 16000, bits = 16.
        let bytes = [UInt8](data)
        func le16(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) }
        func le32(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
                | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
        }
        precondition(le16(22) == 1, "channels must be mono")
        precondition(le32(24) == 16000, "sample rate mismatch")
        precondition(le16(34) == 16, "bits per sample mismatch")
        precondition(le32(40) == 14, "data byte count mismatch")

        // Clamping: 2.0 -> Int16.max, -2.0 -> -Int16.max.
        let first = le16(44)
        precondition(first == 0, "silence sample became \(first)")
        func asInt16(_ raw: Int) -> Int { raw > 32767 ? raw - 65536 : raw }
        let clampedMax = le16(44 + 10) // the 2.0 sample
        precondition(clampedMax == 32767, "expected clamped max, got \(clampedMax)")
        let clampedMin = asInt16(le16(44 + 12)) // the -2.0 sample
        precondition(clampedMin == -32767, "expected clamped min, got \(clampedMin)")

        // Parser: full engine reply.
        let reply = #"{"text":"hello world","language":"en","ttft_ms":36.0,"decode_tps":500.3}"#
        let transcription = try! WhistleAudio.parseResult(reply.data(using: .utf8)!)
        precondition(transcription.text == "hello world", "text mismatch: \(transcription.text)")
        precondition(transcription.language == "en", "language mismatch")
        precondition(transcription.ttftMilliseconds == 36.0, "ttft mismatch")
        precondition(transcription.decodeTokensPerSecond == 500.3, "tps mismatch")

        // Parser: empty output is a valid empty transcript, not an error.
        let empty = try! WhistleAudio.parseResult(Data())
        precondition(empty.text == "" && empty.language == nil, "empty output must parse to empty text")

        // Parser: garbage output throws, never a silent invented transcript.
        var threw = false
        do {
            _ = try WhistleAudio.parseResult(Data("not json at all".utf8))
        } catch {
            threw = true
        }
        precondition(threw, "garbage output must throw")

        print("WhistleAudioTests: all passed")
    }
}
