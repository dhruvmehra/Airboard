//
//  ax-probe — does an app expose its text to Accessibility, and does
//  setting AXManualAccessibility (Electron) / AXEnhancedUserInterface
//  (Chromium) change that?
//
//  PRIVACY: prints ONLY booleans, roles, counts and lengths — never any
//  text content. Read-only apart from setting the two AX flags on the
//  application element; every flag it changes is restored to its prior
//  value at the end (pass --keep to leave AXManualAccessibility on).
//
//  Usage: scripts/ax-probe/run.sh [--enhanced] [--keep] [--app <substring>] [--settle <s>]
//    --enhanced  also test AXEnhancedUserInterface (Chromium/Electron only;
//                known to break window-manager animations while set — it
//                is restored right after the measurement)
//
//  NOTE: Electron applies AXManualAccessibility after a 2s debounce timer
//  that only fired while the app was FRONTMOST in testing — background
//  Electron apps show no change here. To test one properly, bring it to the
//  front during the run:
//    sleep 5 && scripts/ax-probe/run.sh --app Slack --settle 3
//  (switch to Slack within 5s; switch back after it prints).
//

import AppKit
import ApplicationServices

let args = CommandLine.arguments
let testEnhanced = args.contains("--enhanced")
let keepManual = args.contains("--keep")
let appFilter: String? = args.firstIndex(of: "--app").flatMap { $0 + 1 < args.count ? args[$0 + 1].lowercased() : nil }

let timeout: Float = 0.25
// Wait after each step so the renderer can build its AX tree (--settle <seconds>).
let settle: useconds_t = args.firstIndex(of: "--settle").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
    .map { useconds_t($0 * 1_000_000) } ?? 1_200_000

// MARK: - AX helpers (no text ever leaves these as content)

func copy(_ el: AXUIElement, _ attr: String) -> (AXError, CFTypeRef?) {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
    return (e, v)
}
func str(_ el: AXUIElement, _ attr: String) -> String? { copy(el, attr).1 as? String }
func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool? {
    let (e, v) = copy(el, attr)
    guard e == .success, let v else { return nil }
    if let b = v as? Bool { return b }
    if let n = v as? NSNumber { return n.boolValue }
    return nil
}
func isSecure(_ el: AXUIElement) -> Bool {
    str(el, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) || str(el, kAXRoleAttribute) == "AXSecureTextField"
}

struct Snapshot {
    var focused = false
    var role = "-"
    var secure = false
    var valueReadable = false   // AXValue is a String
    var valueLen = 0
    var selReadable = false     // AXSelectedText is a String
    var rangeReadable = false   // AXSelectedTextRange present
    var window = false
    var nodes = 0               // nodes visited in the focused window
    var textNodes = 0           // nodes with a non-empty Value/Title/Description string
    var textChars = 0           // total length of those strings (not printed as text)
    var webAreas = 0            // AXWebArea count (web content exposed at all)
}

func snapshot(pid: pid_t) -> Snapshot {
    var s = Snapshot()
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, timeout)
    let (fe, fv) = copy(app, kAXFocusedUIElementAttribute)
    if fe == .success, let fv, CFGetTypeID(fv) == AXUIElementGetTypeID() {
        let el = fv as! AXUIElement
        s.focused = true
        s.role = str(el, kAXRoleAttribute) ?? "?"
        s.secure = isSecure(el)
        if !s.secure {
            if let v = str(el, kAXValueAttribute) { s.valueReadable = true; s.valueLen = (v as NSString).length }
            s.selReadable = str(el, kAXSelectedTextAttribute) != nil
            s.rangeReadable = copy(el, kAXSelectedTextRangeAttribute).0 == .success
        }
    }
    var (we, wv) = copy(app, kAXFocusedWindowAttribute)
    if we != .success || wv == nil { (we, wv) = copy(app, kAXMainWindowAttribute) }
    guard we == .success, let wv, CFGetTypeID(wv) == AXUIElementGetTypeID() else { return s }
    s.window = true
    var queue: [AXUIElement] = [wv as! AXUIElement]
    var i = 0
    while i < queue.count && s.nodes < 4000 {
        let el = queue[i]; i += 1
        s.nodes += 1
        if str(el, kAXRoleAttribute) == "AXWebArea" { s.webAreas += 1 }
        if isSecure(el) { continue }
        var hasText = false
        for a in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let t = str(el, a), !t.isEmpty { hasText = true; s.textChars += (t as NSString).length }
        }
        if hasText { s.textNodes += 1 }
        if let kids = copy(el, kAXChildrenAttribute).1 as? [AXUIElement] { queue.append(contentsOf: kids) }
    }
    return s
}

// MARK: - App classification (bundle layout only)

func kind(of app: NSRunningApplication) -> String {
    guard let url = app.bundleURL else { return "?" }
    let fw = url.appendingPathComponent("Contents/Frameworks")
    let fm = FileManager.default
    if fm.fileExists(atPath: fw.appendingPathComponent("Electron Framework.framework").path) { return "Electron" }
    let items = (try? fm.contentsOfDirectory(atPath: fw.path)) ?? []
    for f in items where f.hasSuffix(" Framework.framework") {
        let helpers = fw.appendingPathComponent(f).appendingPathComponent("Versions/Current/Helpers").path
        let h = (try? fm.contentsOfDirectory(atPath: helpers)) ?? []
        if h.contains(where: { $0.contains("(Renderer)") }) { return "Chromium" }
    }
    if fm.fileExists(atPath: fw.appendingPathComponent("Chromium Embedded Framework.framework").path) { return "CEF" }
    return "native"
}

func setFlag(_ pid: pid_t, _ attr: String, _ on: Bool) -> AXError {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, timeout)
    return AXUIElementSetAttributeValue(app, attr as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
}
func errName(_ e: AXError) -> String {
    switch e {
    case .success: return "ok"
    case .attributeUnsupported: return "unsupported"
    case .illegalArgument: return "illegalArg"
    case .cannotComplete: return "cannotComplete"
    case .apiDisabled: return "apiDisabled"
    case .notImplemented: return "notImpl"
    case .noValue: return "noValue"
    default: return "err\(e.rawValue)"
    }
}

// MARK: - Main

guard AXIsProcessTrusted() else {
    let parent = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "your terminal app"
    print("""
    ax-probe: this process is NOT trusted for Accessibility (AXIsProcessTrusted() == false).
    Grant it: System Settings → Privacy & Security → Accessibility → enable \(parent)
    (the app that launched this probe), then quit and reopen that app and re-run.
    """)
    exit(2)
}

let me = ProcessInfo.processInfo.processIdentifier
let apps = NSWorkspace.shared.runningApplications.filter {
    $0.activationPolicy == .regular && $0.processIdentifier != me
        && !($0.bundleIdentifier ?? "").hasPrefix("com.pype.airboard")
        && (appFilter == nil || ($0.localizedName ?? "").lowercased().contains(appFilter!))
}

func cell(_ s: Snapshot) -> String {
    let f = s.focused ? "\(s.role)\(s.secure ? "(secure)" : "")" : "noFocus"
    let v = s.valueReadable ? "V\(s.valueLen)" : "V-"
    let sel = s.selReadable ? "S+" : "S-"
    let w = s.window ? "n\(s.nodes)/t\(s.textNodes)/c\(s.textChars)/w\(s.webAreas)" : "noWin"
    return "\(f) \(v) \(sel) \(w)"
}

print("Legend: role  V<len>=AXValue readable (length)  S+=AXSelectedText readable  n=nodes t=text nodes c=text chars w=AXWebAreas")
print("Columns: before = first touch; again = re-read after \(Double(settle)/1e6)s with NO flag (Chromium enables lazily on role queries); manual = after AXManualAccessibility=true; enh = after AXEnhancedUserInterface=true\n")

for app in apps {
    let pid = app.processIdentifier
    let name = app.localizedName ?? "?"
    let k = kind(of: app)
    let appEl = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appEl, timeout)
    let priorManual = boolAttr(appEl, "AXManualAccessibility")
    let priorEnh = boolAttr(appEl, "AXEnhancedUserInterface")

    let before = snapshot(pid: pid)
    usleep(settle)
    let again = snapshot(pid: pid)

    let mErr = setFlag(pid, "AXManualAccessibility", true)
    usleep(settle)
    let manual = snapshot(pid: pid)

    var enhLine = ""
    if testEnhanced && (k == "Chromium" || k == "Electron") {
        let eErr = setFlag(pid, "AXEnhancedUserInterface", true)
        usleep(settle)
        let enh = snapshot(pid: pid)
        _ = setFlag(pid, "AXEnhancedUserInterface", priorEnh ?? false)   // restore
        enhLine = "\n    enh   [set=\(errName(eErr))]: \(cell(enh))"
    }
    if !keepManual && mErr == .success { _ = setFlag(pid, "AXManualAccessibility", priorManual ?? false) }

    func b(_ x: Bool?) -> String { x.map { $0 ? "1" : "0" } ?? "-" }
    print("""
    \(name) [\(k)] priorManual=\(b(priorManual)) priorEnh=\(b(priorEnh))
        before: \(cell(before))
        again : \(cell(again))
        manual[set=\(errName(mErr))]: \(cell(manual))\(enhLine)
    """)
}
