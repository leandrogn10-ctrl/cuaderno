/*  Vault.swift — the durable copy of the training log, and the rule that decides what may replace it.
    Ported from Bitácora's (ios-bitacora/Vault.swift), where the reasoning is written out in full.
    The short version: the log lives in ONE localStorage key inside a WKWebView that the free-signing
    cron REINSTALLS weekly, so the webview holds the working copy and this file holds the record.

    APPEND-ONLY and MONOTONIC: every offered state is archived to a time-stamped generation, but the
    PRIMARY (what a restore reads) is replaced only by a state that is newer and has not collapsed.
    The mistake it exists against: a boot that finds no readable key correctly starts an EMPTY log,
    saves it, and a naive backup records the empty state over the full one.

    What differs from Bitácora is only the measure of "collapse": there it is titles, here it is
    LOGGED SETS across all sessions — the one number no ordinary save ever makes smaller by much.
    (Merging duplicate exercises moves sets between entries; it never drops one.) */
import Foundation

struct StateSummary: Equatable {
    let lastModified: Double     // epoch MILLISECONDS — index.html writes Date.now()
    let itemCount: Int           // total logged sets across every session
}

enum VaultVerdict: Equatable {
    case accepted                // newer (or first) and intact — primary replaced
    case heldStale               // older than what we hold — a late/duplicate write
    case heldShrink(was: Int, now: Int)   // lost a meaningful share of the logged sets
    case rejectedInvalid(String) // not a La Forja state at all — never touches anything
}

enum VaultRule {
    /// A drop this large stops being an edit and starts being an accident: more than five sets at
    /// once (a whole exercise's worth) is never an ordinary save, and on a young log, halving is.
    static func isCollapse(was: Int, now: Int) -> Bool {
        let drop = was - now
        if drop <= 0 { return false }
        if drop > 5 { return true }
        return was >= 3 && Double(now) < 0.5 * Double(was)
    }

    /// nil when the payload is not a plausible La Forja state — the same shape looksLikeMyState()
    /// checks in index.html: a settings object plus exercises and sessions ARRAYS. Anything else is a
    /// different schema or a half-written file, and neither may become the record.
    static func summarize(_ data: Data) -> StateSummary? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["settings"] is [String: Any],
              obj["exercises"] is [Any],
              let sessions = obj["sessions"] as? [[String: Any]] else { return nil }
        var sets = 0
        for s in sessions { for e in (s["entries"] as? [[String: Any]] ?? []) { sets += (e["sets"] as? [Any])?.count ?? 0 } }
        // No lastModified = never saved = epoch 0, so ANY real save outranks it.
        let lm = (obj["lastModified"] as? Double) ?? 0
        return StateSummary(lastModified: lm, itemCount: sets)
    }

    static func decide(incoming: Data, current: StateSummary?) -> VaultVerdict {
        guard let inc = summarize(incoming) else {
            return .rejectedInvalid("payload is not a La Forja state (settings + exercises + sessions)")
        }
        guard let cur = current else { return .accepted }
        if inc.lastModified < cur.lastModified { return .heldStale }
        if isCollapse(was: cur.itemCount, now: inc.itemCount) {
            return .heldShrink(was: cur.itemCount, now: inc.itemCount)
        }
        return .accepted
    }
}

/// On-disk side. Kept apart from the rule above so the rule stays pure Foundation and the
/// harness can falsify it without a filesystem, a webview or a phone.
final class Vault {
    static let shared = Vault()

    private let fm = FileManager.default
    private var docs: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var primaryURL: URL { docs.appendingPathComponent("forja-vault.json") }
    var pendingURL: URL { docs.appendingPathComponent("forja-vault-pending.json") }
    var historyDir: URL { docs.appendingPathComponent("vault-history", isDirectory: true) }
    var logURL: URL { docs.appendingPathComponent("vault.log") }

    private let q = DispatchQueue(label: "com.leandro.forja.vault")

    func log(_ m: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(m)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else { try? d.write(to: logURL) }
    }

    func currentSummary() -> StateSummary? {
        guard let d = try? Data(contentsOf: primaryURL) else { return nil }
        return VaultRule.summarize(d)
    }

    /// What a cold boot restores from. nil when we hold nothing readable.
    func primaryJSON() -> String? {
        guard let d = try? Data(contentsOf: primaryURL),
              VaultRule.summarize(d) != nil,
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    /// Generations are time-stamped, never a rolling count. N rolling saves is zero
    /// protection: the autosaves that follow a bad boot roll the good copy off the end.
    private func archive(_ data: Data, tag: String) {
        try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.timeZone = .current
        let name = "\(f.string(from: Date()))-\(tag).json"
        try? data.write(to: historyDir.appendingPathComponent(name), options: .atomic)
        prune()
    }

    /// Hourly for a day, daily for a month, then gone. Bounded without being forgetful.
    private func prune() {
        guard let names = try? fm.contentsOfDirectory(atPath: historyDir.path) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.timeZone = .current
        let now = Date()
        var keptHour = Set<String>(), keptDay = Set<String>()
        for name in names.sorted(by: >) {                       // newest first
            let stamp = String(name.prefix(15))
            guard let d = f.date(from: stamp) else { continue }
            let age = now.timeIntervalSince(d)
            let hourKey = String(name.prefix(11)), dayKey = String(name.prefix(8))
            var keep = false
            if age < 86_400 { keep = keptHour.insert(hourKey).inserted }
            else if age < 30 * 86_400 { keep = keptDay.insert(dayKey).inserted }
            if !keep { try? fm.removeItem(at: historyDir.appendingPathComponent(name)) }
        }
    }

    /// Returns the verdict so the caller can tell the page. Runs serialized: two saves racing
    /// must not both read the same "current" and both decide they are newer.
    @discardableResult
    func offer(_ data: Data) -> VaultVerdict {
        q.sync {
            let verdict = VaultRule.decide(incoming: data, current: currentSummary())
            switch verdict {
            case .rejectedInvalid(let why):
                log("REJECT \(why) (\(data.count) bytes)")
            case .accepted:
                try? data.write(to: primaryURL, options: .atomic)
                archive(data, tag: "ok")
                try? fm.removeItem(at: pendingURL)      // a good save clears an old dispute
                if let s = VaultRule.summarize(data) {
                    log("accept sets=\(s.itemCount) lastModified=\(Int(s.lastModified))")
                }
            case .heldStale:
                archive(data, tag: "stale")
                log("HOLD stale — primary kept")
            case .heldShrink(let was, let now):
                // The state is NOT thrown away: it is parked and archived. Nothing is lost
                // whichever way this turns out to be resolved.
                try? data.write(to: pendingURL, options: .atomic)
                archive(data, tag: "shrink")
                log("HOLD shrink \(was)→\(now) sets — primary kept, pending written")
            }
            return verdict
        }
    }

    /// The human's answer to a held shrink: promote what we parked. Only ever called from an
    /// explicit tap in the page, never automatically.
    @discardableResult
    func promotePending() -> Bool {
        q.sync {
            guard let d = try? Data(contentsOf: pendingURL), VaultRule.summarize(d) != nil
            else { return false }
            try? d.write(to: primaryURL, options: .atomic)
            archive(d, tag: "promoted")
            try? fm.removeItem(at: pendingURL)
            log("promote pending → primary (confirmed in app)")
            return true
        }
    }
}
