# WhalePet 鲸鱼娘桌宠

一个 macOS 桌面 Live2D 鲸鱼娘宠物（DeepSeek 娘），Swift + WKWebView + pixi-live2d 实现。

## 功能

- 🐳 **Live2D 真动画**：透明无边框窗口，右下角悬浮，8 组身体动作（自拍/撒娇/吹泡泡/番茄酱/开盖/喷水/待机）+ 44 个表情
- 💬 **AI 对话**：直连 Hermes gateway (8642) 或自定义 OpenAI 兼容 API
- 😊 **情绪驱动**：AI 通过标准 tools 调用（set_emotion / play_motion）或文本标签 `[开心][动作:自拍]` 控制表情和动作
- 🔤 **打字机气泡**：文字逐字显示，按语音时长同步（字音同步），最多 3 行自动滚动
- 🎀 **萝莉语音**：edge-tts 晓伊音色（更萌参数），按情绪调制语速/音调/音量，自动过滤颜文字/emoji
- ⚙️ **设置面板**：大小倍率 x1-x5、API 地址/Key/模型、提示词、语音开关/音色选择，UserDefaults 持久化
- 📦 **打包分发**：自包含 .app（ad-hoc 签名），可拷到其他 Mac

## 结构

```
shell.swift          # Swift 主程序 (窗口/HTTP server/设置/AI调用/TTS/调试watcher)
index.html           # Live2D 页面 (pixi-live2d, 气泡/表情/动作)
whalepet_tts.py      # edge-tts 语音助手
model/               # Live2D 模型 c_0120 (moc3/textures/expressions/motions)
vendor/              # pixi.js / live2dcubismcore / cubism4
```

## 运行

```bash
# 开发运行
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk -O shell.swift -o WhalePetL2D
./WhalePetL2D

# 打包
mkdir -p WhalePet.app/Contents/{MacOS,Resources}
cp WhalePetL2D WhalePet.app/Contents/MacOS/WhalePet
cp Info.plist WhalePet.app/Contents/Info.plist
cp index.html whalepet_tts.py WhalePet.app/Contents/Resources/
cp -r model vendor WhalePet.app/Contents/Resources/
codesign --force --deep --sign - WhalePet.app
```

## AI 接入

- 内置 Hermes gateway：`http://127.0.0.1:8642/v1`（key 从 `~/.hermes/.env` 的 `API_SERVER_KEY` 读取）
- 自定义 API：设置面板填 baseURL / key / model（OpenAI 兼容）
- 工具协议：`set_emotion`（15 情绪枚举）、`play_motion`（8 动作枚举）；不支持 tools 的 API 自动降级为文本标签

## 调试

```bash
echo 3 > /tmp/pet_scale_cmd       # 倍率 x3
echo "开心" > /tmp/pet_emotion_cmd # 触发情绪
echo "selfie" > /tmp/pet_motion_cmd # 触发动作
```

## 环境

- macOS 26.5, Swift 6.3.3, Xcode CommandLineTools SDK MacOSX26
- TTS 需要 Python venv: `python3 -m venv /tmp/ttsvenv && /tmp/ttsvenv/bin/pip install edge-tts`
