// Correction-watcher timeline simulator (E2: watcher coverage).
// Replays scripted user timelines — dictate, keep typing, fix later,
// dictate again, switch apps, send chat messages, keyless users — through
// the OLD watcher (2/5/10s, key only, cancelled by the next recording, one
// lesson) and the NEW CorrectionWatchPolicy (poll-only and poll+AX), and
// counts captured / missed / spurious lessons. Synthetic text only.
// Run: scripts/watch-eval/run.sh
import Foundation

// MARK: - World + timeline builder

struct Fix { let heard: String; let corrected: String; let real: Bool }

enum Kind {
    case text(field: Int, String)               // the field's text changes (user/app)
    case focus(app: Int, field: Int)            // the user moves to app/field
    case recStart
    case land(field: Int, String)               // our insertion lands
    case watchStart(field: Int, String)         // watcher snapshot (+0.3s)
    case readable(field: Int, Bool)
}
struct Step { let t: Double; let kind: Kind }

final class Timeline {
    let name: String
    var steps: [Step] = []
    var fixes: [Fix] = []
    var text: [Int: String] = [:]
    var appOf: [Int: Int] = [1: 1, 2: 2, 3: 1]  // field → app (field 3 = another field in app 1)
    var front = (app: 1, field: 1)
    init(_ name: String) { self.name = name }

    private func set(_ f: Int, _ s: String, _ t: Double) { text[f] = s; steps.append(Step(t: t, kind: .text(field: f, s))) }

    /// Hold hotkey at t, speak ~1s, text lands 1.2s later at the cursor
    /// (end of field, or just before `before`).
    @discardableResult
    func dictate(_ s: String, at t: Double, field f: Int? = nil, before: String? = nil) -> Timeline {
        let f = f ?? front.field
        steps.append(Step(t: t, kind: .recStart))
        let cur = text[f] ?? ""
        var new: String
        if let before, let r = cur.range(of: before) {
            new = String(cur[..<r.lowerBound]) + s + " " + String(cur[r.lowerBound...])
        } else {
            new = cur.isEmpty || cur.hasSuffix(" ") || cur.hasSuffix("\n") ? cur + s : cur + " " + s
        }
        text[f] = new
        steps.append(Step(t: t + 1.2, kind: .land(field: f, new)))
        steps.append(Step(t: t + 1.5, kind: .watchStart(field: f, s)))
        return self
    }

    /// The user types `s` at the end of the field (or after `after`), cps chars/sec.
    @discardableResult
    func type(_ s: String, at t: Double, field f: Int? = nil, after: String? = nil, cps: Double = 7) -> Timeline {
        let f = f ?? front.field
        var cur = text[f] ?? ""
        var idx = cur.endIndex
        if let after, let r = cur.range(of: after) { idx = r.upperBound }
        var off = cur.distance(from: cur.startIndex, to: idx)
        for (i, ch) in s.enumerated() {
            let at = cur.index(cur.startIndex, offsetBy: off)
            cur.insert(ch, at: at); off += 1
            set(f, cur, t + Double(i) / cps)
        }
        return self
    }

    enum Style { case select, backspace }
    /// The user fixes the LAST whole-word occurrence of `wrong`.
    @discardableResult
    func fix(_ wrong: String, _ right: String, at t: Double, real: Bool = true, style: Style = .select,
             field f: Int? = nil, cps: Double = 7, pauseAfter: Int? = nil, pause: Double = 0) -> Timeline {
        let f = f ?? front.field
        let cur = text[f] ?? ""
        guard let r = lastWord(wrong, in: cur) else { fatalError("\(name): '\(wrong)' not in field") }
        let head = String(cur[..<r.lowerBound]), tail = String(cur[r.upperBound...])
        var time = t + 0.5   // double-click / place cursor
        if style == .backspace {
            var w = wrong
            while !w.isEmpty { w.removeLast(); set(f, head + w + tail, time); time += 0.08 }
        }
        var typed = ""
        for (i, ch) in right.enumerated() {
            typed.append(ch); set(f, head + typed + tail, time); time += 1 / cps
            if let p = pauseAfter, i + 1 == p { time += pause }
        }
        fixes.append(Fix(heard: wrong, corrected: right, real: real))
        return self
    }

    /// Chat "send": the composer empties.
    @discardableResult
    func send(at t: Double, field f: Int? = nil) -> Timeline { set(f ?? front.field, "", t); return self }

    /// The app swaps the field's content (another channel's draft) — not the user.
    @discardableResult
    func swap(_ s: String, at t: Double, field f: Int) -> Timeline { set(f, s, t); return self }

    @discardableResult
    func focus(app: Int, field: Int, at t: Double) -> Timeline {
        front = (app, field); steps.append(Step(t: t, kind: .focus(app: app, field: field))); return self
    }

    @discardableResult
    func preset(_ s: String, field f: Int = 1) -> Timeline { text[f] = s; steps.append(Step(t: 0, kind: .text(field: f, s))); return self }

    @discardableResult
    func unreadable(field f: Int) -> Timeline { steps.append(Step(t: 0, kind: .readable(field: f, false))); return self }

    private func lastWord(_ w: String, in s: String) -> Range<String.Index>? {
        var end = s.endIndex
        while let r = s.range(of: w, options: .backwards, range: s.startIndex..<end) {
            let okL = r.lowerBound == s.startIndex || !s[s.index(before: r.lowerBound)].isLetter
            let okR = r.upperBound == s.endIndex || !s[r.upperBound].isLetter
            if okL && okR { return r }
            end = r.lowerBound
        }
        return nil
    }

    var sorted: [Step] { steps.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element) }
}

struct World {
    var text: [Int: String] = [:]
    var front = (app: 1, field: 1)
    var appOf: [Int: Int]
    var readable: [Int: Bool] = [:]
    func focused(_ f: Int) -> Bool { front.field == f && front.app == appOf[f] }
    func read(_ f: Int) -> String? { readable[f] == false ? nil : (text[f] ?? "") }
}

// MARK: - Watchers under test

struct Emitted { let heard: String; let corrected: String; let fixed: String }

protocol Watcher {
    mutating func step(_ s: Step, world: World)
    mutating func nextTime(after now: Double) -> Double?
    mutating func tick(at now: Double, world: World) -> [Emitted]
    var reads: Int { get }
}

/// The shipped watcher, as it was: snapshot at +0.3s, checks at +2/+5/+10
/// from there, skipped if the app/field isn't focused, cancelled by the
/// next recording, stops after one lesson. Not started without a key.
struct OldWatcher: Watcher {
    let keyless: Bool
    var gen = 0
    var watching: (field: Int, before: String, inserted: String, gen: Int)?
    var checks: [Double] = []
    var reads = 0

    mutating func step(_ s: Step, world: World) {
        switch s.kind {
        case .recStart: gen += 1; watching = nil; checks = []
        case .watchStart(let f, let ins):
            gen += 1
            guard !keyless, world.focused(f), let before = world.read(f), before.contains(ins) else { return }
            reads += 1
            watching = (f, before, ins, gen)
            checks = [2.0, 5, 10].map { s.t + $0 }
        default: break
        }
    }
    mutating func nextTime(after now: Double) -> Double? { checks.first }
    mutating func tick(at now: Double, world: World) -> [Emitted] {
        guard let w = watching, !checks.isEmpty else { return [] }
        checks.removeFirst()
        guard world.focused(w.field) else { return [] }
        reads += 1
        guard let after = world.read(w.field), after != w.before else { return [] }
        if let c = EditDiff.correction(before: w.before, after: after, inserted: w.inserted) {
            watching = nil; checks = []
            return [Emitted(heard: c.heard, corrected: c.corrected, fixed: "")]
        }
        return []
    }
}

struct NewWatcher: Watcher {
    let ax: Bool
    var trace = false
    var policy = CorrectionWatchPolicy()
    var reads = 0
    var pendingStart: [(Double, Int, String)] = []
    var t0 = Date(timeIntervalSinceReferenceDate: 0)
    func date(_ t: Double) -> Date { t0.addingTimeInterval(t) }

    mutating func step(_ s: Step, world: World) {
        switch s.kind {
        case .recStart: policy.recordingStarted()
        case .text(let f, _): if ax { policy.valueChanged(fieldID: f, at: date(s.t)) }
        case .land(let f, _): if ax { policy.valueChanged(fieldID: f, at: date(s.t)) }
        case .watchStart(let f, let ins):
            guard let txt = world.read(f) else { return }
            reads += 1
            _ = policy.inserted(fieldID: f, text: ins, fieldText: txt, at: date(s.t))
        default: break
        }
    }
    mutating func nextTime(after now: Double) -> Double? {
        policy.nextCheck(now: date(now)).map { max(now, $0.timeIntervalSince(t0)) }
    }
    mutating func tick(at now: Double, world: World) -> [Emitted] {
        var out: [Emitted] = []
        for f in policy.fieldsDue(at: date(now)) {
            reads += 1
            let r = policy.observe(fieldID: f, text: world.read(f), focused: world.focused(f), at: date(now))
            if trace { print(String(format: "    t=%6.2f f%d focused=%d %@ lessons=%@", now, f, world.focused(f) ? 1 : 0,
                                "\"\(world.read(f) ?? "nil")\"", "\(r.lessons.map { "\($0.correction.heard)→\($0.correction.corrected)" })")) }
            out += r.lessons.map { Emitted(heard: $0.correction.heard, corrected: $0.correction.corrected, fixed: $0.fixed) }
        }
        _ = policy.expire(now: date(now))
        return out
    }
}

/// Replay one timeline through one watcher; returns its raw lessons.
func run<W: Watcher>(_ tl: Timeline, _ w: inout W) -> [Emitted] {
    var world = World(appOf: tl.appOf)
    let steps = tl.sorted
    var i = 0, now = 0.0, out: [Emitted] = []
    var guardN = 0
    while guardN < 100_000 {
        guardN += 1
        let nextStep = i < steps.count ? steps[i].t : Double.infinity
        let nextCheck = w.nextTime(after: now) ?? Double.infinity
        if nextStep == .infinity && nextCheck == .infinity { break }
        if nextStep <= nextCheck {
            let s = steps[i]; i += 1; now = s.t
            switch s.kind {
            case .text(let f, let txt), .land(let f, let txt): world.text[f] = txt
            case .focus(let a, let f): world.front = (a, f)
            case .readable(let f, let ok): world.readable[f] = ok
            default: break
            }
            w.step(s, world: world)
        } else {
            now = nextCheck
            out += w.tick(at: now, world: world)
            if now > 400 { break }
        }
    }
    return out
}

// MARK: - Timelines

func timelines() -> [Timeline] {
    var all: [Timeline] = []
    func tl(_ name: String, _ build: (Timeline) -> Void) { let t = Timeline(name); build(t); all.append(t) }
    let s1 = "Can you ask bright AI about the contract"
    tl("01 quick fix at 3s") { $0.dictate(s1, at: 0).fix("bright", "Brite", at: 3) }
    tl("02 fix at 8s") { $0.dictate(s1, at: 0).fix("bright", "Brite", at: 8) }
    tl("03 fix after re-reading at 25s") { $0.dictate(s1, at: 0).fix("bright", "Brite", at: 25) }
    tl("04 fix at 45s") { $0.dictate(s1, at: 0).fix("bright", "Brite", at: 45) }
    tl("05 fix at 75s (past any window)") { $0.dictate(s1, at: 0).fix("bright", "Brite", at: 75) }
    tl("06 keep typing, pause, fix at 15s") {
        $0.dictate("I spoke with a lisha yesterday", at: 0).type(" and she agreed to the plan.", at: 4).fix("a lisha", "Alisha", at: 15)
    }
    tl("07 keep typing then fix with no pause") {
        $0.dictate("Ping super base about the outage", at: 0).type(" before lunch", at: 3).fix("super base", "Supabase", at: 5.0)
    }
    tl("08 back-to-back dictation, fix first at 12s") {
        $0.dictate("Send the deck to Steven", at: 0).dictate("and copy the finance team", at: 4).fix("Steven", "Stephen", at: 12)
    }
    tl("09 three dictations, fix first at 20s") {
        $0.dictate("Meeting with car tear at noon", at: 0).dictate("then the design review", at: 5)
          .dictate("and drinks after", at: 10).fix("car tear", "Kartier", at: 20)
    }
    tl("10 four dictations, fix first at 30s (pushed out)") {
        $0.dictate("Ask john about the budget", at: 0).dictate("he owns the numbers", at: 4)
          .dictate("and the forecast", at: 8).dictate("for next quarter", at: 12).fix("john", "Jon", at: 30)
    }
    tl("11 fix then dictate immediately") {
        $0.dictate("Call bright AI tomorrow", at: 0).fix("bright", "Brite", at: 3).dictate("about pricing", at: 4.6)
    }
    tl("12 switch app at 3s, back at 10s, fix at 14s") {
        $0.dictate(s1, at: 0).focus(app: 2, field: 2, at: 3).focus(app: 1, field: 1, at: 10).fix("bright", "Brite", at: 14)
    }
    tl("13 fix at 3s then switch away at once") {
        $0.dictate(s1, at: 0).fix("bright", "Brite", at: 3).focus(app: 2, field: 2, at: 4.7)
    }
    tl("14 chat: send, type unrelated message") {
        $0.dictate("Is bright coming to the call", at: 0).send(at: 4).type("brief update for you all", at: 5)
    }
    tl("15 chat: send, dictate again, fix new message") {
        $0.dictate("Lunch at noon?", at: 0).send(at: 3).dictate("Ask cooper netties team first", at: 5)
          .fix("cooper netties", "kubernetes", at: 10)
    }
    tl("16 chat: send, retype the same message by hand") {
        $0.dictate("bright AI is hiring", at: 0).send(at: 3).type("Brite AI is hiring", at: 3.5, cps: 9)
    }
    tl("17 grammar fix their->there (not a name)") {
        $0.dictate("I think their is a problem", at: 0).fix("their", "there", at: 6, real: false)
    }
    tl("18 sentence start Their->There (not a name)") {
        $0.dictate("Their is a bug in checkout", at: 0).fix("Their", "There", at: 6, real: false)
    }
    tl("19 typo-style fix form->from (not a name)") {
        $0.dictate("Notes form the meeting", at: 0).fix("form", "from", at: 5, real: false)
    }
    tl("20 content edit meeting->call (not a fix)") {
        $0.dictate("Lets move the meeting to Friday", at: 0).fix("meeting", "call", at: 5, real: false)
    }
    tl("21 two name fixes at 6s and 30s") {
        $0.dictate("Loop in Steven and a lisha on this", at: 0).fix("Steven", "Stephen", at: 6).fix("a lisha", "Alisha", at: 30)
    }
    tl("22 two name fixes back to back") {
        $0.dictate("Steven and a lisha will join", at: 0).fix("Steven", "Stephen", at: 6).fix("a lisha", "Alisha", at: 8)
    }
    tl("23 same pair in two insertions") {
        $0.dictate("Ask bright AI", at: 0).fix("bright", "Brite", at: 4).dictate("then thank bright AI", at: 10).fix("bright", "Brite", at: 15)
    }
    tl("24 slow fixer pauses mid-word") {
        $0.dictate(s1, at: 0).fix("bright", "Brite", at: 6, pauseAfter: 3, pause: 2.5)
    }
    tl("25 slow backspace fixer") {
        $0.dictate("Thanks to Katherine for the notes", at: 0).fix("Katherine", "Kathryn", at: 7, style: .backspace, cps: 3)
    }
    tl("26 fix finishing just before old 10s check") {
        $0.dictate(s1, at: 0).fix("bright", "Brite", at: 9.4)
    }
    tl("27 multi-word to one: super base") { $0.dictate("Deploy it on super base tonight", at: 0).fix("super base", "Supabase", at: 9) }
    tl("28 two-to-one name at 40s") { $0.dictate("Dinner with a lisha on Friday", at: 0).fix("a lisha", "Alisha", at: 40) }
    tl("29 lowercase product kubernetes at 7s") {
        $0.dictate("Our cooper netties cluster is down", at: 0).fix("cooper netties", "kubernetes", at: 7)
    }
    tl("30 insertion mid-document, fix at 20s") {
        $0.preset("Hi team,\nThanks, Dhruv").dictate("Please welcome Steven to the team.", at: 0, before: "Thanks")
          .fix("Steven", "Stephen", at: 20)
    }
    tl("31 edit top of doc, then fix at 30s") {
        $0.preset("Draft\n").dictate("Next we meet car tear on Monday", at: 0).type(" v2", at: 8, after: "Draft")
          .fix("car tear", "Kartier", at: 30)
    }
    tl("32 two apps, back to first, fix at 25s") {
        $0.dictate("Invoice for bright AI attached", at: 0).focus(app: 2, field: 2, at: 3)
          .dictate("Reminder to call mom", at: 5).focus(app: 1, field: 1, at: 20).fix("bright", "Brite", at: 25)
    }
    tl("33 select all, delete, write new paragraph") {
        $0.dictate("The bright idea was simple", at: 0).send(at: 5).type("Brite ideas need work", at: 6)
    }
    tl("34 unreadable field (app hides text)") { $0.unreadable(field: 1).dictate(s1, at: 0).fix("bright", "Brite", at: 5) }
    tl("35 back-to-back within 3s, fix second at 4s, first at 15s") {
        $0.dictate("Ping Steven", at: 0).dictate("and car tear", at: 2.5).fix("car tear", "Kartier", at: 5).fix("Steven", "Stephen", at: 15)
    }
    tl("36 no edits (control)") { $0.dictate(s1, at: 0) }
    tl("37 keeps typing for a minute, no fix") {
        $0.dictate("Quick summary of the bright side", at: 0)
          .type(" Revenue grew, churn fell, and the team shipped the new onboarding flow on time.", at: 3, cps: 4)
          .type(" Next up is pricing.", at: 30, cps: 4)
    }
    tl("38 types a similar-sounding word after ours") {
        $0.dictate("Met Steven today", at: 0).type(" and Stephen too", at: 6)
    }
    tl("39 channel switch swaps field (not the user)") {
        $0.dictate("Ask bright AI about it", at: 0).focus(app: 2, field: 2, at: 3).swap("Ask Brite AI about it", at: 6, field: 1)
    }
    tl("40 fix while next recording runs") {
        $0.dictate("Thank Steven for the intro", at: 0).fix("Steven", "Stephen", at: 6).dictate("and schedule a call", at: 6.5)
    }
    tl("41 name twice, fix one occurrence") {
        $0.dictate("bright AI said bright AI will call", at: 0).fix("bright", "Brite", at: 8)
    }
    tl("42 sentence-start real name Bright->Brite") { $0.dictate("Bright is hiring engineers", at: 0).fix("Bright", "Brite", at: 6) }
    tl("43 Jon->John at 18s") { $0.dictate("Forward this to Jon please", at: 0).fix("Jon", "John", at: 18) }
    tl("44 content edit Monday->Tuesday") {
        $0.dictate("See you Monday", at: 0).fix("Monday", "Tuesday", at: 5, real: false)
    }
    tl("45 hands-free style: 5 quick dictations, fix second at 12s") {
        $0.dictate("First point", at: 0).dictate("ask Steven", at: 2).dictate("about pricing", at: 4)
          .dictate("and timing", at: 6).dictate("thanks", at: 8).fix("Steven", "Stephen", at: 12)
    }
    tl("46 fix in another field of same app, then back") {
        $0.dictate("Tell Katherine hello", at: 0).focus(app: 1, field: 3, at: 3).type("search", at: 3.5)
          .focus(app: 1, field: 1, at: 8).fix("Katherine", "Kathryn", at: 10)
    }
    tl("47 typo fix teh->the (not a name)") {
        $0.dictate("Ship it", at: 0).type(" teh build", at: 2).fix("teh", "the", at: 6, real: false)
    }
    tl("48 fix at 55s") { $0.dictate("Invite car tear to the offsite", at: 0).fix("car tear", "Kartier", at: 55) }
    tl("49 sentence start Accept->Except (not a name)") {
        $0.dictate("Accept for the logo everything is final", at: 0).fix("Accept", "Except", at: 7, real: false)
    }
    tl("50 capitalisation only new york->New York") {
        $0.dictate("Flying to new york on Monday", at: 0).fix("new york", "New York", at: 9, real: false)
    }
    tl("51 different person Sam->Pam (content)") {
        $0.dictate("Ask Sam to review", at: 0).fix("Sam", "Pam", at: 6, real: false)
    }
    tl("52 typo fix recieve->receive (not a name)") {
        $0.dictate("Did you", at: 0).type(" recieve it", at: 2).fix("recieve", "receive", at: 6, real: false)
    }
    // The founder's names (2026-10-12): Pype, Dhruv, Mehra.
    tl("53 pipe->Pype") { $0.dictate("I work at pipe and we are hiring.", at: 0).fix("pipe", "Pype", at: 5) }
    tl("54 two names in one edit") {
        $0.dictate("this is druv mera from the sales team", at: 0).fix("druv mera", "Dhruv Mehra", at: 6)
    }
    tl("55 Mehta->Mehra (short codes differ)") {
        $0.dictate("My surname is Mehta, not Sharma.", at: 0).fix("Mehta", "Mehra", at: 5)
    }
    tl("56 Mehta->Mehra at sentence start") { $0.dictate("Mehta is my surname.", at: 0).fix("Mehta", "Mehra", at: 5) }
    tl("57 possessive druv's->Dhruv's") {
        $0.dictate("Please forward it to druv's inbox today.", at: 0).fix("druv's", "Dhruv's", at: 5)
    }
    tl("58 Meyra->Mehra") { $0.dictate("Mr Meyra will join the call.", at: 0).fix("Meyra", "Mehra", at: 4) }
    tl("59 pipe->pipes (not a name)") {
        $0.dictate("the water pipe burst last night", at: 0).fix("pipe", "pipes", at: 4, real: false)
    }
    tl("60 Mark->Mike (different person)") {
        $0.dictate("I met Mark yesterday.", at: 0).fix("Mark", "Mike", at: 4, real: false)
    }
    tl("61 Drew->Drawn (grammar)") {
        $0.dictate("Drew a diagram of the flow.", at: 0).fix("Drew", "Drawn", at: 4, real: false)
    }
    // 2026-10-12 new-name path: a word fixed into a name that sounds unlike
    // it (real Parakeet: Aman "I work at Python.", "…from Fight."), a
    // re-cased name, and the content edits that must stay out.
    tl("62 Python->Pype (unlike, new name)") {
        $0.dictate("I work at Python and we are hiring.", at: 0).fix("Python", "Pype", at: 5)
    }
    tl("63 Fight->Pype at the end") {
        $0.dictate("This is Dhruv Mehra from Fight.", at: 0).fix("Fight", "Pype", at: 6)
    }
    tl("64 Python->Pype, slow fixer pauses at Pyp") {
        $0.dictate("I work at Python and we are hiring.", at: 0).fix("Python", "Pype", at: 5, pauseAfter: 3, pause: 2.5)
    }
    tl("65 two fixes, one unlike: Druv + Fight") {
        $0.dictate("This is Druv from Fight.", at: 0).fix("Druv", "Dhruv", at: 4).fix("Fight", "Pype", at: 8)
    }
    tl("66 pype->Pype (re-cased name)") {
        $0.dictate("I work at pype and we are hiring.", at: 0).fix("pype", "Pype", at: 5)
    }
    tl("67 Priya->Zoya (different person)") {
        $0.dictate("Ask Priya to call me.", at: 0).fix("Priya", "Zoya", at: 4, real: false)
    }
    tl("68 him->Priya (content)") {
        $0.dictate("I will call him later.", at: 0).fix("him", "Priya", at: 4, real: false)
    }
    tl("69 Mira->Meri (Hinglish grammar)") {
        $0.dictate("Mira gaadi kahan hai", at: 0).fix("Mira", "Meri", at: 4, real: false)
    }
    tl("70 Monday->Pype inside a rewrite") {
        $0.dictate("See you Monday at the office.", at: 0).fix("Monday", "Pype", at: 4, real: false)
          .fix("office", "warehouse", at: 8, real: false)
    }
    return all
}

// MARK: - Scoring

struct Score { var captured = 0, missed = 0, spurious = 0, reads = 0 }

/// The app's gate since 2026-10-12: RuleLearning with the system dictionary.
let ordinaryWords = RuleLearning.loadOrdinaryWords()
enum Gate { case oracle, oldLocal, ruleKeyless, ruleKeyedDirect }

func score(_ tl: Timeline, _ emitted: [Emitted], keyless: Bool, keyed: Bool, gate: Gate? = nil) -> (Score, [String]) {
    let gate = gate ?? (keyed ? .oracle : .oldLocal)
    var s = Score()
    var notes: [String] = []
    // Unique real pairs: the same pair twice is one lesson.
    var real: [String: Fix] = [:]
    for f in tl.fixes where f.real { real[f.heard.lowercased() + "→" + f.corrected] = f }
    var got = Set<String>()
    for e in emitted {
        let k = e.heard.lowercased() + "→" + e.corrected
        let pass: Bool
        let c = EditDiff.Correction(heard: e.heard, corrected: e.corrected)
        switch gate {
        case .oracle:
            // What reaches the decision model (an ideal oracle) or a card:
            // pairs RuleLearning rejects outright never leave the Mac
            // (since 2026-10-12 — EditDiff's newNames path reports unlike
            // swaps such as "Priya" → "Zoya" only for RuleLearning to judge).
            let p = RuleLearning.propose(c, fixed: e.fixed, source: .keyboard, existing: [], hasKey: true,
                                         isOrdinaryWord: { ordinaryWords.contains($0) })
            if p.gate == .reject { continue }
            pass = real[k] != nil
            if real[k] == nil { s.spurious += 1; notes.append("diff-spurious \(k)") }
        case .oldLocal:
            pass = CorrectionWatchPolicy.passesLocalGate(c, fixed: e.fixed)
            if pass && real[k] == nil { s.spurious += 1; notes.append("SPURIOUS card \(k)") }
        case .ruleKeyless, .ruleKeyedDirect:
            // ruleKeyedDirect: cards made WITHOUT asking the model (the
            // rest go to it); spurious = wrong cards the model never saw.
            let p = RuleLearning.propose(c, fixed: e.fixed, source: .keyboard, existing: [],
                                         hasKey: gate == .ruleKeyedDirect,
                                         isOrdinaryWord: { ordinaryWords.contains($0) })
            pass = p.gate == .learnDirect
            if pass && real[k] == nil { s.spurious += 1; notes.append("SPURIOUS card \(k)") }
        }
        if pass && real[k] != nil { got.insert(k) }
    }
    s.captured = got.count
    s.missed = real.count - got.count
    for k in real.keys where !got.contains(k) { notes.append("missed \(k)") }
    return (s, notes)
}

// MARK: - Unit tests on the policy

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("  TEST FAIL: \(what)") } }

func unitTests() {
    let d = { (t: Double) in Date(timeIntervalSinceReferenceDate: t) }
    // Eviction bound.
    var p = CorrectionWatchPolicy()
    var field = ""
    for i in 0..<8 { field += "line \(i) words here. "; _ = p.inserted(fieldID: 1, text: "line \(i) words here.", fieldText: field, at: d(Double(i))) }
    check(p.entries.count == p.config.maxWatched, "keeps at most maxWatched insertions")
    // Mid-word state never taught; settled fix taught once.
    p = CorrectionWatchPolicy()
    _ = p.inserted(fieldID: 1, text: "ask bright AI now", fieldText: "ask bright AI now", at: d(0))
    var r = p.observe(fieldID: 1, text: "ask Brite AI now", focused: true, at: d(2))
    check(r.lessons.isEmpty, "unsettled change is not a lesson")
    r = p.observe(fieldID: 1, text: "ask Brite AI now", focused: true, at: d(3.5))
    check(r.lessons.count == 1, "settled change is a lesson")
    r = p.observe(fieldID: 1, text: "ask Brite AI now", focused: true, at: d(5))
    check(r.lessons.isEmpty, "no repeat lesson")
    // Same pair in a second insertion: never twice.
    _ = p.inserted(fieldID: 1, text: "bright AI again", fieldText: "ask Brite AI now bright AI again", at: d(6))
    _ = p.observe(fieldID: 1, text: "ask Brite AI now Brite AI again", focused: true, at: d(8))
    r = p.observe(fieldID: 1, text: "ask Brite AI now Brite AI again", focused: true, at: d(9.5))
    check(r.lessons.isEmpty, "same pair never twice")
    // Field emptied → watch ends.
    r = p.observe(fieldID: 1, text: "", focused: true, at: d(10))
    check(p.entries.isEmpty && r.stopped.allSatisfy { $0.1 == .lost }, "emptied field ends the watch")
    // Expiry.
    p = CorrectionWatchPolicy()
    _ = p.inserted(fieldID: 1, text: "hello there", fieldText: "hello there", at: d(0))
    _ = p.expire(now: d(30)); check(p.entries.count == 1, "alive at 30s")
    _ = p.expire(now: d(65)); check(p.entries.isEmpty, "expired after window")
    // Keyless gate.
    let g = { (h: String, c: String, fixed: String) in
        CorrectionWatchPolicy.passesLocalGate(EditDiff.Correction(heard: h, corrected: c), fixed: fixed) }
    check(g("bright", "Brite", "ask Brite AI"), "gate: Brite passes")
    check(g("a lisha", "Alisha", "with Alisha"), "gate: Alisha passes")
    check(!g("their", "there", "I think there is"), "gate: lowercase grammar fix fails")
    check(!g("Their", "There", "There is a bug"), "gate: sentence-start homophone fails")
    check(!g("cooper netties", "kubernetes", "our kubernetes"), "gate: lowercase product fails (accepted miss)")
    check(!g("form", "from", "notes from"), "gate: form/from fails")
}

// MARK: - Main

unitTests()
let tls = timelines()
// -trace NN [ax]: print every reading the new policy makes on timeline NN.
if let i = CommandLine.arguments.firstIndex(of: "-trace"), i + 1 < CommandLine.arguments.count {
    let tl = tls.first { $0.name.hasPrefix(CommandLine.arguments[i + 1]) }!
    var w = NewWatcher(ax: CommandLine.arguments.contains("ax"), trace: true)
    print(tl.name)
    _ = run(tl, &w)
    exit(0)
}
let gateFor: [String: Gate] = ["new  keyless poll+AX dict": .ruleKeyless, "new  key    poll+AX direct": .ruleKeyedDirect]
let modes: [(String, Bool, () -> any Watcher)] = [
    ("old  key    ", false, { OldWatcher(keyless: false) }),
    ("new  key    poll", false, { NewWatcher(ax: false) }),
    ("new  key    poll+AX", false, { NewWatcher(ax: true) }),
    ("old  keyless", true, { OldWatcher(keyless: true) }),
    ("new  keyless poll", true, { NewWatcher(ax: false) }),
    ("new  keyless poll+AX", true, { NewWatcher(ax: true) }),
    ("new  key poll+AX max3", false, {
        var c = CorrectionWatchPolicy.Config(); c.maxWatched = 3
        return NewWatcher(ax: true, policy: CorrectionWatchPolicy(config: c)) }),
    ("new  keyless poll+AX dict", true, { NewWatcher(ax: true) }),
    ("new  key    poll+AX direct", false, { NewWatcher(ax: true) }),
]
let verbose = CommandLine.arguments.contains("-v")
var totals: [String: Score] = [:]
var legacyTotals: [String: Score] = [:]
var perTimeline: [String: [String: Int]] = [:]
for (label, keyless, make) in modes {
    var t = Score()
    var legacy = Score()   // timelines 01–61 only (see the gate checks)
    for tl in tls {
        var w = make()
        let emitted: [Emitted]
        if var o = w as? OldWatcher { emitted = run(tl, &o); w = o }
        else if var n = w as? NewWatcher { emitted = run(tl, &n); w = n }
        else { fatalError() }
        var (s, notes) = score(tl, emitted, keyless: keyless, keyed: !keyless, gate: gateFor[label])
        s.reads = w.reads
        t.captured += s.captured; t.missed += s.missed; t.spurious += s.spurious; t.reads += s.reads
        if let n = Int(tl.name.prefix(2)), n <= 61 {
            legacy.captured += s.captured; legacy.missed += s.missed; legacy.spurious += s.spurious
        }
        perTimeline[tl.name, default: [:]][label] = s.captured
        if verbose && !notes.isEmpty { print("  [\(label)] \(tl.name): \(notes.joined(separator: ", "))") }
    }
    totals[label] = t
    legacyTotals[label] = legacy
}
let realTotal = tls.reduce(0) { acc, tl in acc + Set(tl.fixes.filter(\.real).map { $0.heard.lowercased() + "→" + $0.corrected }).count }
print("\n\(tls.count) timelines, \(realTotal) real name fixes, \(tls.flatMap(\.fixes).filter { !$0.real }.count) non-name edits")
print("mode                        captured  missed  spurious  AX-reads(field reads, ×2 AX calls)")
for (label, _, _) in modes {
    let t = totals[label]!
    print(label.padding(toLength: 28, withPad: " ", startingAt: 0)
          + String(format: "%8d  %6d  %8d  %8d", t.captured, t.missed, t.spurious, t.reads))
}
print("(key modes: spurious = diff-level triggers sent to the decision model, which is scored as an ideal oracle;")
print(" keyless modes: spurious = wrong Learned cards after the local gate;")
print(" dict = RuleLearning keyless gate (app since 2026-10-12); key direct = cards made with a key WITHOUT asking the model)")

// Gates.
let oldK = totals["old  key    "]!, newK = totals["new  key    poll"]!, newKL = totals["new  keyless poll"]!
let newAXK = totals["new  key    poll+AX"]!, newAXKL = totals["new  keyless poll+AX"]!
check(newK.captured > oldK.captured, "new (key) captures more than old")
check(newAXK.captured >= newK.captured - 1, "poll+AX not worse than poll")
// Shipped mode is poll+AX; poll-only (apps that post no AX changes) can't
// see a chat field emptied-and-retyped between two polls (timeline 16).
// The plain sound-only gate (no dictionary) has not shipped since
// 2026-10-12; it is held to its old bar on its old timelines (01–61). It
// passes "Mira" → "Meri" (69, Hinglish) — the shipped dict gate does not.
let legAXKL = legacyTotals["new  keyless poll+AX"]!, legKL = legacyTotals["new  keyless poll"]!
check(legAXKL.spurious == 0, "keyless poll+AX (sound-only gate, timelines 01-61): zero wrong cards")
check(legKL.spurious <= 1, "keyless poll-only (sound-only gate, 01-61): at most the known send-and-retype card")
check(newKL.captured > 0, "keyless captures something")
check(newK.spurious <= oldK.spurious + 2, "new: diff-level spurious not materially above old")
let dictKL = totals["new  keyless poll+AX dict"]!, directK = totals["new  key    poll+AX direct"]!
check(dictKL.spurious == 0, "keyless dict gate: zero wrong cards")
check(dictKL.captured >= newAXKL.captured, "keyless dict gate captures at least the old gate")
check(directK.spurious == 0, "keyed direct (no model): zero wrong cards")
print(failures == 0 ? "\nWATCH-EVAL PASS" : "\nWATCH-EVAL FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
