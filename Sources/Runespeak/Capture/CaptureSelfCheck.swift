import AppKit
import CoreGraphics
import RunespeakCore

/// `--ocr-selftest --capture-check`: exercises the capture path without the game. Geometry is
/// checked headless; if this process has screen-recording permission, a small test-pattern
/// window is shown for a moment and captured through the same code that captures the game
/// window, which proves the coordinate flip, the crop, the pixel scale and that this app's own
/// windows stay out of a display capture.
enum CaptureSelfCheck {

    @MainActor
    static func run() -> Int32 {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) {
            print("  \(ok ? "통과" : "실패")  \(what)")
            if !ok { failures.append(what) }
        }

        print("[게임 찾기]")
        print("  번들 ID: \(GameApp.bundleIDs.sorted().joined(separator: ", "))")
        if let game = GameApp.runningApplication() {
            print("  실행 중: \(game.bundleURL?.path ?? "?") → \(GameApp.flavor(of: game).map(\.rawValue) ?? "?")")
        } else {
            print("  게임이 실행 중이 아닙니다.")
        }
        expect(GameApp.flavor(ofInstallPath: "/Applications/World of Warcraft/_retail_/World of Warcraft.app") == .retail,
               "_retail_ → retail")
        expect(GameApp.flavor(ofInstallPath: "/Applications/World of Warcraft/_classic_era_/World of Warcraft Classic.app") == .classic,
               "_classic_era_ → classic")
        expect(GameApp.flavor(ofInstallPath: "/Applications/World of Warcraft/_anniversary_/World of Warcraft.app") == .classic,
               "_anniversary_ → classic")
        expect(GameApp.flavor(ofInstallPath: "/Applications/World of Warcraft/_classic_beta_/World of Warcraft Classic.app") == .classic,
               "_classic_beta_ → classic")

        print("[좌표]")
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let flipped = ScreenChatCapturer.cgRect(fromAppKit: CGRect(x: 30, y: 40, width: 600, height: 250))
        expect(flipped == CGRect(x: 30, y: primaryHeight - 290, width: 600, height: 250), "AppKit → Quartz 좌표 변환")
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        expect(ScreenChatCapturer.visiblePart(of: CGRect(x: 120, y: 400, width: 500, height: 200), in: frame)
               == CGRect(x: 120, y: 400, width: 500, height: 200), "창 안의 영역은 그대로")
        expect(ScreenChatCapturer.visiblePart(of: CGRect(x: 80, y: 400, width: 500, height: 200), in: frame)
               == CGRect(x: 100, y: 400, width: 480, height: 200), "창을 조금 벗어난 영역은 잘라서")
        expect(ScreenChatCapturer.visiblePart(of: CGRect(x: 2000, y: 400, width: 500, height: 200), in: frame) == nil,
               "창 밖의 영역은 캡처하지 않음")
        expect(ScreenChatCapturer.visiblePart(of: CGRect(x: -300, y: 400, width: 500, height: 200), in: frame) == nil,
               "절반 넘게 벗어난 영역은 캡처하지 않음")

        print("[영역 지정 화면]")
        for problem in RegionSelector.selfCheck() { expect(false, problem) }
        expect(true, "드래그·취소·최소 크기 처리")

        print("[화면 캡처]")
        let capturer = ScreenChatCapturer()
        guard capturer.hasPermission() else {
            print("  건너뜀: 이 프로세스에 화면 기록 권한이 없습니다.")
            return finish(failures)
        }
        guard let screen = NSScreen.screens.first else {
            print("  건너뜀: 화면이 없습니다.")
            return finish(failures)
        }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let windowFrame = CGRect(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 80, width: 420, height: 260)
        let window = NSWindow(contentRect: windowFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hasShadow = false
        window.contentView = PatternView(frame: CGRect(origin: .zero, size: windowFrame.size))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        pump(0.6)

        let pid = ProcessInfo.processInfo.processIdentifier
        let scale = screen.backingScaleFactor
        func shoot(_ rect: CGRect, display: Bool = false) -> CaptureResult {
            var result: CaptureResult = .gameNotVisible
            var done = false
            Task.detached {
                let r = await capturer.capture(region: CaptureRegion(rect: rect), ownerPID: pid, forceDisplayCapture: display)
                await MainActor.run { result = r; done = true }
            }
            let deadline = Date().addingTimeInterval(8)
            while !done, Date() < deadline { pump(0.02) }
            return result
        }
        /// Pixel at a point given in points from the image's top-left corner.
        func pixel(_ image: CGImage, _ x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int)? {
            guard let buffer = PixelBuffer(image) else { return nil }
            let px = min(buffer.width - 1, max(0, Int(x * scale))), py = min(buffer.height - 1, max(0, Int(y * scale)))
            let o = buffer.offset(px, py)
            return (Int(buffer.data[o]), Int(buffer.data[o + 1]), Int(buffer.data[o + 2]))
        }
        func isRed(_ p: (r: Int, g: Int, b: Int)?) -> Bool { p.map { $0.r > 180 && $0.g < 90 && $0.b < 90 } ?? false }
        func isBlue(_ p: (r: Int, g: Int, b: Int)?) -> Bool { p.map { $0.b > 180 && $0.r < 90 && $0.g < 90 } ?? false }
        func isGreen(_ p: (r: Int, g: Int, b: Int)?) -> Bool { p.map { $0.g > 150 && $0.r < 90 && $0.b < 90 } ?? false }
        func isBlack(_ p: (r: Int, g: Int, b: Int)?) -> Bool { p.map { $0.r < 12 && $0.g < 12 && $0.b < 12 } ?? false }

        // Whole window: green square top-left, red left half, blue right half.
        if case .image(let image) = shoot(windowFrame) {
            expect(image.width == Int(420 * scale) && image.height == Int(260 * scale),
                   "창 전체: 원래 픽셀 해상도 (\(image.width)×\(image.height), 배율 \(scale))")
            expect(isGreen(pixel(image, 15, 15)), "창 전체: 왼쪽 위 초록")
            expect(isRed(pixel(image, 100, 200)), "창 전체: 왼쪽 빨강")
            expect(isBlue(pixel(image, 320, 60)), "창 전체: 오른쪽 파랑")
        } else {
            expect(false, "창 전체 캡처")
        }

        // Bottom-right quarter in AppKit coordinates (y up): all blue.
        let quarter = CGRect(x: windowFrame.minX + 210, y: windowFrame.minY, width: 210, height: 130)
        if case .image(let image) = shoot(quarter) {
            expect(image.width == Int(210 * scale) && image.height == Int(130 * scale), "부분 영역: 크기")
            expect(isBlue(pixel(image, 5, 5)) && isBlue(pixel(image, 200, 120)), "부분 영역: 오른쪽 아래만 잘림")
        } else {
            expect(false, "부분 영역 캡처")
        }

        // Top-left corner: the green square, which only a correct y flip finds.
        let corner = CGRect(x: windowFrame.minX, y: windowFrame.maxY - 40, width: 40, height: 40)
        if case .image(let image) = shoot(corner) {
            expect(isGreen(pixel(image, 20, 20)), "위아래 뒤집힘 없음")
        } else {
            expect(false, "모서리 캡처")
        }

        // 30 pt over the left edge: padded black, content shifted right.
        let over = CGRect(x: windowFrame.minX - 30, y: windowFrame.minY, width: 200, height: 100)
        if case .image(let image) = shoot(over) {
            expect(image.width == Int(200 * scale) && image.height == Int(100 * scale), "창을 벗어난 영역: 크기 유지")
            expect(isBlack(pixel(image, 10, 50)) && isRed(pixel(image, 60, 50)), "창을 벗어난 부분은 검게 채움")
        } else {
            expect(false, "창을 벗어난 영역 캡처")
        }

        if case .gameNotVisible = shoot(CGRect(x: windowFrame.minX - 400, y: windowFrame.minY, width: 300, height: 100)) {
            expect(true, "창 밖 영역 → 쉬는 상태")
        } else {
            expect(false, "창 밖 영역 → 쉬는 상태")
        }

        // Display capture must not contain this app's own window.
        if case .image(let image) = shoot(windowFrame, display: true) {
            expect(image.width == Int(420 * scale) && image.height == Int(260 * scale), "화면 캡처: 크기")
            let own = isGreen(pixel(image, 15, 15)) && isRed(pixel(image, 100, 200)) && isBlue(pixel(image, 320, 60))
            expect(!own, "화면 캡처: 이 앱의 창은 찍히지 않음")
        } else {
            expect(false, "화면 캡처")
        }

        // Moving the window must be noticed without a manual reset.
        window.setFrameOrigin(CGPoint(x: windowFrame.minX + 60, y: windowFrame.minY + 40))
        pump(0.5)
        let movedCorner = CGRect(x: windowFrame.minX + 60, y: windowFrame.minY + 40 + 220, width: 40, height: 40)
        if case .image(let image) = shoot(movedCorner) {
            expect(isGreen(pixel(image, 20, 20)), "창을 옮겨도 따라감")
        } else {
            expect(false, "옮긴 창 캡처")
        }

        // Timing of the steady state (cached window and filter).
        var total = 0.0
        let rounds = 10
        for _ in 0..<rounds {
            let start = CFAbsoluteTimeGetCurrent()
            _ = shoot(movedCorner)
            total += CFAbsoluteTimeGetCurrent() - start
        }
        print(String(format: "  캡처 한 번에 평균 %.0f ms", total / Double(rounds) * 1000))

        window.orderOut(nil)
        pump(0.4)
        if case .gameNotVisible = shoot(windowFrame) {
            expect(true, "창이 사라지면 쉬는 상태")
        } else {
            expect(false, "창이 사라지면 쉬는 상태")
        }
        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Int32 {
        print(failures.isEmpty ? "결과: 통과" : "결과: 실패 \(failures.count)건")
        return failures.isEmpty ? 0 : 1
    }

    @MainActor
    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private final class PatternView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.midX, height: bounds.height))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: bounds.midX, y: 0, width: bounds.width - bounds.midX, height: bounds.height))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }
}
