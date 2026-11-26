import Cocoa
import ApplicationServices
import IOKit.pwr_mgt

/// 全程用快捷键操作微信分身，把文本发送到指定会话。
///
/// 微信 4.x 不向系统暴露界面元素，辅助功能读到的是空壳，
/// 但窗口编号和尺寸属于系统层面，可以正常读取。
/// 会话名来自真实发来消息的对象，搜索一定命中，
/// 回车后光标自动落在输入框，因此不需要点击任何东西。
/// 所有方法同步执行，调用方需放在后台队列。
final class WeChatSender {

    enum Outcome {
        case sent
        case displayAsleep
        case windowMissing
        case activateFailed
        case inputEmpty
        case sendFailed
    }

    private let bundleId = "com.tencent.xinWeChat2"
    private let appPath = "/Applications/WeChat2.app"

    /// 主窗口在窗口服务器里的编号与尺寸。编号用来截图，尺寸用来换算像素。
    private struct Window {
        let number: CGWindowID
        let width: CGFloat
        let height: CGFloat
    }

    // MARK: - 对外入口

    func send(session: String, text: String) -> Outcome {
        guard wakeDisplay() else { return .displayAsleep }
        guard let pid = appPid() else { return .windowMissing }
        guard let opened = ensureWindow(pid: pid) else { return .windowMissing }

        // 按键是全局事件，微信不在前台时会落到别的应用上
        guard bringToFront(pid: pid) else { return .activateFailed }
        Thread.sleep(forTimeInterval: 0.4)
        // 唤醒窗口后尺寸可能已经和刚才读到的不一样，重新取一次
        let window = mainWindow(pid: pid) ?? opened

        // 第一步：搜索并进入会话
        pressKey(0x03, flags: .maskCommand)   // Cmd+F
        Thread.sleep(forTimeInterval: 0.45)
        selectAllAndDelete()
        paste(session)
        Thread.sleep(forTimeInterval: 0.9)
        pressReturn()
        Thread.sleep(forTimeInterval: 1.2)

        // 第二步：写入内容并发送。回车后光标已经在输入框里
        selectAllAndDelete()
        paste(text)
        Thread.sleep(forTimeInterval: 0.35)

        guard let filled = grabWindow(window.number),
              (textPixels(filled, window: window) ?? 0) >= textPixelThreshold else {
            return .inputEmpty
        }

        pressReturn()
        Thread.sleep(forTimeInterval: 1.0)

        guard let after = grabWindow(window.number) else { return .sent }
        guard inputHasText(after, window: window) else { return .sent }

        // 窗口刚拿到焦点时回车偶尔会被丢掉，补按一次再判定
        pressReturn()
        Thread.sleep(forTimeInterval: 1.0)
        guard let retry = grabWindow(window.number) else { return .sent }
        return inputHasText(retry, window: window) ? .sendFailed : .sent
    }

    // MARK: - 显示器

    /// 屏幕睡眠时窗口不做合成，截图只会读到黑屏。
    /// 发送前声明一次用户活动把显示器点亮，等画面真正渲染出来再继续。
    private func wakeDisplay() -> Bool {
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return true }

        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "WeChat-Push 发送前唤醒显示器" as CFString,
            IOPMUserActiveType(0),   // kIOPMUserActiveLocal
            &assertionID
        )
        // 屏幕点亮后立即释放，否则系统会持续认为有人在操作，显示器不再自动关闭
        defer {
            if assertionID != 0 { IOPMAssertionRelease(assertionID) }
        }

        let deadline = Date().addingTimeInterval(3)
        while CGDisplayIsAsleep(CGMainDisplayID()) != 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return false }

        // 屏幕亮起后窗口还需要时间重新合成
        Thread.sleep(forTimeInterval: 1.0)
        return true
    }

    // MARK: - 进程与窗口

    private func appPid() -> pid_t? {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleId {
            return app.processIdentifier
        }
        return nil
    }

    /// 主窗口是层级 0 的普通窗口，搜一搜、设置之类的独立窗口层级不同。
    private func mainWindow(pid: pid_t) -> Window? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let h = (bounds["Height"] as? NSNumber)?.doubleValue,
                  w > 200, h > 200 else { continue }
            return Window(number: number, width: CGFloat(w), height: CGFloat(h))
        }
        return nil
    }

    /// 主窗口被关掉时微信进程还活着，但窗口列表里没有它。
    /// 唤起应用会把窗口重新打开，等窗口出现再返回。
    private func ensureWindow(pid: pid_t) -> Window? {
        if let window = mainWindow(pid: pid) { return window }
        for _ in 0..<3 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", appPath]
            try? task.run()
            task.waitUntilExit()
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.5)
                if let window = mainWindow(pid: pid) { return window }
            }
        }
        return nil
    }

    /// 系统会限制后台应用直接抢前台。用 open 把应用带到前台，
    /// 不产生鼠标事件，避免连点标题栏被识别成双击缩放窗口。
    private func bringToFront(pid: pid_t) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        for _ in 0..<3 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", appPath]
            try? task.run()
            task.waitUntilExit()
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.3)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            }
        }
        return false
    }

    // MARK: - 输入事件

    private func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.04)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    private func pressReturn() {
        pressKey(0x24)
    }

    /// 全选后删除，清掉上一次残留内容，避免把旧内容一起发出去
    private func selectAllAndDelete() {
        pressKey(0x00, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.1)
        pressKey(0x33)
        Thread.sleep(forTimeInterval: 0.15)
    }

    /// 通过剪贴板写入，中文和换行都能原样带过去。
    /// 微信读取剪贴板是异步的，恢复原内容要等它读完，否则粘贴出来是空的。
    private func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        Thread.sleep(forTimeInterval: 0.2)
        pressKey(0x09, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.5)
        if let saved = saved {
            board.clearContents()
            board.setString(saved, forType: .string)
        }
    }

    // MARK: - 屏幕识别

    /// 按窗口编号截图，窗口被其他窗口遮挡、挪到屏幕外都不影响。
    private func grabWindow(_ number: CGWindowID) -> NSBitmapImageRep? {
        let path = NSTemporaryDirectory() + "wechat2push-shot.png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(number), path]
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard let img = NSImage(contentsOfFile: path),
              let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff) else { return nil }
        return bmp
    }

    /// 输入框里是否有文字。
    ///
    /// 区域取输入框的文字带：横向从会话列表右边界往右，到发送按钮之前；
    /// 纵向从窗口底部往上 160 到 95。输入框贴着窗口底部、高度固定，
    /// 所以纵向按到窗口底部的距离算，窗口拉高拉矮都不会偏。
    ///
    /// 实测（窗口 1145×944，输入框为空）：距底 176 以上是聊天区，
    /// 最后一条消息的文字落在距底 199 到 188；输入框顶部在 176；
    /// 一行文字占 146 到 135；工具栏图标从 82 往下。
    /// 所以取 160 到 95，上下都留出余量，不会框到聊天区，也不会框到工具栏。
    ///
    /// 空白输入框在这块区域里一个暗像素都没有，占位提示是浅灰色；
    /// 最小的字符（半角句点）也有 10 个暗像素，所以按绝对数量判断。
    /// 不能用占比：区域很大，短消息的占比会低到和空白区分不开。
    private let textPixelThreshold = 4

    private func inputHasText(_ bmp: NSBitmapImageRep, window: Window) -> Bool {
        (textPixels(bmp, window: window) ?? 0) >= textPixelThreshold
    }

    /// 输入框文字带里的暗像素个数
    private func textPixels(_ bmp: NSBitmapImageRep, window: Window) -> Int? {
        guard let data = bmp.bitmapData else { return nil }
        let perPixel = bmp.bitsPerPixel / 8
        let colorOffset = bmp.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        guard perPixel >= colorOffset + 3 else { return nil }

        let scale = CGFloat(bmp.pixelsWide) / window.width
        let chatLeft = min(363, window.width - 364)
        let x0 = max(0, Int((chatLeft + 20) * scale))
        let x1 = min(bmp.pixelsWide, Int((window.width - 40) * scale))
        let y0 = max(0, Int((window.height - 160) * scale))
        let y1 = min(bmp.pixelsHigh, Int((window.height - 95) * scale))
        guard x1 > x0, y1 > y0 else { return nil }

        var count = 0
        for y in y0..<y1 {
            let row = data + y * bmp.bytesPerRow
            var x = x0
            while x < x1 {
                let p = row + x * perPixel
                if (Int(p[colorOffset]) + Int(p[colorOffset + 1]) + Int(p[colorOffset + 2])) / 3 < 120 {
                    count += 1
                }
                x += 1
            }
        }
        return count
    }
}
