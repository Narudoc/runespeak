import AppKit
import SwiftUI
import RunespeakCore

// MARK: - Root

struct MainWindowRootView: View {
    @ObservedObject var state: AppState
    @State private var toast: String?
    @State private var toastGeneration = 0
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            MainWindowStatusLine(status: state.status, actions: state.actions)
            toolbar
            banners
            Divider()
            MainWindowHistoryList(entries: state.entries, state: state, notify: showToast)
                .overlay(alignment: .bottom) { toastView }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(state.$notice) { notice in
            if let notice { showToast(notice) }
        }
        .confirmationDialog("번역 기록을 모두 지울까요?", isPresented: $confirmingClear) {
            Button("기록 지우기", role: .destructive) { state.actions?.clearHistory() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기록 창의 목록과 게임 위에 겹쳐 있던 줄이 함께 사라집니다.")
        }
    }

    private var isCovering: Bool { state.settings.overlayEnabled && state.overlayVisible }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("채팅창 위치 잡기") { state.actions?.beginRegionSelection() }
                .help("게임 화면 위에서 채팅창을 감싸는 사각형을 그립니다. 채널 이름이 시작되는 왼쪽 가장자리까지 넣어 주세요")
            Button(isCovering ? "겹쳐 보기 끄기" : "겹쳐 보기 켜기") { state.actions?.toggleOverlay() }
                .help("번역한 줄을 게임 채팅창과 같은 자리에 띄우거나 내립니다 (\(state.settings.toggleHotkey.displayString))")
            Button("보낼 말 번역") { state.actions?.showCompose() }
                .help("적은 말을 상대 언어로 바꿔 클립보드에 넣어 둡니다 (게임 안에서는 \(state.settings.composeHotkey.displayString))")
            Button("설정") { state.actions?.showSettings() }
            Spacer(minLength: 8)
            Button("기록 지우기") { confirmingClear = true }
                .disabled(state.entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var banners: some View {
        if !state.hasAPIKey {
            MainWindowBanner(text: Self.noKeyBanner(state),
                             buttonTitle: "키 입력") { state.actions?.showSettings() }
        }
        if state.glossaryCount == 0 {
            MainWindowBanner(text: "게임 용어 사전을 하나도 읽지 못했습니다. swift build로 만든 실행 파일에는 사전이 들어 있지 않으니 scripts/build-app.sh가 만든 앱을 실행해 주세요",
                             buttonTitle: "데이터 폴더 열기") { state.actions?.openDataFolder() }
        }
    }

    static func noKeyBanner(_ state: AppState) -> String {
        let others = state.keyedProviders.subtracting([state.settings.provider])
        if others.isEmpty {
            return "등록된 AI 키가 없어 MyMemory 무료 번역이 대신하고 있습니다. 게임 용어에 약하고 하루에 옮길 수 있는 분량이 정해져 있습니다"
        }
        // A key is stored, just not for the provider that is selected.
        return "\(state.settings.provider.shortName) 키가 등록되지 않아 MyMemory 무료 번역이 대신하고 있습니다. 게임 용어에 약하고 하루에 옮길 수 있는 분량이 정해져 있습니다"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if state.hasAPIKey {
                Text("오늘 쓴 금액(추정) \(AppState.costText(state.usageTodayKRW, incomplete: state.usageTodayIncomplete))")
                if state.usageTotalKRW > 0 || state.usageTotalIncomplete {
                    Text("누적 \(AppState.costText(state.usageTotalKRW, incomplete: state.usageTotalIncomplete))").foregroundStyle(.tertiary)
                }
            } else {
                Text("MyMemory 무료 번역 · 과금 없음")
            }
            Spacer(minLength: 8)
            Text("\(state.activeEngineTitle) · \(state.activeFlavor == .retail ? "리테일" : "클래식")")
                .foregroundStyle(.tertiary)
            Text("기록 \(state.entries.count)줄")
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.yellow.opacity(0.5)))
                .padding(.bottom, 10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func showToast(_ message: String) {
        toastGeneration += 1
        let generation = toastGeneration
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            guard generation == toastGeneration else { return }
            withAnimation(.easeIn(duration: 0.3)) { toast = nil }
        }
    }
}

// MARK: - Status line

private struct MainWindowStatusLine: View {
    let status: PipelineStatus
    let actions: AppActions?

    private static let screenRecordingSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(status.koreanText)
                .font(.headline)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            switch status {
            case .needsScreenRecordingPermission:
                Button("시스템 설정 열기") {
                    if let url = Self.screenRecordingSettingsURL { NSWorkspace.shared.open(url) }
                }
                .help("열리는 설정 화면의 앱 목록에서 Runespeak의 스위치를 올려 주세요. 이미 켜져 있다면 껐다가 다시 켜거나, 목록에서 [−]로 지운 뒤 새로 허용합니다. 허용은 앱을 새로 띄워야 적용됩니다")
                Button("다시 실행") { actions?.relaunch() }
                    .help("스위치를 올린 다음 누르면 번역기가 스스로 종료했다가 다시 뜹니다")
            case .needsRegion:
                Button("채팅창 위치 잡기") { actions?.beginRegionSelection() }
                    .keyboardShortcut(.defaultAction)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var dotColor: Color {
        switch status {
        case .starting: return .yellow
        case .running: return .green
        case .needsScreenRecordingPermission, .needsRegion: return .orange
        case .pausedGameNotVisible: return .gray
        case .error: return .red
        }
    }
}

private struct MainWindowBanner: View {
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(buttonTitle, action: action).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow.opacity(0.35)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

// MARK: - History

private struct MainWindowHistoryList: View {
    let entries: [ChatEntry]
    let state: AppState
    let notify: (String) -> Void

    @State private var isAtBottom = true
    @StateObject private var pin = MainWindowBottomPin()

    var body: some View {
        if entries.isEmpty {
            VStack(spacing: 6) {
                Text("표시할 기록이 없습니다")
                    .font(.title3)
                Text("번역기가 채팅창에서 새 줄을 읽을 때마다 원문과 번역이 이 목록에 추가됩니다.")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        MainWindowHistoryRow(entry: entry, menu: menuProvider(for: entry.id))
                            .equatable()
                    }
                }
                .background(MainWindowBottomPinAnchor(pin: pin))
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                pin.onPinnedChange = { isAtBottom = $0 }
                isAtBottom = pin.isPinned
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        pin.scrollToBottom()
                    } label: {
                        Label("최신 채팅", systemImage: "arrow.down")
                    }
                    .controlSize(.small)
                    .padding(10)
                }
            }
        }
    }

    private func menuProvider(for id: UUID) -> () -> NSMenu? {
        { [weak state] in
            // Look the entry up at click time: the row's copy may be older than the state.
            guard let state, let entry = state.entries.first(where: { $0.id == id }) else { return nil }
            return OverlayChatMenu.entryMenu(for: entry, state: state, notify: notify)
        }
    }
}

private struct MainWindowHistoryRow: View, Equatable {
    let entry: ChatEntry
    let menu: () -> NSMenu?

    // The menu closure only captures the entry id, so the entry alone decides whether to redraw.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.entry == rhs.entry }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.timeFormatter.string(from: entry.message.firstSeen))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                headline
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
            Spacer(minLength: 6)
            if let engine = entry.engine, !engine.isEmpty {
                Text(engine)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
                    .foregroundStyle(.secondary)
                    .help("번역에 쓰인 엔진")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
        .overlay { MainWindowRightClickCatcher(menu: menu) }
    }

    private var chatColor: Color { Color(nsColor: entry.message.color.overlayNSColor) }

    private var headline: Text {
        var prefix = Text("")
        if let tag = OverlayChatFormat.channelTag(for: entry.message) {
            prefix = prefix + Text("[\(tag)] ").foregroundColor(chatColor)
        }
        let sender = ChatDisplay.senderPrefix(for: entry.message)
        if !sender.isEmpty {
            prefix = prefix + Text(sender).fontWeight(.semibold).foregroundColor(chatColor)
        }
        switch entry.state {
        case .translated(let text):
            return prefix + Text(text).foregroundColor(.primary)
        case .original:
            return prefix + Text(ChatDisplay.body(for: entry.message)).foregroundColor(chatColor)
        case .pending, .failed:
            return prefix + Text(entry.message.body).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var detail: some View {
        switch entry.state {
        case .translated:
            Text(entry.message.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .pending:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("번역하는 중…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Label("번역 실패: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
        case .original:
            EmptyView()
        }
        if let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            Label(note, systemImage: "lightbulb")
                .font(.callout)
                .foregroundStyle(Color(red: 0.6, green: 0.8, blue: 1))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Staying at the newest line

/// Keeps the history at the newest line while the user has not scrolled up.
///
/// Done on the NSScrollView behind SwiftUI's ScrollView: `defaultScrollAnchor(.bottom)` only places
/// the initial position — measured on macOS 27, the list drifts off the bottom when the viewport
/// shrinks (a warning banner appears, the window is resized) and when lazy rows change height.
@MainActor
final class MainWindowBottomPin: ObservableObject {
    private(set) var isPinned = true
    var onPinnedChange: ((Bool) -> Void)?

    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var lastDocumentHeight: CGFloat = -1
    private var lastViewportSize = NSSize(width: -1, height: -1)
    private var recheckScheduled = false

    func attach(to scrollView: NSScrollView?) {
        guard scrollView !== self.scrollView else { return }
        detach()
        self.scrollView = scrollView
        guard let scrollView else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        var sources: [(NSNotification.Name, NSView)] = [
            (NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, clip),
        ]
        if let document = scrollView.documentView { sources.append((NSView.frameDidChangeNotification, document)) }
        for (name, view) in sources {
            observers.append(center.addObserver(forName: name, object: view, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.geometryChanged() }
            })
        }
        isPinned = true
        geometryChanged()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        scrollView = nil
        lastDocumentHeight = -1
        lastViewportSize = NSSize(width: -1, height: -1)
    }

    func scrollToBottom() {
        setPinned(true)
        moveToBottom()
    }

    private func geometryChanged() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let viewport = scrollView.contentView.bounds
        let documentHeight = document.frame.height
        if documentHeight != lastDocumentHeight || viewport.size != lastViewportSize {
            // Layout moved under the user (new line, row height settled, viewport resized):
            // not a scroll, so the pinned state stands and is re-applied.
            lastDocumentHeight = documentHeight
            lastViewportSize = viewport.size
            if isPinned {
                moveToBottom()
                // SwiftUI may still reposition the content later in this layout pass.
                scheduleRecheck()
            }
            return
        }
        setPinned(Self.distanceFromBottom(scrollView) < 12)
    }

    private func scheduleRecheck() {
        guard !recheckScheduled else { return }
        recheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recheckScheduled = false
            if self.isPinned { self.moveToBottom() }
        }
    }

    private func moveToBottom() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxOffset = max(0, document.frame.height - clip.bounds.height)
        let target = document.isFlipped ? maxOffset : 0
        guard abs(clip.bounds.origin.y - target) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    private static func distanceFromBottom(_ scrollView: NSScrollView) -> CGFloat {
        guard let document = scrollView.documentView else { return 0 }
        let visible = scrollView.contentView.bounds
        return document.isFlipped ? document.frame.height - visible.maxY : visible.minY
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        // Reported on the next turn: this can run in the middle of a SwiftUI layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPinnedChange?(self.isPinned)
        }
    }
}

/// Invisible view inside the scroll content whose only job is to find the enclosing NSScrollView.
private struct MainWindowBottomPinAnchor: NSViewRepresentable {
    let pin: MainWindowBottomPin

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.pin = pin
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.pin = pin
        nsView.attach()
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.pin?.detach()
    }

    final class AnchorView: NSView {
        weak var pin: MainWindowBottomPin?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard window != nil, let scrollView = enclosingScrollView else { return }
            pin?.attach(to: scrollView)
        }
    }
}

// MARK: - Right-click support

/// Transparent AppKit layer over a row that takes ONLY right clicks (and Control-clicks), so the
/// text underneath stays selectable while the row still offers the shared NSMenu.
private struct MainWindowRightClickCatcher: NSViewRepresentable {
    let menu: () -> NSMenu?

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.provider = menu
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.provider = menu
    }

    final class CatcherView: NSView {
        var provider: (() -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContextClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContextClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { provider?() }

        // A Control-click arrives as a left press; AppKit only turns it into a menu for views
        // that handle it, so do it explicitly.
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = provider?() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
