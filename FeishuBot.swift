import Foundation

/// 飞书开放接口的最小封装：令牌缓存、发送文本、拉取会话消息。
/// 回调统一切回主队列。
final class FeishuBot {

    struct Message {
        let parentId: String
        let senderId: String
        let senderType: String
        let createTime: TimeInterval
        let text: String
    }

    private let appId: String
    private let secret: String
    private let chatId: String
    private let host = "https://open.feishu.cn"

    private var token: String?
    private var expireAt = Date.distantPast

    init(appId: String, secret: String, chatId: String) {
        self.appId = appId
        self.secret = secret
        self.chatId = chatId
    }

    // MARK: - 发送

    /// 成功时返回飞书消息 id，失败返回错误说明
    func sendText(_ text: String, completion: @escaping (_ messageId: String?, _ error: String?) -> Void) {
        withToken { [weak self] token, error in
            guard let self = self, let token = token else {
                completion(nil, error ?? "取令牌失败")
                return
            }
            self.post(text: text, token: token) { messageId, postError in
                guard messageId == nil else {
                    completion(messageId, nil)
                    return
                }
                // 令牌可能在服务端提前失效，作废后重取一次
                self.invalidateToken()
                self.withToken { freshToken, tokenError in
                    guard let freshToken = freshToken else {
                        completion(nil, postError ?? tokenError)
                        return
                    }
                    self.post(text: text, token: freshToken, completion: completion)
                }
            }
        }
    }

    private func post(text: String,
                      token: String,
                      completion: @escaping (_ messageId: String?, _ error: String?) -> Void) {
        guard let url = URL(string: host + "/open-apis/im/v1/messages?receive_id_type=chat_id"),
              let inner = try? JSONSerialization.data(withJSONObject: ["text": text]),
              let content = String(data: inner, encoding: .utf8),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "receive_id": chatId,
                  "msg_type": "text",
                  "content": content,
              ]) else {
            completion(nil, "消息体构造失败")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, _, error in
            var messageId: String?
            var detail: String?
            if let data = data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (json["code"] as? Int) == 0 {
                messageId = ((json["data"] as? [String: Any])?["message_id"] as? String)
            } else {
                detail = error?.localizedDescription
                    ?? (data.flatMap { String(data: $0, encoding: .utf8) } ?? "无响应")
            }
            DispatchQueue.main.async { completion(messageId, detail) }
        }.resume()
    }

    // MARK: - 拉取

    /// 取最近消息，按时间倒序返回
    func fetchRecent(limit: Int, completion: @escaping ([Message]) -> Void) {
        withToken { [weak self] token, _ in
            guard let self = self, let token = token else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            var components = URLComponents(string: self.host + "/open-apis/im/v1/messages")!
            components.queryItems = [
                URLQueryItem(name: "container_id_type", value: "chat"),
                URLQueryItem(name: "container_id", value: self.chatId),
                URLQueryItem(name: "sort_type", value: "ByCreateTimeDesc"),
                URLQueryItem(name: "page_size", value: String(limit)),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")

            URLSession.shared.dataTask(with: request) { data, _, _ in
                var result: [Message] = []
                if let data = data,
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   (json["code"] as? Int) == 0,
                   let items = (json["data"] as? [String: Any])?["items"] as? [[String: Any]] {
                    for item in items {
                        guard (item["msg_type"] as? String) == "text" else { continue }
                        let sender = item["sender"] as? [String: Any] ?? [:]
                        let body = item["body"] as? [String: Any] ?? [:]
                        let text = Self.extractText(body["content"] as? String)
                        let millis = Double(item["create_time"] as? String ?? "0") ?? 0
                        result.append(Message(
                            parentId: item["parent_id"] as? String ?? "",
                            senderId: sender["id"] as? String ?? "",
                            senderType: sender["sender_type"] as? String ?? "",
                            createTime: millis / 1000,
                            text: text
                        ))
                    }
                }
                DispatchQueue.main.async { completion(result) }
            }.resume()
        }
    }

    private static func extractText(_ content: String?) -> String {
        guard let content = content,
              let data = content.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = json["text"] as? String else { return "" }
        return text
    }

    // MARK: - 令牌

    private func invalidateToken() {
        token = nil
        expireAt = .distantPast
    }

    private func withToken(_ completion: @escaping (_ token: String?, _ error: String?) -> Void) {
        if let cached = token, Date() < expireAt {
            completion(cached, nil)
            return
        }
        guard let url = URL(string: host + "/open-apis/auth/v3/tenant_access_token/internal"),
              let body = try? JSONSerialization.data(withJSONObject: ["app_id": appId, "app_secret": secret]) else {
            completion(nil, "配置不完整")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["code"] as? Int) == 0,
                  let value = json["tenant_access_token"] as? String else {
                let detail = error?.localizedDescription
                    ?? (data.flatMap { String(data: $0, encoding: .utf8) } ?? "无响应")
                DispatchQueue.main.async { completion(nil, "取令牌失败 " + detail) }
                return
            }
            let expire = (json["expire"] as? Int) ?? 7200
            DispatchQueue.main.async {
                self?.token = value
                self?.expireAt = Date().addingTimeInterval(Double(max(expire - 120, 60)))
                completion(value, nil)
            }
        }.resume()
    }
}
