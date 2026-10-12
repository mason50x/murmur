import AVFoundation
import FluidAudio
import Foundation

/// Runs the selected `SpeechModel` on whole recordings when you stop talking. Parakeet Unified
/// uses its offline (full-attention) encoder; Phonon-2 goes through FluidAudio's TDT pipeline.
/// The Unified streaming encoder is only loaded for the CLI check.
final class Transcriber: @unchecked Sendable {
    static let streamingConfig = UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7)

    private enum Engine {
        case unified(UnifiedAsrManager)
        case tdt(AsrManager)
    }

    private var engine: Engine?
    private(set) var model: SpeechModel?
    private lazy var streaming = StreamingUnifiedAsrManager(config: Transcriber.streamingConfig)
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// Downloads (first run only) and loads `model` onto the Neural Engine, replacing any
    /// model loaded before.
    func load(
        _ model: SpeechModel, includeStreaming: Bool = false,
        progress: @escaping @Sendable (Double?, String) -> Void
    ) async throws {
        await unload()
        let fresh = !model.isDownloaded
        progress(nil, fresh ? "Starting download…" : "Loading model…")
        let handler: ProgressHandler = { p in Self.report(p, fresh: fresh, into: progress) }
        switch model {
        case .unified:
            let manager = UnifiedAsrManager()
            try await manager.loadModels(progressHandler: handler)
            engine = .unified(manager)
        case .phonon2:
            if fresh {
                // One download pass so progress is a single 0–100% run (AsrModels fetches file by file).
                try await ModelHub.download(
                    .phonon2, to: model.cacheDirectory.deletingLastPathComponent(), progressHandler: handler)
            }
            let models = try await AsrModels.downloadAndLoad(version: .phonon2, progressHandler: handler)
            let manager = AsrManager()
            try await manager.loadModels(models)
            engine = .tdt(manager)
        }
        if includeStreaming {
            try await streaming.loadModels(progressHandler: { p in
                Self.report(p, fresh: true, into: progress)
            })
        }
        self.model = model
        progress(nil, "Warming up…")
        // One tiny pass so the first real dictation doesn't pay CoreML/ANE warmup.
        _ = await finalize(samples: [Float](repeating: 0, count: 16000))
    }

    private func unload() async {
        switch engine {
        case .unified(let m): await m.cleanup()
        case .tdt(let m): await m.cleanup()
        case nil: break
        }
        engine = nil
        model = nil
    }

    private static func report(
        _ p: DownloadProgress, fresh: Bool, into progress: @Sendable (Double?, String) -> Void
    ) {
        switch p.phase {
        case .downloading:
            // Repo downloads report 0–0.5; the CoreML compile that follows takes the rest.
            let fraction = min(1, p.fractionCompleted / 0.5)
            progress(fraction, "Downloading model \(Int(fraction * 100))%")
        case .compiling:
            // The first load compiles the model for this Mac's Neural Engine; later launches hit the cache.
            progress(nil, fresh ? "Optimizing for your Neural Engine…" : "Loading model…")
        case .listing:
            progress(nil, fresh ? "Starting download…" : "Loading model…")
        }
    }

    /// A finished transcript and when each word was spoken.
    struct Transcript: Sendable {
        let text: String
        let words: [WordTiming]
    }

    /// Transcribes a finished recording (16 kHz mono). Returns empty text on failure.
    func finalize(samples: [Float]) async -> Transcript {
        do {
            switch engine {
            case .unified(let m):
                let result = try await m.transcribeWithTimings(samples)
                return Transcript(text: Self.clean(result.text), words: Self.words(result.tokenTimings))
            case .tdt(let m):
                var state = TdtDecoderState.make()
                let result = try await m.transcribe(samples, decoderState: &state)
                return Transcript(text: Self.clean(result.text), words: Self.words(result.tokenTimings ?? []))
            case nil:
                return Transcript(text: "", words: [])
            }
        } catch {
            Log.info("transcription failed: \(error)")
            return Transcript(text: "", words: [])
        }
    }

    /// Groups tokens into words like `buildWordTimings`, except a word ends at its last letter or
    /// digit: punctuation is only emitted once the next word starts, which would hide the pause
    /// between sentences.
    private static func words(_ tokens: [TokenTiming]) -> [WordTiming] {
        var out: [WordTiming] = []
        var word = ""
        var start = 0.0
        var end = 0.0
        func flush() {
            let w = word.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty { out.append(WordTiming(word: w, startTime: start, endTime: end)) }
        }
        for t in tokens where !t.token.isEmpty && t.token != "<blank>" && t.token != "<pad>" {
            if isWordBoundary(t.token) || word.isEmpty {
                flush()
                word = ""
                start = t.startTime
                end = t.endTime
            }
            word += t.token
            if t.token.contains(where: { $0.isLetter || $0.isNumber }) { end = t.endTime }
        }
        flush()
        return out
    }

    func transcribeOffline(_ samples: [Float]) async throws -> String {
        await finalize(samples: samples).text
    }

    /// CLI only: streams `samples` through the Unified live path in small chunks, then flushes.
    func streamWhole(_ samples: [Float]) async throws -> String {
        try await streaming.reset()
        let chunk = 4096
        var i = 0
        while i < samples.count {
            let slice = Array(samples[i..<min(i + chunk, samples.count)])
            try await streaming.appendAudio(buffer(from: slice))
            try await streaming.processBufferedAudio()
            i += chunk
        }
        let text = try await streaming.finish()
        try await streaming.reset()
        return Self.clean(text)
    }

    private func buffer(from samples: [Float]) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
