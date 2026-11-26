import Cocoa
import Foundation
import SQLite3
import ApplicationServices

private let supportDir = NSHomeDirectory() + "/Library/Application Support/WeChat-Push"
private let configPath = supportDir + "/config.json"
private let logPath = supportDir + "/push.log"
private let replyStatePath = supportDir + "/replies.json"
private let notifyDBPath = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
private let appleEpochOffset: Double = 978_307_200
private let maxAgeSeconds: Double = 1800
private let lunchStartMinute = 11 * 60 + 40
private let lunchEndMinute = 12 * 60 + 40

// MARK: - 会话

enum Session: String {
    case indefinite
    case workday
    case daily

    var label: String {
        switch self {
        case .indefinite: return "无限期"
        case .workday: return "工作日 17:30-20:00"
        case .daily: return "白天 08:30-20:00"
        }
    }

    /// 菜单里让时间列对齐：另外两项都是三个字，「白天」只有两个字，中间补三个字符
    var menuLabel: String {
        self == .daily ? "白   天 08:30-20:00" : label
    }

    var start: Int? {
        switch self {
        case .indefinite: return nil
        case .workday: return 1050
        case .daily: return 510
        }
    }

    var end: Int? {
        switch self {
        case .indefinite: return nil
        case .workday: return 1200
        case .daily: return 1200
        }
    }

    var weekdaysOnly: Bool {
        self == .workday
    }

    func active(at date: Date) -> Bool {
        guard let lower = start, let upper = end else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        if weekdaysOnly, let weekday = parts.weekday, weekday == 1 || weekday == 7 {
            return false
        }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= lower && minute <= upper
    }
}

private let sessions: [Session] = [.indefinite, .workday, .daily]

// MARK: - 菜单栏应用

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private var config: [String: String] = [:]
    private var configMissing = false
    private var dbDenied = false

    private var bot: FeishuBot?
    private var router: ReplyRouter?
    private let wechatSender = WeChatSender()

    private var lastRecId = 0
    private var baselineReady = false
    private var isSending = false
    private var nextRetryAt: Date = .distantPast
    private var failureLogged = false
    private var droppedCount = 0

    /// 推送失败后尚未送达的组，重试时只补发这些
    private var pendingGroups: [(session: String, text: String)] = []
    private var pendingIds: [Int] = []
    private var pendingTotal = 0

    private var session: Session? {
        get {
            guard let raw = defaults.string(forKey: "session") else { return nil }
            return Session(rawValue: raw)
        }
        set {
            if let value = newValue {
                defaults.set(value.rawValue, forKey: "session")
            } else {
                defaults.removeObject(forKey: "session")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateOtherInstances()
        loadConfig()
        lastRecId = defaults.integer(forKey: "lastRecId")
        log("辅助功能权限：\(AXIsProcessTrusted() ? "已授权" : "未授权，无法操作微信")")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        rebuildMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func terminateOtherInstances() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        where other.processIdentifier != current {
            other.terminate()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private var lunchEnabled: Bool {
        defaults.string(forKey: "lunchOffDate") != todayKey()
    }

    private func lunchActive(at date: Date) -> Bool {
        guard lunchEnabled else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, weekday >= 2, weekday <= 6 else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= lunchStartMinute && minute <= lunchEndMinute
    }

    private func isActiveNow() -> Bool {
        let now = Date()
        if lunchActive(at: now) { return true }
        guard let current = session else { return false }
        return current.active(at: now)
    }

    private func refreshIcon() {
        let symbol: String
        if configMissing || dbDenied {
            symbol = "exclamationmark.triangle"
        } else if isActiveNow() {
            symbol = "bell.fill"
        } else {
            symbol = "bell"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if let current = session {
            let title = NSMenuItem(title: current.menuLabel, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            let stop = NSMenuItem(title: "结束会话", action: #selector(endSession), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            menu.addItem(.separator())
        }

        for candidate in sessions {
            let item = NSMenuItem(title: candidate.menuLabel, action: #selector(startSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let lunch = NSMenuItem(title: "干饭中 11:40-12:40", action: #selector(toggleLunch), keyEquivalent: "")
        lunch.target = self
        lunch.state = lunchEnabled ? .on : .off
        menu.addItem(lunch)
        menu.addItem(.separator())

        if configMissing || dbDenied {
            let hint = NSMenuItem(
                title: dbDenied ? "需要完全磁盘访问权限" : "配置缺失，检查 config.json",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)
        }

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func startSession(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = Session(rawValue: raw) else { return }
        session = selected
        refreshIcon()
        log("开启会话：\(selected.label)")
    }

    @objc private func endSession() {
        session = nil
        refreshIcon()
        log("结束会话")
    }

    @objc private func toggleLunch() {
        if lunchEnabled {
            defaults.set(todayKey(), forKey: "lunchOffDate")
            log("暂停午休推送，仅今天")
        } else {
            defaults.removeObject(forKey: "lunchOffDate")
            log("恢复午休推送")
        }
        refreshIcon()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 轮询

    private func tick() {
        refreshIcon()
        router?.poll()
        guard !configMissing else { return }
        guard let db = openDB() else {
            if !dbDenied { log("通知库读取失败，需要完全磁盘访问权限") }
            dbDenied = true
            return
        }
        defer { sqlite3_close(db) }
        dbDenied = false

        guard let appId = resolveAppId(db) else { return }

        if !baselineReady {
            let current = maxRecId(db, appId: appId)
            if current > 0 && (lastRecId == 0 || current < lastRecId) {
                lastRecId = current
                defaults.set(current, forKey: "lastRecId")
            }
            baselineReady = true
            log("启动，基线 rec_id=\(lastRecId)")
            return
        }

        let (items, staleMax) = fetchNew(db, appId: appId, after: lastRecId)
        if let stale = staleMax, stale > lastRecId {
            lastRecId = stale
            defaults.set(stale, forKey: "lastRecId")
            if droppedCount > 0 {
                log("\(droppedCount) 条未能送达，已超过 \(Int(maxAgeSeconds / 60)) 分钟时效")
                droppedCount = 0
                failureLogged = false
            }
        }
        guard !items.isEmpty else { return }

        if !isActiveNow() {
            pendingGroups = []
            advance(items.map { $0.0 })
            return
        }
        guard !isSending else { return }

        // 上一批还有组没送到，只补发这些，不重新扫描数据库，避免已送达的组重复推送
        if !pendingGroups.isEmpty {
            guard Date() >= nextRetryAt else { return }
            isSending = true
            sendGroups(pendingGroups)
            return
        }
        guard Date() >= nextRetryAt else { return }

        let groups = grouped(items)
        isSending = true
        pendingIds = items.map { $0.0 }
        pendingTotal = groups.count
        sendGroups(groups)
    }

    /// 按会话分组推送，每组一条飞书消息，这样引用回复时目标唯一。
    /// 全部送达后才推进基线，中途失败时只保留未送出的组。
    private func sendGroups(_ groups: [(session: String, text: String)]) {
        guard let group = groups.first else {
            isSending = false
            pendingGroups = []
            advance(pendingIds)
            failureLogged = false
            droppedCount = 0
            log("已推送 \(pendingTotal) 组，最新 rec_id=\(pendingIds.last ?? 0)")
            return
        }
        guard let bot = bot else {
            isSending = false
            return
        }
        bot.sendText(group.text) { [weak self] messageId, error in
            guard let self = self else { return }
            guard let messageId = messageId else {
                self.isSending = false
                self.nextRetryAt = Date().addingTimeInterval(10)
                // 已送达的组已经出列，剩下的留到下次重试
                self.pendingGroups = groups
                self.droppedCount = groups.count
                if !self.failureLogged {
                    self.failureLogged = true
                    self.log("推送失败：\(error ?? "未知原因")")
                }
                return
            }
            self.router?.record(messageId: messageId, session: group.session)
            self.sendGroups(Array(groups.dropFirst()))
        }
    }

    private func advance(_ ids: [Int]) {
        guard let last = ids.last, last > lastRecId else { return }
        lastRecId = last
        defaults.set(last, forKey: "lastRecId")
    }

    // MARK: - 通知库

    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(notifyDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let handle = db { sqlite3_close(handle) }
            return nil
        }
        return db
    }

    private func resolveAppId(_ db: OpaquePointer) -> Int? {
        var stmt: OpaquePointer?
        let sql = "SELECT app_id FROM app WHERE LOWER(identifier) = 'com.tencent.xinwechat2' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func maxRecId(_ db: OpaquePointer, appId: Int) -> Int {
        var stmt: OpaquePointer?
        let sql = "SELECT MAX(rec_id) FROM record WHERE app_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(appId))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func fetchNew(_ db: OpaquePointer, appId: Int, after: Int)
        -> ([(Int, String, String)], Int?) {
        var stmt: OpaquePointer?
        let sql = "SELECT rec_id, delivered_date, data FROM record "
            + "WHERE app_id = ? AND rec_id > ? ORDER BY rec_id"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ([], nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(appId))
        sqlite3_bind_int64(stmt, 2, Int64(after))

        let cutoff = Date().timeIntervalSince1970 - appleEpochOffset - maxAgeSeconds
        var items: [(Int, String, String)] = []
        var staleMax: Int?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recId = Int(sqlite3_column_int64(stmt, 0))
            let delivered = sqlite3_column_double(stmt, 1)
            if delivered > 0 && delivered < cutoff {
                staleMax = recId
                continue
            }
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 2))
            let data = Data(bytes: blob, count: length)
            guard let parsed = parseRecord(data) else { continue }
            items.append((recId, parsed.0, parsed.1))
        }
        return (items, staleMax)
    }

    private func parseRecord(_ data: Data) -> (String, String)? {
        guard let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let top = raw as? [String: Any],
              let reqValue = top["req"] else { return nil }
        var req: [String: Any]?
        if let nested = reqValue as? Data,
           let inner = try? PropertyListSerialization.propertyList(from: nested, options: [], format: nil) {
            req = inner as? [String: Any]
        } else {
            req = reqValue as? [String: Any]
        }
        guard let fields = req,
              let title = fields["titl"] as? String,
              !title.isEmpty else { return nil }
        return (title, (fields["body"] as? String) ?? "")
    }

    private func grouped(_ items: [(Int, String, String)]) -> [(session: String, text: String)] {
        var order: [String] = []
        var buckets: [String: [String]] = [:]

        for item in items {
            let session = item.1
            if buckets[session] == nil { order.append(session) }
            guard (buckets[session]?.count ?? 0) < 10 else { continue }
            let body = item.2.isEmpty
                ? "（内容未取到）"
                : (item.2.count > 150 ? String(item.2.prefix(150)) + "…" : item.2)
            buckets[session, default: []].append("\(session)：\(body)")
        }

        return order.map { session in
            (session: session, text: (buckets[session] ?? []).joined(separator: "\n"))
        }
    }

    // MARK: - 配置与日志

    private func loadConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              json["app_id"]?.isEmpty == false,
              json["app_secret"]?.isEmpty == false,
              json["chat_id"]?.isEmpty == false else {
            configMissing = true
            return
        }
        config = json
        buildReplyPipeline()
    }

    /// 回复链路依赖飞书接口与微信发送，两者都在这里组装
    private func buildReplyPipeline() {
        guard let appId = config["app_id"],
              let secret = config["app_secret"],
              let chatId = config["chat_id"] else { return }
        let bot = FeishuBot(appId: appId, secret: secret, chatId: chatId)
        let router = ReplyRouter(bot: bot,
                                 sender: wechatSender,
                                 statePath: replyStatePath,
                                 ownerOpenId: config["owner_open_id"] ?? "")
        router.logger = { [weak self] message in self?.log(message) }
        router.onResult = { [weak self] session, text, detail in
            self?.bot?.sendText("「\(session)」\(detail)：\(text)") { _, _ in }
        }
        router.onCommand = { [weak self] command in
            guard let self = self else { return "程序还没起来，稍后再试" }
            switch command {
            case .start(let selected):
                self.session = selected
                self.refreshIcon()
                self.log("飞书指令：开启会话 \(selected.label)")
                return "已切换到「\(selected.label)」"
            case .stop:
                self.session = nil
                self.refreshIcon()
                self.log("飞书指令：结束会话")
                return "已结束会话，暂停转发"
            case .status:
                guard let current = self.session else { return "无进行中会话" }
                if self.lunchActive(at: Date()) { return "午休 11:40-12:40" }
                return current.label
            }
        }
        self.bot = bot
        self.router = router
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = formatter.string(from: Date()) + " " + message + "\n"
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? NSNumber, size.intValue > 2_000_000 {
            try? fm.removeItem(atPath: logPath)
        }
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logPath), let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
        }
    }
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
