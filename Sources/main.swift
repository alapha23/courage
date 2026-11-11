// Courage — a floating "money earned today" widget for macOS.
// Enter your monthly pay (pre-tax and/or take-home) and watch today's earnings tick up in real time.
// Optionally, it can read the amounts from your latest payslip PDF instead.

import AppKit
import SwiftUI
import PDFKit
import ServiceManagement

// MARK: - Config

struct Config: Codable, Equatable {
    /// Monthly pay before tax (gross).
    var monthlyGross: Double? = nil
    /// Monthly take-home pay (net).
    var monthlyNet: Double? = nil
    var currency: String = Locale.current.currencySymbol ?? "$"

    var startTime: String = "09:00"
    var endTime: String = "17:30"
    /// Unpaid lunch break in minutes (subtracted from paid time, taken at lunchStart).
    var lunchMinutes: Int = 0
    var lunchStart: String = "12:30"
    /// "net" (take-home) or "gross"
    var mode: String = "net"

    /// Public holidays (YYYY-MM-DD). Defaults to Irish public holidays; replace with your own.
    var publicHolidays: [String] = WorkCalendar.irishHolidays2026_27
    /// Extra non-working days, e.g. annual leave: ["2026-12-24"]
    var extraDaysOff: [String] = []

    /// Show today's amount in the menu bar. Turn off when screen sharing.
    var menuBarShowsAmount: Bool = true

    /// Optional payslip import. Leave empty to use the amounts above.
    /// Reads the newest `YYYYMM.pdf` in this folder; manual amounts above take precedence.
    var payslipDir: String = ""
    /// Line label for gross salary on the payslip.
    var payslipSalaryLabel: String = "SALARY"
    /// Recurring deduction labels subtracted from gross to get net.
    var payslipDeductions: [String] = ["PAYE", "PRSI", "USC"]

    init() {}

    // Tolerant decoding: missing keys fall back to defaults, so older config files keep working.
    private enum LegacyKeys: String, CodingKey { case monthlyGrossOverride, monthlyNetOverride }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let d = Config()
        monthlyGross = try c.decodeIfPresent(Double.self, forKey: .monthlyGross)
            ?? legacy.decodeIfPresent(Double.self, forKey: .monthlyGrossOverride)
        monthlyNet = try c.decodeIfPresent(Double.self, forKey: .monthlyNet)
            ?? legacy.decodeIfPresent(Double.self, forKey: .monthlyNetOverride)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? d.currency
        startTime = try c.decodeIfPresent(String.self, forKey: .startTime) ?? d.startTime
        endTime = try c.decodeIfPresent(String.self, forKey: .endTime) ?? d.endTime
        lunchMinutes = try c.decodeIfPresent(Int.self, forKey: .lunchMinutes) ?? d.lunchMinutes
        lunchStart = try c.decodeIfPresent(String.self, forKey: .lunchStart) ?? d.lunchStart
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? d.mode
        publicHolidays = try c.decodeIfPresent([String].self, forKey: .publicHolidays) ?? d.publicHolidays
        extraDaysOff = try c.decodeIfPresent([String].self, forKey: .extraDaysOff) ?? d.extraDaysOff
        menuBarShowsAmount = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowsAmount) ?? d.menuBarShowsAmount
        payslipDir = try c.decodeIfPresent(String.self, forKey: .payslipDir) ?? d.payslipDir
        payslipSalaryLabel = try c.decodeIfPresent(String.self, forKey: .payslipSalaryLabel) ?? d.payslipSalaryLabel
        payslipDeductions = try c.decodeIfPresent([String].self, forKey: .payslipDeductions) ?? d.payslipDeductions
    }

    /// `~/Library/Application Support/Courage/config.json`, or `$COURAGE_CONFIG` if set (handy for demos/tests).
    static let url: URL = {
        if let p = ProcessInfo.processInfo.environment["COURAGE_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Courage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do { return try JSONDecoder().decode(Config.self, from: data) } catch {
            NSLog("Courage: could not read \(url.path): \(error). Using defaults.")
            return Config()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        // Salary data: keep the file private to the current user.
        try? data.write(to: Config.url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.url.path)
    }
}

// MARK: - Payslip parsing (optional)

struct Payslip {
    var file: String
    var gross: Double
    var net: Double
}

enum PayslipParser {
    static func latest(in dirPath: String, salaryLabel: String, deductions: [String]) -> Payslip? {
        guard !dirPath.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: (dirPath as NSString).expandingTildeInPath)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        // Only regular monthly slips named YYYYMM.pdf (skips e.g. 202601-CN.pdf)
        let candidates = files.filter { $0.range(of: #"^\d{6}\.pdf$"#, options: .regularExpression) != nil }.sorted()
        for name in candidates.reversed() {
            if let p = parse(dir.appendingPathComponent(name), salaryLabel: salaryLabel, deductions: deductions) {
                return p
            }
        }
        return nil
    }

    static func parse(_ url: URL, salaryLabel: String, deductions: [String]) -> Payslip? {
        guard let doc = PDFDocument(url: url), let text = doc.string else { return nil }
        guard let gross = firstAmount(after: salaryLabel, in: text) else { return nil }
        let total = deductions.compactMap { firstAmount(after: $0, in: text) }.reduce(0, +)
        return Payslip(file: url.lastPathComponent, gross: gross, net: gross - total)
    }

    /// Finds `LABEL [flag] amount`, where flag is an optional single capital letter (Y/N/G/M).
    static func firstAmount(after label: String, in text: String) -> Double? {
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: label).replacingOccurrences(of: " ", with: #"\s+"#)
        let pattern = #"(?<![A-Za-z])"# + escaped + #"\s+(?:[A-Z]\s+)?(-?[\d,]+\.\d{2})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r].replacingOccurrences(of: ",", with: ""))
    }
}

// MARK: - Calendar

enum WorkCalendar {
    /// Irish public holidays, used as the default holiday list.
    static let irishHolidays2026_27: [String] = [
        "2026-01-01", "2026-02-02", "2026-03-17", "2026-04-06", "2026-05-04",
        "2026-06-01", "2026-08-03", "2026-10-26", "2026-12-25", "2026-12-28",
        "2027-01-01", "2027-02-01", "2027-03-17", "2027-03-29", "2027-05-03",
        "2027-06-07", "2027-08-02", "2027-10-25", "2027-12-27", "2027-12-28",
    ]

    static let cal = Calendar(identifier: .gregorian)
    static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func key(_ d: Date) -> String { dayFmt.string(from: d) }
    static func isWeekend(_ d: Date) -> Bool { cal.isDateInWeekend(d) }
    static func isHoliday(_ d: Date, off: Set<String>) -> Bool { off.contains(key(d)) }
    static func isWorkday(_ d: Date, off: Set<String>) -> Bool { !isWeekend(d) && !isHoliday(d, off: off) }

    /// (workdays in month, workdays before today, workdays after today)
    static func monthStats(for now: Date, off: Set<String>) -> (total: Int, before: Int, after: Int) {
        let today = cal.startOfDay(for: now)
        guard let range = cal.range(of: .day, in: .month, for: now),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: now)) else { return (21, 0, 0) }
        var total = 0, before = 0, after = 0
        for i in 0..<range.count {
            let d = cal.date(byAdding: .day, value: i, to: first)!
            guard isWorkday(d, off: off) else { continue }
            total += 1
            if d < today { before += 1 } else if d > today { after += 1 }
        }
        return (max(total, 1), before, after)
    }

    static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return p[0] * 60 + p[1]
    }

    static func time(_ hhmm: String, on day: Date) -> Date {
        let m = minutes(hhmm) ?? 9 * 60
        return cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) ?? day
    }
}

// MARK: - Model

enum DayStatus { case beforeWork, onDuty, lunch, afterWork, weekend, holiday }

final class Model: ObservableObject {
    @Published var config: Config
    @Published var payslip: Payslip?
    @Published var now = Date()
    private var timer: Timer?

    init() {
        config = Config.load()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.now = Date() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func reload() {
        config = Config.load()
        payslip = PayslipParser.latest(in: config.payslipDir, salaryLabel: config.payslipSalaryLabel,
                                       deductions: config.payslipDeductions)
    }

    func apply(_ c: Config) {
        c.save()
        reload()
    }

    func toggleMode() {
        config.mode = isNet ? "gross" : "net"
        config.save()
    }

    var isNet: Bool { config.mode != "gross" }
    var daysOff: Set<String> { Set(config.publicHolidays + config.extraDaysOff) }

    var monthly: Double {
        if isNet { return config.monthlyNet ?? payslip?.net ?? 0 }
        return config.monthlyGross ?? payslip?.gross ?? 0
    }

    /// Shown in place of the quip when the selected amount isn't set.
    var missingHint: String? {
        guard monthly <= 0 else { return nil }
        return isNet ? "Add your take-home pay in Settings (⌘,)" : "Add your pre-tax pay in Settings (⌘,)"
    }

    var month: (total: Int, before: Int, after: Int) { WorkCalendar.monthStats(for: now, off: daysOff) }
    var daily: Double { monthly / Double(month.total) }

    var start: Date { WorkCalendar.time(config.startTime, on: now) }
    var end: Date { WorkCalendar.time(config.endTime, on: now) }
    var lunchStart: Date { WorkCalendar.time(config.lunchStart, on: now) }
    var lunchEnd: Date { lunchStart.addingTimeInterval(Double(config.lunchMinutes) * 60) }

    /// Paid seconds in a full working day.
    var paidSecondsPerDay: Double { max(end.timeIntervalSince(start) - Double(config.lunchMinutes) * 60, 1) }
    var hourly: Double { daily / (paidSecondsPerDay / 3600) }
    var perSecond: Double { daily / paidSecondsPerDay }

    var isWorkday: Bool { WorkCalendar.isWorkday(now, off: daysOff) }

    var status: DayStatus {
        if WorkCalendar.isWeekend(now) { return .weekend }
        if WorkCalendar.isHoliday(now, off: daysOff) { return .holiday }
        if now < start { return .beforeWork }
        if now >= end { return .afterWork }
        if config.lunchMinutes > 0, now >= lunchStart, now < lunchEnd { return .lunch }
        return .onDuty
    }

    /// Paid seconds elapsed today (excludes unpaid lunch).
    var workedSeconds: Double {
        guard isWorkday else { return 0 }
        let t = min(max(now, start), end)
        var s = t.timeIntervalSince(start)
        if config.lunchMinutes > 0 {
            let overlap = min(t, lunchEnd).timeIntervalSince(lunchStart)
            s -= max(0, min(overlap, Double(config.lunchMinutes) * 60))
        }
        return max(0, s)
    }

    var progress: Double { isWorkday ? min(workedSeconds / paidSecondsPerDay, 1) : 0 }
    var earnedToday: Double { workedSeconds * perSecond }
    var remainingSeconds: Double { isWorkday ? max(0, end.timeIntervalSince(now)) : 0 }
    var earnedThisMonth: Double { Double(month.before) * daily + earnedToday }

    var quip: String {
        switch status {
        case .weekend: return "Weekend. You're off the clock."
        case .holiday: return "Day off. Enjoy it guilt-free."
        case .beforeWork: return "Coffee first. The meter starts at \(config.startTime)."
        case .afterWork: return "Clocked out. Go live your life."
        case .lunch: return "Lunch break. Eat something proper."
        case .onDuty:
            switch progress {
            case ..<0.1: return "Fresh start. Every second counts."
            case ..<0.4: return "Warming up — the money's trickling in."
            case ..<0.6: return "Halfway there. Keep cruising."
            case ..<0.85: return "Afternoon grind. Stay hydrated."
            default: return "Final stretch — don't burn yourself out."
            }
        }
    }
}

// MARK: - Formatting

private let moneyFormatters: [Int: NumberFormatter] = Dictionary(uniqueKeysWithValues: (0...4).map { d in
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = d
    f.maximumFractionDigits = d
    return (d, f)
})

func money(_ v: Double, _ cur: String, _ digits: Int = 2) -> String {
    cur + (moneyFormatters[digits]?.string(from: NSNumber(value: v)) ?? String(format: "%.\(digits)f", v))
}

func hms(_ s: Double) -> String {
    let t = Int(s)
    return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
}

// MARK: - Widget UI

let accent = Color(red: 0.22, green: 0.86, blue: 0.40)
let dim = Color.white.opacity(0.62)

struct Badge: View {
    let status: DayStatus
    var body: some View {
        let (label, color): (String, Color) = {
            switch status {
            case .onDuty: return ("On duty", accent)
            case .lunch: return ("Lunch", .orange)
            case .beforeWork: return ("Not started", .gray)
            case .afterWork: return ("Off duty", .gray)
            case .weekend: return ("Weekend", .blue)
            case .holiday: return ("Holiday", .purple)
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }
}

struct Stat: View {
    let title: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundColor(dim)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WidgetView: View {
    @ObservedObject var m: Model

    var body: some View {
        let cur = m.config.currency
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Earned today" + (m.isNet ? " · take-home" : " · pre-tax"))
                    .font(.system(size: 13)).foregroundColor(dim)
                Spacer()
                Badge(status: m.status)
            }

            Text(money(m.earnedToday, cur, 3))
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [accent, Color(red: 0.55, green: 0.95, blue: 0.35)],
                                                startPoint: .leading, endPoint: .trailing))
                .shadow(color: accent.opacity(0.35), radius: 8)
                .onTapGesture { m.toggleMode() }
                .help("Click to switch take-home / pre-tax")

            HStack(spacing: 6) {
                Stat(title: "Per second", value: money(m.perSecond, cur, 4))
                Stat(title: "Hourly", value: money(m.hourly, cur))
                Stat(title: "Daily", value: money(m.daily, cur))
            }

            Divider().overlay(Color.white.opacity(0.15))

            HStack(spacing: 8) {
                Text("Worked \(hms(m.workedSeconds))").foregroundColor(dim)
                Text("\(Int(m.progress * 100))%").foregroundColor(.white).fontWeight(.semibold)
                Spacer()
                Text("Clock-out in \(hms(m.remainingSeconds))").foregroundColor(accent).fontWeight(.semibold)
            }
            .font(.system(size: 12)).monospacedDigit()

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(LinearGradient(colors: [accent, .yellow], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, g.size.width * m.progress))
                }
            }
            .frame(height: 7)

            HStack {
                HStack(spacing: 4) {
                    Text("This month").foregroundColor(dim)
                    Text(money(m.earnedThisMonth, cur)).foregroundColor(.white).bold()
                }
                Spacer()
                Text("\(m.month.after) workdays left").foregroundColor(dim)
            }
            .font(.system(size: 12)).monospacedDigit()

            Text(m.missingHint ?? m.quip)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(m.missingHint != nil ? .orange : Color.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.11, green: 0.14, blue: 0.17).opacity(0.94))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Settings UI

/// Editable copy of the config. (A class rather than @State so it builds with the Command Line Tools alone.)
final class SettingsDraft: ObservableObject {
    @Published var config: Config
    @Published var daysOffText: String
    @Published var deductionsText: String
    init(_ c: Config) {
        config = c
        daysOffText = c.extraDaysOff.joined(separator: ", ")
        deductionsText = c.payslipDeductions.joined(separator: ", ")
    }
}

struct SettingsView: View {
    @ObservedObject var s: SettingsDraft
    let payslip: Payslip?
    let onSave: (Config) -> Void
    let onCancel: () -> Void

    private func timeBinding(_ kp: WritableKeyPath<Config, String>) -> Binding<Date> {
        Binding(
            get: { WorkCalendar.time(s.config[keyPath: kp], on: Date()) },
            set: { d in
                let c = WorkCalendar.cal.dateComponents([.hour, .minute], from: d)
                s.config[keyPath: kp] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            })
    }

    private static func list(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var badDates: [String] {
        Self.list(s.daysOffText).filter { WorkCalendar.dayFmt.date(from: $0) == nil }
    }

    private var errors: [String] {
        var e: [String] = []
        if let g = s.config.monthlyGross, g < 0 { e.append("Pre-tax pay can't be negative.") }
        if let n = s.config.monthlyNet, n < 0 { e.append("Take-home pay can't be negative.") }
        if let g = s.config.monthlyGross, let n = s.config.monthlyNet, n > g { e.append("Take-home is higher than pre-tax.") }
        if (WorkCalendar.minutes(s.config.endTime) ?? 0) <= (WorkCalendar.minutes(s.config.startTime) ?? 0) {
            e.append("Finish time must be after start time.")
        }
        if !badDates.isEmpty { e.append("Use YYYY-MM-DD for days off: \(badDates.joined(separator: ", "))") }
        return e
    }

    private func choosePayslipFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Choose"
        if p.runModal() == .OK, let url = p.url {
            s.config.payslipDir = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Pre-tax (gross)", value: $s.config.monthlyGross, format: .number,
                              prompt: Text("e.g. 5000"))
                    TextField("Take-home (net)", value: $s.config.monthlyNet, format: .number,
                              prompt: Text("e.g. 3600"))
                    TextField("Currency symbol", text: $s.config.currency)
                    Picker("Show", selection: $s.config.mode) {
                        Text("Take-home").tag("net")
                        Text("Pre-tax").tag("gross")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Monthly pay")
                } footer: {
                    Text("Stored only on this Mac, in ~/Library/Application Support/Courage.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("Working hours") {
                    DatePicker("Start", selection: timeBinding(\.startTime), displayedComponents: .hourAndMinute)
                    DatePicker("Finish", selection: timeBinding(\.endTime), displayedComponents: .hourAndMinute)
                    Stepper("Unpaid lunch: \(s.config.lunchMinutes) min", value: $s.config.lunchMinutes, in: 0...180, step: 15)
                    if s.config.lunchMinutes > 0 {
                        DatePicker("Lunch at", selection: timeBinding(\.lunchStart), displayedComponents: .hourAndMinute)
                    }
                    TextField("Days off", text: $s.daysOffText, prompt: Text("2026-12-24, 2026-12-31"))
                }

                Section("Privacy") {
                    Toggle("Show amount in menu bar", isOn: $s.config.menuBarShowsAmount)
                }

                Section {
                    HStack {
                        TextField("Folder", text: $s.config.payslipDir, prompt: Text("Not used"))
                        Button("Choose…", action: choosePayslipFolder)
                    }
                    TextField("Salary label", text: $s.config.payslipSalaryLabel)
                    TextField("Deduction labels", text: $s.deductionsText)
                    if !s.config.payslipDir.isEmpty {
                        Text(payslip.map { "Last read: \($0.file)" } ?? "No YYYYMM.pdf payslip read yet.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Payslip import (optional)")
                } footer: {
                    Text("Reads the newest YYYYMM.pdf. Amounts typed above take precedence.")
                        .font(.caption).foregroundColor(.secondary)
                }

                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { Text($0).foregroundColor(.red) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Edit config file…") { NSWorkspace.shared.open(Config.url) }
                    .help("Public holidays and other advanced settings")
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var c = s.config
                    c.extraDaysOff = Self.list(s.daysOffText)
                    c.payslipDeductions = Self.list(s.deductionsText)
                    c.currency = c.currency.trimmingCharacters(in: .whitespaces)
                    if c.monthlyGross == 0 { c.monthlyGross = nil }
                    if c.monthlyNet == 0 { c.monthlyNet = nil }
                    onSave(c)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!errors.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 440, height: 640)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = Model()
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var menuTimer: Timer?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        let host = NSHostingView(rootView: WidgetView(m: model))
        host.frame.size = host.fittingSize

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        if !panel.setFrameUsingName("CourageWidget") {
            if let s = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: s.maxX - panel.frame.width - 24, y: s.maxY - panel.frame.height - 24))
            }
        }
        panel.setFrameAutosaveName("CourageWidget")
        panel.orderFrontRegardless()

        // Menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        menuTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatusTitle() }
        RunLoop.main.add(menuTimer!, forMode: .common)
        updateStatusTitle()

        // First run: ask for pay straight away.
        if !Config.exists || model.monthly <= 0 { openSettings() }
    }

    func updateStatusTitle() {
        statusItem.button?.title = model.config.menuBarShowsAmount
            ? "💰 " + money(model.earnedToday, model.config.currency)
            : "💰"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cur = model.config.currency
        let src: String
        if model.config.monthlyGross != nil || model.config.monthlyNet != nil {
            src = "Using the amounts you entered"
        } else if let p = model.payslip {
            src = "Payslip \(p.file): pre-tax \(money(p.gross, cur)), take-home \(money(p.net, cur))"
        } else {
            src = "No pay set — open Settings"
        }
        let info = NSMenuItem(title: src, action: nil, keyEquivalent: ""); info.isEnabled = false
        menu.addItem(info)
        let hours = NSMenuItem(title: "Hours \(model.config.startTime)–\(model.config.endTime)" +
                               (model.config.lunchMinutes > 0 ? ", \(model.config.lunchMinutes)m lunch" : ""),
                               action: nil, keyEquivalent: ""); hours.isEnabled = false
        menu.addItem(hours)
        menu.addItem(.separator())
        add(menu, panel.isVisible ? "Hide widget" : "Show widget", #selector(toggleWidget), "w")
        add(menu, model.isNet ? "Show pre-tax" : "Show take-home", #selector(toggleMode), "g")
        add(menu, "Settings…", #selector(openSettings), ",")
        add(menu, "Reload", #selector(reload), "r")
        let login = add(menu, "Launch at login", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "Quit Courage", #selector(NSApplication.terminate(_:)), "q")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = sel == #selector(NSApplication.terminate(_:)) ? NSApp : self
        menu.addItem(i)
        return i
    }

    @objc func openSettings() {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(s: SettingsDraft(model.config), payslip: model.payslip,
                                onSave: { [weak self] c in self?.model.apply(c); self?.closeSettings() },
                                onCancel: { [weak self] in self?.closeSettings() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Courage Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func closeSettings() { settingsWindow?.close() }
    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === settingsWindow { settingsWindow = nil }
    }

    @objc func toggleWidget() { panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless() }
    @objc func toggleMode() { model.toggleMode() }
    @objc func reload() { model.reload() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change login item"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
