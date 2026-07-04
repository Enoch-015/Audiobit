@preconcurrency import AVFoundation
import Foundation
import LAME

@MainActor
final class AudioExportController: ObservableObject {
    enum State: Equatable {
        case idle
        case exporting(progress: Double, message: String)
        case completed(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var exportTask: Task<Void, Never>?

    var isExporting: Bool {
        if case .exporting = state { return true }
        return false
    }

    func start(content: DocumentContent, speech: SpeechController) {
        guard !isExporting else { return }
        let chunks = content.sections.flatMap { SpeechChunker.chunks(from: $0.text) }
        guard !chunks.isEmpty else {
            state = .failed("This document has no text to export.")
            return
        }

        state = .exporting(progress: 0, message: "Preparing audio…")
        exportTask = Task { [weak self, weak speech] in
            guard let self, let speech else { return }
            do {
                let destination = try Self.destinationURL(for: content.title)
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Audiobit-\(UUID().uuidString).caf")
                defer { try? FileManager.default.removeItem(at: temporary) }

                try await speech.renderForExport(
                    chunks: chunks,
                    to: temporary
                ) { [weak self] completed, total in
                    guard let self else { return }
                    self.state = .exporting(
                        progress: Double(completed) / Double(max(total, 1)) * 0.9,
                        message: "Creating audio \(completed) of \(total)…"
                    )
                }
                try Task.checkCancellation()
                state = .exporting(progress: 0.93, message: "Encoding MP3…")
                try await MP3Encoder.encode(source: temporary, destination: destination)
                try Task.checkCancellation()
                state = .completed(destination)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
            exportTask = nil
        }
    }

    func cancel() {
        exportTask?.cancel()
        exportTask = nil
        state = .idle
    }

    func dismissResult() {
        guard !isExporting else { return }
        state = .idle
    }

    nonisolated static func exportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw AudioExportError.documentsDirectoryUnavailable
        }
        let directory = documents.appendingPathComponent("Audiobit", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    nonisolated static func destinationURL(
        for title: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try exportDirectory(fileManager: fileManager)
        let invalid = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
        let safeTitle = title
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeTitle.isEmpty ? "Audiobit Export" : safeTitle
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("mp3")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(base) \(suffix)")
                .appendingPathExtension("mp3")
            suffix += 1
        }
        return candidate
    }
}

enum AudioExportError: LocalizedError {
    case documentsDirectoryUnavailable
    case noAudio
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            "The Documents folder could not be found."
        case .noAudio:
            "The selected voice did not produce any audio."
        case .encodingFailed(let detail):
            "The MP3 could not be created. \(detail)"
        }
    }
}

enum MP3Encoder {
    static func encode(source: URL, destination: URL) async throws {
        do {
            try await Task.detached(priority: .utility) {
                try encodeSynchronously(source: source, destination: destination)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func encodeSynchronously(
        source: URL,
        destination: URL
    ) throws {
        try? FileManager.default.removeItem(at: destination)
        let input: AVAudioFile
        do {
            input = try AVAudioFile(
                forReading: source,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioExportError.encodingFailed("Opening rendered audio failed: \(error).")
        }
        let format = input.processingFormat
        let sampleRate = Int32(format.sampleRate.rounded())
        guard sampleRate > 0, let lame = lame_init() else {
            throw AudioExportError.encodingFailed("The encoder could not start.")
        }
        defer { lame_close(lame) }

        lame_set_in_samplerate(lame, sampleRate)
        lame_set_num_channels(lame, 1)
        lame_set_mode(lame, MONO)
        lame_set_brate(lame, 128)
        lame_set_quality(lame, 2)
        guard lame_init_params(lame) >= 0 else {
            throw AudioExportError.encodingFailed("The encoder rejected the audio format.")
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch {
            throw AudioExportError.encodingFailed("Opening the MP3 output failed: \(error).")
        }
        defer { try? output.close() }
        let frameCapacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else { throw AudioExportError.noAudio }
        var pcm = [Int16](repeating: 0, count: Int(frameCapacity))
        var encoded = [UInt8](
            repeating: 0,
            count: Int(Double(frameCapacity) * 1.25) + 7_200
        )
        var wroteAudio = false

        while input.framePosition < input.length {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(
                min(Int64(frameCapacity), input.length - input.framePosition)
            )
            do {
                try input.read(into: buffer, frameCount: remaining)
            } catch {
                throw AudioExportError.encodingFailed("Reading rendered audio failed: \(error).")
            }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw AudioExportError.encodingFailed("The rendered audio was not PCM.")
            }
            let channelCount = Int(format.channelCount)
            for frame in 0..<frameCount {
                var sample: Float = 0
                for channel in 0..<channelCount {
                    sample += channels[channel][frame]
                }
                sample /= Float(max(channelCount, 1))
                pcm[frame] = Int16(
                    max(-1, min(1, sample)) * Float(Int16.max)
                )
            }

            let byteCount = pcm.withUnsafeBufferPointer { samples in
                encoded.withUnsafeMutableBufferPointer { outputBytes in
                    lame_encode_buffer(
                        lame,
                        samples.baseAddress,
                        samples.baseAddress,
                        Int32(frameCount),
                        outputBytes.baseAddress,
                        Int32(outputBytes.count)
                    )
                }
            }
            guard byteCount >= 0 else {
                throw AudioExportError.encodingFailed("Encoding stopped with error \(byteCount).")
            }
            if byteCount > 0 {
                try output.write(contentsOf: Data(encoded.prefix(Int(byteCount))))
                wroteAudio = true
            }
        }

        let finalCount = encoded.withUnsafeMutableBufferPointer {
            lame_encode_flush(lame, $0.baseAddress, Int32($0.count))
        }
        guard finalCount >= 0 else {
            throw AudioExportError.encodingFailed("The encoder could not finish the MP3.")
        }
        if finalCount > 0 {
            try output.write(contentsOf: Data(encoded.prefix(Int(finalCount))))
            wroteAudio = true
        }
        guard wroteAudio else { throw AudioExportError.noAudio }
    }
}

@MainActor
final class AppleOfflineRenderer {
    private let synthesizer = AVSpeechSynthesizer()

    func render(
        chunks: [String],
        voiceIdentifier: String?,
        rate: Float,
        destination: URL,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        var output: AVAudioFile?
        var renderedAudio = false

        for (index, text) in chunks.enumerated() {
            try Task.checkCancellation()
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = rate
            if let voiceIdentifier {
                utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            }

            try await withCheckedThrowingContinuation { continuation in
                var finished = false
                synthesizer.write(utterance) { buffer in
                    guard !finished else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        finished = true
                        continuation.resume()
                        return
                    }
                    do {
                        if output == nil {
                            output = try AVAudioFile(
                                forWriting: destination,
                                settings: pcm.format.settings
                            )
                        }
                        try output?.write(from: pcm)
                        renderedAudio = true
                    } catch {
                        finished = true
                        self.synthesizer.stopSpeaking(at: .immediate)
                        continuation.resume(throwing: error)
                    }
                }
            }
            progress(index + 1, chunks.count)
        }

        guard renderedAudio else { throw AudioExportError.noAudio }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
