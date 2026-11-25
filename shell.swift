// 鲸鱼娘 Live2D 桌宠 - macOS 透明壳 (Swift + WebView)
// 加载本地 Live2D 页面, 透明无边框置顶窗口, 连 Hermes gateway 对话
import Cocoa
import WebKit
import Network
import AVFoundation
import Speech

// 资源根目录: .app 内 Resources (打包后) 或开发目录 (调试)
let RESOURCE_DIR: String = {
    if let res = Bundle.main.resourcePath {
        return res  // .app/Contents/Resources
    }
    return NSString(string: "~/workspace/whale-pet").expandingTildeInPath
}()
let SERVER_PORT: UInt16 = 8977

// 简单 HTTP 静态文件 server (Network.framework)
// 用于给 WebView 提供本地 Live2D 页面, 避免 file:// CORS 限制
final class LocalHTTPServer {
    private var listener: NWListener?
    private let root: String
    private let port: UInt16
    private let debugToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    init(root: String, port: UInt16) {
        self.root = root
        self.port = port
    }

    func start() -> Bool {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: params)
        } catch {
            print("HTTP server listen failed: \(error)")
            return false
        }
        listener?.newConnectionHandler = { [weak self] conn in
            conn.stateUpdateHandler = { state in
                if case .failed(let error) = state { print("HTTP connection failed: \(error)") }
            }
            conn.start(queue: .global(qos: .userInitiated))
            self?.handle(conn)
        }
        listener?.start(queue: .global(qos: .userInitiated))
        // token 落盘: App 以 .app 启动时 stdout 无处可见, 调试端点会变成完全不可用。
        // 写到用户私有目录(0700)，并同步 flush，避免被缓冲吞掉。
        let tokenPath = NSHomeDirectory() + "/Library/Application Support/WhalePet/debug_session_token"
        try? FileManager.default.createDirectory(
            atPath: (tokenPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? debugToken.write(toFile: tokenPath, atomically: true, encoding: .utf8)
        // 文件级权限收到 0600: 目录 0700 已挡住他人, 但 atomic write 会重置文件权限
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)
        print("WhalePet debug token: \(debugToken)")
        return true
    }

    private func handle(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, _ in
            guard let self, let data, !data.isEmpty else { return }
            // 解析请求行 (GET /path HTTP/1.1)
            guard let req = String(data: data, encoding: .utf8) else { return }
            let lines = req.components(separatedBy: "\r\n")
            guard let first = lines.first, first.hasPrefix("GET ") else { return }
            var path = first.components(separatedBy: " ").dropFirst().first ?? "/"
            if path.hasPrefix("http") {  // 绝对 URL 形式
                if let u = URL(string: path) { path = u.path }
            }
            if path == "/" { path = "/index.html" }
            let requestURL = URLComponents(string: "http://127.0.0.1\(path)")
            let cleanPath = requestURL?.path ?? path
            if cleanPath.hasPrefix("/debug/"),
               requestURL?.queryItems?.first(where: { $0.name == "token" })?.value != debugToken {
                let body = "403 Forbidden"
                let header = "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            // 调试端点: GET /debug/speak?text=... 触发一次真实说话（用于验证口型动画）
            if path.hasPrefix("/debug/speak") {
                var text = "调试说话测试，一二三四五六七八九十。"
                if let decoded = requestURL?.queryItems?.first(where: { $0.name == "text" })?.value,
                   !decoded.isEmpty {
                    text = decoded
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .init("WhalePetDebugSpeak"),
                                                    object: nil, userInfo: ["text": text])
                }
                let body = "OK: queued speak len=\(text.count)"
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            // 调试端点: GET /debug/ask?text=... 走完整 askHermes 链路（验证会话续接/超时）
            if path.hasPrefix("/debug/ask") || path.hasPrefix("/debug/session") {
                let isReset = path.hasPrefix("/debug/session")
                var text = isReset ? "" : "调试消息"
                if let decoded = requestURL?.queryItems?.first(where: { $0.name == "text" })?.value,
                   !decoded.isEmpty {
                    text = decoded
                }
                DispatchQueue.main.async {
                    if isReset {
                        NotificationCenter.default.post(name: .init("WhalePetDebugSessionReset"), object: nil)
                    } else {
                        NotificationCenter.default.post(name: .init("WhalePetDebugAsk"),
                                                        object: nil, userInfo: ["text": text])
                    }
                }
                let body = isReset ? "OK: session reset" : "OK: queued ask len=\(text.count)"
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            // 规范化: 去掉 .. 和 %
            path = path.removingPercentEncoding ?? path
            if path.contains("..") { path = "/index.html" }
            let filePath = self.root + path
            let fm = FileManager.default
            if fm.fileExists(atPath: filePath), let content = fm.contents(atPath: filePath) {
                let ext = (filePath as NSString).pathExtension.lowercased()
                let mime = Self.mimeType(for: ext)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(content.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                var out = Data(header.utf8)
                out.append(content)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            } else {
                let body = "404 Not Found"
                let header = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(header.utf8) + Data(body.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
            if !isComplete {
                // 继续读(理论上 GET 一次读完, 这里安全处理)
            }
        }
    }

    static func mimeType(for ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "moc3": return "application/octet-stream"
        case "motion3": return "application/json; charset=utf-8"
        case "exp3": return "application/json; charset=utf-8"
        case "physics3": return "application/json; charset=utf-8"
        case "model3": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// WKWebView 不参与鼠标事件 (事件全部交给上层 DragView)
final class PassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// 让第一下点击也能收到 (无边框窗口首击被系统吞掉的问题)
// 同时实现: 按下拖动=拖窗口, 单击=触发动作
final class DragView: NSView {
    var clickAction: ((CGPoint, Bool) -> Void)?
    var activityAction: ((Bool) -> Void)?
    var dragFeedbackAction: ((Bool) -> Void)?
    var rightClickMenu: NSMenu?
    var characterRect: CGRect?  // 左上角原点、CSS 像素；nil 时兼容旧行为
    private var dragStart: NSPoint?
    private var isDragging = false
    private var lastClickTime: TimeInterval = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        isDragging = false
        activityAction?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart = dragStart else { return }
        let cur = event.locationInWindow
        // 超过阈值判定为拖动, 交给系统原生拖动 (丝滑无晃动)
        if !isDragging && (abs(cur.x - dragStart.x) + abs(cur.y - dragStart.y) > 4) {
            isDragging = true
            dragFeedbackAction?(true)
            window?.performDrag(with: event)
            // performDrag 会一直阻塞到系统拖动结束；部分 macOS 版本不会再派发 mouseUp。
            activityAction?(false)
            dragFeedbackAction?(false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            let p = convert(event.locationInWindow, from: nil)
            let cssPoint = CGPoint(x: p.x, y: bounds.height - p.y)
            if characterRect?.contains(cssPoint) ?? true {
                let now = event.timestamp
                let isDoubleClick = event.clickCount > 1 || now - lastClickTime <= 0.3
                lastClickTime = now
                clickAction?(cssPoint, isDoubleClick)
            }
        }
        dragStart = nil
        isDragging = false
        activityAction?(false)
    }

    // 右键弹菜单 (含关闭)
    override func rightMouseDown(with event: NSEvent) {
        activityAction?(false)
        if let menu = rightClickMenu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

// 自绘输入条: 半透明白圆角容器 + 输入框 + 发送按钮 (替代 NSAlert sheet, 避免点击时父窗口变暗黑幕)
final class InputBar: NSView, NSTextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onMicrophone: (() -> Void)?
    let textField = NSTextField(frame: NSRect(x: 8, y: 8, width: 220, height: 26))
    private let sendBtn = NSButton(title: "发送", target: nil, action: nil)
    private let micBtn = NSButton(title: "🎤", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.26, alpha: 0.82).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        textField.placeholderString = "输入你想说的话... 回车发送"
        textField.isBezeled = true
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.textColor = .white
        textField.placeholderAttributedString = NSAttributedString(
            string: "输入你想说的话... 回车发送",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        )
        textField.delegate = self
        textField.autoresizingMask = [.width, .maxXMargin]
        addSubview(textField)

        sendBtn.title = "发送"
        sendBtn.target = self
        sendBtn.action = #selector(sendTapped)
        sendBtn.bezelStyle = .rounded
        sendBtn.contentTintColor = .white
        sendBtn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        sendBtn.layer?.cornerRadius = 6
        sendBtn.autoresizingMask = [.minXMargin]
        addSubview(sendBtn)

        micBtn.target = self
        micBtn.action = #selector(microphoneTapped)
        micBtn.bezelStyle = .rounded
        micBtn.toolTip = "语音对话（按住说话，停顿自动提交）"
        micBtn.autoresizingMask = [.minXMargin]
        addSubview(micBtn)

        layoutInput()
    }

    // 子控件随容器宽度自适应 (按钮钉右缘, 输入框占剩余)
    private func layoutInput() {
        let w = max(0, bounds.width)
        let btnW: CGFloat = 56
        let btnX = max(8, w - btnW - 8)
        sendBtn.frame = NSRect(x: btnX, y: 8, width: btnW, height: 26)
        let micX = max(8, btnX - 38)
        micBtn.frame = NSRect(x: micX, y: 8, width: 32, height: 26)
        textField.frame = NSRect(x: 8, y: 8, width: max(0, micX - 16), height: 26)
    }

    override func layout() {
        super.layout()
        layoutInput()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func sendTapped() { onSend?(textField.stringValue) }
    @objc func microphoneTapped() { onMicrophone?() }

    func setListening(_ listening: Bool) {
        micBtn.title = listening ? "🔴" : "🎤"
        textField.placeholderString = listening ? "在听呢，说完停顿一下..." : "输入你想说的话... 回车发送"
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC = 取消
            onCancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {  // Enter
            onSend?(textField.stringValue)
            return
        }
        super.keyDown(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSend?(textField.stringValue)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, AVSpeechSynthesizerDelegate {
    var window: PetWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem?
    var httpServer: LocalHTTPServer?
    // These fields are confined to the main thread; UserDefaults is persistence only.
    private var sessionID = UserDefaults.standard.string(forKey: "pet_sessionId") ?? ""
    private var sessionGeneration = 0
    private var lastSuccessfulExchange = UserDefaults.standard.double(forKey: "pet_lastExchangeAt")
    private var sessionReservedAt: TimeInterval = 0
    private let webLogQueue = DispatchQueue(label: "WhalePet.webview-log")
    private var webLogHandle: FileHandle?
    private var webLogBytes: UInt64?   // 内存累计的日志大小, 避免每行一次 stat
    private var lastLoggedCharRect: CGRect = .zero   // 角色区域日志去重
    // 尺寸设置: x1~x5, 当前为 x3 (400x560)
    var currentScale: Int = 3
    let baseSize = CGSize(width: 400.0 / 3.0, height: 560.0 / 3.0)  // x1 基准 ≈133x187
    weak var dragView: DragView?
    let speechSynthesizer = AVSpeechSynthesizer()
    var speechPlayer: AVPlayer?
    var speechProcess: Process?
    var ttsDaemonProcess: Process?
    var ttsDaemonInput: FileHandle?
    var ttsDaemonOutput: FileHandle?
    var ttsDaemonBuffer = Data()
    var ttsDaemonCompletion: ((String, Bool, String) -> Void)?
    var speechRequestID = UUID()
    var speechOutputPath: String?
    var speechEndObserver: NSObjectProtocol?
    var speechFailureObserver: NSObjectProtocol?
    // ———— 语音识别（🎤 手动语音对话 + 常驻语音对话共用） ————
    private let recordingEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false
    // ———— 免手持语音对话 ————
    private var isVoiceChatListening = false
    private var voiceChatText = ""
    private var voiceChatLastSpeechAt: Date?
    private var voiceChatUtteranceStartedAt: Date?
    private var voiceChatSilenceTimer: Timer?
    private var voiceChatReplyMonitor: Timer?
    private var isVoiceChatConversationActive = false
    private var voiceChatDiscardingInput = false
    private var voiceChatManualMode = false   // 🎤 手动模式 (由输入框按钮触发)
    private var voiceChatSessionGeneration = 0   // 会话代数: 停止/失败时 +1, 过期延迟重启自动作废
    var wanderTimer: Timer?
    var lastActivity = Date()
    var isUserDragging = false
    var isAIReplying = false
    private var isReplySpeechActive = false   // speak() 已接管回复输出；允许丢弃输入的识别会话与 TTS 并存
    var isInputOpen = false   // 输入框/设置面板打开中 = 操作中, 禁止漫游
    var inputBar: InputBar?  // 自绘输入条 (无系统 sheet)
    var pendingEmotions: [String] = []   // AI 回复的多情绪标签 (依次播放)
    var pendingMotions: [String] = []    // AI 回复的多动作标签 (依次播放)
    var isWindowAnimating = false
    private var windowAnimationID = UUID()

    struct SpeechProsody {
        let rate: String
        let pitch: String
        let volume: String
    }

    let edgeVoiceChoices: [(title: String, id: String)] = [
        ("豆包·vv 女声(火山)", "zh_female_vv_uranus_bigtts"),
        ("晓伊·萝莉(云端)", "zh-CN-XiaoyiNeural"),
        ("晓晓·温暖(云端)", "zh-CN-XiaoxiaoNeural"),
        ("系统默认", "system")
    ]

    // ———— AI 配置 (UserDefaults 持久化) ————
    // apiBaseURL 为空 = 用内置 Hermes gateway
    struct AIConfig {
        var apiBaseURL: String   // 例: http://127.0.0.1:8642/v1
        var apiKey: String
        var model: String
        var systemPrompt: String
        var sessionIdleTimeoutMinutes: Int
    }

    func loadConfig() -> AIConfig {
        let d = UserDefaults.standard
        return AIConfig(
            apiBaseURL: d.string(forKey: "pet_apiBaseURL") ?? "",
            apiKey: d.string(forKey: "pet_apiKey") ?? "",
            model: d.string(forKey: "pet_model") ?? "hermes-token",
            systemPrompt: d.string(forKey: "pet_systemPrompt") ?? "你是一只可爱的鲸鱼娘桌宠, 用简短可爱的语气回答, 不超过80字, 可以带颜文字。",
            sessionIdleTimeoutMinutes: d.object(forKey: "pet_sessionIdleTimeoutMinutes") == nil ? 30 : max(0, d.integer(forKey: "pet_sessionIdleTimeoutMinutes"))
        )
    }

    func saveConfig(_ c: AIConfig) {
        let d = UserDefaults.standard
        d.set(c.apiBaseURL, forKey: "pet_apiBaseURL")
        d.set(c.apiKey, forKey: "pet_apiKey")
        d.set(c.model, forKey: "pet_model")
        d.set(c.systemPrompt, forKey: "pet_systemPrompt")
        d.set(c.sessionIdleTimeoutMinutes, forKey: "pet_sessionIdleTimeoutMinutes")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例: 用户重复点图标时, 只保留最先启动的那只宠物。
        // 用 CFBundleIdentifier + pid 判据, 直接把新实例踢掉 (退出码 0),
        // 并顺手把已有实例的窗口提到前面, 让用户感觉"就是它被唤醒了"。
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let bid = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            if running.count > 1 {
                let others = running.filter { $0.processIdentifier != myPID }
                if let first = others.first {
                    NSLog("[WhalePet] 已有实例在运行 (pid=\(first.processIdentifier)), 本实例退出")
                    first.activate(options: [.activateIgnoringOtherApps])
                    NSApp.terminate(nil)
                    exit(0)
                }
            }
        }
        // 调试端点 GET /debug/ask?text=... 走完整 askHermes 链路（验证会话续接/超时）
        NotificationCenter.default.addObserver(
            forName: .init("WhalePetDebugAsk"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let text = note.userInfo?["text"] as? String else { return }
            self.handleJSEvent("DEBUG_ASK: \(text)")
            self.askHermes(text)
        }
        NotificationCenter.default.addObserver(
            forName: .init("WhalePetDebugSessionReset"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.resetSession(reason: "debug")
            self.handleJSEvent("DEBUG_SESSION_RESET")
            self.showBubble("🆕 会话已重置")
        }
        // 调试端点 GET /debug/speak?text=... 通过通知触发一次真实说话
        NotificationCenter.default.addObserver(
            forName: .init("WhalePetDebugSpeak"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let text = note.userInfo?["text"] as? String ?? "调试说话测试。"
            self.handleJSEvent("DEBUG_SPEAK: \(text)")
            self.speak(text, emotion: "开心")
        }
        speechSynthesizer.delegate = self
        // Preload Python + edge-tts before the first reply; synthesis still starts only on demand.
        if let helper = ttsHelperPath() {
            try? startTTSDaemonIfNeeded(helper: helper)
        }
        // 启动内置 HTTP server (提供本地 Live2D 页面)
        httpServer = LocalHTTPServer(root: RESOURCE_DIR, port: SERVER_PORT)
        _ = httpServer?.start()
        // 恢复保存的设置
        let savedScale = UserDefaults.standard.integer(forKey: "pet_scale")
        if savedScale >= 1 && savedScale <= 5 {
            currentScale = savedScale
        }
        let w0 = baseSize.width * CGFloat(currentScale)
        let h0 = baseSize.height * CGFloat(currentScale)
        // 超屏幕则 clamp (x5 高度可能超过 visibleFrame)
        let screen0 = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        let w0c = min(w0, screen0.width)
        let h0c = min(h0, screen0.height)
        // 透明无边框窗口
        let win = PetWindow(
            contentRect: NSRect(x: 0, y: 0, width: w0c, height: h0c),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.isReleasedWhenClosed = false

        // 右下角定位
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.maxX - w0c - 20, y: visible.minY + 20)
            win.setFrameOrigin(origin)
        }

        // WebView (透明)
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        let web = PassiveWebView(frame: NSRect(x: 0, y: 0, width: w0c, height: h0c), configuration: config)
        web.autoresizingMask = [.width, .height]  // 跟随窗口缩放
        web.wantsLayer = true
        web.setValue(false, forKey: "drawsBackground")  // 透明背景
        web.navigationDelegate = self
        web.configuration.userContentController.add(self, name: "hermes")
        // JS console 转发到 Swift
        let js = """
        window.onerror = function(msg, src, line) {
            window.webkit.messageHandlers.hermes.postMessage('ERROR:' + msg + ' @' + line);
            return false;
        };
        console.log = function(...args) {
            window.webkit.messageHandlers.hermes.postMessage('LOG:' + args.join(' '));
        };
        """
        let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        web.configuration.userContentController.addUserScript(script)
        // DragView 盖在 web 之上: 拖动=拖窗口, 单击=触发动作
        // (WebView 不需要接收鼠标事件, 动作由 Swift 触发)
        let clickView = DragView(frame: NSRect(x: 0, y: 0, width: w0c, height: h0c))
        clickView.autoresizingMask = [.width, .height]  // 跟随窗口缩放
        win.contentView = clickView
        clickView.addSubview(web)
        clickView.clickAction = { [weak self, weak clickView] point, isDoubleClick in
            guard let self else { return }
            self.handlePetClick(at: point, in: clickView?.characterRect, isDoubleClick: isDoubleClick)
        }
        clickView.activityAction = { [weak self] pressed in
            self?.isUserDragging = pressed
            self?.markActivity()
        }
        clickView.dragFeedbackAction = { [weak self] dragging in
            self?.showDragFeedback(dragging)
        }
        // 右键菜单
        let ctxMenu = NSMenu()
        ctxMenu.addItem(NSMenuItem(title: "🎬 播放动作", action: #selector(playMotion), keyEquivalent: ""))
        ctxMenu.addItem(NSMenuItem(title: "🆕 开新会话", action: #selector(newSession), keyEquivalent: ""))
        ctxMenu.addItem(NSMenuItem(title: "⚙️ 设置大小", action: #selector(openSettings), keyEquivalent: ","))
        ctxMenu.addItem(NSMenuItem(title: "↩ 回到右下角", action: #selector(resetPos), keyEquivalent: ""))
        ctxMenu.addItem(NSMenuItem.separator())
        ctxMenu.addItem(NSMenuItem(title: "✕ 退出桌宠", action: #selector(quit), keyEquivalent: "q"))
        clickView.rightClickMenu = ctxMenu
        dragView = clickView
        webView = web

        // 加载页面 (内置 HTTP server, 避免 file:// CORS 限制)
        let url = URL(string: "http://127.0.0.1:\(SERVER_PORT)/index.html")!
        web.load(URLRequest(url: url))

        window = win
        win.orderFrontRegardless()
        startDebugScaleWatcher()
        scheduleWander()

        // 状态栏
        setupStatusBar()
        autoDemoMotion()

        if voiceChatEnabled() {
            startVoiceChatListener()
        }

        // 点击穿透: 只挡鲸鱼娘所在区域 (页面会通过 hermes handler 通知实际位置)
        // 简化: 整个窗口可点击, 点击后触发动作/对话
    }

    func applicationWillTerminate(_ notification: Notification) {
        ttsDaemonOutput?.readabilityHandler = nil
        ttsDaemonInput?.closeFile()
        ttsDaemonProcess?.terminate()
    }

    func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐳"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "🎬 播放动作", action: #selector(playMotion), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "🆕 开新会话", action: #selector(newSession), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "⚙️ 设置大小", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "回到右下角", action: #selector(resetPos), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc func playMotion() {
        // 通过 JS 触发随机动作 (测试/菜单触发)；走 __setMotion 以遵守说话锁定
        let groups = ["selfie", "ketchup", "bubble", "splash", "openLid", "aidale", "wave", "heartKiss", "headpat", "tailWag", "bellyUp", "sleep", "stretch", "dance", "hop", "angryPuff", "worship", "coolShades", "catPaws", "bunnyEars", "peek", "coffee"]
        let g = groups[Int.random(in: 0..<groups.count)]
        let js = "try { window.__setMotion ? window.__setMotion('\(g)') : window.__petModel.motion('\(g)', 0, 3); 'ok' } catch(e) { 'err:' + e.message }"
        webView.evaluateJavaScript(js) { result, err in
            self.handleJSEvent("MENU_MOTION: \(g) -> \(result ?? "nil") err=\(String(describing: err))")
        }
    }

    private func freshSessionID() -> String {
        "pet-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    @objc func newSession() {
        resetSession(reason: "manual")
        let sid = sessionID
        let timeout = loadConfig().sessionIdleTimeoutMinutes * 60
        handleJSEvent("SESSION_NEW sid=\(sid) reason=manual idle=0s timeout=\(timeout)s")
        showBubble("新会话开始～")
    }

    private func resetSession(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        sessionGeneration += 1
        sessionID = freshSessionID()
        lastSuccessfulExchange = 0
        // Reservation prevents simultaneous first requests from creating separate sessions.
        sessionReservedAt = Date().timeIntervalSince1970
        let d = UserDefaults.standard
        d.set(sessionID, forKey: "pet_sessionId")
        d.set(0.0, forKey: "pet_lastExchangeAt")
        handleJSEvent("SESSION_RESET sid=\(sessionID) generation=\(sessionGeneration) reason=\(reason)")
    }

    @objc func resetPos() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width - 20, y: visible.minY + 20))
        }
    }

    // ———— Hermes 对话 ————

    // 单击 = 对话: 弹出内嵌输入条 (自绘, 透明背景, 无系统 sheet 黑幕)
    func startChat(playGreeting: Bool = true) {
        if playGreeting { playMotion() }  // 普通入口顺便触发动作；点击反应入口保留指定动作
        markActivity()
        isInputOpen = true
        // 若已显示输入条则复用
        if let inputBar = inputBar, inputBar.superview != nil {
            inputBar.textField.becomeFirstResponder()
            return
        }
        let bar = InputBar(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        bar.onSend = { [weak self] text in
            self?.dismissInputBar()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.showBubble("你说: " + trimmed)
            self?.askHermes(trimmed)
        }
        bar.onCancel = { [weak self] in
            self?.dismissInputBar()
        }
        bar.onMicrophone = { [weak self] in
            self?.toggleVoiceChat()
        }
        // 左右各留 8pt，并随窗口一起缩放，确保小倍率时发送按钮也不会被裁切。
        let contentW = window.contentView?.bounds.width ?? 300
        let contentH = window.contentView?.bounds.height ?? 100
        let barW = max(0, contentW - 16)
        bar.frame = NSRect(x: 8, y: max(8, contentH - 70),
                           width: barW, height: 44)
        bar.autoresizingMask = [.width, .minYMargin]
        window.contentView?.addSubview(bar)
        inputBar = bar
        NSApp.activate(ignoringOtherApps: true)
        bar.textField.becomeFirstResponder()
    }

    // ———— Task 1: 点击部位反应 ————
    private func handlePetClick(at point: CGPoint, in rect: CGRect?, isDoubleClick: Bool) {
        markActivity()
        guard let rect, rect.height > 0 else {
            handleJSEvent("CLICK_PART: unknown -> chat")
            startChat(playGreeting: false)
            return
        }
        let yRatio = min(1, max(0, (point.y - rect.minY) / rect.height))
        if isDoubleClick {
            // 双击 = 打开聊天框 (若已开着则关闭 = toggle)
            if isInputOpen { dismissInputBar() } else { startChat(playGreeting: false) }
            playReaction(emotion: "惊讶", motion: "splash")
            handleJSEvent("CLICK_PART: double -> toggle chat")
        } else if yRatio < 0.35 {
            playReaction(emotion: "开心", motion: "aidale")
            handleJSEvent("CLICK_PART: head -> happy/aidale")
            startChat(playGreeting: false)
        } else if yRatio < 0.75 {
            // 点身体: 若输入框开着则先关闭 (否则一直挂着无法关)
            if isInputOpen {
                dismissInputBar()
                handleJSEvent("CLICK_PART: body -> dismiss chat")
                return
            }
            playReaction(emotion: "调皮", motion: "bubble")
            showBubble("好痒呀～", durationMs: 1600)
            handleJSEvent("CLICK_PART: body -> tickle/bubble")
        } else {
            // 点尾巴: 若输入框开着则先关闭
            if isInputOpen {
                dismissInputBar()
                handleJSEvent("CLICK_PART: tail -> dismiss chat")
                return
            }
            playReaction(emotion: "开心", motion: "splash")
            handleJSEvent("CLICK_PART: tail -> happy/splash")
        }
    }

    private func playReaction(emotion: String, motion: String) {
        let js = "window.__setEmotion('\(jsEscapedString(emotion))'); window.__setMotion('\(jsEscapedString(motion))');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // ———— Task 4: 真正开始拖动后才显示惊讶反馈 ————
    private func showDragFeedback(_ dragging: Bool) {
        if dragging {
            webView.evaluateJavaScript("window.__setEmotion('惊讶')", completionHandler: nil)
            handleJSEvent("DRAG_FEEDBACK: surprised")
        } else {
            webView.evaluateJavaScript("window.__resetExpression && window.__resetExpression()", completionHandler: nil)
            handleJSEvent("DRAG_FEEDBACK: reset")
        }
    }

    // ———— 🎤 手动语音对话 ————
    private func toggleVoiceChat() {
        if isVoiceChatListening {
            // 再次点击 = 停止并提交当前已识别内容
            stopVoiceChatListener()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.showBubble("没有录音权限呢～")
                    self.handleJSEvent("VOICECHAT: microphone denied")
                    return
                }
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async {
                        guard status == .authorized else {
                            self.showBubble("没有语音识别权限呢～")
                            self.handleJSEvent("VOICECHAT: speech denied")
                            return
                        }
                        self.beginVoiceChatRecognition(showListeningHint: true, force: true)
                    }
                }
            }
        }
    }

    // ———— 常驻语音对话 ————
    func voiceChatEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "pet_voiceChat")
    }

    private func startVoiceChatListener() {
        guard voiceChatEnabled(), !isVoiceChatListening, !isRecording else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] microphoneGranted in
            guard let self else { return }
            guard microphoneGranted else {
                DispatchQueue.main.async { self.disableVoiceChatForMissingPermission() }
                return
            }
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard status == .authorized else {
                        self.disableVoiceChatForMissingPermission()
                        return
                    }
                    self.beginVoiceChatRecognition(showListeningHint: true)
                }
            }
        }
    }

    private func disableVoiceChatForMissingPermission() {
        UserDefaults.standard.set(false, forKey: "pet_voiceChat")
        stopVoiceChatListener()
        showBubble("没有录音权限呢～")
        handleJSEvent("VOICECHAT: permission denied; disabled")
    }

    private func beginVoiceChatRecognition(showListeningHint: Bool = false, force: Bool = false) {
        guard (force || voiceChatEnabled()), !isVoiceChatListening, !isRecording else { return }
        if !force { voiceChatManualMode = false }   // 常驻模式重置手动标记
        let input = recordingEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            failVoiceChatStart(reason: "麦克风暂时不可用～")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        voiceChatText = ""
        voiceChatLastSpeechAt = nil
        voiceChatUtteranceStartedAt = nil
        voiceChatDiscardingInput = false
        recognitionTask?.cancel()
        recognitionTask = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isVoiceChatListening else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if self.voiceChatCanProcessInput(manual: self.voiceChatManualMode) {
                        if !text.isEmpty, text != self.voiceChatText {
                            // 此时识别器正在接收用户语音，绝不能保留回复的说话/口型动作。
                            self.stopTalkingMotion()
                            self.voiceChatText = text
                            self.voiceChatLastSpeechAt = Date()
                            if self.voiceChatUtteranceStartedAt == nil { self.voiceChatUtteranceStartedAt = Date() }
                            // 实时显示识别到的文字, 让用户知道正在被听到 (整段直接显示, 不重打不闪烁)
                            self.showBubble("你说: " + text, instant: true)
                        }
                    } else {
                        self.resetVoiceChatUtterance()
                        self.voiceChatDiscardingInput = true
                    }
                    if result.isFinal {
                        self.finishVoiceChatUtterance()
                        return
                    }
                }
                if let error {
                    self.handleJSEvent("VOICECHAT: recognition error \(error.localizedDescription)")
                    self.restartVoiceChatRecognition(after: 0.5)
                }
            }
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        do {
            recordingEngine.prepare()
            try recordingEngine.start()
            isVoiceChatListening = true
            // AI/TTS 期间会提前重建一个“丢弃输入”的识别会话；只有真正进入听用户状态才复位动作。
            if !isReplySpeechActive { stopTalkingMotion() }
            if force { voiceChatManualMode = true }   // manual 标记仅在会话真正启动后生效 (避免与常驻会话竞争)
            voiceChatSilenceTimer?.invalidate()
            voiceChatSilenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.checkVoiceChatSilence()
            }
            if showListeningHint { showBubble("🎧 在听呢...") }
            inputBar?.setListening(true)
            handleJSEvent("VOICECHAT: started")
        } catch {
            input.removeTap(onBus: 0)
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            failVoiceChatStart(reason: "语音对话启动失败，再试一次吧～", detail: error.localizedDescription)
        }
    }

    /// 语音对话启动失败统一清理: 清 manual 标记 / 会话代数 +1 / 复位 UI / 可见提示
    private func failVoiceChatStart(reason: String, detail: String = "") {
        voiceChatManualMode = false
        voiceChatSessionGeneration += 1
        inputBar?.setListening(false)
        showBubble(reason)
        handleJSEvent("VOICECHAT: start failed \(detail)")
    }

    private func voiceChatCanProcessInput(manual: Bool = false) -> Bool {
        // 必须把 TTS 生成阶段(ttsDaemonCompletion 未回调)也算作"正在说话"。
        // 否则识别器重启后的 partial result 会调 stopTalkingMotion(),
        // 把 isReplySpeechActive 重置为 false, 导致音频就绪后 startTalkingMotion() 被 guard 挡掉。
        let isSpeaking = isReplySpeechActive
            || ttsDaemonCompletion != nil
            || speechProcess != nil
            || speechPlayer != nil
            || speechSynthesizer.isSpeaking
        if manual {
            // 🎤 手动模式: 由输入框按钮触发, 监听期间不因 isInputOpen 而丢弃
            return !isAIReplying && !isSpeaking && !isUserDragging && !isRecording
        }
        // ⚠️ 不能在这里判 isInputOpen: 麦克风按钮就在输入框里, 点它时输入框必定是开的,
        // 判了就等于"用手动麦克风说话永远被丢弃"。设置面板自己会在 openSettings()
        // 里主动停监听, 不需要这里再兜。
        return (manual || voiceChatEnabled())
            && !isAIReplying && !isSpeaking && !isUserDragging && !isRecording
    }

    private func checkVoiceChatSilence() {
        guard isVoiceChatListening else { return }
        guard voiceChatCanProcessInput(manual: voiceChatManualMode) else {
            resetVoiceChatUtterance()
            voiceChatDiscardingInput = true
            return
        }
        // 之前是"丢弃中 -> restart -> 下一轮又丢弃 -> 再 restart"的死循环:
        // 重启会重置计时, 0.25s 的 timer 每轮都触发, 永远退不出去。
        // 只有真的从"丢弃"回到"可接受"时重启一次, 然后清标记。
        if voiceChatDiscardingInput {
            voiceChatDiscardingInput = false
            restartVoiceChatRecognition(after: 0.1)
            return
        }
        let now = Date()
        // 中文短句尾部 1.0s 静音即可可靠判停；原 2.2s 每轮固定多等近一秒。
        if let last = voiceChatLastSpeechAt, now.timeIntervalSince(last) >= 1.0 {
            finishVoiceChatUtterance()
        } else if let started = voiceChatUtteranceStartedAt, now.timeIntervalSince(started) >= 15.0 {
            finishVoiceChatUtterance()
        }
    }

    private func resetVoiceChatUtterance() {
        voiceChatText = ""
        voiceChatLastSpeechAt = nil
        voiceChatUtteranceStartedAt = nil
    }

    private func finishVoiceChatUtterance() {
        let manual = voiceChatManualMode
        let text = voiceChatText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canProcess = voiceChatCanProcessInput(manual: manual)
        resetVoiceChatUtterance()
        guard !text.isEmpty, canProcess else {
            // 识别任务已经 final, 空结果就直接返回会留下"假监听"状态
            // (isVoiceChatListening 还是 true 但 task 已死), 之后再也收不到任何结果。
            // 必须换一个新 task。
            restartVoiceChatRecognition(after: 0.1)
            return
        }
        // 用户话语已结束、AI 回复尚未开始；明确清掉任何遗留的 talk lock / 口型驱动。
        stopTalkingMotion()
        showBubble("你说: " + text)
        handleJSEvent("VOICECHAT: recognized text=\(text)")
        handleJSEvent("VOICECHAT: sent-to-AI")
        handleJSEvent("VOICECHAT: reply started")
        isVoiceChatConversationActive = true
        askHermes(text)
        monitorVoiceChatReplyCompletion()
        // 回复期间不重建识别 (重建出来的会话只会丢弃输入); 由
        // monitorVoiceChatReplyCompletion 在 TTS 播完后统一重启。
    }

    private func monitorVoiceChatReplyCompletion() {
        voiceChatReplyMonitor?.invalidate()
        voiceChatReplyMonitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let isSpeaking = self.isReplySpeechActive
                || self.ttsDaemonCompletion != nil
                || self.speechProcess != nil
                || self.speechPlayer != nil
                || self.speechSynthesizer.isSpeaking
            if self.isVoiceChatConversationActive && !self.isAIReplying && !isSpeaking {
                self.isVoiceChatConversationActive = false
                timer.invalidate()
                self.voiceChatReplyMonitor = nil
                self.handleJSEvent("VOICECHAT: reply finished")
                self.restartVoiceChatRecognition(after: 0.1)
            }
        }
    }

    private func restartVoiceChatRecognition(after delay: TimeInterval) {
        guard (voiceChatManualMode || voiceChatEnabled()), !isRecording else { return }
        let manual = voiceChatManualMode
        // 必须在 stop 之后取 generation —— stopVoiceChatRecognitionSession 会 +1,
        // 先取再 stop 会让下面的相等判断永远为假, 延迟重启 100% 失效
        // (这才是"说了没反应"的主因: 别处一旦丢弃过一次输入, 就再也恢复不了监听)。
        stopVoiceChatRecognitionSession(logStopped: false)
        let generation = voiceChatSessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.voiceChatSessionGeneration == generation,
                  (manual || self.voiceChatEnabled()),
                  !self.isRecording else { return }
            self.beginVoiceChatRecognition(force: manual)
        }
    }

    private func stopVoiceChatRecognitionSession(logStopped: Bool) {
        guard isVoiceChatListening || recognitionRequest != nil else { return }
        isVoiceChatListening = false
        voiceChatSessionGeneration += 1   // 作废所有未决的延迟重启
        voiceChatSilenceTimer?.invalidate()
        voiceChatSilenceTimer = nil
        recordingEngine.stop()
        recordingEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        resetVoiceChatUtterance()
        inputBar?.setListening(false)
        if logStopped { handleJSEvent("VOICECHAT: stopped") }
    }

    private func stopVoiceChatListener() {
        stopVoiceChatRecognitionSession(logStopped: true)
        voiceChatReplyMonitor?.invalidate()
        voiceChatReplyMonitor = nil
        isVoiceChatConversationActive = false
        voiceChatManualMode = false
    }

    func dismissInputBar() {
        // 手动语音对话的 mic 控件在输入框内, 关闭输入框必须同步停止手动监听, 否则识别无限继续
        if voiceChatManualMode, isVoiceChatListening {
            stopVoiceChatListener()
        }
        inputBar?.removeFromSuperview()
        inputBar = nil
        isInputOpen = false
    }

    /// 工具调用之后拿正文。
    /// OpenAI 协议里 finish_reason=tool_calls 时 content 通常为空, 正文要靠
    /// 回填 tool 结果后再请求一次才出来。桌宠的工具是即时副作用 (动作/表情已播),
    /// 所以这里只需要续写的正文文本。
    func continueAfterToolCalls(fullPrompt: String, userText: String,
                                assistantMsg: [String: Any], toolCalls: [[String: Any]],
                                baseURL: String, apiKey: String, model: String,
                                emotion: String?, motion: String?, moveTarget: (Int, Int)?) {
        guard let url = URL(string: baseURL + "/chat/completions") else { return }
        var messages: [[String: Any]] = [
            ["role": "system", "content": fullPrompt],
            ["role": "user", "content": userText],
            ["role": "assistant", "content": assistantMsg["content"] as? String ?? "",
             "tool_calls": toolCalls]
        ]
        for call in toolCalls {
            let id = (call["id"] as? String) ?? ""
            messages.append(["role": "tool", "tool_call_id": id, "content": "ok"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = ["model": model, "messages": messages, "max_tokens": 300]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        req.httpBody = payload

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                var reply = ""
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let msg = first["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    reply = content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if reply.isEmpty {
                    reply = "（小鲸鱼鼓了鼓腮帮子）"
                    self.handleJSEvent("TOOL_CONTINUE: empty, fallback")
                } else {
                    self.handleJSEvent("TOOL_CONTINUE: ok chars=\(reply.count)")
                }
                self.isAIReplying = false
                self.showBubble(reply)
                self.speak(reply, emotion: emotion)
                if let motion {
                    let js = "window.__setMotion ? window.__setMotion('\\(self.jsEscapedString(motion))') : 0"
                    self.webView.evaluateJavaScript(js, completionHandler: nil)
                }
                if let moveTarget {
                    self.moveWindow(xPercent: moveTarget.0, yPercent: moveTarget.1,
                                    reason: "ai", duration: 1.2)
                }
            }
        }.resume()
    }

    // 调 AI (自定义 API 优先, 否则 Hermes gateway)
    func askHermes(_ text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let userText = text          // 原始用户输入, 后续闭包里 text 会被解析结果覆盖
        let requestStartedAt = Date()
        markActivity()
        isAIReplying = true
        let cfg = loadConfig()
        let now = Date().timeIntervalSince1970
        let timeoutSeconds = max(0, cfg.sessionIdleTimeoutMinutes * 60)
        let activityAt = lastSuccessfulExchange > 0 ? lastSuccessfulExchange : sessionReservedAt
        let idleSeconds = activityAt > 0 ? max(0, Int(now - activityAt)) : 0
        let shouldCreate = sessionID.isEmpty || timeoutSeconds == 0 || activityAt <= 0 || now - activityAt > Double(timeoutSeconds)
        if shouldCreate {
            let reason = sessionID.isEmpty || activityAt <= 0 ? "empty" : "timeout"
            resetSession(reason: reason)
            handleJSEvent("SESSION_NEW sid=\(sessionID) reason=\(reason) idle=\(idleSeconds)s timeout=\(timeoutSeconds)s")
        } else {
            handleJSEvent("SESSION_REUSE sid=\(sessionID) idle=\(idleSeconds)s timeout=\(timeoutSeconds)s")
        }
        let requestSessionID = sessionID
        let requestGeneration = sessionGeneration
        // 决定 baseURL / key / model
        var baseURL = cfg.apiBaseURL
        var apiKey = cfg.apiKey
        var model = cfg.model
        if baseURL.isEmpty {
            // 内置 Hermes gateway
            guard let key = readGatewayKey() else {
                isAIReplying = false
                showBubble("⚠️ 未找到 API_SERVER_KEY (检查 ~/.hermes/.env)")
                return
            }
            baseURL = "http://127.0.0.1:8642/v1"
            apiKey = key
            if model.isEmpty { model = "hermes-token" }
        } else if apiKey.isEmpty {
            // 外部中转站必须带 Bearer, 否则上游一律返回
            // 500 {"message":"Internal server error, please try again later"} (99 字节)。
            // 别让用户手填: 先复用同名 key 的既有配置, 再退回内置网关。
            if let reuse = readReusableKey(for: baseURL) {
                apiKey = reuse
                handleJSEvent("API_KEY_REUSE: 复用 ~/.hermes/.env 的 key 访问 \(baseURL)")
            } else if let gw = readGatewayKey(), baseURL.contains("127.0.0.1") || baseURL.contains("localhost") {
                apiKey = gw
                handleJSEvent("API_KEY_REUSE: 复用 API_SERVER_KEY 访问本机 \(baseURL)")
            } else {
                isAIReplying = false
                showBubble("⚠️ 缺少 API Key: 请到设置里填写 \(baseURL) 的 key")
                handleJSEvent("API_KEY_MISSING: \(baseURL)")
                return
            }
        }
        // 规范化 baseURL: 去掉末尾 /
        if baseURL.hasSuffix("/") { baseURL = String(baseURL.dropLast()) }
        guard let url = URL(string: baseURL + "/chat/completions") else {
            isAIReplying = false
            showBubble("⚠️ API 地址无效: \(baseURL)")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(requestSessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let systemPrompt = cfg.systemPrompt.isEmpty ? "你是一只可爱的鲸鱼娘桌宠, 用简短可爱的语气回答, 不超过80字, 可以带颜文字。" : cfg.systemPrompt
        let fullPrompt = systemPrompt + """

        【可用的工具】
        - set_emotion(emotion): 情绪表情，可选值：开心、悲伤、生气、害羞、惊讶、疑惑、疲惫、调皮、无语、心动、星星眼、爱心眼、晕、哭、发呆、恶魔角、天使、猫耳爱心、兔兔星星、耍帅、花花爱心、心跳脸红、虚脱流汗、晕眩、兴奋眨眼、舔嘴、阴郁（每次回复必须调用一次，选最贴切的）
        - play_motion(motion): 身体动作，可选值：待机、撒娇、自拍、简单自拍、番茄酱、开盖、吹泡泡、喷水、爬动、招手、比心、摸头、摇尾巴、露肚皮、睡觉、伸懒腰、跳舞、蹦跳、生气鼓脸、崇拜、墨镜、猫爪、兔耳、探头、喝咖啡（只在需要明显身体动作时调用）
        - move_window(x, y): 移动窗口，x/y 为 0-100 百分比（需要走动/找我时调用；“找我”可用 direction 参数，移动到用户常驻位置，例如右下角或屏幕中央附近）
        - open_chat(): 弹出文本输入框让主人打字对话（主人要求打字/打开输入框时调用）
        - open_settings(): 打开设置面板（主人要改配置/API/大小/音色/开关时调用）
        - set_scale(scale): 调整大小倍率 1-5（主人说变大/变小/放大/缩小时调用）

        【规则】回复正文只写简短可爱的中文（不超过 80 字），不要输出工具名、参数或标签。每次回复至少调用 set_emotion；需要身体动作时调用 play_motion；想走动或找主人时调用 move_window；主人明确要求打开输入框/设置/改大小时调用对应工具。
        如果环境不能调用工具（例如 API 不返回 tool_calls），你必须使用文本标签来表达，并且标签要写在回复正文里：
        - 情绪标签 [情绪] 放在回复最开头（必须，例如 [开心]、[害羞]、[生气]）
        - 动作标签 [动作:xxx] 放在正文任意位置（可选，例如 [动作:撒娇]、[动作:自拍]、[动作:爬动]；当你想做明显的身体动作/卖萌/展示时才加，不要每条都加）
        - 移动标签 [移动:xx%yy%] 或 [移动:找我] 放在正文任意位置（可选）
        注意：即使能用工具，正文里也不要出现任何工具名/参数/标签字样；标签只在不能调用工具时使用。
        """
        let tools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "play_motion",
                    "description": "播放一个 Live2D 身体动作。仅在需要明显身体动画时调用。",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "motion": [
                                "type": "string",
                                "description": "要播放的身体动作",
                                "enum": ["待机", "撒娇", "自拍", "简单自拍", "番茄酱", "开盖", "吹泡泡", "喷水", "爬动", "招手", "比心", "摸头", "摇尾巴", "露肚皮", "睡觉", "伸懒腰", "跳舞", "蹦跳", "生气鼓脸", "崇拜", "墨镜", "猫爪", "兔耳", "探头", "喝咖啡"]
                            ]
                        ],
                        "required": ["motion"],
                        "additionalProperties": false
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "type": "function",
                "function": [
                    "name": "set_emotion",
                    "description": "设置鲸鱼娘的情绪表情，并触发该情绪的默认动作。每次回复选择最贴切的一个情绪。",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "emotion": [
                                "type": "string",
                                "description": "要显示的情绪",
                                "enum": ["开心", "悲伤", "生气", "害羞", "惊讶", "疑惑", "疲惫", "调皮", "无语", "心动", "星星眼", "爱心眼", "晕", "哭", "发呆", "恶魔角", "天使", "猫耳爱心", "兔兔星星", "耍帅", "花花爱心", "心跳脸红", "虚脱流汗", "晕眩", "兴奋眨眼", "舔嘴", "阴郁"]
                            ]
                        ],
                        "required": ["emotion"],
                        "additionalProperties": false
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "type": "function",
                "function": [
                    "name": "move_window",
                    "description": "移动鲸鱼娘窗口到屏幕某个位置。也可用 direction 指定上、下、左、右、中间或找我。",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "x": ["type": "integer", "minimum": 0, "maximum": 100, "description": "屏幕横向位置百分比（0=最左，100=最右）"],
                            "y": ["type": "integer", "minimum": 0, "maximum": 100, "description": "屏幕纵向位置百分比（0=最上，100=最下）"],
                            "direction": ["type": "string", "enum": ["上", "下", "左", "右", "中间", "找我"], "description": "没有坐标时使用的方向别名"]
                        ],
                        "required": ["x", "y"],
                        "additionalProperties": false
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "type": "function",
                "function": [
                    "name": "open_chat",
                    "description": "弹出文本对话输入框，让主人打字与鲸鱼娘聊天。当主人明确要求打字对话、或主人说'打开输入框/对话框'时调用。",
                    "parameters": [
                        "type": "object",
                        "properties": [:],
                        "required": [],
                        "additionalProperties": false
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "type": "function",
                "function": [
                    "name": "open_settings",
                    "description": "打开桌宠设置面板（API 地址/Key/模型/提示词/大小倍率/语音/自主移动/语音对话开关）。当主人要求修改配置、设置、大小、音色、API 时调用。",
                    "parameters": [
                        "type": "object",
                        "properties": [:],
                        "required": [],
                        "additionalProperties": false
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "type": "function",
                "function": [
                    "name": "set_scale",
                    "description": "调整鲸鱼娘窗口大小倍率（1-5 倍）。当主人要求变大/变小/放大/缩小鲸鱼娘时调用。",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "scale": ["type": "integer", "minimum": 1, "maximum": 5, "description": "大小倍率 1-5（1=最小，5=最大）"]
                        ],
                        "required": ["scale"],
                        "additionalProperties": false
                    ] as [String: Any]
                ] as [String: Any]
            ]
        ]
        let body: [String: Any] = [
            "model": model.isEmpty ? "hermes-token" : model,
            "messages": [
                ["role": "system", "content": fullPrompt],
                ["role": "user", "content": text]
            ],
            "tools": tools,
            "tool_choice": "auto",
            // 系统提示要求不超过 80 个中文字；120 token 足够，回复更短则 TTS 生成更快
            "max_tokens": 120
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        showBubble("🐳 让我想想...")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAIReplying = false
                self.markActivity()
                self.handleJSEvent("HERMES_RESPONSE: \(Int(Date().timeIntervalSince(requestStartedAt) * 1000))ms bytes=\(data?.count ?? 0) status=\((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                if let err {
                    self.showBubble("⚠️ 网络错误: \(err.localizedDescription)")
                    return
                }
                guard let http = resp as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    // 把上游真实原因带回气泡里: 中转站 500/502 的 body 里有可读 message,
                    // 只显示 "HTTP 错误: 500" 对排查毫无帮助。
                    let raw = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
                    var detail = ""
                    if let d = raw.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let err = obj["error"] as? [String: Any],
                       let msg = err["message"] as? String {
                        detail = msg
                    } else if !raw.isEmpty {
                        detail = String(raw.prefix(120))
                    }
                    self.handleJSEvent("HERMES_HTTP_ERR: status=\(status) body=\(raw.prefix(300))")
                    self.showBubble("⚠️ API HTTP \(status)\(detail.isEmpty ? "" : ": " + detail)")
                    return
                }
                guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let msg = first["message"] as? [String: Any] else {
                    let raw = data.map { String(data: $0, encoding: .utf8) ?? "??" } ?? "no data"
                    self.showBubble("⚠️ API 返回异常: \(raw.prefix(150))")
                    return
                }
                if self.sessionGeneration == requestGeneration && self.sessionID == requestSessionID {
                    if let serverID = http.value(forHTTPHeaderField: "X-Hermes-Session-Id"), !serverID.isEmpty {
                        if serverID != requestSessionID { self.handleJSEvent("SESSION_SERVER_ID old=\(requestSessionID) new=\(serverID)") }
                        self.sessionID = serverID
                        UserDefaults.standard.set(serverID, forKey: "pet_sessionId")
                    }
                    self.lastSuccessfulExchange = Date().timeIntervalSince1970
                    self.sessionReservedAt = self.lastSuccessfulExchange
                    UserDefaults.standard.set(self.lastSuccessfulExchange, forKey: "pet_lastExchangeAt")
                } else {
                    self.handleJSEvent("SESSION_STALE_RESPONSE sid=\(requestSessionID) generation=\(requestGeneration) currentSid=\(self.sessionID) currentGeneration=\(self.sessionGeneration)")
                }
                // 标准 tools 响应中 content 允许为 null；工具调用和正文分别解析。
                var text = (msg["content"] as? String) ?? ""
                var emotion: String? = nil
                var motion: String? = nil
                var moveTarget: (Int, Int)? = nil
                let motionAliases = [
                    "idle": "idle", "待机": "idle",
                    "aidale": "aidale", "撒娇": "aidale",
                    "selfie": "selfie", "自拍": "selfie",
                    "selfiequick": "selfieQuick", "简单自拍": "selfieQuick", "快速自拍": "selfieQuick",
                    "ketchup": "ketchup", "番茄酱": "ketchup", "挤番茄酱": "ketchup",
                    "openlid": "openLid", "开盖": "openLid",
                    "bubble": "bubble", "吹泡泡": "bubble",
                    "splash": "splash", "喷水": "splash",
                    "crawl": "crawl", "爬动": "crawl", "游动": "crawl",
                    "talk": "talk", "说话": "talk", "讲话": "talk"
                    , "wave": "wave", "招手": "wave", "打招呼": "wave"
                    , "heartkiss": "heartKiss", "比心": "heartKiss"
                    , "headpat": "headpat", "摸头": "headpat"
                    , "tailwag": "tailWag", "摇尾巴": "tailWag"
                    , "bellyup": "bellyUp", "露肚皮": "bellyUp"
                    , "sleep": "sleep", "睡觉": "sleep"
                    , "stretch": "stretch", "伸懒腰": "stretch"
                    , "dance": "dance", "跳舞": "dance"
                    , "hop": "hop", "蹦跳": "hop"
                    , "angrypuff": "angryPuff", "生气鼓脸": "angryPuff"
                    , "worship": "worship", "崇拜": "worship"
                    , "coolshades": "coolShades", "墨镜": "coolShades"
                    , "catpaws": "catPaws", "猫爪": "catPaws"
                    , "bunnyears": "bunnyEars", "兔耳": "bunnyEars"
                    , "peek": "peek", "探头": "peek"
                    , "coffee": "coffee", "喝咖啡": "coffee"
                ]
                let validEmotions: Set<String> = ["开心", "悲伤", "生气", "害羞", "惊讶", "疑惑", "疲惫", "调皮", "无语", "心动", "星星眼", "爱心眼", "晕", "哭", "发呆", "恶魔角", "天使", "猫耳爱心", "兔兔星星", "耍帅", "花花爱心", "心跳脸红", "虚脱流汗", "晕眩", "兴奋眨眼", "舔嘴", "阴郁"]
                let toolCalls = msg["tool_calls"] as? [[String: Any]] ?? []
                for call in toolCalls {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          let arguments = function["arguments"] as? String else {
                        print("TOOL_CALL: malformed call \(call)")
                        continue
                    }
                    print("TOOL_CALL: \(name) \(arguments)")
                    self.markActivity()
                    guard let argumentData = arguments.data(using: .utf8),
                          let args = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any] else {
                        print("TOOL_RESULT: \(name) invalid JSON arguments")
                        continue
                    }
                    switch name {
                    case "set_emotion":
                        if let value = args["emotion"] as? String, validEmotions.contains(value) {
                            emotion = value
                            print("TOOL_RESULT: set_emotion accepted \(value)")
                        } else {
                            print("TOOL_RESULT: set_emotion rejected \(args)")
                        }
                    case "play_motion":
                        if let value = args["motion"] as? String,
                           let group = motionAliases[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
                            motion = group
                            print("TOOL_RESULT: play_motion accepted \(value) -> \(group)")
                        } else {
                            print("TOOL_RESULT: play_motion rejected \(args)")
                        }
                    case "move_window":
                        if let target = self.moveTarget(from: args) {
                            moveTarget = target
                            print("TOOL_RESULT: move_window accepted \(target.0)% \(target.1)%")
                        } else {
                            print("TOOL_RESULT: move_window rejected \(args)")
                        }
                    case "open_chat":
                        print("TOOL_RESULT: open_chat called")
                        self.startChat(playGreeting: false)
                    case "open_settings":
                        print("TOOL_RESULT: open_settings called")
                        self.openSettings()
                    case "set_scale":
                        if let scale = args["scale"] as? Int, (1...5).contains(scale) {
                            print("TOOL_RESULT: set_scale accepted \(scale)")
                            self.applyScale(scale)
                            self.showBubble("✅ 已调整为 x\(scale) 大小")
                        } else {
                            print("TOOL_RESULT: set_scale rejected \(args)")
                        }
                    default:
                        print("TOOL_RESULT: unsupported tool \(name)")
                    }
                }

                // 支持多个标签: 依次收集 [移动] / [动作:xxx] / [情绪] 并按顺序触发
                var pendingMotions: [String] = []
                var pendingEmotions: [String] = []
                var pendingMove: (Int, Int)? = nil
                if let moveRegex = try? NSRegularExpression(pattern: #"[\[［]\s*移动\s*[:：]\s*([^\]］]+?)\s*[\]］]"#) {
                    let all = moveRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    for m in all {
                        if let vr = Range(m.range(at: 1), in: text) {
                            let value = String(text[vr]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if toolCalls.isEmpty, let t = self.moveTarget(fromTag: value) { pendingMove = t }
                        }
                    }
                    text = moveRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
                }

                // 兼容不支持 tools 的旧/自定义接口：没有 tool_calls 时沿用标签取值；
                // 若已有 tool_calls 但正文误带标签，也会清除，避免显示或朗读工具语法。
                if let motionRegex = try? NSRegularExpression(pattern: #"[\[［]\s*(?:动作|motion)\s*[:：]\s*([^\]］]+?)\s*[\]］]"#, options: [.caseInsensitive]) {
                    let all = motionRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    for m in all {
                        if let vr = Range(m.range(at: 1), in: text) {
                            let value = String(text[vr]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if let g = motionAliases[value.lowercased()] { pendingMotions.append(g) }
                        }
                    }
                    text = motionRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
                }
                if let emotionRegex = try? NSRegularExpression(pattern: #"[\[［]\s*([^\]］:：]{1,6}?)\s*[\]］]"#) {
                    let all = emotionRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    for m in all {
                        if let vr = Range(m.range(at: 1), in: text) {
                            let value = String(text[vr]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if validEmotions.contains(value) { pendingEmotions.append(value) }
                        }
                    }
                    text = emotionRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                }
                if !toolCalls.isEmpty {
                    // tool_calls 已处理, 标签仅作清理 (不覆盖)
                } else {
                    motion = pendingMotions.first
                    emotion = pendingEmotions.first
                    moveTarget = pendingMove ?? moveTarget
                }
                self.pendingEmotions = pendingEmotions
                self.pendingMotions = pendingMotions
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let spaces = try? NSRegularExpression(pattern: #"[ \t]{2,}"#) {
                    text = spaces.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
                }
                // 即使模型只返回工具调用，也始终给气泡和语音一个可见文本。
                // 但不能拿固定串糊过去 (之前是写死 "主人~", 导致只回一句"主人")。
                // 正确做法: 工具调用的回程 —— 把 tool_calls 与结果回填给模型, 让它
                // 按 OpenAI 协议续写出正文。tool_calls 的即时副作用已经触发过了,
                // 这里只要正文; 续写失败才用兜底文案。
                if text.isEmpty && !toolCalls.isEmpty {
                    self.continueAfterToolCalls(
                        fullPrompt: fullPrompt,
                        userText: userText,
                        assistantMsg: msg,
                        toolCalls: toolCalls,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        model: model,
                        emotion: emotion, motion: motion, moveTarget: moveTarget
                    )
                    return
                }
                if text.isEmpty { text = "（小鲸鱼歪了歪头）" }
                // 触发情绪表情
                if let emotion {
                    let js = "window.__setEmotion ? window.__setEmotion('\(self.jsEscapedString(emotion))') : 0"
                    self.webView.evaluateJavaScript(js, completionHandler: nil)
                }
                // 显式动作在情绪默认动作之后触发，以 FORCE 优先级覆盖它。
                if let motion {
                    print("SET_MOTION: \(motion)")
                    let js = "window.__setMotion ? window.__setMotion('\(self.jsEscapedString(motion))') : 0"
                    self.webView.evaluateJavaScript(js, completionHandler: nil)
                }
                // 多标签依次播放: [情绪][情绪]... 或 [动作:a][动作:b]... 每隔 1.8s 播下一个
                // (第一个已由上方 emotion/motion 立即触发, 从第 2 个开始排队)
                var seqDelay = 1.8
                if self.pendingEmotions.count > 1 {
                    for (i, item) in self.pendingEmotions.enumerated() where i > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + seqDelay) { [weak self] in
                            guard let self else { return }
                            let js = "window.__setEmotion ? window.__setEmotion('\(self.jsEscapedString(item))') : 0"
                            self.webView.evaluateJavaScript(js, completionHandler: nil)
                        }
                        seqDelay += 1.8
                    }
                }
                if self.pendingMotions.count > 1 {
                    for (i, item) in self.pendingMotions.enumerated() where i > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + seqDelay) { [weak self] in
                            guard let self else { return }
                            let js = "window.__setMotion ? window.__setMotion('\(self.jsEscapedString(item))') : 0"
                            self.webView.evaluateJavaScript(js, completionHandler: nil)
                        }
                        seqDelay += 1.8
                    }
                }
                if let target = moveTarget {
                    self.moveWindow(xPercent: target.0, yPercent: target.1, reason: "MOVE_WINDOW", duration: 2.6)
                }
                // 气泡与说话动作统一由 speak 控制 (语音开关只影响声音, 动作/气泡始终跟随)
                self.speak(text, emotion: emotion)
            }
        }.resume()
    }

    func speechEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pet_speak") == nil { return true }
        return defaults.bool(forKey: "pet_speak")
    }

    func wanderEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pet_wander") == nil { return true }
        return defaults.bool(forKey: "pet_wander")
    }

    func markActivity() {
        lastActivity = Date()
    }

    private func activeScreenFrame() -> NSRect {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
    }

    private func moveTarget(from args: [String: Any]) -> (Int, Int)? {
        if let x = (args["x"] as? NSNumber)?.intValue,
           let y = (args["y"] as? NSNumber)?.intValue {
            return (min(100, max(0, x)), min(100, max(0, y)))
        }
        if let direction = args["direction"] as? String {
            return moveTarget(fromTag: direction)
        }
        return nil
    }

    private func moveTarget(fromTag value: String) -> (Int, Int)? {
        let compact = value.replacingOccurrences(of: " ", with: "")
        let aliases: [String: (Int, Int)] = [
            "上": (50, 5), "下": (50, 95), "左": (5, 70), "右": (95, 70),
            "中间": (50, 50), "中央": (50, 50), "找我": (85, 85)
        ]
        if let target = aliases[compact] { return target }
        let pattern = #"^(\d{1,3})%?[,，\s]*(\d{1,3})%?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: compact, range: NSRange(compact.startIndex..., in: compact)),
              let xr = Range(match.range(at: 1), in: compact),
              let yr = Range(match.range(at: 2), in: compact),
              let x = Int(compact[xr]), let y = Int(compact[yr]) else { return nil }
        return (min(100, max(0, x)), min(100, max(0, y)))
    }

    private func moveWindow(xPercent: Int, yPercent: Int, reason: String, duration: TimeInterval) {
        guard !isUserDragging, !isWindowAnimating else { return }
        let crawlJS = "window.__setMotion ? window.__setMotion('crawl') : 0"
        webView.evaluateJavaScript(crawlJS, completionHandler: nil)
        handleJSEvent("MOTION_DURING_MOVE: crawl")
        let visible = activeScreenFrame()
        let frame = window.frame
        let availableX = max(0, visible.width - frame.width)
        let availableY = max(0, visible.height - frame.height)
        let x = visible.minX + availableX * CGFloat(min(100, max(0, xPercent))) / 100
        // AppKit 原点在左下；协议的 y=0 是顶部。
        let y = visible.maxY - frame.height - availableY * CGFloat(min(100, max(0, yPercent))) / 100
        let target = NSRect(x: x, y: y, width: frame.width, height: frame.height)
        isWindowAnimating = true
        let animationID = UUID()
        windowAnimationID = animationID
        // 分段爬行移动: 3 段小步 + 停顿, 配合 crawl 循环动作 (视觉上一步一步爬过去)
        let steps = 3
        let stepDuration = max(0.25, duration / Double(steps) * 0.8)
        let pause = 0.12
        animateWindowStep(1, steps: steps, from: frame, to: target,
                          stepDuration: stepDuration, pause: pause, animationID: animationID)
        handleJSEvent("\(reason): \(xPercent)% \(yPercent)% -> \(Int(x)),\(Int(y))")
    }

    private func animateWindowStep(_ step: Int, steps: Int, from start: NSRect, to target: NSRect,
                                   stepDuration: TimeInterval, pause: TimeInterval, animationID: UUID) {
        guard windowAnimationID == animationID else { return }
        guard !isUserDragging else {
            finishWindowMove(animationID: animationID)
            return
        }
        guard step <= steps else {
            finishWindowMove(animationID: animationID)
            return
        }
        let t = CGFloat(step) / CGFloat(steps)
        let intermediate = NSRect(
            x: start.minX + (target.minX - start.minX) * t,
            y: start.minY + (target.minY - start.minY) * t,
            width: start.width, height: start.height
        )
        NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self else { return }
            context.duration = stepDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.window.animator().setFrame(intermediate, display: true)
        } completionHandler: { [weak self] in
            guard let self, self.windowAnimationID == animationID else { return }
            let continueMove = {
                self.animateWindowStep(step + 1, steps: steps, from: start, to: target,
                                       stepDuration: stepDuration, pause: pause, animationID: animationID)
            }
            if step < steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: continueMove)
            } else {
                continueMove()
            }
        }
    }

    private func finishWindowMove(animationID: UUID) {
        guard windowAnimationID == animationID else { return }
        isWindowAnimating = false
        let idleJS = "window.__setMotion ? window.__setMotion('idle') : 0"
        webView.evaluateJavaScript(idleJS, completionHandler: nil)
    }

    func scheduleWander() {
        wanderTimer?.invalidate()
        wanderTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 6...10), repeats: false) { [weak self] _ in
            guard let self else { return }
            defer { self.scheduleWander() }
            let isSpeaking = self.isReplySpeechActive
                || self.ttsDaemonCompletion != nil
                || self.speechProcess != nil
                || self.speechPlayer != nil
                || self.speechSynthesizer.isSpeaking
            // 只有待机满 3 分钟(180s)才自主移动; 有输入/输入框打开/设置面板/AI回复/拖拽/语音/动画中一律不动
            guard self.wanderEnabled(), Date().timeIntervalSince(self.lastActivity) > 180,
                  !self.isUserDragging, !self.isAIReplying, !self.isInputOpen, !isSpeaking, !self.isWindowAnimating else { return }

            // ———— Task 3: 20% 概率用卖萌动作代替本次漫游 ————
            if Int.random(in: 0..<5) == 0 {
                let gestures = [
                    ("吐舌", "bubble"), ("爱心眼", "heartKiss"), ("开心", "hop"),
                    ("发呆", "peek"), ("星星眼", "worship"), ("害羞", "headpat"),
                    ("调皮", "catPaws"), ("疲惫", "stretch"), ("开心", "dance")
                ]
                let gesture = gestures.randomElement()!
                self.playReaction(emotion: gesture.0, motion: gesture.1)
                self.handleJSEvent("RANDOM_GESTURE: \(gesture.1) / \(gesture.0)")
                self.markActivity()
                return
            }

            let visible = self.activeScreenFrame()
            let availableX = max(1, visible.width - self.window.frame.width)
            let availableY = max(1, visible.height - self.window.frame.height)
            let currentX = Int(((self.window.frame.minX - visible.minX) / availableX * 100).rounded())
            let currentY = Int(((visible.maxY - self.window.frame.maxY) / availableY * 100).rounded())
            let nextX = min(100, max(0, currentX + Int.random(in: -8...8)))
            // 偏爱屏幕下方，并保持轻柔的小步移动。
            let verticalStep = currentY < 65 ? Int.random(in: 2...8) : Int.random(in: -5...5)
            let nextY = min(95, max(55, currentY + verticalStep))
            self.moveWindow(xPercent: nextX, yPercent: nextY, reason: "WANDER", duration: 2.6)
        }
    }

    func selectedVoice() -> String {
        UserDefaults.standard.string(forKey: "pet_voice") ?? "zh_female_vv_uranus_bigtts"
    }

    /// 火山音色（_bigtts 结尾）走 volc 后端；其余走 edge-tts
    func ttsBackend(for voice: String) -> String {
        voice.contains("_bigtts") ? "volc" : "edge"
    }

    /// 火山音调（半音，-12..12）。默认 +2 = 升高约两度（更萌）
    func volcPitchSemitones() -> Int {
        if UserDefaults.standard.object(forKey: "pet_pitchST") == nil { return 2 }
        return UserDefaults.standard.integer(forKey: "pet_pitchST")
    }

    func prosody(for emotion: String?) -> SpeechProsody {
        switch emotion {
        case "开心", "调皮", "星星眼":
            return SpeechProsody(rate: "+22%", pitch: "+22Hz", volume: "+12%")
        case "伤心", "悲伤", "哭", "疲惫":
            return SpeechProsody(rate: "-10%", pitch: "-5Hz", volume: "-10%")
        case "生气":
            return SpeechProsody(rate: "+10%", pitch: "+10Hz", volume: "+20%")
        case "害羞", "撒娇", "心动", "爱心眼":
            return SpeechProsody(rate: "+15%", pitch: "+18Hz", volume: "+6%")
        case "惊讶", "晕":
            return SpeechProsody(rate: "+16%", pitch: "+16Hz", volume: "+10%")
        case "疑惑", "无语", "发呆":
            return SpeechProsody(rate: "-5%", pitch: "+0Hz", volume: "+0%")
        default:
            // 第三个版本: 更萌 (快速率+高音调+高音量)
            return SpeechProsody(rate: "+20%", pitch: "+20Hz", volume: "+10%")
        }
    }

    func stopSpeech() {
        speechRequestID = UUID()
        speechProcess?.terminate()
        speechProcess = nil
        ttsDaemonCompletion = nil
        if let data = try? JSONSerialization.data(withJSONObject: ["command": "cancel"]),
           let input = ttsDaemonInput {
            input.write(data + Data([0x0a]))
        }
        speechPlayer?.pause()
        speechPlayer = nil
        if let observer = speechEndObserver {
            NotificationCenter.default.removeObserver(observer)
            speechEndObserver = nil
        }
        if let observer = speechFailureObserver {
            NotificationCenter.default.removeObserver(observer)
            speechFailureObserver = nil
        }
        if let path = speechOutputPath {
            try? FileManager.default.removeItem(atPath: path)
            speechOutputPath = nil
        }
        speechSynthesizer.stopSpeaking(at: .immediate)
        stopTalkingMotion()
    }

    func startTalkingMotion() {
        // 识别会话可能在回复期间提前重建；只有已由 speak() 标记的回复语音可以在该窗口说话。
        guard !isVoiceChatListening || isReplySpeechActive else { return }
        let js = "window.__setMotion ? window.__setMotion('talk') : 0"
        webView.evaluateJavaScript(js, completionHandler: nil)
        handleJSEvent("TALK_DURING_SPEECH: talk")
    }

    func stopTalkingMotion() {
        isReplySpeechActive = false
        let js = "window.__stopTalkingMotion ? window.__stopTalkingMotion() : (window.__setMotion ? window.__setMotion('idle') : 0)"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // 只清理送入 TTS 的文本；气泡始终使用未经修改的原文。
    func cleanSpeechText(_ text: String) -> String {
        var cleaned = text

        // 先找短括号组，再用“脸部字符”计分，避免误删 （明天见） 之类正常内容。
        // 可选前后缀覆盖 ٩(...)۶、ヽ(...)ノ、～(...)～ 等常见颜文字外框。
        let kaomojiPattern = #"[~～〜-]*[٩ヽヾ╰]?[\s]*[\(（]([^\(\)（）\n]{1,20})[\)）][\s]*[۶ノﾉ╯]?[~～〜-]*"#
        let faceCharacters = CharacterSet(charactersIn: "^_^~～-vV><﹏◕◠‿≧≦∇¬°□ω∀•･・ﾟヮДдㅅ益▽△口皿╯╰ಠಥʘ´｀￣✿❀")
        if let regex = try? NSRegularExpression(pattern: kaomojiPattern) {
            let source = cleaned as NSString
            let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: source.length))
            for match in matches.reversed() {
                let content = source.substring(with: match.range(at: 1))
                let faceScore = content.unicodeScalars.reduce(0) {
                    $0 + (faceCharacters.contains($1) ? 1 : 0)
                }
                if faceScore >= 2 {
                    cleaned = (cleaned as NSString).replacingCharacters(in: match.range, with: " ")
                }
            }
        }

        // Foundation 的正则 Unicode 属性在不同 macOS SDK 上兼容性不一，逐 scalar
        // 删除 emoji 区段、变体选择符、ZWJ/keycap，以及指定装饰符号更可控。
        let decorative = CharacterSet(charactersIn: "★☆♪♫✿❀")
        let keptScalars = cleaned.unicodeScalars.filter { scalar in
            let value = scalar.value
            let isEmojiRange = (0x1F000...0x1FAFF).contains(value)
                || (0x2600...0x27BF).contains(value)
                || (0x1F1E6...0x1F1FF).contains(value)
            let isEmojiJoiner = value == 0xFE0F || value == 0x200D || value == 0x20E3
            return !isEmojiRange && !isEmojiJoiner && !decorative.contains(scalar)
        }
        cleaned = String(String.UnicodeScalarView(keptScalars))

        // 独立的连续波浪线属于装饰；单个 ASCII ~ 保留给自然文本。
        cleaned = cleaned.replacingOccurrences(
            of: #"[~～〜]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func containsSpeechContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    // 口型与真实语音强绑定；静音/无可读内容仅保留闭嘴的身体反馈。
    func speak(_ text: String, emotion: String? = nil, prosodyOverride: SpeechProsody? = nil) {
        guard !text.isEmpty else { return }
        stopSpeech()
        isReplySpeechActive = true
        let speechText = cleanSpeechText(text)
        guard containsSpeechContent(speechText) else {
            // 无可读内容 (纯表情/颜文字): 保留身体反馈，但无声音就不驱动嘴。
            showBubble(text)
            webView.evaluateJavaScript("window.__playSilentReplyMotion ? window.__playSilentReplyMotion() : 0", completionHandler: nil)
            isReplySpeechActive = false
            handleJSEvent("TTS_SKIP: no speakable text after cleaning")
            return
        }
        guard speechEnabled() else {
            // 语音开关关闭: 保留短身体反馈 + 气泡，但嘴保持关闭。
            showBubble(text)
            webView.evaluateJavaScript("window.__playSilentReplyMotion ? window.__playSilentReplyMotion() : 0", completionHandler: nil)
            isReplySpeechActive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.stopTalkingMotion()
            }
            handleJSEvent("TTS_MUTED: speech disabled, motion only")
            return
        }
        let voice = selectedVoice()
        if voice == "system" {
            speakWithSystem(speechText, emotion: emotion, displayText: text, prosodyOverride: prosodyOverride)
            return
        }

        guard let helper = ttsHelperPath() else {
            handleJSEvent("TTS_FALLBACK: helper not found")
            speakWithSystem(speechText, emotion: emotion, displayText: text, prosodyOverride: prosodyOverride)
            return
        }
        let requestID = UUID()
        let ttsStartedAt = Date()
        speechRequestID = requestID
        let output = "/tmp/whalepet_tts_\(requestID.uuidString).mp3"
        let params = prosodyOverride ?? prosody(for: emotion)
        let finishGeneration: (String, Bool, String) -> Void = { [weak self] responseID, ok, errorText in
            DispatchQueue.main.async {
                guard let self, self.speechRequestID == requestID else {
                    try? FileManager.default.removeItem(atPath: output)
                    return
                }
                guard responseID == requestID.uuidString else { return }
                self.ttsDaemonCompletion = nil
                guard ok, FileManager.default.fileExists(atPath: output) else {
                    self.handleJSEvent("TTS_FALLBACK: \(errorText.prefix(180))")
                    self.speakWithSystem(speechText, emotion: emotion, displayText: text)
                    return
                }
                let item = AVPlayerItem(url: URL(fileURLWithPath: output))
                self.speechPlayer = AVPlayer(playerItem: item)
                self.speechOutputPath = output
                // 等待时长就绪 (CMTime 异步加载): 用音频时长驱动打字机, 字音同步
                let duration = item.asset.duration
                var durationMs = 0.0
                if duration.isNumeric {
                    durationMs = CMTimeGetSeconds(duration) * 1000
                }
                self.speechEndObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, self.speechRequestID == requestID else { return }
                    self.speechPlayer = nil
                    if let observer = self.speechEndObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    self.speechEndObserver = nil
                    if let observer = self.speechFailureObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    self.speechFailureObserver = nil
                    self.speechOutputPath = nil
                    try? FileManager.default.removeItem(atPath: output)
                    self.stopTalkingMotion()
                }
                self.speechFailureObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] note in
                    guard let self, self.speechRequestID == requestID else { return }
                    self.handleJSEvent("TTS_PLAYBACK_ERROR: \(String(describing: note.userInfo))")
                    self.stopSpeech()
                }
                // 只在真实音频开始播放时启动口型，避免 TTS 网络生成期间空口。
                self.startTalkingMotion()
                self.speechPlayer?.play()
                // 字音同步: 语音开始的同时启动打字机, 文字按音频时长均匀打出
                let typeJs: String
                if durationMs > 0 {
                    typeJs = "window.__showBubble ? window.__showBubble('\(self.jsEscapedString(text))', \(Int(durationMs))) : 0"
                } else {
                    typeJs = "window.__showBubble ? window.__showBubble('\(self.jsEscapedString(text))', 0) : 0"
                }
                self.webView.evaluateJavaScript(typeJs, completionHandler: nil)
                self.handleJSEvent("SPEAK_CLOUD: ready=\(Int(Date().timeIntervalSince(ttsStartedAt) * 1000))ms backend=\(self.ttsBackend(for: voice)) voice=\(voice) emotion=\(emotion ?? "default") rate=\(params.rate) pitchST=\(self.volcPitchSemitones()) volume=\(params.volume) chars=\(speechText.count) dur=\(Int(durationMs))ms")
            }
        }
        do {
            try startTTSDaemonIfNeeded(helper: helper)
            ttsDaemonCompletion = finishGeneration
            let request: [String: String] = [
                "id": requestID.uuidString, "text": speechText, "voice": voice,
                "rate": params.rate, "pitch": params.pitch, "volume": params.volume,
                "backend": ttsBackend(for: voice),
                "pitchST": String(volcPitchSemitones()),
                "output": output
            ]
            let requestData = try JSONSerialization.data(withJSONObject: request)
            ttsDaemonInput?.write(requestData + Data([0x0a]))
            let backend = ttsBackend(for: voice)
            handleJSEvent("TTS_GENERATE: backend=\(backend) voice=\(voice) emotion=\(emotion ?? "default")")
            // 火山双向流式实测 1.0~1.5s (含首包); edge-tts 网络合成可能 3-6s。
            // 阈值别卡太紧: 之前 2.5s, 网络稍抖就超时降级, 用户听到的是无感情的本地
            // Tingting 而不是有感情的火山音色。降到系统 TTS 的代价比多等 1 秒大得多。
            let watchdogSeconds: Double = backend == "volc" ? 4.0 : 6.0
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, self.speechRequestID == requestID, self.ttsDaemonCompletion != nil,
                      self.speechPlayer == nil || self.speechPlayer?.timeControlStatus != .playing else { return }
                self.handleJSEvent("TTS_TIMEOUT: \(backend) >\(watchdogSeconds)s, fallback to system TTS")
                self.ttsDaemonCompletion = nil
                if let data = try? JSONSerialization.data(withJSONObject: ["command": "cancel"]),
                   let input = self.ttsDaemonInput { input.write(data + Data([0x0a])) }
                self.speakWithSystem(speechText, emotion: emotion, displayText: text)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + watchdogSeconds, execute: watchdog)
            // 音频就绪后取消看门狗
            DispatchQueue.main.asyncAfter(deadline: .now() + watchdogSeconds + 0.5) { [weak self] in
                if self?.speechRequestID == requestID, self?.speechPlayer != nil {
                    watchdog.cancel()
                }
            }
        } catch {
            handleJSEvent("TTS_FALLBACK: process launch failed: \(error.localizedDescription)")
            speakWithSystem(speechText, emotion: emotion, displayText: text)
        }
    }

    func startTTSDaemonIfNeeded(helper: String) throws {
        if let process = ttsDaemonProcess, process.isRunning, ttsDaemonInput != nil { return }
        // 重启前清空解析缓冲，避免旧进程残留的半行 JSON 与新进程首行拼接
        ttsDaemonBuffer.removeAll(keepingCapacity: true)
        let process = Process()
        let environment = ProcessInfo.processInfo.environment
        // venv 不能在 /tmp —— 系统会定期清理 /tmp, 把 pyvenv.cfg 删掉后 venv 就废了
        // (python 不再把 site-packages 加进 sys.path, import websockets 直接失败,
        //  volc TTS 静默降级到无感情的本地 Tingting)。放 Application Support 才持久。
        let defaultVenv = "\(NSHomeDirectory())/Library/Application Support/WhalePet/ttsvenv"
        let venv = environment["TTS_VENV"] ?? defaultVenv
        let venvPython = venv + "/bin/python"
        // venv 健全性: 有 pyvenv.cfg 才算真 venv。缺了说明目录被系统清理过,
        // python 不会读它的 site-packages, 硬用只会 import 失败 → 直接退回系统 python 也别
        // 假装是 venv。这次先走本地 TTS, 下次装好 venv 自动恢复。
        let cfgOK = FileManager.default.fileExists(atPath: venv + "/pyvenv.cfg")
        if !cfgOK {
            handleJSEvent("TTS_VENV_BROKEN: \(venv) 缺 pyvenv.cfg (被系统清理过), 本次降级")
        }
        let usableVenvPython = cfgOK && FileManager.default.isExecutableFile(atPath: venvPython)
        process.executableURL = URL(fileURLWithPath: usableVenvPython ? venvPython : "/usr/bin/python3")
        process.arguments = [helper, "--daemon"]
        var childEnvironment = environment
        childEnvironment["TTS_VENV"] = venv
        if let proxy = environment["TTS_PROXY"], !proxy.isEmpty {
            childEnvironment["http_proxy"] = proxy
            childEnvironment["https_proxy"] = proxy
        }
        process.environment = childEnvironment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consumeTTSDaemonOutput(data) }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.ttsDaemonProcess === process else { return }
                self.ttsDaemonProcess = nil
                self.ttsDaemonInput = nil
                self.ttsDaemonOutput = nil
                self.ttsDaemonBuffer.removeAll(keepingCapacity: true)
                let completion = self.ttsDaemonCompletion
                self.ttsDaemonCompletion = nil
                let reason = process.terminationReason == .exit ? "exit" : "signal"
                completion?(self.speechRequestID.uuidString, false,
                            "helper daemon exited reason=\(reason) status=\(process.terminationStatus)")
            }
        }
        try process.run()
        ttsDaemonProcess = process
        ttsDaemonInput = input.fileHandleForWriting
        ttsDaemonOutput = output.fileHandleForReading
    }

    func consumeTTSDaemonOutput(_ data: Data) {
        ttsDaemonBuffer.append(data)
        while let newline = ttsDaemonBuffer.firstIndex(of: 0x0a) {
            let line = ttsDaemonBuffer.prefix(upTo: newline)
            ttsDaemonBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String else { continue }
            let ok = object["ok"] as? Bool ?? false
            let error = object["error"] as? String ?? "unknown error"
            ttsDaemonCompletion?(id, ok, error)
        }
    }

    func ttsHelperPath() -> String? {
        let executableDir = (Bundle.main.executablePath! as NSString).deletingLastPathComponent
        let candidates = [
            Bundle.main.path(forResource: "whalepet_tts", ofType: "py"),
            RESOURCE_DIR + "/whalepet_tts.py",
            executableDir + "/whalepet_tts.py",
            FileManager.default.currentDirectoryPath + "/whalepet_tts.py"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func speakWithSystem(_ text: String, emotion: String?, displayText: String? = nil,
                         prosodyOverride: SpeechProsody? = nil) {
        let speechText = cleanSpeechText(text)
        let bubbleText = displayText ?? text
        guard containsSpeechContent(speechText) else {
            showBubble(bubbleText)
            handleJSEvent("TTS_SKIP: no speakable text after cleaning")
            return
        }
        let utterance = AVSpeechUtterance(string: speechText)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-CN" }
        let names = ["Ting-Ting", "Tingting", "Meijia"]
        utterance.voice = voices.first { voice in
            names.contains { voice.name.localizedCaseInsensitiveContains($0) }
        } ?? voices.first ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let params = prosodyOverride ?? prosody(for: emotion)
        let ratePercent = Float(params.rate.dropLast()) ?? 0
        utterance.rate = min(0.65, max(0.35, 0.5 * (1 + ratePercent / 100)))
        let volumePercent = Float(params.volume.dropLast()) ?? 0
        utterance.volume = min(1, max(0, 0.9 * (1 + volumePercent / 100)))
        let pitchHz = Float(params.pitch.dropLast(2)) ?? 0
        utterance.pitchMultiplier = min(2, max(0.5, 1 + pitchHz / 50))
        startTalkingMotion()
        speechSynthesizer.speak(utterance)
        let voiceName = utterance.voice?.name ?? "zh-CN default"
        handleJSEvent("SPEAK_SYSTEM: voice=\(voiceName) emotion=\(emotion ?? "default") chars=\(speechText.count)")
        // 系统语音: 估算时长驱动打字机 (字音同步), 约 200ms/字 (rate 0.5 基准)
        let estMsPerChar = 200.0 * 100.0 / (100.0 + Double(ratePercent))
        let estDuration = Double(Array(speechText).count) * estMsPerChar
        let typeJs = "window.__showBubble ? window.__showBubble('\(self.jsEscapedString(bubbleText))', \(Int(estDuration))) : 0"
        self.webView.evaluateJavaScript(typeJs, completionHandler: nil)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        stopTalkingMotion()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        stopTalkingMotion()
    }

    // 读 ~/.hermes/.env 里的 API_SERVER_KEY
    func readGatewayKey() -> String? {
        let path = "\(NSHomeDirectory())/.hermes/.env"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("API_SERVER_KEY=") {
                let val = trimmed.dropFirst("API_SERVER_KEY=".count)
                if !val.isEmpty { return String(val) }
            }
        }
        return nil
    }

    /// 给外部 baseURL 找一个能用的 key, 避免用户手动复制粘贴。
    /// 权威来源是 ~/.hermes/config.yaml: 里面每个 provider 都写了 base_url + key_env,
    /// 按主机名匹配最可靠; 匹配不到再退回 .env 的 OPENAI_API_KEY。
    func readReusableKey(for baseURL: String) -> String? {
        guard let host = URL(string: baseURL)?.host?.lowercased(), !host.isEmpty else { return nil }

        // 1) config.yaml: base_url 主机名 == host → 取该条目的 key_env (或 api_key)
        if let yaml = try? String(contentsOfFile: "\(NSHomeDirectory())/.hermes/config.yaml", encoding: .utf8) {
            let lines = yaml.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("base_url:") else { continue }
                let raw = t.dropFirst("base_url:".count).trimmingCharacters(in: .whitespaces)
                let url = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard let h = URL(string: url)?.host?.lowercased(), h == host else { continue }
                // 同一 provider 块内往后找 key_env / api_key
                for j in (i + 1)..<min(i + 8, lines.count) {
                    let n = lines[j].trimmingCharacters(in: .whitespaces)
                    if n.hasPrefix("base_url:") || n.hasPrefix("- ") { break }
                    if n.hasPrefix("key_env:") {
                        let name = n.dropFirst("key_env:".count).trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if let k = envValue(named: name), !k.isEmpty { return k }
                    }
                    if n.hasPrefix("api_key:") {
                        let v = n.dropFirst("api_key:".count).trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !v.isEmpty { return v }
                    }
                }
            }
        }

        // 2) .env: 配对的 XXX_BASE_URL 主机名相同 → XXX_API_KEY
        let env = readDotEnv()
        for (k, v) in env where k.hasSuffix("_BASE_URL") {
            guard let h = URL(string: v)?.host?.lowercased(), h == host else { continue }
            if let key = env[k.replacingOccurrences(of: "_BASE_URL", with: "_API_KEY")], !key.isEmpty {
                return key
            }
        }
        // 3) 兜底: 只有本机回环地址才复用通用 key, 防止把 key 发给陌生域名
        let isLocal = host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
        if isLocal, let key = env["OPENAI_API_KEY"], !key.isEmpty { return key }
        return nil
    }

    /// 按变量名从 ~/.hermes/.env 取单个值 (config.yaml 的 key_env 指向它)
    func envValue(named name: String) -> String? {
        return readDotEnv()[name]
    }

    /// 读 ~/.hermes/.env 成字典 (忽略注释与空值, 去掉成对引号)
    func readDotEnv() -> [String: String] {
        var out: [String: String] = [:]
        guard let content = try? String(contentsOfFile: "\(NSHomeDirectory())/.hermes/.env", encoding: .utf8) else {
            return out
        }
        for line in content.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let k = String(t[t.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if !k.isEmpty, !v.isEmpty { out[k] = v }
        }
        return out
    }

    // 安全的 JS 字符串字面量编码 (处理换行/反斜杠/引号/Unicode 行分隔符)
    func jsEscapedString(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.append(ch)
            }
        }
        return out
    }

    // 页面里显示气泡
    func showBubble(_ text: String, durationMs: Int = 0, instant: Bool = false) {
        let js = "window.__showBubble ? window.__showBubble('\(jsEscapedString(text))', \(durationMs), \(instant ? "true" : "false")) : 0"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // ———— 设置 ————

    // 右键/菜单: 完整设置面板 (大小 + AI API + 提示词)
    @objc func openSettings() {
        markActivity()
        isInputOpen = true   // 设置面板打开 = 操作中
        if isVoiceChatListening { stopVoiceChatListener() }
        let cfg = loadConfig()
        let alert = NSAlert()
        alert.messageText = "⚙️ 桌宠设置"
        alert.informativeText = "大小倍率 + AI 接口配置"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        // 垂直排列的输入区
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 518))
        var y: CGFloat = 498

        func addLabel(_ text: String) {
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 0, y: y, width: 380, height: 16)
            box.addSubview(l)
            y -= 20
        }
        func addField(_ text: String, placeholder: String, width: CGFloat = 380) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: y - 22, width: width, height: 24))
            f.stringValue = text
            f.placeholderString = placeholder
            f.isSelectable = true   // 允许选中文本复制 (⌘C)
            box.addSubview(f)
            y -= 34
            return f
        }

        // 大小倍率
        addLabel("大小倍率 (当前 x\(currentScale))")
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: y - 22, width: 120, height: 26))
        for i in 1...5 { pop.addItem(withTitle: "x\(i)") }
        pop.selectItem(at: currentScale - 1)
        box.addSubview(pop)
        y -= 34

        let speakCheck = NSButton(checkboxWithTitle: "语音朗读", target: nil, action: nil)
        speakCheck.frame = NSRect(x: 0, y: y - 20, width: 160, height: 22)
        speakCheck.state = speechEnabled() ? .on : .off
        box.addSubview(speakCheck)
        y -= 32

        let wanderCheck = NSButton(checkboxWithTitle: "自主移动", target: nil, action: nil)
        wanderCheck.frame = NSRect(x: 0, y: y - 20, width: 160, height: 22)
        wanderCheck.state = wanderEnabled() ? .on : .off
        box.addSubview(wanderCheck)
        y -= 32

        let voiceChatCheck = NSButton(checkboxWithTitle: "语音对话", target: nil, action: nil)
        voiceChatCheck.frame = NSRect(x: 0, y: y - 20, width: 160, height: 22)
        voiceChatCheck.state = voiceChatEnabled() ? .on : .off
        box.addSubview(voiceChatCheck)
        y -= 32

        addLabel("语音音色")
        let voicePop = NSPopUpButton(frame: NSRect(x: 0, y: y - 22, width: 200, height: 26))
        for choice in edgeVoiceChoices { voicePop.addItem(withTitle: choice.title) }
        let savedVoice = selectedVoice()
        voicePop.selectItem(at: edgeVoiceChoices.firstIndex { $0.id == savedVoice } ?? 0)
        box.addSubview(voicePop)
        y -= 34

        // AI API
        addLabel("API 地址 (留空 = 内置 Hermes)")
        let urlField = addField(cfg.apiBaseURL, placeholder: "http://127.0.0.1:8642/v1 或 https://api.openai.com/v1")

        addLabel("API Key (留空 = 不鉴权)")
        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: y - 22, width: 380, height: 24))
        keyField.stringValue = cfg.apiKey
        keyField.placeholderString = "sk-..."
        box.addSubview(keyField)
        y -= 34

        addLabel("模型名")
        let modelField = addField(cfg.model, placeholder: "hermes-token / grok / deepseek-chat")

        addLabel("会话空闲超时（分钟，0=每条新会话）")
        let timeoutField = addField(String(cfg.sessionIdleTimeoutMinutes), placeholder: "30")

        addLabel("角色提示词 (人设/语气)")
        let promptField = NSTextView(frame: NSRect(x: 0, y: y - 88, width: 380, height: 88))
        promptField.string = cfg.systemPrompt
        promptField.font = NSFont.systemFont(ofSize: 12)
        promptField.isEditable = true
        promptField.isSelectable = true
        promptField.autoresizingMask = [.width]
        promptField.drawsBackground = true
        box.addSubview(promptField)

        alert.accessoryView = box
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            self.isInputOpen = false   // 设置面板关闭
            guard resp == .alertFirstButtonReturn else {
                if self.voiceChatEnabled() { self.startVoiceChatListener() }
                return
            }
            // 保存
            let scale = pop.indexOfSelectedItem + 1
            var cfg = self.loadConfig()
            cfg.apiBaseURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.apiKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.systemPrompt = promptField.string
            cfg.sessionIdleTimeoutMinutes = max(0, Int(timeoutField.stringValue) ?? 30)
            self.saveConfig(cfg)
            UserDefaults.standard.set(speakCheck.state == .on, forKey: "pet_speak")
            UserDefaults.standard.set(wanderCheck.state == .on, forKey: "pet_wander")
            UserDefaults.standard.set(voiceChatCheck.state == .on, forKey: "pet_voiceChat")
            if voiceChatCheck.state == .on {
                self.startVoiceChatListener()
            } else {
                self.stopVoiceChatListener()
            }
            let voiceIndex = max(0, voicePop.indexOfSelectedItem)
            UserDefaults.standard.set(self.edgeVoiceChoices[voiceIndex].id, forKey: "pet_voice")
            if speakCheck.state != .on { self.stopSpeech() }
            self.handleJSEvent("SETTINGS_SAVED scale=x\(scale) voice=\(self.edgeVoiceChoices[voiceIndex].id) wander=\(wanderCheck.state == .on) voiceChat=\(voiceChatCheck.state == .on)")
            // sheet 关闭后再改窗口尺寸 (sheet 期间改 frame 会导致窗口消失)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // 确保窗口可见
                self.window.orderFrontRegardless()
                self.applyScale(scale)
                self.showBubble("✅ 设置已保存")
            }
        }
    }

    // 应用大小倍率: 窗口 + WebView + 页面 canvas 同步缩放
    func applyScale(_ scale: Int) {
        guard scale >= 1 && scale <= 5 else { return }
        currentScale = scale
        UserDefaults.standard.set(scale, forKey: "pet_scale")  // 持久化
        handleJSEvent("APPLY_SCALE: x\(scale)")
        let js = "window.__getTightSize ? window.__getTightSize(\(scale)) : null"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self, self.currentScale == scale else { return }
            var size: CGSize?
            if let d = result as? [String: Any],
               let width = (d["width"] as? NSNumber)?.doubleValue,
               let height = (d["height"] as? NSNumber)?.doubleValue {
                size = CGSize(width: width, height: height)
            }
            if let error { self.handleJSEvent("TIGHT_SIZE_ERROR: \(error.localizedDescription)") }
            let fallback = CGSize(width: self.baseSize.width * CGFloat(scale),
                                  height: self.baseSize.height * CGFloat(scale))
            self.setWindowSize(size ?? fallback, scale: scale)
        }
    }

    private func setWindowSize(_ requested: CGSize, scale: Int) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)

        var w = requested.width
        var h = requested.height
        // 超屏幕可见区域则 clamp (x5 高度可能超过 visibleFrame)
        w = min(w, screen.width)
        h = min(h, screen.height)

        // 右下角定位 (窗口完整在屏幕内)
        let x = screen.maxX - w - 20
        let y = screen.minY + 20
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: false)
        handleJSEvent("FRAME_SET: tight x\(scale) \(Int(w))x\(Int(h)) at \(Int(x)),\(Int(y)) screen=\(Int(screen.width))x\(Int(screen.height))")
        // autoresizing 会同步大部分布局；强制 layout 后让 JS 从 innerWidth/innerHeight
        // 读取实际 viewport。再补一次下一轮调用，覆盖 WebKit 延迟提交 viewport 的情况。
        window.contentView?.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        notifyPageResize(requestedWidth: w, requestedHeight: h, delay: 0)
        notifyPageResize(requestedWidth: w, requestedHeight: h, delay: 0.35)
    }

    private func notifyPageResize(requestedWidth w: CGFloat, requestedHeight h: CGFloat, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.window.contentView?.layoutSubtreeIfNeeded()
            self.webView.layoutSubtreeIfNeeded()
            let actual = self.webView.bounds.size
            self.handleJSEvent("RESIZE_NOTIFY: requested=\(Int(w))x\(Int(h)) webView=\(Int(actual.width))x\(Int(actual.height)) delay=\(delay)")
            let js = "window.__resize && window.__resize(\(w), \(h))"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    private func debugCommandDirectory() -> String? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = appSupport.appendingPathComponent("WhalePet/debug", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return directory.path
        } catch {
            handleJSEvent("DEBUG_DIR_ERROR: \(error.localizedDescription)")
            return nil
        }
    }

    // 调试: 监听用户私有 0700 目录中的命令文件 (便于自动化验证)
    var debugTimer: Timer?
    func startDebugScaleWatcher() {
        guard let debugDirectory = debugCommandDirectory() else { return }
        // 性能: 原 0.5s 一次, 每轮 5 次文件读取 (存在性检查 + 内容) —— 空闲时也在
        // 持续唤醒主线程。调试命令是人在敲, 1.5s 延迟完全够用, 唤醒频率降到 1/3。
        debugTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let emoPath = debugDirectory + "/pet_emotion_cmd"
            if let emoTxt = try? String(contentsOfFile: emoPath, encoding: .utf8) {
                let emo = emoTxt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !emo.isEmpty {
                    try? FileManager.default.removeItem(atPath: emoPath)
                    self.webView.callAsyncJavaScript(
                        "return window.__setEmotion ? window.__setEmotion(emotion) : false",
                        arguments: ["emotion": emo], in: nil, in: .page,
                        completionHandler: nil)
                    self.handleJSEvent("DEBUG_EMOTION: \(emo)")
                }
            }
            let motionPath = debugDirectory + "/pet_motion_cmd"
            if let motionTxt = try? String(contentsOfFile: motionPath, encoding: .utf8) {
                let motionGroup = motionTxt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !motionGroup.isEmpty {
                    try? FileManager.default.removeItem(atPath: motionPath)
                    self.webView.callAsyncJavaScript(
                        "return window.__setMotion ? window.__setMotion(group) : false",
                        arguments: ["group": motionGroup], in: nil, in: .page,
                        completionHandler: nil)
                    self.handleJSEvent("DEBUG_MOTION: \(motionGroup)")
                }
            }
            let statsPath = debugDirectory + "/pet_stats_cmd"
            if let statsTxt = try? String(contentsOfFile: statsPath, encoding: .utf8) {
                let groupArg = statsTxt.trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(atPath: statsPath)
                self.handleJSEvent("MOTION_TEST_START: \(groupArg)")
                self.webView.callAsyncJavaScript(
                    "return window.__motionTest ? window.__motionTest(group) : false",
                    arguments: ["group": groupArg], in: nil, in: .page,
                    completionHandler: nil)
            }
            let movePath = debugDirectory + "/pet_move_cmd"
            if let moveTxt = try? String(contentsOfFile: movePath, encoding: .utf8) {
                let moveVal = moveTxt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !moveVal.isEmpty, let target = self.moveTarget(fromTag: moveVal) {
                    try? FileManager.default.removeItem(atPath: movePath)
                    self.moveWindow(xPercent: target.0, yPercent: target.1, reason: "DEBUG_MOVE", duration: 2.6)
                }
            }
            let path = debugDirectory + "/pet_scale_cmd"
            guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let n = Int(trimmed), n >= 1, n <= 5 else { return }
            if n != self.currentScale {
                try? FileManager.default.removeItem(atPath: path)
                self.applyScale(n)
            }
        }
    }

    // JS -> Swift 消息
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "hermes" {
            if let body = message.body as? String {
                // 处理 JS 发来的消息 (如点击了鲸鱼娘)
                handleJSEvent(body)
                if body == "READY" { applyScale(currentScale) }
            } else if let body = message.body as? [String: Any], body["type"] as? String == "charRect",
                      let x = (body["x"] as? NSNumber)?.doubleValue,
                      let y = (body["y"] as? NSNumber)?.doubleValue,
                      let w = (body["w"] as? NSNumber)?.doubleValue,
                      let h = (body["h"] as? NSNumber)?.doubleValue {
                dragView?.characterRect = CGRect(x: x, y: y, width: w, height: h)
                // 只在尺寸真的变了才记日志: resize 期间通知很密集, 每次写盘没必要。
                let rect = CGRect(x: x, y: y, width: w, height: h)
                if self.lastLoggedCharRect != rect {
                    self.lastLoggedCharRect = rect
                    handleJSEvent("CHAR_RECT: \(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))")
                }
            }
        }
    }

    func handleJSEvent(_ event: String) {
        let line = "[\(Date())] \(event)\n"
        guard let data = line.data(using: .utf8) else { return }
        webLogQueue.async { [weak self] in
            guard let self else { return }
            // 日志放 ~/Library/Logs/WhalePet (macOS 标准日志位, 不受 /tmp 定期清理影响)
            let logDir = NSString(string: "~/Library/Logs/WhalePet").expandingTildeInPath
            let path = (logDir as NSString).appendingPathComponent("webview.log")
            let fm = FileManager.default
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            // 性能: 原来每写一行都要 attributesOfItem (一次 stat 系统调用), 高频
            // 诊断日志下这本身就成了开销。改成内存累加, 只在超过阈值时 stat 一次做校准。
            if self.webLogBytes == nil {
                let size = ((try? fm.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0
                self.webLogBytes = size
            }
            self.webLogBytes! += UInt64(data.count)
            if self.webLogBytes! > 5 * 1024 * 1024 {
                try? self.webLogHandle?.close()
                self.webLogHandle = nil
                let first = path + ".1"
                try? fm.removeItem(atPath: first)
                if fm.fileExists(atPath: path) { try? fm.moveItem(atPath: path, toPath: first) }
                self.webLogBytes = 0
            }
            if self.webLogHandle == nil {
                if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
                self.webLogHandle = FileHandle(forWritingAtPath: path)
                _ = try? self.webLogHandle?.seekToEnd()
            }
            try? self.webLogHandle?.write(contentsOf: data)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面加载完成
    }

    // 启动 8 秒后自动触发一个动作 (验证 motion API 有效 + 演示动画)
    // 必须走 __setMotion, 否则会绕过"说话锁定"把 talk 动作顶掉
    func autoDemoMotion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let groups = ["selfie", "ketchup", "bubble", "splash", "openLid", "aidale"]
            let g = groups[Int.random(in: 0..<groups.count)]
            let js = "try { window.__setMotion ? window.__setMotion('\(g)') : window.__petModel.motion('\(g)', 0, 3); 'ok' } catch(e) { 'err:' + e.message }"
            self.webView.evaluateJavaScript(js) { result, err in
                // 只在失败时记日志: 成功日志每 25s 一条纯属噪音, 还会走一遍
                // JS->Swift->磁盘全链路, 对排查没有价值。
                if err != nil || (result as? String)?.hasPrefix("err") == true {
                    self.handleJSEvent("AUTO_MOTION_FAIL: \(g) -> \(result ?? "nil") err=\(String(describing: err))")
                }
            }
            // 每 25 秒自动换动作 (演示)
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                self.autoDemoMotion()
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
