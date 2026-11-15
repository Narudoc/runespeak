import CoreGraphics
import Foundation
import RunespeakCore

/// One capture → new chat messages. Skips OCR when the picture did not change, but keeps feeding
/// the tracker for a few ticks: it holds the bottom line (and distrusted readings) back until it
/// has seen them again, and a quiet chat would otherwise never release them.
final class FrameProcessor {
    /// Frames the tracker may need to settle: its longest hold is six frames.
    static let settleFrames = 7

    private let recognizer: TextRecognizing
    private let tracker: ChatTracker
    private let locale: ClientLocale
    private var lastFingerprint: UInt64?
    private var lastFrame: OCRFrame?
    private var repeatsLeft = 0
    private(set) var ocrRuns = 0
    /// For the messages the latest `process` returned that say again what earlier ones said
    /// in part (`ChatTracker.corrections`): the ids of those earlier messages.
    private(set) var corrections: [UUID: [UUID]] = [:]

    init(recognizer: TextRecognizing, locale: ClientLocale) {
        self.recognizer = recognizer
        self.locale = locale
        tracker = ChatTracker(clientLocale: locale)
    }

    func process(_ image: CGImage, now: Date) async throws -> [ChatMessage] {
        corrections = [:]
        let fingerprint = VisionTextRecognizer.fingerprint(image)
        if fingerprint == lastFingerprint, let frame = lastFrame {
            guard repeatsLeft > 0 else { return [] }
            repeatsLeft -= 1
            return ingest(frame, now: now)
        }
        let frame = try await recognizer.recognize(image, clientLocale: locale)
        ocrRuns += 1
        lastFingerprint = fingerprint
        lastFrame = frame
        repeatsLeft = Self.settleFrames
        return ingest(frame, now: now)
    }

    private func ingest(_ frame: OCRFrame, now: Date) -> [ChatMessage] {
        let messages = tracker.ingest(frame, now: now)
        corrections = tracker.corrections
        return messages
    }
}

/// The background loop: capture → OCR → tracker, one run at a time, never on the main thread.
final class CaptureLoop: @unchecked Sendable {
    struct Config: Sendable {
        var region: CaptureRegion?
        var interval: Double
        var locale: ClientLocale
        /// Bumped when the region or the client language changes: the tracker starts over and
        /// results of an older generation are thrown away.
        var generation: Int
    }

    private let capturer: ChatCapturing
    private let recognizer: TextRecognizing
    private let config: @MainActor () -> Config
    private let onStatus: @MainActor (PipelineStatus) -> Void
    /// New messages, the earlier messages some of them stand in for (by the new message's
    /// id, see `ChatTracker.corrections`), and the generation they belong to.
    private let onMessages: @MainActor ([ChatMessage], [UUID: [UUID]], Int) -> Void
    private let onError: @Sendable (String) -> Void
    private var task: Task<Void, Never>?

    init(capturer: ChatCapturing, recognizer: TextRecognizing,
         config: @escaping @MainActor () -> Config,
         onStatus: @escaping @MainActor (PipelineStatus) -> Void,
         onMessages: @escaping @MainActor ([ChatMessage], [UUID: [UUID]], Int) -> Void,
         onError: @escaping @Sendable (String) -> Void) {
        self.capturer = capturer
        self.recognizer = recognizer
        self.config = config
        self.onStatus = onStatus
        self.onMessages = onMessages
        self.onError = onError
    }

    /// Main thread only.
    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [self] in await run() }
    }

    /// Main thread only.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// A stale window handle fails once or twice when the game window changes; only a run of
    /// failures is shown.
    static let captureFailuresBeforeStatus = 3

    private func run() async {
        var processor: FrameProcessor?
        var generation = -1
        var failures = 0
        var captureFailures = 0
        var loggedCaptureFailures: Set<String> = []

        while !Task.isCancelled {
            let started = Date()
            let config = await self.config()
            var pause = min(5, max(0.2, config.interval))

            if generation != config.generation || processor == nil {
                generation = config.generation
                processor = FrameProcessor(recognizer: recognizer, locale: config.locale)
            }

            if !capturer.hasPermission() {
                await onStatus(.needsScreenRecordingPermission)
                pause = 1.5
            } else if let region = config.region {
                switch await capturer.capture(region: region) {
                case .noPermission:
                    await onStatus(.needsScreenRecordingPermission)
                    pause = 1.5
                case .gameNotVisible:
                    captureFailures = 0
                    await onStatus(.pausedGameNotVisible)
                    pause = max(pause, 1)
                case .failed(let detail):
                    captureFailures += 1
                    // Once per kind of error: the same one would otherwise fill the log.
                    if loggedCaptureFailures.insert(detail).inserted { onError("화면 캡처 실패: \(detail)") }
                    if captureFailures >= Self.captureFailuresBeforeStatus {
                        await onStatus(.error("게임 화면을 찍지 못했습니다 (\(detail))"))
                    }
                    pause = max(pause, captureFailures >= Self.captureFailuresBeforeStatus ? 2 : 1)
                case .image(let image):
                    captureFailures = 0
                    do {
                        let messages = try await processor!.process(image, now: Date())
                        let corrections = processor!.corrections
                        failures = 0
                        if Task.isCancelled { return }
                        await onStatus(.running)
                        if !messages.isEmpty { await onMessages(messages, corrections, generation) }
                    } catch {
                        failures += 1
                        // One bad frame is nothing; a run of them is worth telling the user.
                        if failures == 5 {
                            onError("글자 읽기 실패가 이어집니다: \(error)")
                            await onStatus(.error("채팅창 글자를 읽지 못하고 있습니다"))
                        }
                    }
                }
            } else {
                await onStatus(.needsRegion)
                pause = 0.5
            }

            let rest = max(0.05, pause - Date().timeIntervalSince(started))
            try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))
        }
    }
}
