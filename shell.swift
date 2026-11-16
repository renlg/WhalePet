// 鲸鱼娘 Live2D 桌宠 - macOS 透明壳 (Swift + WebView)
// 加载本地 Live2D 页面, 透明无边框置顶窗口, 连 Hermes gateway 对话
import Cocoa
import WebKit
import Network
import AVFoundation

// 资源根目录: .app 内 Resources (打包后) 或开发目录 (调试)
let RESOURCE_DIR: String = {
    if let res = Bundle.main.resourcePath {
        return res  // .app/Contents/Resources
    }
    return "/tmp/whale_pet_live2d"
}()
let SERVER_PORT: UInt16 = 8977

// 简单 HTTP 静态文件 server (Network.framework)
// 用于给 WebView 提供本地 Live2D 页面, 避免 file:// CORS 限制
final class LocalHTTPServer {
    private var listener: NWListener?
    private let root: String
    private let port: UInt16

    init(root: String, port: UInt16) {
        self.root = root
        self.port = port
    }

    func start() -> Bool {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("HTTP server listen failed: \(error)")
            return false
        }
        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            self?.handle(conn)
        }
        listener?.start(queue: .global(qos: .userInitiated))
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
    var clickAction: (() -> Void)?
    var rightClickMenu: NSMenu?
    var characterRect: CGRect?  // 左上角原点、CSS 像素；nil 时兼容旧行为
    private var dragStart: NSPoint?
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart = dragStart else { return }
        let cur = event.locationInWindow
        // 超过阈值判定为拖动, 交给系统原生拖动 (丝滑无晃动)
        if !isDragging && (abs(cur.x - dragStart.x) + abs(cur.y - dragStart.y) > 4) {
            isDragging = true
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            let p = convert(event.locationInWindow, from: nil)
            let cssPoint = CGPoint(x: p.x, y: bounds.height - p.y)
            if characterRect?.contains(cssPoint) ?? true {
                clickAction?()
            }
        }
        dragStart = nil
        isDragging = false
    }

    // 右键弹菜单 (含关闭)
    override func rightMouseDown(with event: NSEvent) {
        if let menu = rightClickMenu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: PetWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem?
    var httpServer: LocalHTTPServer?
    // 尺寸设置: x1~x5, 当前为 x3 (400x560)
    var currentScale: Int = 3
    let baseSize = CGSize(width: 400.0 / 3.0, height: 560.0 / 3.0)  // x1 基准 ≈133x187
    weak var dragView: DragView?
    let speechSynthesizer = AVSpeechSynthesizer()
    var speechPlayer: AVPlayer?
    var speechProcess: Process?
    var speechRequestID = UUID()
    var speechOutputPath: String?
    var speechEndObserver: NSObjectProtocol?

    struct SpeechProsody {
        let rate: String
        let pitch: String
        let volume: String
    }

    let edgeVoiceChoices: [(title: String, id: String)] = [
        ("晓伊·萝莉(更萌)", "zh-CN-XiaoyiNeural"),
        ("晓晓·温暖", "zh-CN-XiaoxiaoNeural"),
        ("云夏·可爱男声", "zh-CN-YunxiaNeural"),
        ("系统默认", "system")
    ]

    // ———— AI 配置 (UserDefaults 持久化) ————
    // apiBaseURL 为空 = 用内置 Hermes gateway
    struct AIConfig {
        var apiBaseURL: String   // 例: http://127.0.0.1:8642/v1
        var apiKey: String
        var model: String
        var systemPrompt: String
    }

    func loadConfig() -> AIConfig {
        let d = UserDefaults.standard
        return AIConfig(
            apiBaseURL: d.string(forKey: "pet_apiBaseURL") ?? "",
            apiKey: d.string(forKey: "pet_apiKey") ?? "",
            model: d.string(forKey: "pet_model") ?? "grok",
            systemPrompt: d.string(forKey: "pet_systemPrompt") ?? "你是一只可爱的鲸鱼娘桌宠, 用简短可爱的语气回答, 不超过80字, 可以带颜文字。"
        )
    }

    func saveConfig(_ c: AIConfig) {
        let d = UserDefaults.standard
        d.set(c.apiBaseURL, forKey: "pet_apiBaseURL")
        d.set(c.apiKey, forKey: "pet_apiKey")
        d.set(c.model, forKey: "pet_model")
        d.set(c.systemPrompt, forKey: "pet_systemPrompt")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        clickView.clickAction = { [weak self] in
            self?.startChat()  // 单击 = 对话
        }
        // 右键菜单
        let ctxMenu = NSMenu()
        ctxMenu.addItem(NSMenuItem(title: "🎬 播放动作", action: #selector(playMotion), keyEquivalent: ""))
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

        // 状态栏
        setupStatusBar()
        autoDemoMotion()

        // 点击穿透: 只挡鲸鱼娘所在区域 (页面会通过 hermes handler 通知实际位置)
        // 简化: 整个窗口可点击, 点击后触发动作/对话
    }

    func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐳"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "🎬 播放动作", action: #selector(playMotion), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "⚙️ 设置大小", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "回到右下角", action: #selector(resetPos), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc func playMotion() {
        // 通过 JS 触发随机动作 (测试/菜单触发)
        let groups = ["selfie", "ketchup", "bubble", "splash", "openLid", "aidale"]
        let g = groups[Int.random(in: 0..<groups.count)]
        let js = "try { window.__petModel.motion('\(g)', 0, 3); 'ok' } catch(e) { 'err:' + e.message }"
        webView.evaluateJavaScript(js) { result, err in
            self.handleJSEvent("MENU_MOTION: \(g) -> \(result ?? "nil") err=\(String(describing: err))")
        }
    }

    @objc func resetPos() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width - 20, y: visible.minY + 20))
        }
    }

    // ———— Hermes 对话 ————

    // 单击 = 对话: 弹输入框
    func startChat() {
        playMotion()  // 顺便触发个动作
        let alert = NSAlert()
        alert.messageText = "🐳 鲸鱼娘"
        alert.informativeText = "想对我说什么？"
        alert.addButton(withTitle: "发送")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "输入你想说的话..."
        alert.accessoryView = input
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            self.askHermes(text)
        }
    }

    // 调 AI (自定义 API 优先, 否则 Hermes gateway)
    func askHermes(_ text: String) {
        let cfg = loadConfig()
        // 决定 baseURL / key / model
        var baseURL = cfg.apiBaseURL
        var apiKey = cfg.apiKey
        var model = cfg.model
        if baseURL.isEmpty {
            // 内置 Hermes gateway
            guard let key = readGatewayKey() else {
                showBubble("⚠️ 未找到 API_SERVER_KEY (检查 ~/.hermes/.env)")
                return
            }
            baseURL = "http://127.0.0.1:8642/v1"
            apiKey = key
            if model.isEmpty { model = "grok" }
        }
        // 规范化 baseURL: 去掉末尾 /
        if baseURL.hasSuffix("/") { baseURL = String(baseURL.dropLast()) }
        guard let url = URL(string: baseURL + "/chat/completions") else {
            showBubble("⚠️ API 地址无效: \(baseURL)")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let systemPrompt = cfg.systemPrompt.isEmpty ? "你是一只可爱的鲸鱼娘桌宠, 用简短可爱的语气回答, 不超过80字, 可以带颜文字。" : cfg.systemPrompt
        let fullPrompt = systemPrompt + "\n\n【情绪/动作协议】回复时优先调用工具：set_emotion 设置情绪（可选：开心、悲伤、生气、害羞、惊讶、疑惑、疲惫、调皮、无语、心动、星星眼、爱心眼、晕、哭、发呆），play_motion 播放身体动作（可选：待机、撒娇、自拍、简单自拍、番茄酱、开盖、吹泡泡、喷水）。如果当前环境无法调用工具，则改用文本标签格式：回复以 [情绪词] 开头（如 [开心]），需要动作时在任意位置加 [动作:xxx]（如 [动作:自拍]）。正文只写简短可爱的中文，不要输出工具名或标签之外的内容。例如：[开心][动作:自拍] 今天好开心呀~"
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
                                "enum": ["待机", "撒娇", "自拍", "简单自拍", "番茄酱", "开盖", "吹泡泡", "喷水"]
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
                                "enum": ["开心", "悲伤", "生气", "害羞", "惊讶", "疑惑", "疲惫", "调皮", "无语", "心动", "星星眼", "爱心眼", "晕", "哭", "发呆"]
                            ]
                        ],
                        "required": ["emotion"],
                        "additionalProperties": false
                    ] as [String: Any]
                ] as [String: Any]
            ]
        ]
        let body: [String: Any] = [
            "model": model.isEmpty ? "grok" : model,
            "messages": [
                ["role": "system", "content": fullPrompt],
                ["role": "user", "content": text]
            ],
            "tools": tools,
            "tool_choice": "auto",
            "max_tokens": 300
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        showBubble("🐳 让我想想...")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let err {
                    self.showBubble("⚠️ 网络错误: \(err.localizedDescription)")
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
                // 标准 tools 响应中 content 允许为 null；工具调用和正文分别解析。
                var text = (msg["content"] as? String) ?? ""
                var emotion: String? = nil
                var motion: String? = nil
                let motionAliases = [
                    "idle": "idle", "待机": "idle",
                    "aidale": "aidale", "撒娇": "aidale",
                    "selfie": "selfie", "自拍": "selfie",
                    "selfiequick": "selfieQuick", "简单自拍": "selfieQuick", "快速自拍": "selfieQuick",
                    "ketchup": "ketchup", "番茄酱": "ketchup", "挤番茄酱": "ketchup",
                    "openlid": "openLid", "开盖": "openLid",
                    "bubble": "bubble", "吹泡泡": "bubble",
                    "splash": "splash", "喷水": "splash"
                ]
                let validEmotions: Set<String> = ["开心", "悲伤", "生气", "害羞", "惊讶", "疑惑", "疲惫", "调皮", "无语", "心动", "星星眼", "爱心眼", "晕", "哭", "发呆"]
                let toolCalls = msg["tool_calls"] as? [[String: Any]] ?? []
                for call in toolCalls {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          let arguments = function["arguments"] as? String else {
                        print("TOOL_CALL: malformed call \(call)")
                        continue
                    }
                    print("TOOL_CALL: \(name) \(arguments)")
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
                    default:
                        print("TOOL_RESULT: unsupported tool \(name)")
                    }
                }

                // 兼容不支持 tools 的旧/自定义接口：没有 tool_calls 时沿用标签取值；
                // 若已有 tool_calls 但正文误带标签，也会清除，避免显示或朗读工具语法。
                if let motionRegex = try? NSRegularExpression(pattern: #"[\[［]\s*(?:动作|motion)\s*[:：]\s*([^\]］]+?)\s*[\]］]"#, options: [.caseInsensitive]),
                   let match = motionRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   let valueRange = Range(match.range(at: 1), in: text) {
                    let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if toolCalls.isEmpty { motion = motionAliases[value.lowercased()] }
                    text = motionRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
                }
                // 动作标签可在最前面；先移除后，仍可识别紧随其后的情绪标签。
                if let emotionRegex = try? NSRegularExpression(pattern: #"^\s*[\[［]\s*([^\]］:：]{1,6}?)\s*[\]］]"#),
                   let match = emotionRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   let valueRange = Range(match.range(at: 1), in: text) {
                    let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if validEmotions.contains(value) {
                        if toolCalls.isEmpty { emotion = value }
                        text = emotionRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                    }
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let spaces = try? NSRegularExpression(pattern: #"[ \t]{2,}"#) {
                    text = spaces.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
                }
                // 即使模型只返回工具调用，也始终给气泡和语音一个可见文本。
                if text.isEmpty { text = "主人~" }
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
                if self.speechEnabled() {
                    self.showBubble("……")
                } else {
                    self.showBubble(text)
                }
                self.speak(text, emotion: emotion)
            }
        }.resume()
    }

    func speechEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pet_speak") == nil { return true }
        return defaults.bool(forKey: "pet_speak")
    }

    func selectedVoice() -> String {
        UserDefaults.standard.string(forKey: "pet_voice") ?? "zh-CN-XiaoyiNeural"
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
        speechPlayer?.pause()
        speechPlayer = nil
        if let observer = speechEndObserver {
            NotificationCenter.default.removeObserver(observer)
            speechEndObserver = nil
        }
        if let path = speechOutputPath {
            try? FileManager.default.removeItem(atPath: path)
            speechOutputPath = nil
        }
        speechSynthesizer.stopSpeaking(at: .immediate)
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

    func speak(_ text: String, emotion: String? = nil) {
        guard speechEnabled(), !text.isEmpty else { return }
        stopSpeech()
        let speechText = cleanSpeechText(text)
        guard containsSpeechContent(speechText) else {
            // 启用语音时调用方会先显示“……”，无可读内容时必须恢复完整气泡。
            showBubble(text)
            handleJSEvent("TTS_SKIP: no speakable text after cleaning")
            return
        }
        let voice = selectedVoice()
        if voice == "system" {
            speakWithSystem(speechText, emotion: emotion, displayText: text)
            return
        }

        guard let helper = ttsHelperPath() else {
            handleJSEvent("TTS_FALLBACK: helper not found")
            speakWithSystem(speechText, emotion: emotion, displayText: text)
            return
        }
        let requestID = UUID()
        speechRequestID = requestID
        let output = "/tmp/whalepet_tts_\(requestID.uuidString).mp3"
        let params = prosody(for: emotion)
        let process = Process()
        let environment = ProcessInfo.processInfo.environment
        let venv = environment["TTS_VENV"] ?? "/tmp/ttsvenv"
        let venvPython = venv + "/bin/python"
        process.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: venvPython) ? venvPython : "/usr/bin/python3")
        process.arguments = [helper, "--text", speechText, "--voice", voice,
                             "--rate", params.rate, "--pitch", params.pitch,
                             "--volume", params.volume, "--output", output]
        var childEnvironment = environment
        childEnvironment["TTS_VENV"] = venv
        if let proxy = environment["TTS_PROXY"], !proxy.isEmpty {
            childEnvironment["http_proxy"] = proxy
            childEnvironment["https_proxy"] = proxy
        }
        process.environment = childEnvironment
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] finished in
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self, self.speechRequestID == requestID else {
                    try? FileManager.default.removeItem(atPath: output)
                    return
                }
                self.speechProcess = nil
                guard finished.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: output) else {
                    self.handleJSEvent("TTS_FALLBACK: exit=\(finished.terminationStatus) \(errorText.prefix(180))")
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
                    self.speechOutputPath = nil
                    try? FileManager.default.removeItem(atPath: output)
                }
                self.speechPlayer?.play()
                // 字音同步: 语音开始的同时启动打字机, 文字按音频时长均匀打出
                let typeJs: String
                if durationMs > 0 {
                    typeJs = "window.__showBubble ? window.__showBubble('\(self.jsEscapedString(text))', \(Int(durationMs))) : 0"
                } else {
                    typeJs = "window.__showBubble ? window.__showBubble('\(self.jsEscapedString(text))', 0) : 0"
                }
                self.webView.evaluateJavaScript(typeJs, completionHandler: nil)
                self.handleJSEvent("SPEAK_EDGE: voice=\(voice) emotion=\(emotion ?? "default") rate=\(params.rate) pitch=\(params.pitch) volume=\(params.volume) chars=\(speechText.count) dur=\(Int(durationMs))ms")
            }
        }
        do {
            try process.run()
            speechProcess = process
            handleJSEvent("TTS_GENERATE: voice=\(voice) emotion=\(emotion ?? "default")")
        } catch {
            handleJSEvent("TTS_FALLBACK: process launch failed: \(error.localizedDescription)")
            speakWithSystem(speechText, emotion: emotion, displayText: text)
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

    func speakWithSystem(_ text: String, emotion: String?, displayText: String? = nil) {
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
        let params = prosody(for: emotion)
        let ratePercent = Float(params.rate.dropLast()) ?? 0
        utterance.rate = min(0.65, max(0.35, 0.5 * (1 + ratePercent / 100)))
        let volumePercent = Float(params.volume.dropLast()) ?? 0
        utterance.volume = min(1, max(0, 0.9 * (1 + volumePercent / 100)))
        let pitchHz = Float(params.pitch.dropLast(2)) ?? 0
        utterance.pitchMultiplier = min(2, max(0.5, 1 + pitchHz / 50))
        speechSynthesizer.speak(utterance)
        let voiceName = utterance.voice?.name ?? "zh-CN default"
        handleJSEvent("SPEAK_SYSTEM: voice=\(voiceName) emotion=\(emotion ?? "default") chars=\(speechText.count)")
        // 系统语音: 估算时长驱动打字机 (字音同步), 约 200ms/字 (rate 0.5 基准)
        let estMsPerChar = 200.0 * 100.0 / (100.0 + Double(ratePercent))
        let estDuration = Double(Array(speechText).count) * estMsPerChar
        let typeJs = "window.__showBubble ? window.__showBubble('\(self.jsEscapedString(bubbleText))', \(Int(estDuration))) : 0"
        self.webView.evaluateJavaScript(typeJs, completionHandler: nil)
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
    func showBubble(_ text: String) {
        let js = "window.__showBubble ? window.__showBubble('\(jsEscapedString(text))') : 0"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // ———— 设置 ————

    // 右键/菜单: 完整设置面板 (大小 + AI API + 提示词)
    @objc func openSettings() {
        let cfg = loadConfig()
        let alert = NSAlert()
        alert.messageText = "⚙️ 桌宠设置"
        alert.informativeText = "大小倍率 + AI 接口配置"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        // 垂直排列的输入区
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        var y: CGFloat = 380

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
        let modelField = addField(cfg.model, placeholder: "grok / gpt-4o / deepseek-chat")

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
            guard let self, resp == .alertFirstButtonReturn else { return }
            // 保存
            let scale = pop.indexOfSelectedItem + 1
            var cfg = self.loadConfig()
            cfg.apiBaseURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.apiKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.systemPrompt = promptField.string
            self.saveConfig(cfg)
            UserDefaults.standard.set(speakCheck.state == .on, forKey: "pet_speak")
            let voiceIndex = max(0, voicePop.indexOfSelectedItem)
            UserDefaults.standard.set(self.edgeVoiceChoices[voiceIndex].id, forKey: "pet_voice")
            if speakCheck.state != .on { self.stopSpeech() }
            self.handleJSEvent("SETTINGS_SAVED scale=x\(scale) voice=\(self.edgeVoiceChoices[voiceIndex].id)")
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

    // 调试: 监听 /tmp/pet_scale_cmd 文件, 内容为倍率数字 -> 应用 (便于自动化验证)
    var debugTimer: Timer?
    func startDebugScaleWatcher() {
        debugTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 调试: 监听 /tmp/pet_emotion_cmd 文件, 内容为情绪词 -> 触发 __setEmotion
            let emoPath = "/tmp/pet_emotion_cmd"
            if let emoTxt = try? String(contentsOfFile: emoPath, encoding: .utf8) {
                let emo = emoTxt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !emo.isEmpty {
                    try? FileManager.default.removeItem(atPath: emoPath)
                    let js = "window.__setEmotion ? window.__setEmotion('\(emo)') : 0"
                    self.webView.evaluateJavaScript(js, completionHandler: nil)
                    self.handleJSEvent("DEBUG_EMOTION: \(emo)")
                }
            }
            // 调试: 监听 /tmp/pet_motion_cmd 文件, 内容为动作组名 -> 触发 __setMotion
            let motionPath = "/tmp/pet_motion_cmd"
            if let motionTxt = try? String(contentsOfFile: motionPath, encoding: .utf8) {
                let motionGroup = motionTxt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !motionGroup.isEmpty {
                    try? FileManager.default.removeItem(atPath: motionPath)
                    let js = "window.__setMotion ? window.__setMotion('\(motionGroup)') : 0"
                    self.webView.evaluateJavaScript(js, completionHandler: nil)
                    self.handleJSEvent("DEBUG_MOTION: \(motionGroup)")
                }
            }
            let path = "/tmp/pet_scale_cmd"
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
                handleJSEvent("CHAR_RECT: \(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))")
            }
        }
    }

    func handleJSEvent(_ event: String) {
        // 写日志文件
        let line = "[\(Date())] \(event)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/whale_pet_live2d/webview.log"
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面加载完成
    }

    // 启动 8 秒后自动触发一个动作 (验证 motion API 有效 + 演示动画)
    func autoDemoMotion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let groups = ["selfie", "ketchup", "bubble", "splash", "openLid", "aidale"]
            let g = groups[Int.random(in: 0..<groups.count)]
            let js = "try { window.__petModel.motion('\(g)', 0, 3); 'ok' } catch(e) { 'err:' + e.message }"
            self.webView.evaluateJavaScript(js) { result, err in
                self.handleJSEvent("AUTO_MOTION: \(g) -> \(result ?? "nil") err=\(String(describing: err))")
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
