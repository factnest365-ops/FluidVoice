import Foundation

/// Pure helpers for the Whistle engine boundary: writing 16 kHz mono PCM16 WAV
/// files and parsing the engine's JSON reply. Kept free of app dependencies so
/// Tests/WhistleAudioTests.swift can compile them standalone.
enum WhistleAudio {
    struct Transcription {
        let text: String
        let language: String?
        let ttftMilliseconds: Double?
        let decodeTokensPerSecond: Double?
    }

    /// Minimal RIFF/PCM16 writer: mono, samples clamped to [-1, 1].
    static func writeWAV(samples: [Float], sampleRate: Int, channels: Int = 1, to url: URL) throws {
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataByteCount = samples.count * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(UInt16(channels), to: &data)
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(byteRate), to: &data)
        appendUInt16LE(UInt16(blockAlign), to: &data)
        appendUInt16LE(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32LE(UInt32(dataByteCount), to: &data)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            appendInt16LE(scaled, to: &data)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Parses the engine's stdout. Silence and short clips produce empty JSON
    /// or no output at all; both are valid empty transcripts.
    static func parseResult(_ data: Data) throws -> Transcription {
        guard data.count > 0 else {
            return Transcription(text: "", language: nil, ttftMilliseconds: nil, decodeTokensPerSecond: nil)
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw NSError(
                domain: "WhistleAudio",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Whistle returned unexpected output."]
            )
        }
        return Transcription(
            text: ((dictionary["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            language: dictionary["language"] as? String,
            ttftMilliseconds: dictionary["ttft_ms"] as? Double,
            decodeTokensPerSecond: dictionary["decode_tps"] as? Double
        )
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendInt16LE(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
