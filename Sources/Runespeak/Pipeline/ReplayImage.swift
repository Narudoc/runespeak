import CoreGraphics
import Foundation
import ImageIO
import RunespeakCore

/// `--replay-image <png> [<png> ...] [--crop x,y,w,h] [--frames N] [--locale koKR|enUS]`: runs
/// saved screenshots through the recogniser and the tracker the capture loop uses, without the
/// game. Several images are consecutive captures of the same region, one capture interval
/// apart; the last one is then repeated until N frames (default 3 for a single image, images +
/// 6 for several) have been fed, the way a chat that stopped changing is re-read. Prints
/// every recognised line of every distinct image (box, confidence, colour), then each chat
/// message the tracker emits. Headless: no network, no translation, no permission.
enum ReplayImage {
    /// Hands the frame it read to the caller as well as to the `FrameProcessor`.
    private final class RecordingRecognizer: TextRecognizing {
        let inner = VisionTextRecognizer()
        var frames: [OCRFrame] = []
        func recognize(_ image: CGImage, clientLocale: ClientLocale) async throws -> OCRFrame {
            let frame = try await inner.recognize(image, clientLocale: clientLocale)
            frames.append(frame)
            return frame
        }
    }

    static func run() async -> Int32 {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        var paths: [String] = []
        if let flag = arguments.firstIndex(of: "--replay-image") {
            for argument in arguments[(flag + 1)...] {
                if argument.hasPrefix("--") { break }
                paths.append(argument)
            }
        }
        guard !paths.isEmpty else {
            print("사용법: --replay-image <png> [<png> ...] [--crop x,y,w,h] [--frames N] [--locale koKR|enUS]")
            return 2
        }
        var crop: CGRect?
        if let text = value("--crop") {
            let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else {
                print("--crop 형식: x,y,w,h (픽셀, 왼쪽 위 기준)")
                return 2
            }
            crop = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        var images: [CGImage] = []
        for path in paths {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("이미지를 열 수 없습니다: \(path)")
                return 2
            }
            print("image: \(image.width)x\(image.height) px")
            if let crop {
                // CGImage cropping uses top-left pixel coordinates already.
                let rect = crop.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
                guard !rect.isEmpty, let cropped = image.cropping(to: rect) else {
                    print("--crop 영역이 이미지 밖입니다")
                    return 2
                }
                image = cropped
                print("crop: x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))")
            } else {
                print("crop: (none)")
            }
            images.append(image)
        }

        let frames = max(images.count, value("--frames").flatMap { Int($0) } ?? (images.count == 1 ? 3 : images.count + 6))
        let locale = value("--locale").flatMap { ClientLocale(rawValue: $0) } ?? .koKR
        let settings = AppSettings()   // defaults; reader language Korean
        var everyTab = settings
        everyTab.enabledGroups = Set(ChannelGroup.allCases)
        print("locale: \(locale.rawValue)  frames: \(frames)  interval: \(settings.captureInterval)s")

        let recognizer = RecordingRecognizer()
        let processor = FrameProcessor(recognizer: recognizer, locale: locale)
        let start = Date()
        var emitted: [(frame: Int, messages: [ChatMessage])] = []
        // For a message that says an earlier one again (see `ChatTracker.corrections`): the
        // earlier messages it stands in for.
        var corrections: [UUID: [UUID]] = [:]
        do {
            for index in 0..<frames {
                let now = start.addingTimeInterval(Double(index) * settings.captureInterval)
                emitted.append((index + 1, try await processor.process(images[min(index, images.count - 1)], now: now)))
                corrections.merge(processor.corrections) { _, new in new }
            }
        } catch {
            print("글자 읽기 실패: \(error)")
            return 1
        }

        func f(_ v: CGFloat) -> String { String(format: "%.0f", Double(v)) }
        for (n, frame) in recognizer.frames.enumerated() {
            let title = recognizer.frames.count > 1 ? "OCR lines of image \(n + 1)" : "OCR lines"
            print("\n== \(title) (\(frame.lines.count)), image \(f(frame.imageSize.width))x\(f(frame.imageSize.height)) ==")
            for (i, line) in frame.lines.enumerated() {
                let box = line.box
                let color = String(format: "%.2f,%.2f,%.2f", line.color.r, line.color.g, line.color.b)
                print(String(format: "%2d", i) + "  x=\(f(box.minX)) y=\(f(box.minY)) w=\(f(box.width)) h=\(f(box.height))"
                      + "  conf=" + String(format: "%.2f", line.confidence) + "  rgb=\(color)  |\(line.text)|")
            }
        }

        print("\n== Tracker (OCR runs: \(processor.ocrRuns)) ==")
        var total = 0
        var numbers: [UUID: Int] = [:]
        var replaced = 0
        for (frame, messages) in emitted {
            print("-- frame \(frame): \(messages.count) message(s)")
            for message in messages {
                total += 1
                numbers[message.id] = total
                let byDefault = TranslationPolicy.shouldTranslate(message, settings: settings)
                let allTabs = TranslationPolicy.shouldTranslate(message, settings: everyTab)
                print("   #\(total) channel=\(message.channel.rawValue) label=\(message.channelLabel.map { "\"\($0)\"" } ?? "nil")"
                      + " sender=\(message.sender.map { "\"\($0)\"" } ?? "nil")")
                print("     body: |\(message.body)|")
                print("     raw:  |\(message.rawText)|")
                print("     translate: default tabs=\(byDefault ? "yes" : "no"), all tabs on=\(allTabs ? "yes" : "no")")
                if let earlier = corrections[message.id], !earlier.isEmpty {
                    replaced += earlier.count
                    print("     replaces: " + earlier.map { numbers[$0].map { "#\($0)" } ?? "?" }.joined(separator: ", ")
                          + " (reported before this row could be read)")
                }
            }
        }
        print("\ntotal messages: \(total)" + (replaced > 0 ? " (\(total - replaced) lines after replacements)" : ""))
        return 0
    }
}
