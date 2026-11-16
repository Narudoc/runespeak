import Foundation
import RunespeakCore

/// The shared record of live (billed) translation requests made while checking prompt or
/// dictionary changes with `--translate-check`. One line per request, tab-separated:
/// run name, who ran it, requests, US dollars. A run given `--ledger` reads the file first,
/// does not start when it would pass a limit, stops when a limit is reached on the way, and
/// appends a line after every request it has sent, so that a run stopped half-way is counted
/// as far as it got. The file stays locked for the length of a run, so that
/// two runs started together cannot both fit under a limit that only one of them fits under.
struct LiveLedger {
    struct Totals: Equatable {
        var requests = 0
        var usd = 0.0

        static func + (a: Totals, b: Totals) -> Totals {
            Totals(requests: a.requests + b.requests, usd: a.usd + b.usd)
        }
    }

    struct Limits: Equatable {
        var maxRequests: Int?
        var maxUSD: Double?
    }

    enum Failure: Error, Equatable {
        /// A line that is neither a comment nor four fields with two numbers: what it stands
        /// for may be spending, so the totals are unknown. Carries the line number.
        case unreadableLine(Int)
        case cannotOpen(String)
    }

    /// Below this the totals count as equal: amounts are written with six decimals.
    private static let cent = 0.000_000_5

    // MARK: - Reading

    /// The sums of a ledger text. Empty lines and lines starting with "#" are skipped.
    static func totals(of text: String) throws -> Totals {
        var sum = Totals()
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4, let requests = Int(fields[2]), requests >= 0,
                  let usd = Double(fields[3]), usd >= 0, usd.isFinite else {
                throw Failure.unreadableLine(index + 1)
            }
            sum.requests += requests
            sum.usd += usd
        }
        return sum
    }

    /// One ledger line (without the line break). Tabs and line breaks in the names would
    /// break the format and are written as spaces.
    static func line(run: String, agent: String, used: Totals) -> String {
        func field(_ text: String) -> String {
            let flat = text.map { $0 == "\t" || $0.isNewline ? " " : $0 }
            let trimmed = String(flat).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "-" : trimmed
        }
        return [field(run), field(agent), String(used.requests), String(format: "%.6f", used.usd)].joined(separator: "\t")
    }

    // MARK: - Limits

    /// Why a run of `planned` must not start after `spent`, or nil when it fits.
    static func refusal(spent: Totals, planned: Totals, limits: Limits) -> String? {
        if let max = limits.maxRequests, spent.requests + planned.requests > max {
            return "요청 한도 초과: 이미 \(spent.requests)건, 이번 실행 \(planned.requests)건, 한도 \(max)건"
        }
        if let max = limits.maxUSD, spent.usd + planned.usd > max + cent {
            return String(format: "비용 한도 초과: 이미 $%.6f, 이번 실행 예상 $%.6f, 한도 $%.6f", spent.usd, planned.usd, max)
        }
        return nil
    }

    /// Why no further request may be made once `spent` is used, or nil while there is room.
    static func reached(spent: Totals, limits: Limits) -> String? {
        if let max = limits.maxRequests, spent.requests >= max {
            return "요청 한도에 닿음: \(spent.requests)건 / \(max)건"
        }
        if let max = limits.maxUSD, spent.usd >= max - cent {
            return String(format: "비용 한도에 닿음: $%.6f / $%.6f", spent.usd, max)
        }
        return nil
    }

    /// What `requests` requests carrying `lines` chat lines in all are expected to cost: the
    /// system prompt written to the cache once and read from it afterwards, and a generous
    /// guess at the rest. An estimate for the check before a run; the ledger line written
    /// after it carries what the provider reported.
    static func estimate(requests: Int, lines: Int, systemPromptBytes: Int, price: ModelPrice) -> Double {
        guard requests > 0 else { return 0 }
        // The prompt mixes Latin and Hangul: about 2.5 bytes per token, counted low here.
        let system = Double(systemPromptBytes) / 2.2
        let input = Double(300 * requests + 90 * lines)
        let output = Double(40 * requests + 45 * lines)
        let first = system * price.cacheWrite
        let later = Double(requests - 1) * system * price.cacheRead
        return (first + later + input * price.input + output * price.output) / 1_000_000
    }

    // MARK: - The file

    let file: URL
    private var descriptor: Int32 = -1

    /// Opens (or creates) the ledger and takes its lock. `busy` is called once when another
    /// run holds the lock and this one has to wait.
    init(file: URL, busy: () -> Void = {}) throws {
        self.file = file
        descriptor = open(file.path, O_RDWR | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { throw Failure.cannotOpen(String(cString: strerror(errno))) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            busy()
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR {
                    let reason = String(cString: strerror(errno))
                    Darwin.close(descriptor)
                    throw Failure.cannotOpen(reason)
                }
            }
        }
    }

    func totals() throws -> Totals {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            throw Failure.cannotOpen("읽을 수 없는 파일")
        }
        return try Self.totals(of: text)
    }

    /// Appends one line. A file that does not end in a line break gets one first, so that the
    /// new line never joins the one before it.
    func append(run: String, agent: String, used: Totals) throws {
        var text = Self.line(run: run, agent: agent, used: used) + "\n"
        if let data = try? Data(contentsOf: file), let last = data.last, last != 0x0A { text = "\n" + text }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw Failure.cannotOpen(String(cString: strerror(errno))) }
    }

    /// Gives the lock back. The process ending does the same.
    func close() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }
}
