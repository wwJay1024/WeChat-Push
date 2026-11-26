import Foundation

/// 飞书群里的开关指令，用于人不在电脑前时切换转发状态
enum ControlCommand {
    case start(Session)
    case stop
    case status
}

/// 把飞书里的引用回复，按推送时的对应关系转发到微信会话。
/// 映射表与处理进度持久化在应用支持目录。
final class ReplyRouter {

    private let bot: FeishuBot
    private let sender: WeChatSender
    private let statePath: String
    private let queue = DispatchQueue(label: "com.wwj.wechat2push.reply", qos: .utility)

    private var routes: [(id: String, session: String)] = []
    private var lastSeen: TimeInterval = 0
    private var isPolling = false
    private var lastPollAt = Date.distantPast
    private var pollStartedAt: Date?

    private let minInterval: TimeInterval = 3
    /// 拉取超过这个时长没有回调返回，视为卡死并复位
    private let stalePollTimeout: TimeInterval = 30
    private let maxRoutes = 500

    var ownerOpenId: String
    var logger: ((String) -> Void)?
    /// 发送完成后的通知，用于回执
    var onResult: ((_ session: String, _ text: String, _ detail: String) -> Void)?
    /// 执行开关指令，返回要回给群里的说明
    var onCommand: ((ControlCommand) -> String)?

    init(bot: FeishuBot, sender: WeChatSender, statePath: String, ownerOpenId: String) {
        self.bot = bot
        self.sender = sender
        self.statePath = statePath
        self.ownerOpenId = ownerOpenId
        load()
        // 首次运行从当前时刻开始计，避免把历史回复重新发一遍
        if lastSeen == 0 {
            lastSeen = Date().timeIntervalSince1970
            persist()
        }
    }

    // MARK: - 映射

    /// 推送发出后登记，用于把后续的引用回复对应回会话
    func record(messageId: String, session: String) {
        guard !messageId.isEmpty else { return }
        routes.removeAll { $0.id == messageId }
        routes.append((id: messageId, session: session))
        if routes.count > maxRoutes {
            routes.removeFirst(routes.count - maxRoutes)
        }
        persist()
    }

    // MARK: - 轮询

    func poll() {
        // 网络异常时上一次请求可能不回调，这里兜底复位，否则轮询会永久停摆
        if let started = pollStartedAt, Date().timeIntervalSince(started) > stalePollTimeout {
            isPolling = false
            pollStartedAt = nil
            logger?("上一次拉取超过 \(Int(stalePollTimeout)) 秒未返回，已复位")
        }
        guard !isPolling, Date().timeIntervalSince(lastPollAt) >= minInterval else { return }
        isPolling = true
        lastPollAt = Date()
        pollStartedAt = Date()

        bot.fetchRecent(limit: 20) { [weak self] messages in
            guard let self = self else { return }
            self.isPolling = false
            self.pollStartedAt = nil

            let fresh = messages
                .filter { $0.senderType == "user" }
                .filter { self.ownerOpenId.isEmpty || $0.senderId == self.ownerOpenId }
                .filter { $0.createTime > self.lastSeen }
                .filter { !$0.text.isEmpty }
                .sorted { $0.createTime < $1.createTime }

            guard !fresh.isEmpty else { return }

            for message in fresh {
                self.lastSeen = max(self.lastSeen, message.createTime)
                // 指令只认独立发言。引用了某条消息的文字即使碰巧同字，也按回复处理。
                if message.parentId.isEmpty, let command = Self.command(from: message.text) {
                    self.run(command)
                    continue
                }
                guard !message.parentId.isEmpty else { continue }
                guard let session = self.routes.first(where: { $0.id == message.parentId })?.session else {
                    self.logger?("收到引用回复，但原推送不在映射表中，已忽略")
                    continue
                }
                self.dispatch(session: session, message: message)
            }
            self.persist()
        }
    }

    // MARK: - 开关指令

    private static let commandTable: [String: ControlCommand] = [
        "开启会话": .start(.indefinite),
        "无限期": .start(.indefinite),
        "工作日": .start(.workday),
        "每天": .start(.daily),
        "结束会话": .stop,
        "状态": .status,
    ]

    /// 整条消息精确等于指令才生效，正常聊天里提到这些词不会被误判
    private static func command(from text: String) -> ControlCommand? {
        commandTable[text.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    private func run(_ command: ControlCommand) {
        let reply = onCommand?(command) ?? "程序未就绪，指令没有执行"
        logger?("收到飞书指令：\(reply)")
        bot.sendText(reply) { [weak self] _, error in
            if let error = error {
                self?.logger?("指令回执发送失败：\(error)")
            }
        }
    }

    private func dispatch(session: String, message: FeishuBot.Message) {
        logger?("收到引用回复，转发到「\(session)」")
        queue.async { [weak self] in
            guard let self = self else { return }
            let outcome = self.sender.send(session: session, text: message.text)
            let detail: String
            switch outcome {
            case .sent:
                detail = "已发送"
            case .displayAsleep:
                detail = "屏幕没能点亮，未能操作微信"
            case .windowMissing:
                detail = "微信分身没有窗口，未能唤起"
            case .activateFailed:
                detail = "微信没能切到前台，为避免误发已中止"
            case .inputEmpty:
                detail = "内容没能写进输入框，已中止"
            case .sendFailed:
                detail = "回车后输入框仍有内容，可能没有发出"
            }
            DispatchQueue.main.async {
                self.logger?("转发结果：\(session) - \(detail)")
                self.onResult?(session, message.text, detail)
            }
        }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = FileManager.default.contents(atPath: statePath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        lastSeen = json["lastSeen"] as? TimeInterval ?? 0
        if let list = json["routes"] as? [[String: String]] {
            routes = list.compactMap { entry in
                guard let id = entry["id"], let session = entry["session"] else { return nil }
                return (id: id, session: session)
            }
        }
    }

    private func persist() {
        let payload: [String: Any] = [
            "lastSeen": lastSeen,
            "routes": routes.map { ["id": $0.id, "session": $0.session] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}
