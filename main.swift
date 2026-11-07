// Meeting Alerts: fires a macOS notification N minutes before every timed calendar event.
// The notification's title counts down ("Standup in 7 min"), refreshed on each minute boundary, and the
// notification is removed from screen / Notification Center when the meeting starts. (Use the "Alerts" style in
// System Settings > Notifications > Meeting Alerts so it stays on screen rather than sliding away.)
// Reads events via EventKit (all accounts in Apple Calendar, incl. Google once added in Internet Accounts).
// Config: ~/Library/Application Support/MeetingAlerts/config.json  {"leadMinutes":10,"calendars":[],"attendeesOnly":false}
// Log:    ~/Library/Logs/meeting-alerts.log
import Foundation
import EventKit
import UserNotifications

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/MeetingAlerts")
let stateURL = supportDir.appendingPathComponent("state.json")
let configURL = supportDir.appendingPathComponent("config.json")
let logURL = home.appendingPathComponent("Library/Logs/meeting-alerts.log")
try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

func log(_ s: String) {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(s)\n"
    print(line, terminator: ""); fflush(stdout)
    guard let d = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(d); try? h.close() }
    else { try? d.write(to: logURL) }
}

struct Config: Codable {
    var leadMinutes: Double = 10
    var calendars: [String] = []      // empty = all calendars; otherwise exact calendar titles
    var attendeesOnly: Bool = false   // true = only events that have attendees
}
func loadConfig() -> Config {
    if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
    let c = Config()
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(c) { try? d.write(to: configURL) }
    return c
}

// One entry per notified event occurrence; the key doubles as the notification identifier.
struct Entry: Codable {
    var start: Double        // event start, unix seconds
    var title: String        // event title
    var body: String
    var lastMins: Int        // minutes shown in the last update
    var notifiedAt: Double
    var cleared: Bool = false
}
var notified: [String: Entry] = {
    if let d = try? Data(contentsOf: stateURL), let m = try? JSONDecoder().decode([String: Entry].self, from: d) { return m }
    return [:]
}()
func saveState() {
    let cutoff = Date().timeIntervalSince1970 - 86400
    notified = notified.filter { $0.value.start > cutoff }
    if let d = try? JSONEncoder().encode(notified) { try? d.write(to: stateURL) }
}

let store = EKEventStore()
let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
var unAuthorized = false

func osascriptNotify(title: String, body: String) {
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Glass\""]
    try? p.run()
}

/// Posts (or, with the same id, replaces in place) a notification.
func post(id: String, title: String, body: String, sound: Bool) {
    if unAuthorized, let center = center {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        if sound { c.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { err in
            if let err = err { log("UN add error: \(err); falling back to osascript"); if sound { osascriptNotify(title: title, body: body) } }
        }
    } else if sound { osascriptNotify(title: title, body: body) }   // fallback can't update or clear, so only the first post
}

func minutesLeft(_ secs: Double) -> Int { max(1, Int((secs / 60).rounded(.up))) }
func countdownTitle(_ title: String, secs: Double) -> String { "\(title) in \(minutesLeft(secs)) min" }

let timeFmt = DateFormatter(); timeFmt.dateFormat = "h:mm a"
func describe(_ ev: EKEvent) -> String {
    var body = timeFmt.string(from: ev.startDate)
    if let end = ev.endDate { body += " – " + timeFmt.string(from: end) }
    body += " · " + (ev.calendar?.title ?? "")
    if let loc = ev.location, !loc.isEmpty { body += "\n" + loc }
    return body
}

func tick() {
    // Re-check notification permission each tick so enabling it in System Settings takes effect without a restart.
    center?.getNotificationSettings { s in
        let ok = s.authorizationStatus == .authorized
        if ok != unAuthorized { log("notification permission changed: \(ok)") }
        unAuthorized = ok
    }
    let cfg = loadConfig()
    let now = Date()
    let lead = cfg.leadMinutes * 60
    var dirty = false

    // 1. New events entering the warning window.
    let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(lead + 120), calendars: nil)
    for ev in store.events(matching: pred) {
        guard !ev.isAllDay, ev.status != .canceled, let start = ev.startDate else { continue }
        let secs = start.timeIntervalSince(now)
        guard secs > 0, secs <= lead + 30 else { continue }
        let calTitle = ev.calendar?.title ?? ""
        if !cfg.calendars.isEmpty && !cfg.calendars.contains(calTitle) { continue }
        if cfg.attendeesOnly && (ev.attendees?.isEmpty ?? true) { continue }
        if let me = ev.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { continue }
        let key = "\(ev.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))"
        if notified[key] != nil { continue }
        let title = ev.title ?? "Event"
        let body = describe(ev)
        let mins = minutesLeft(secs)
        let shown = countdownTitle(title, secs: secs)
        post(id: key, title: shown, body: body, sound: true)
        notified[key] = Entry(start: start.timeIntervalSince1970, title: title, body: body,
                              lastMins: mins, notifiedAt: now.timeIntervalSince1970)
        dirty = true
        log("notified: \(shown) | \(body.replacingOccurrences(of: "\n", with: " "))")
    }

    // 2. Count down: re-post with the same identifier (replaces the delivered notification) whenever the
    //    minutes-left figure changes, and clear it from screen / Notification Center when the meeting starts.
    for (key, var e) in notified where !e.cleared {
        let secs = e.start - now.timeIntervalSince1970
        if secs <= 0 {
            center?.removeDeliveredNotifications(withIdentifiers: [key])
            e.cleared = true; notified[key] = e; dirty = true
            log("cleared at start: \(e.title)")
        } else if minutesLeft(secs) != e.lastMins, unAuthorized {
            e.lastMins = minutesLeft(secs); notified[key] = e; dirty = true
            post(id: key, title: countdownTitle(e.title, secs: secs), body: e.body, sound: false)
        }
    }
    if dirty { saveState() }
    scheduleBoundaryTick(now: now)
}

// Wake exactly when the next active warning crosses a minute boundary (or starts), so the countdown
// changes on time instead of up to one poll interval late.
var boundaryTimer: Timer?
func scheduleBoundaryTick(now: Date) {
    boundaryTimer?.invalidate(); boundaryTimer = nil
    var next: Double?
    for e in notified.values where !e.cleared {
        let secs = e.start - now.timeIntervalSince1970
        guard secs > 0 else { continue }
        let wait = secs - Double(minutesLeft(secs) - 1) * 60   // seconds until minutesLeft drops by one (or start)
        next = min(next ?? wait, wait)
    }
    if let w = next {
        boundaryTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, w + 0.5), repeats: false) { _ in tick() }
    }
}

func runTest() {
    log("--test: calendars visible to EventKit:")
    for cal in store.calendars(for: .event) { log("  [\(cal.source?.title ?? "?")] \(cal.title)") }
    let now = Date()
    let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(24*3600), calendars: nil)
    let evs = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
    log("--test: \(evs.count) events in the next 24h:")
    for ev in evs { log("  \(ev.isAllDay ? "[all-day] " : "")\(ev.title ?? "?") | \(describe(ev).replacingOccurrences(of: "\n", with: " "))") }
    post(id: "test-\(UUID().uuidString)", title: "Meeting Alerts test", body: "If you can read this, notifications work.", sound: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
}

/// Posts a fake warning and updates it twice, 5 s apart, to show how macOS renders same-identifier replacement.
func runCountdownTest() {
    let id = "countdown-test"
    let body = "1:00 PM – 1:30 PM · Test calendar"
    func delivered() { center?.getDeliveredNotifications { ns in log("--countdown-test: delivered now: \(ns.map { "\"\($0.request.content.title)\" id=\($0.request.identifier)" })") } }
    post(id: id, title: "Countdown test in 3 min", body: body, sound: true); log("--countdown-test: posted 3 min")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { delivered() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { post(id: id, title: "Countdown test in 2 min", body: body, sound: false); log("--countdown-test: updated to 2 min") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7) { delivered() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { post(id: id, title: "Countdown test in 1 min", body: body, sound: false); log("--countdown-test: updated to 1 min") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { delivered() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { center?.removeDeliveredNotifications(withIdentifiers: [id]); log("--countdown-test: cleared"); exit(0) }
}

func start(test: Bool) {
    if CommandLine.arguments.contains("--countdown-test") { DispatchQueue.main.async { runCountdownTest() }; return }
    store.requestFullAccessToEvents { granted, error in
        log("calendar access granted=\(granted)\(error.map { " error=\($0)" } ?? "")")
        if !granted {
            log("Calendar access denied. Enable it in System Settings > Privacy & Security > Calendars for Meeting Alerts.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(1) }  // launchd restarts us; re-check later
            return
        }
        DispatchQueue.main.async {
            if test { runTest(); return }
            tick()
            Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in tick() }
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in tick() }
            log("running; lead=\(loadConfig().leadMinutes) min; polling every 20s")
        }
    }
}

let isTest = CommandLine.arguments.contains("--test")
log("starting Meeting Alerts\(isTest ? " (test mode)" : "")")
if let center = center {
    center.requestAuthorization(options: [.alert, .sound]) { ok, err in
        unAuthorized = ok
        log("notification permission=\(ok)\(err.map { " error=\($0)" } ?? "")\(ok ? "" : "; will fall back to osascript")")
        start(test: isTest)
    }
} else { log("no bundle id; using osascript for notifications"); start(test: isTest) }
RunLoop.main.run()
