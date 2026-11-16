import Foundation

/// An answer that says the line over again is not a translation. A model returns the source
/// when it finds nothing to translate (a name, a sound, what OCR made of text it could not
/// read) and, now and then, for a line it should have translated. Shown as a translation,
/// either reads as if the app had done its work; so such an answer is told apart here and the
/// line stays what it is: the original.
public enum TranslationEcho {

    /// Letters and digits only, lower-cased: what is left of a text when letter case, spacing
    /// and punctuation are ignored.
    public static func looseKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// True when `translation` is `source` again, ignoring letter case, spacing and
    /// punctuation ("Wassup!" for "wassup").
    public static func isEcho(_ translation: String, of source: String) -> Bool {
        looseKey(translation) == looseKey(source)
    }

    /// The same for a chat message and the translation as the app shows it. Of an action
    /// typed with "/me" only the action is compared: the command is not sent to the model and
    /// the marker in front of the shown translation ("(행동)") is not part of its answer.
    public static func isEcho(_ translation: String, of message: ChatMessage, reader: ReaderLanguage) -> Bool {
        guard let action = TranslationPrompt.typedEmote(message.body) else {
            return isEcho(translation, of: message.body)
        }
        var shown = translation.trimmingCharacters(in: .whitespaces)
        for marker in ReaderLanguage.allCases.map(TranslationPrompt.emoteMarker(for:)) where shown.hasPrefix(marker) {
            shown = String(shown.dropFirst(marker.count))
            break
        }
        return isEcho(shown, of: action)
    }
}
