import Foundation

/// Links in chat text ("[Some Item]", "[Some Quest]"): what of a row or a message is link and
/// what is the player's own text, and the repair of link brackets OCR read as thin letters where
/// the brackets that were read leave no doubt.
enum ChatLinks {
    /// Glyphs OCR writes for "[" or "]" next to Latin letters.
    private static let thin: Set<Character> = ["l", "I", "i", "j", "1", "|", "!"]

    /// Letters and digits of `text` that stand outside link brackets. What stands in front of a
    /// bracket that closes without having opened is inside a link that began on the row above
    /// ("Vow][Bring Back a Ring] pst"), and what stands behind one that never closes is inside a
    /// link that goes on below.
    static func lettersOutsideLinks(_ text: String) -> Int {
        var depth = text.first(where: { $0 == "[" || $0 == "]" }) == "]" ? 1 : 0
        var count = 0, pending = 0
        for c in text {
            if c == "[" {
                if depth == 0 { count += pending; pending = 0 }
                depth += 1
            } else if c == "]" {
                depth = max(0, depth - 1)
                pending = 0
            } else if depth == 0, c.isLetter || c.isNumber {
                pending += 1
            }
        }
        return depth == 0 ? count + pending : count
    }

    /// The row has link brackets in it.
    static func hasBrackets(_ text: String) -> Bool { text.contains("[") || text.contains("]") }

    /// The row ends inside a link: its last bracket opens one.
    static func leavesLinkOpen(_ text: String) -> Bool {
        text.last(where: { $0 == "[" || $0 == "]" }) == "["
    }

    /// The row begins inside a link: its first bracket closes one.
    static func closesUnopenedLink(_ text: String) -> Bool {
        text.first(where: { $0 == "[" || $0 == "]" }) == "]"
    }

    private static func isLinkWord(_ word: Substring) -> Bool {
        guard let head = word.first(where: { $0.isLetter }) else { return !word.contains(where: { $0.isLetter }) }
        if head.isUppercase { return true }
        return ["of", "the", "a", "an", "and", "to", "in", "for", "on", "de", "la"].contains(word.lowercased())
    }

    /// The body of a whole message with the link brackets mended that OCR read as thin letters,
    /// where the brackets it did read leave no doubt:
    ///
    ///  * a link that opens inside another ("[Bring Back a Ringl[The Marrow Span]", "...Ringi[The..."):
    ///    the thin letter glued to the second "[" is the "]" of the first;
    ///  * a link that closes without having opened ("LFGlThe Old Iron Vow][Bring ...", in a
    ///    message, where no row above can have opened it): the thin letter in front of the
    ///    capitalised words before the "]" is its "[";
    ///  * the same right behind another link ("[Bring Back a Ring]The Marrow Span]"): the
    ///    bracket that opens it was not read at all.
    ///
    /// Anything less evident ("RinglThe" inside one pair of brackets may as well be two words
    /// that lost their space) is left as read.
    static func mendBrackets(inBody body: String) -> String {
        guard body.contains("[") || body.contains("]") else { return body }
        var chars = Array(body)
        var depth = 0
        // Index behind the last closing bracket: where an unopened link can have begun.
        var floor = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "[" {
                if depth >= 1, i >= 2, thin.contains(chars[i - 1]), chars[i - 2].isLetter,
                   i + 1 < chars.count, chars[i + 1].isUppercase {
                    chars[i - 1] = "]"
                    depth = 0
                }
                depth += 1
            } else if c == "]" {
                if depth == 0 {
                    if let open = unopenedLinkStart(chars, close: i, floor: floor) {
                        chars[open] = "["
                    } else if floor > 0, floor < i, chars[floor - 1] == "]", chars[floor].isUppercase,
                              String(chars[floor..<i]).split(separator: " ").allSatisfy(isLinkWord) {
                        chars.insert("[", at: floor)
                        i += 1
                    }
                } else {
                    depth -= 1
                }
                floor = i + 1
            }
            i += 1
        }
        return String(chars)
    }

    /// Index of the thin letter that stands where the link closed at `close` must have opened:
    /// the nearest one in front of a capitalised word with nothing but link words between it and
    /// the bracket.
    private static func unopenedLinkStart(_ chars: [Character], close: Int, floor: Int) -> Int? {
        guard close - floor >= 3 else { return nil }
        var k = close - 2
        while k >= floor {
            defer { k -= 1 }
            guard thin.contains(chars[k]), k + 2 < close, chars[k + 1].isUppercase, chars[k + 2].isLowercase else { continue }
            // Glued to the word in front of it ("LFGlThe") or a word of its own start ("lThe").
            guard k == floor || chars[k - 1] == " " || chars[k - 1].isLetter else { continue }
            // Not the "I" of an all-capital word, nor the "l" inside an ordinary one ("Small").
            if k > floor, chars[k - 1].isLowercase, chars[k].isLowercase { continue }
            let inside = String(chars[(k + 1)..<close])
            guard inside.split(separator: " ").allSatisfy(isLinkWord) else { continue }
            return k
        }
        return nil
    }
}
