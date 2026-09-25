/*  test-vault.swift — falsifies VaultRule. Pure Foundation on purpose (no UIKit, no WebKit,
    no simulator, no signing): the rule that decides whether the training log may be replaced has
    to be testable in a second, on any machine, forever.

      swiftc -o /tmp/vaultgate Vault.swift test-vault.swift && /tmp/vaultgate

    Every load-bearing assertion is followed by a CONTROL that re-plants the original defect
    and requires the check to FAIL. A green harness proves nothing until it has been watched
    going red — and the defect this file exists for (an empty state overwriting a full one)
    is invisible to any test that only asserts the happy path. */
import Foundation

var failures = 0, checks = 0
func ok(_ cond: Bool, _ what: String) {
    checks += 1
    if cond { print("  ok   \(what)") } else { failures += 1; print("  FAIL \(what)") }
}
/// A La Forja state carrying `items` logged sets, spread over sessions of 4 sets so the summarizer
/// has to sum across sessions AND entries, not just count one array.
func state(items: Int, modified: Double) -> Data {
    var sessions: [[String: Any]] = [], left = items, n = 0
    while left > 0 {
        let k = min(4, left); left -= k; n += 1
        sessions.append(["id": "s\(n)", "entries": [["exerciseId": "e1", "sets": (0..<k).map { ["w": 25, "r": 10, "ts": $0] }]]])
    }
    return try! JSONSerialization.data(withJSONObject: ["settings": [:] as [String: Any], "exercises": [["id": "e1"]], "sessions": sessions, "lastModified": modified])
}

@main struct VaultGate {
    static func main() {
        print("\n── summarize ──")
        ok(VaultRule.summarize(state(items: 46, modified: 1_700_000_000_000))
            == StateSummary(lastModified: 1_700_000_000_000, itemCount: 46), "reads total sets (summed across sessions) + lastModified")
        ok(VaultRule.summarize(Data("not json".utf8)) == nil, "garbage is not a state")
        ok(VaultRule.summarize(Data(#"{"lastModified":1}"#.utf8)) == nil, "no sessions array is not a state")
        ok(VaultRule.summarize(Data(#"{"settings":{},"exercises":[],"items":[]}"#.utf8)) == nil, "a Bitácora-shaped state is not a La Forja state")
        // A state that never saved has no lastModified. It must sort OLDEST, not newest: a default of
        // "now" would let a blank library outrank the real one on every comparison below.
        ok(VaultRule.summarize(Data(#"{"settings":{},"exercises":[],"sessions":[]}"#.utf8))?.lastModified == 0, "missing lastModified reads as epoch 0, not now")

        print("\n── the defect this file exists for: an empty state must not replace a full one ──")
        let full = StateSummary(lastModified: 1_700_000_000_000, itemCount: 46)
        let wipe = state(items: 0, modified: 1_700_000_900_000)   // NEWER, and empty — the poisoned save
        if case .heldShrink(let was, let now) = VaultRule.decide(incoming: wipe, current: full) {
            ok(was == 46 && now == 0, "a newer EMPTY save is held, not accepted (46→0 sets)")
        } else { ok(false, "a newer EMPTY save is held, not accepted (46→0)") }

        //  CONTROL — re-plant the original rule ("accept anything newer") and prove it would have
        //  shipped the wipe. If this control ever passes, the assertion above is decorative.
        func originalRule(incoming: Data, current: StateSummary?) -> VaultVerdict {
            guard let inc = VaultRule.summarize(incoming) else { return .rejectedInvalid("x") }
            guard let cur = current else { return .accepted }
            return inc.lastModified < cur.lastModified ? .heldStale : .accepted
        }
        ok(originalRule(incoming: wipe, current: full) == .accepted,
           "CONTROL: the naive newest-wins rule DOES accept the wipe (so the test can see it)")

        print("\n── staleness ──")
        ok(VaultRule.decide(incoming: state(items: 46, modified: 1_600_000_000_000), current: full) == .heldStale,
           "an older save is held")
        ok(VaultRule.decide(incoming: state(items: 47, modified: 1_700_000_000_000), current: full) == .accepted,
           "an equal timestamp with more sets is accepted (a same-ms save is not a regression)")
        ok(VaultRule.decide(incoming: state(items: 47, modified: 1_700_000_900_000), current: nil) == .accepted,
           "with nothing held, anything valid is accepted")
        ok(VaultRule.decide(incoming: Data("{".utf8), current: full) == .rejectedInvalid("payload is not a La Forja state (settings + exercises + sessions)"),
           "a truncated payload never touches the primary")

        print("\n── collapse: where the line sits ──")
        ok(!VaultRule.isCollapse(was: 46, now: 45), "unchecking one set is an edit, not a collapse")
        ok(!VaultRule.isCollapse(was: 46, now: 41), "removing five sets is still an edit")
        ok(VaultRule.isCollapse(was: 46, now: 40),  "losing six sets at once is held")
        ok(VaultRule.isCollapse(was: 46, now: 0),   "losing everything is held")
        ok(!VaultRule.isCollapse(was: 46, now: 60), "growing is never a collapse")
        ok(!VaultRule.isCollapse(was: 46, now: 46), "unchanged is never a collapse")
        //  The proportional arm exists because an absolute-only threshold waves through the collapse
        //  of a SMALL library — which is exactly the state a newly-seeded phone is in.
        ok(VaultRule.isCollapse(was: 6, now: 1), "6→1 is held by the proportional arm (a young log on a fresh install)")
        ok(!VaultRule.isCollapse(was: 2, now: 1), "2→1 is too small a log to judge; allowed")

        //  CONTROL — drop the proportional arm and prove 6→1 sails through.
        func absoluteOnly(was: Int, now: Int) -> Bool { (was - now) > 5 }
        ok(absoluteOnly(was: 6, now: 1) == false,
           "CONTROL: an absolute-only threshold MISSES 6→1 (so the proportional arm is load-bearing)")

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 { print("VAULT GATE RED — \(failures) failure(s)\n"); exit(1) }
        print("vault gate green\n")
    }
}
