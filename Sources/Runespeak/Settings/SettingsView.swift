import AppKit
import SwiftUI
import RunespeakCore

struct SettingsView: View {
    @ObservedObject var state: AppState


    /// English language name sent to the translator → Korean label.
    static let outgoingLanguages: [(name: String, label: String)] = OverlayOutgoingLanguages.all.map { ($0.name, $0.title) }

    var body: some View {
        Form {
            AIConnectionSection(state: state)
            translationSection
            gameSection
            displaySection
            hotkeySection
            glossarySection
            usageSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 720)
    }

    // MARK: - Settings plumbing

    private func apply(_ mutate: (inout AppSettings) -> Void) {
        if let actions = state.actions {
            actions.updateSettings(mutate)
        } else {
            mutate(&state.settings)
        }
    }

    private func setting<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: { newValue in
                guard state.settings[keyPath: keyPath] != newValue else { return }
                apply { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    // MARK: - 번역

    private var translationSection: some View {
        Section("번역") {
            Picker("읽는 언어", selection: readerLanguageBinding) {
                Text("한국어").tag(ReaderLanguage.korean)
                Text("English").tag(ReaderLanguage.english)
            }
            if state.settings.readerLanguage == .english {
                Text("영어로 읽기를 고르면 한글·한자·가나·키릴 문자로 쓰인 채팅을 영어로 풀어 줍니다. 무료 번역으로는 되지 않으니 AI 키를 먼저 등록해 주세요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Picker("보낼 말의 언어", selection: setting(\.outgoingLanguage)) {
                ForEach(outgoingChoices, id: \.name) { choice in
                    Text(choice.label).tag(choice.name)
                }
            }
            LabeledContent("번역할 채팅") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ChannelGroup.allCases, id: \.self) { group in
                        Toggle(group.koreanTitle, isOn: groupBinding(group))
                            .toggleStyle(.checkbox)
                    }
                    if state.settings.enabledGroups.isEmpty {
                        Text("고른 채널이 하나도 없어서 지금은 어떤 채팅도 번역하지 않습니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var outgoingChoices: [(name: String, label: String)] {
        var choices = Self.outgoingLanguages
        let current = state.settings.outgoingLanguage
        // A value written by hand into settings.json stays selectable.
        if !choices.contains(where: { $0.name == current }) { choices.append((current, current)) }
        return choices
    }

    private var readerLanguageBinding: Binding<ReaderLanguage> {
        Binding(
            get: { state.settings.readerLanguage },
            set: { newValue in
                guard newValue != state.settings.readerLanguage else { return }
                apply { s in
                    s.readerLanguage = newValue
                    // Reading in English is for people who chat in English, so the direction of
                    // outgoing chat flips with it unless the user chose something else.
                    if newValue == .english, s.outgoingLanguage == "English" { s.outgoingLanguage = "Korean" }
                    if newValue == .korean, s.outgoingLanguage == "Korean" { s.outgoingLanguage = "English" }
                }
            }
        )
    }

    private func groupBinding(_ group: ChannelGroup) -> Binding<Bool> {
        Binding(
            get: { state.settings.enabledGroups.contains(group) },
            set: { on in
                guard on != state.settings.enabledGroups.contains(group) else { return }
                apply { s in
                    if on { s.enabledGroups.insert(group) } else { s.enabledGroups.remove(group) }
                }
            }
        )
    }

    // MARK: - 게임

    static func flavorTitle(_ flavor: GameFlavor) -> String {
        switch flavor {
        case .retail: return "리테일"
        case .classic: return "클래식"
        }
    }

    private var gameSection: some View {
        Section("게임") {
            Toggle("게임 종류 자동 감지", isOn: setting(\.autoDetectFlavor))
            if state.settings.autoDetectFlavor {
                LabeledContent("게임 종류", value: "\(Self.flavorTitle(state.activeFlavor)) (자동)")
            } else {
                Picker("게임 종류", selection: setting(\.flavor)) {
                    ForEach(GameFlavor.allCases, id: \.self) { Text(Self.flavorTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Picker("게임 클라이언트 언어", selection: setting(\.clientLocale)) {
                Text("한국어").tag(ClientLocale.koKR)
                Text("English").tag(ClientLocale.enUS)
            }
        }
    }

    // MARK: - 화면

    private var displaySection: some View {
        Section("화면") {
            LabeledContent("글자 크기") {
                HStack {
                    Slider(value: setting(\.fontSize), in: 10...28, step: 1)
                    Text("\(Int(state.settings.fontSize.rounded()))pt")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            LabeledContent("겹친 번역의 배경 진하기") {
                HStack {
                    Slider(value: setting(\.overlayOpacity), in: 0.3...1.0, step: 0.05)
                    Text("\(Int((state.settings.overlayOpacity * 100).rounded()))%")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Toggle("번역 결과를 게임 채팅창 자리에 겹쳐서 표시", isOn: setting(\.overlayEnabled))
            Toggle("화면 캡처와 스트리밍에도 겹친 번역을 포함", isOn: setting(\.showOverlayInCaptures))
            Text("해제해 두면 캡처 프로그램은 겹친 번역을 건너뛰므로, 찍힌 화면에는 게임의 원래 채팅만 남습니다.")
                .font(.footnote).foregroundStyle(.secondary)
            LabeledContent("화면을 읽는 주기") {
                HStack {
                    Slider(value: setting(\.captureInterval), in: 0.3...2.0, step: 0.1)
                    Text(String(format: "%.1f초", state.settings.captureInterval))
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            LabeledContent("채팅창 위치") {
                HStack {
                    Text(regionSummary).foregroundStyle(.secondary)
                    Button("채팅창 위치 잡기") { state.actions?.beginRegionSelection() }
                }
            }
        }
    }

    private var regionSummary: String {
        guard let rect = state.region?.rect else { return "아직 없음" }
        return "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    // MARK: - 단축키

    private var hotkeySection: some View {
        Section {
            LabeledContent("겹쳐 보기 전환") {
                hotkeyRow(\.toggleHotkey, other: \.composeHotkey, default: .defaultToggle)
            }
            LabeledContent("보낼 말 입력창") {
                hotkeyRow(\.composeHotkey, other: \.toggleHotkey, default: .defaultCompose)
            }
            Text("단축키 칸을 클릭하면 입력을 기다리니 그때 새 조합을 눌러 주세요. 입력창 단축키는 월드 오브 워크래프트 창이 활성일 때에만 가로채고 그 밖의 앱에서는 건드리지 않습니다. 겹친 번역 아래의 원래 채팅을 잠깐 보려면 마우스를 채팅창에 올린 채 ⌥ 키를 누르고 계세요.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("단축키")
        }
    }

    private func hotkeyRow(_ keyPath: WritableKeyPath<AppSettings, HotkeySpec>,
                           other: KeyPath<AppSettings, HotkeySpec>,
                           default defaultSpec: HotkeySpec) -> some View {
        HStack {
            HotkeyRecorder(
                spec: state.settings[keyPath: keyPath],
                validate: { candidate in
                    candidate == state.settings[keyPath: other] ? "다른 단축키와 같은 조합입니다" : nil
                },
                onChange: { newSpec in apply { $0[keyPath: keyPath] = newSpec } }
            )
            .fixedSize()
            Button("기본값") { apply { $0[keyPath: keyPath] = defaultSpec } }
                .disabled(state.settings[keyPath: keyPath] == defaultSpec
                          || state.settings[keyPath: other] == defaultSpec)
        }
    }

    // MARK: - 용어 사전

    private var glossarySection: some View {
        Section("용어 사전") {
            LabeledContent("게임 용어") {
                if state.glossaryCount > 0 {
                    Text("이름 \(state.glossaryCount.formatted())개 · 줄임말 \(state.abbreviationCount.formatted())개")
                } else {
                    Text("불러온 항목이 0건입니다 · build-app.sh로 만든 앱인지 확인해 주세요").foregroundStyle(.orange)
                }
            }
            Button("데이터 폴더 열기") { state.actions?.openDataFolder() }
            Text("게임 이름과 줄임말 표는 앱과 함께 설치되므로 따로 받을 것이 없습니다. 어떤 이름이 계속 엉뚱하게 옮겨진다면 위 버튼으로 폴더를 열어 my_terms.tsv에 직접 이름을 등록하세요(쓰는 법은 그 파일 첫머리에 있습니다). 등록한 이름은 Runespeak을 다시 실행하면 반영되며 AI 번역에서만 쓰입니다.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 예상 비용

    private var usageSection: some View {
        Section("예상 비용") {
            LabeledContent("오늘", value: AppState.costText(state.usageTodayKRW, incomplete: state.usageTodayIncomplete))
            LabeledContent("누적", value: AppState.costText(state.usageTotalKRW, incomplete: state.usageTotalIncomplete))
            Text("주고받은 토큰 수에 공개 단가를 곱해 원화로 바꾼 추정치입니다(세 AI 합산, 환율은 1달러 = \(Int(ModelCatalog.krwPerUSD).formatted())원 고정). 청구서는 AI 회사마다 따로 나오니 정확한 금액은 해당 회사의 결제 화면에서 보세요.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.usageTodayIncomplete || state.usageTotalIncomplete {
                Text("단가를 알 수 없는 모델로 번역한 분량은 추정치에 들어 있지 않습니다. 금액 옆의 '일부 모델 단가 미상'이 그 표시입니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("읽은 채팅과 번역을 chat_history.txt에 남기기", isOn: setting(\.saveChatLog))
        }
    }

    // MARK: - 정보

    private var aboutSection: some View {
        Section("정보") {
            VStack(alignment: .leading, spacing: 6) {
                Text("팬이 취미로 만든 도구이며 Blizzard Entertainment의 제품이 아닙니다. Blizzard의 검수나 후원, 보증을 받은 적이 없습니다.")
                Text("동작 방식: macOS 화면 캡처로 채팅창 사각형의 그림을 받아 거기서 글자를 인식합니다. 게임 프로세스와 게임 폴더에는 접근하지 않고, 자동으로 입력해 주는 기능도 없습니다.")
                Text("보낼 말 번역은 결과를 클립보드에 올려 두는 데서 끝납니다. 채팅 입력줄에 넣는 ⌘V는 사용자가 누릅니다.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
