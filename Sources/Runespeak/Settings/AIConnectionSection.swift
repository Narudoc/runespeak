import AppKit
import SwiftUI
import RunespeakCore

/// "AI 연결": which provider translates, its API key and its two models.
struct AIConnectionSection: View {
    @ObservedObject var state: AppState

    private enum Job { case checking, listing }
    private struct Outcome {
        var job: Job
        var ok: Bool
        var text: String
    }

    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var confirmRemoveKey = false
    @State private var running: Job?
    @State private var outcome: Outcome?
    @State private var customModelDraft = ""

    private var provider: AIProvider { state.settings.provider }
    private var hasKey: Bool { state.hasKey(provider) }

    var body: some View {
        Section {
            Picker("AI 제공자", selection: providerBinding) {
                ForEach(AIProvider.allCases, id: \.self) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            keyDots

            HStack {
                SecureField("\(provider.shortName) API 키", text: $keyDraft,
                            prompt: Text(hasKey ? "새 키로 바꾸려면 붙여넣기" : "\(provider.keyFormatHint) — 붙여넣기"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                Button("저장", action: saveKey)
                    .disabled(trimmedKeyDraft.isEmpty)
                Button("지우기") { confirmRemoveKey = true }
                    .disabled(!hasKey)
            }
            HStack {
                if hasKey {
                    Label("저장됨", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("등록된 키 없음 · 지금은 MyMemory 무료 번역이 대신합니다", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("연결 확인") { run(.checking) }
                    .disabled(!hasKey || running != nil)
                Button("키 만드는 곳 열기") { NSWorkspace.shared.open(provider.keyConsoleURL) }
                    .buttonStyle(.link)
            }
            if let keyMessage {
                Text(keyMessage).font(.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if running == .checking {
                progressRow("\(provider.companyName)에 연결해 보는 중…")
            } else if let outcome, outcome.job == .checking {
                outcomeRow(outcome)
            }

            modelPicker("번역 모델", retranslate: false)
            modelPicker("다시 번역 모델", retranslate: true)
            HStack {
                TextField("모델 ID 직접 입력", text: $customModelDraft, prompt: Text("모델 ID 직접 입력"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button("번역에 적용") { applyCustomModel(retranslate: false) }
                    .disabled(trimmedCustomModel.isEmpty)
                    .fixedSize()
                Button("다시 번역에 적용") { applyCustomModel(retranslate: true) }
                    .disabled(trimmedCustomModel.isEmpty)
                    .fixedSize()
            }
            HStack {
                Button("모델 목록 새로 고침") { run(.listing) }
                    .disabled(!hasKey || running != nil)
                if running == .listing {
                    ProgressView().controlSize(.small)
                    Text("불러오는 중…").foregroundStyle(.secondary)
                } else if let outcome, outcome.job == .listing {
                    outcomeLabel(outcome)
                } else if !hasKey {
                    Text("키를 등록한 뒤에 모델 목록을 받아올 수 있습니다").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)

            Text("채팅창에서 인식한 글자는 번역을 위해 외부 서버로 전송됩니다. 받는 곳은 위에서 선택한 AI의 운영사(현재 \(provider.companyName))이고, 그 AI의 키가 비어 있으면 MyMemory입니다. 입력한 키는 이 컴퓨터의 파일로만 보관되며 해당 운영사에 요청할 때에만 쓰입니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("ChatGPT Plus, Claude.ai, Gemini 앱 같은 월 구독으로는 API를 쓸 수 없습니다. 개발자용 콘솔에서 키를 따로 만들어야 하며, 번역한 분량만큼 \(provider.companyName)가 과금합니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("AI 연결")
        }
        .confirmationDialog("저장된 \(provider.shortName) API 키를 지울까요?", isPresented: $confirmRemoveKey) {
            Button("지우기", role: .destructive) {
                state.actions?.saveAPIKey("", for: provider)
                keyDraft = ""
                keyMessage = nil
                outcome = nil
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("키가 없는 동안 \(provider.shortName)를 선택하면 MyMemory 무료 번역이 대신합니다.")
        }
        .onChange(of: provider) { _, _ in
            // Everything typed or reported so far was about the other provider.
            keyDraft = ""
            keyMessage = nil
            outcome = nil
            customModelDraft = ""
        }
    }

    // MARK: - Provider and key

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { state.settings.provider },
            set: { newValue in
                guard newValue != state.settings.provider else { return }
                apply { $0.provider = newValue }
            }
        )
    }

    private var keyDots: some View {
        HStack(spacing: 14) {
            ForEach(AIProvider.allCases, id: \.self) { item in
                let saved = state.hasKey(item)
                HStack(spacing: 5) {
                    Circle()
                        .fill(saved ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                    Text("\(item.shortName) \(saved ? "키 있음" : "키 없음")")
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var trimmedKeyDraft: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveKey() {
        let key = trimmedKeyDraft
        guard !key.isEmpty else { return }
        state.actions?.saveAPIKey(key, for: provider)
        // The stored key is never shown again.
        keyDraft = ""
        outcome = nil
        keyMessage = provider.looksLikeKey(key) ? nil
            : "저장했습니다. 다만 \(provider.shortName) 키는 \(provider.keyFormatHint)합니다 — [연결 확인]으로 확인해 주세요."
    }

    // MARK: - Connection check and model list

    private func run(_ job: Job) {
        guard running == nil, let actions = state.actions else { return }
        let asked = provider
        running = job
        outcome = nil
        Task { @MainActor in
            let result = await actions.refreshModels(for: asked)
            running = nil
            // The answer is about `asked`; the user may have moved to another provider meanwhile.
            guard asked == provider else { return }
            switch result {
            case .success(let models):
                keyMessage = nil
                outcome = Outcome(job: job, ok: true,
                                  text: job == .checking ? "연결됨" : "모델 \(models.count)개를 불러왔습니다")
            case .failure(let error):
                outcome = Outcome(job: job, ok: false, text: error.userMessage(for: asked))
            }
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func outcomeRow(_ outcome: Outcome) -> some View {
        outcomeLabel(outcome).font(.callout)
    }

    private func outcomeLabel(_ outcome: Outcome) -> some View {
        Label(outcome.text, systemImage: outcome.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(outcome.ok ? Color.green : Color.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Models

    @ViewBuilder private func modelPicker(_ title: String, retranslate: Bool) -> some View {
        let models = state.models(for: provider)
        let current = retranslate ? state.settings.retranslateModelID(for: provider) : state.settings.modelID(for: provider)
        Picker(title, selection: modelBinding(retranslate: retranslate)) {
            ForEach(models) { Text(Self.pickerTitle($0)).tag($0.id) }
        }
        Text(Self.costHint(models.first { $0.id == current }?.price))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func modelBinding(retranslate: Bool) -> Binding<String> {
        let provider = self.provider
        return Binding(
            get: { retranslate ? state.settings.retranslateModelID(for: provider) : state.settings.modelID(for: provider) },
            set: { id in setModel(id, retranslate: retranslate, provider: provider) }
        )
    }

    private func setModel(_ id: String, retranslate: Bool, provider: AIProvider) {
        apply { s in
            if retranslate { s.setRetranslateModelID(id, for: provider) } else { s.setModelID(id, for: provider) }
        }
    }

    private var trimmedCustomModel: String {
        customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyCustomModel(retranslate: Bool) {
        let id = trimmedCustomModel
        guard !id.isEmpty else { return }
        setModel(id, retranslate: retranslate, provider: provider)
    }

    /// Built-in models read "GPT-6 Luna (빠르고 저렴)"; a fetched one also shows its id when
    /// the name alone would not tell two snapshots apart.
    static func pickerTitle(_ model: ModelInfo) -> String {
        if model.role != nil || model.displayName == model.id { return model.title }
        if ModelCatalog.builtIn(model.provider).contains(where: { $0.id == model.id }) { return model.title }
        return "\(model.displayName) (\(model.id))"
    }

    static func costHint(_ price: ModelPrice?) -> String {
        guard let price else { return "단가를 모르는 모델입니다 — 요금 어림에 들어가지 않습니다." }
        func usd(_ value: Double) -> String { "$" + String(format: "%g", value) }
        return "요금(100만 토큰당): 입력 \(usd(price.input)) · 출력 \(usd(price.output))"
    }

    private func apply(_ mutate: (inout AppSettings) -> Void) {
        if let actions = state.actions {
            actions.updateSettings(mutate)
        } else {
            mutate(&state.settings)
        }
    }
}
