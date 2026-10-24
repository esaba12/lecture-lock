import AppKit

// MARK: - Browser control (AppleScript)

enum BrowserKind {
    case chromium(String)   // AppleScript app name
    case safari

    static func of(_ app: NSRunningApplication) -> BrowserKind? { of(bundleID: app.bundleIdentifier) }

    static func of(bundleID: String?) -> BrowserKind? {
        switch bundleID {
        case "com.google.Chrome": return .chromium("Google Chrome")
        case "com.brave.Browser": return .chromium("Brave Browser")
        case "com.microsoft.edgemac": return .chromium("Microsoft Edge")
        case "company.thebrowser.Browser": return .chromium("Arc")
        case "com.apple.Safari": return .safari
        default: return nil
        }
    }

    var appName: String {
        switch self {
        case .chromium(let name): name
        case .safari: "Safari"
        }
    }
    /// AppleScript for the front window's visible tab.
    var frontTab: String {
        switch self {
        case .chromium: "active tab of window 1"
        case .safari: "current tab of front window"
        }
    }
}

@discardableResult
func runScript(_ source: String) -> NSAppleEventDescriptor? {
    var err: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
    return err == nil ? result : nil
}

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// A JavaScript string literal for `s`.
func jsString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

func currentTab(_ kind: BrowserKind) -> (url: String, title: String)? {
    let title = if case .safari = kind { "name" } else { "title" }
    let src = """
    tell application "\(kind.appName)"
      with timeout of 5 seconds
        return {URL of \(kind.frontTab), \(title) of \(kind.frontTab)}
      end timeout
    end tell
    """
    guard let d = runScript(src), d.numberOfItems == 2,
          let url = d.atIndex(1)?.stringValue else { return nil }
    return (url, d.atIndex(2)?.stringValue ?? url)
}

/// What must stay in the URL when locked to one page: the video id on YouTube, otherwise host + path.
func pageAnchor(_ urlString: String) -> String {
    guard let c = URLComponents(string: urlString), let host = c.host else { return urlString }
    if host.hasSuffix("youtube.com"), let v = c.queryItems?.first(where: { $0.name == "v" })?.value { return "v=\(v)" }
    if host == "youtu.be" { return "v=" + c.path.dropFirst() }
    return host + c.path
}

/// What must stay in the URL when locked to a whole site.
func siteAnchor(_ urlString: String) -> String {
    let host = URLComponents(string: urlString)?.host ?? urlString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// "https://www.sqlbolt.com/lesson/end/" -> "sqlbolt.com/lesson/end", for forgiving link matching.
func normalizeLink(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
    while t.hasSuffix("/") { t.removeLast() }
    return t
}

/// AppleScript that looks for a tab whose URL contains `anchor`: the front tab first (runs `onFront`),
/// then every tab of every window (runs `onFound` with `w`, `t` and Chromium's tab index `i` bound).
/// `otherwise` runs if none match.
func tabSearchScript(_ kind: BrowserKind, anchor: String, before: String = "", onFront: String, onFound: String, otherwise: String) -> String {
    let a = esc(anchor)
    return """
    tell application "\(kind.appName)"
      with timeout of 5 seconds
      \(before)
      if (count of windows) > 0 then
        set t to \(kind.frontTab)
        set tu to ""
        try
          set tu to URL of t
        end try
        if tu contains "\(a)" then \(onFront)
      end if
      repeat with w in windows
        set i to 0
        repeat with t in tabs of w
          set i to i + 1
          set tu to ""
          try
            set tu to URL of t
          end try
          if tu contains "\(a)" then
            \(onFound)
          end if
        end repeat
      end repeat
      \(otherwise)
      end timeout
    end tell
    """
}

/// Make sure a tab matching `anchor` is the one in front; reopen `url` if none is left.
/// Returns the front tab's URL when it matches.
@discardableResult
func enforceTab(_ kind: BrowserKind, url: String, anchor: String) -> String? {
    let u = esc(url)
    let (noWindows, select, reopen) = switch kind {
    case .chromium:
        ("make new window\n    set URL of active tab of window 1 to \"\(u)\"",
         "set active tab index of w to i",
         "tell window 1 to make new tab with properties {URL:\"\(u)\"}")
    case .safari:
        ("make new document with properties {URL:\"\(u)\"}",
         "set current tab of w to t",
         "tell front window to set current tab to (make new tab with properties {URL:\"\(u)\"})")
    }
    let src = tabSearchScript(kind, anchor: anchor,
        before: "if (count of windows) is 0 then\n    \(noWindows)\n    return \"\"\n  end if",
        onFront: "return tu",
        onFound: "\(select)\n        set index of w to 1\n        return \"\"",
        otherwise: "\(reopen)\n  return \"\"")
    let cur = runScript(src)?.stringValue ?? ""
    return cur.isEmpty ? nil : cur
}

// MARK: - Page inspection (JavaScript run inside the lecture tab)

enum TabJS { case value(String), jsDisabled, failed }

/// Runs `js` in the front tab if it matches `anchor`, else the first tab that does. Returns "notab" if none.
func runInLectureTab(_ kind: BrowserKind, anchor: String, js: String) -> TabJS {
    let j = esc(js)
    let exec = switch kind {
    case .chromium: "execute t javascript \"\(j)\""
    case .safari: "do JavaScript \"\(j)\" in t"
    }
    let src = tabSearchScript(kind, anchor: anchor, onFront: "return (\(exec))",
                              onFound: "return (\(exec))", otherwise: "return \"notab\"")
    var err: NSDictionary?
    let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err {
        let msg = err[NSAppleScript.errorMessage] as? String ?? ""
        return msg.contains("JavaScript") ? .jsDisabled : .failed
    }
    return .value(result?.stringValue ?? "")
}

func enableJSHint(_ kind: BrowserKind) -> String {
    switch kind {
    case .chromium(let name): "Turn on \(name) › View › Developer › Allow JavaScript from Apple Events, then try again."
    case .safari: "Turn on Safari › Develop › Allow JavaScript from Apple Events (enable the Develop menu in Settings › Advanced first), then try again."
    }
}

let sep = "|~|"

/// Picks the longest video on the page (skips previews/thumbnails).
private let pickVideo = "var vs=[].slice.call(document.querySelectorAll('video')).filter(function(v){return isFinite(v.duration)&&v.duration>0});vs.sort(function(a,b){return b.duration-a.duration});var v=vs[0];"
let probeVideoJS = "(function(){if(document.querySelector('.ad-showing'))return 'ad';\(pickVideo)if(!v)return 'none';return [v.currentTime,v.duration,v.paused?1:0,v.playbackRate].join(',')})()"

/// URL plus referrer: an empty referrer means the page was typed in, not clicked to.
let locationJS = "(function(){return location.href+'\(sep)'+document.referrer})()"
func pageHasTextJS(_ phrase: String) -> String {
    "(function(){return document.body&&document.body.innerText.toLowerCase().indexOf(\(jsString(phrase.lowercased())))>=0?'1':'0'})()"
}

struct VideoState { var current, duration, rate: Double; var paused: Bool }
