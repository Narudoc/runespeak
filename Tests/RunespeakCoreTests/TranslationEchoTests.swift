import XCTest
@testable import RunespeakCore

private func chat(_ body: String, channel: ChatChannel = .publicChannel, label: String? = "1. 공개 - 도시",
                  sender: String? = "Brann") -> ChatMessage {
    ChatMessage(channel: channel, channelLabel: label, sender: sender, body: body,
                rawText: body, color: .white, firstSeen: Date(timeIntervalSince1970: 0))
}

/// An answer that says the line over again is not a translation (`TranslationEcho`).
final class TranslationEchoTests: XCTestCase {

    func testAnswerEqualToTheSourceIsAnEcho() {
        XCTAssertTrue(TranslationEcho.isEcho("heyo", of: "heyo"))
        XCTAssertTrue(TranslationEcho.isEcho("Heyo!", of: "heyo"), "letter case and punctuation do not make a translation")
        XCTAssertTrue(TranslationEcho.isEcho("LF 2M  UBRS", of: "lf2m ubrs."), "nor does spacing")
        XCTAssertTrue(TranslationEcho.isEcho("E7| ЛФ 9t.", of: "E7| ЛФ 9t."), "what OCR could not read comes back as it went")
        XCTAssertTrue(TranslationEcho.isEcho("[Runed Bar] x2", of: "[Runed Bar] x2"))
        XCTAssertTrue(TranslationEcho.isEcho("...", of: "?!"), "nothing but punctuation on both sides says nothing new")
    }

    func testTranslationIsNotAnEcho() {
        XCTAssertFalse(TranslationEcho.isEcho("ㅎㅇ", of: "heyo"))
        XCTAssertFalse(TranslationEcho.isEcho("[Runed Bar] 팝니다", of: "WTS [Runed Bar]"), "a copied link is not the whole line")
        XCTAssertFalse(TranslationEcho.isEcho("LFM UBRS need healer", of: "LFM UBRS need tank"))
        XCTAssertFalse(TranslationEcho.isEcho("heyo 2", of: "heyo"), "a digit is part of what was said")
        XCTAssertFalse(TranslationEcho.isEcho("looking for group", of: "파티 구함"))
        XCTAssertFalse(TranslationEcho.isEcho("뭐", of: "..."))
    }

    func testLooseKeyKeepsLettersAndDigitsOfEveryScript() {
        XCTAssertEqual(TranslationEcho.looseKey("LFM  Molten Core - need 2 healers!"), "lfmmoltencoreneed2healers")
        XCTAssertEqual(TranslationEcho.looseKey("화산 심장부, 힐러 2명!"), "화산심장부힐러2명")
        XCTAssertEqual(TranslationEcho.looseKey(" ?! … "), "")
    }

    /// Of a typed emote the model gets the action alone and the app shows a marker in front
    /// of the answer: neither the command nor the marker makes the answer a translation.
    func testTypedEmoteIsComparedByItsAction() {
        let emote = chat("/me pokes the bear")
        XCTAssertTrue(TranslationEcho.isEcho("(행동) pokes the bear", of: emote, reader: .korean))
        XCTAssertTrue(TranslationEcho.isEcho("(행동) Pokes the bear.", of: emote, reader: .korean))
        XCTAssertTrue(TranslationEcho.isEcho("(action) pokes the bear", of: chat("/e pokes the bear"), reader: .english))
        XCTAssertFalse(TranslationEcho.isEcho("(행동) 곰을 쿡 찌릅니다", of: emote, reader: .korean))
        XCTAssertFalse(TranslationEcho.isEcho("me pokes the bear", of: emote, reader: .korean),
                       "the command is not part of what was sent")
        // An ordinary line is compared whole.
        XCTAssertTrue(TranslationEcho.isEcho("LF tank /me pls", of: chat("LF tank /me pls"), reader: .korean))
        XCTAssertFalse(TranslationEcho.isEcho("(행동) heyo", of: chat("heyo"), reader: .korean))
    }

    /// Through the translator: what comes back for an unchanged line is recognised from the
    /// output the app receives, next to a line of the same request that was translated.
    func testEchoIsRecognisedInWhatTheTranslatorReturns() async throws {
        let reply = try JSONSerialization.data(withJSONObject: [
            "translations": [["n": 1, "text": "Zug zug"], ["n": 2, "text": "곰을 쿡 찌릅니다"], ["n": 3, "text": "waves"],
                             ["n": 4, "text": "탱커 구함"]],
            "note": "",
        ])
        let body = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": String(data: reply, encoding: .utf8)!]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
        ] as [String: Any])
        StubURLProtocol.install { _, _ in .init(json: String(data: body, encoding: .utf8)!) }
        let translator = ClaudeTranslator(apiKey: "sk-ant-test", glossary: StubGlossary(), usage: nil, session: StubURLProtocol.session())
        let lines = [chat("zug zug"), chat("/me pokes the bear"), chat("/me waves"), chat("LF tank")]
        let context = TranslationRequestContext(reader: .korean, flavor: .classic, model: .haiku)
        let result = try await translator.translateIncoming(lines, context: context)

        let echoes = lines.map { TranslationEcho.isEcho(result[$0.id]?.text ?? "", of: $0, reader: .korean) }
        XCTAssertEqual(echoes, [true, false, true, false])
        XCTAssertEqual(result[lines[2].id]?.text, "(행동) waves", "the marker is on the output that is compared")
    }
}

/// chat_history.txt names the model behind every translation (`ChatDisplay.historyLine`).
final class HistoryLineTests: XCTestCase {

    func testTranslationLineNamesTheModel() {
        let guild = chat("anyone up for a dungeon", channel: .guild, label: "길드", sender: "Mira Fenn")
        XCTAssertEqual(ChatDisplay.historyLine(translation: "던전 가실 분?", of: guild, engine: "Sonnet"),
                       "    → [Sonnet] Mira Fenn: 던전 가실 분?")
        XCTAssertEqual(ChatDisplay.historyLine(translation: "던전 가실 분?", of: guild, engine: "Haiku", reused: true),
                       "    → [Haiku·재사용] Mira Fenn: 던전 가실 분?", "a translation taken from an earlier line says so: no request was made")
        XCTAssertEqual(ChatDisplay.historyLine(translation: "던전 가실 분?", of: guild, engine: "MyMemory"),
                       "    → [MyMemory] Mira Fenn: 던전 가실 분?")
        XCTAssertEqual(ChatDisplay.historyLine(translation: "던전 가실 분?", of: guild, engine: nil),
                       "    → [?] Mira Fenn: 던전 가실 분?", "every translation line carries exactly one tag")
    }

    /// A line without a speaker, and a translation that begins with a link: the tag is still
    /// the first bracketed group behind the arrow.
    func testTagStandsInFrontOfSpeakerAndLinks() {
        let system = chat("[Runed Bar] for sale", channel: .yell, label: nil, sender: nil)
        XCTAssertEqual(ChatDisplay.historyLine(translation: "[Runed Bar] 팝니다", of: system, engine: "Sonnet"),
                       "    → [Sonnet] [Runed Bar] 팝니다")
        let emote = chat("Mira Fenn dances.", channel: .emote, label: nil, sender: "Mira Fenn")
        XCTAssertEqual(ChatDisplay.historyLine(translation: "Mira Fenn이 춤을 춥니다.", of: emote, engine: "Sonnet"),
                       "    → [Sonnet] Mira Fenn이 춤을 춥니다.", "an emote names its speaker itself")
    }

    func testUnchangedAnswerIsRecordedAsNoTranslation() {
        let line = chat("zug zug", channel: .yell, label: nil, sender: "Grok")
        let record = ChatDisplay.historyLine(unchangedAnswerFor: line, engine: "Haiku")
        // The record names its line: it is written when the answer arrives, and in a busy chat
        // other lines (of the same speaker, too) stand between it and the line it is about.
        XCTAssertEqual(record, "    = [Haiku] Grok: zug zug  (원문과 같은 답 — 번역 없음)")
        XCTAssertFalse(record.contains("→"), "the arrow marks translations only")
        let other = ChatDisplay.historyLine(unchangedAnswerFor: chat("lok tar", channel: .yell, label: nil, sender: "Grok"), engine: "Haiku")
        XCTAssertNotEqual(record, other, "two unchanged answers for one speaker can be told apart")
        // A line without a speaker, and one that was not asked about again.
        let bare = chat("Kagh zug nogah", channel: .publicChannel, label: "1. 공개", sender: nil)
        XCTAssertEqual(ChatDisplay.historyLine(unchangedAnswerFor: bare, engine: "Sonnet", reused: true),
                       "    = [Sonnet·재사용] Kagh zug nogah  (원문과 같은 답 — 번역 없음)")
        XCTAssertFalse(ChatDisplay.historyLine(unchangedAnswerFor: chat("one\ntwo", channel: .yell, label: nil, sender: nil), engine: nil)
            .contains("\n"), "one record is one line")
    }

    /// A model id can be typed by hand in the settings: whatever it holds, the tag stays one
    /// short bracketed group on one line.
    func testEngineTagIsOneShortGroupOnOneLine() {
        XCTAssertEqual(ChatDisplay.engineTag("Sonnet"), "[Sonnet]")
        XCTAssertEqual(ChatDisplay.engineTag("  GPT-6   Luna \n"), "[GPT-6 Luna]")
        XCTAssertEqual(ChatDisplay.engineTag("my]model[v2]\tfinal"), "[my)model(v2) final]", "brackets inside a name cannot end the tag early")
        XCTAssertEqual(ChatDisplay.engineTag("line one\nline two"), "[line one line two]")
        XCTAssertEqual(ChatDisplay.engineTag(""), "[?]")
        XCTAssertEqual(ChatDisplay.engineTag(" \n "), "[?]")
        XCTAssertEqual(ChatDisplay.engineTag(nil, reused: true), "[?·재사용]")
        let long = ChatDisplay.engineTag(String(repeating: "x", count: 200))
        XCTAssertEqual(long.count, ChatDisplay.engineTagLimit + 2)
        XCTAssertTrue(long.hasSuffix("…]"))
        XCTAssertEqual(ChatDisplay.engineTag(String(repeating: "y", count: ChatDisplay.engineTagLimit)),
                       "[" + String(repeating: "y", count: ChatDisplay.engineTagLimit) + "]", "a name of exactly the limit is not cut")
        for tag in [ChatDisplay.engineTag("a\u{0}b\u{7}c"), ChatDisplay.engineTag("claude-sonnet-5-5-20260915")] {
            XCTAssertFalse(tag.unicodeScalars.contains { $0.properties.generalCategory == .control }, tag)
            XCTAssertEqual(tag.filter { $0 == "[" }.count, 1)
            XCTAssertEqual(tag.filter { $0 == "]" }.count, 1)
        }
    }
}
