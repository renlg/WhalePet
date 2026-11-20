# WhalePet 需求：会话空闲超时 + 新动作/新素材（codex 实施说明）

本文件是给 codex 的实施规格。项目根 = 本仓库（`/tmp/wp_repo`）。改完必须：`python3 tools/validate_motions.py` 全绿、`swiftc` 编译零 error、`git commit` 并 push 到 origin/main。

---

## 需求 1（硬性）：30 分钟没说就开新会话，30 分钟内说过话就复用同一个 Hermes 会话

现状：`shell.swift` 的 `askHermes()` 每次发**单条 user 消息**（无历史）到 `POST {baseURL}/chat/completions`，模型完全记不住上一句。

Hermes gateway 已实现 OpenAI 兼容的**会话续接**机制（本机实测通过，勿自创协议）：

- 请求头 `X-Hermes-Session-Id: <会话ID>` → gateway 从 `state.db` 载入该会话历史，继续同一对话
- 不带头 → 无历史（stateless）
- 响应头里会回传 `X-Hermes-Session-Id`（以服务端值为准，客户端要读回来保存）
- 续接要求 `API_SERVER_KEY` 鉴权（本 app 已带 Bearer，满足）
- 会话 ID 限制：软长度上限约 200 字符，不允许 `\r\n\0`；建议 `pet-<32hex>` 形式
- `system` 消息照常放在 `messages[0]`（每轮都发，gateway 作为 ephemeral prompt 叠加）

### 实现要求

1. `AIConfig` 增加 `sessionIdleTimeoutMinutes: Int`（默认 **30**），UserDefaults key `pet_sessionIdleTimeoutMinutes`。设置面板加一个输入框「会话空闲超时（分钟，0=永不复用/每条新会话）」。
2. UserDefaults 另存两个 key：
   - `pet_sessionId`（当前会话 ID，字符串）
   - `pet_lastExchangeAt`（最后一次成功对话的 Unix 时间戳 Double，**持久化**，重启 app 也要算进空闲时长）
3. `askHermes()` 发请求前决定会话：
   - 读 `pet_sessionId` + `pet_lastExchangeAt` + 超时分钟数
   - 若 `sessionId` 为空 或 `now - lastExchangeAt > timeoutSeconds` → **生成新会话 ID**（`pet-` + 32 位随机小写 hex/UUID 去横线），写回 UserDefaults
   - 否则 → **复用**现有 ID
   - 请求加 header `X-Hermes-Session-Id: <id>`
4. 响应回调里读 `HTTPURLResponse.value(forHTTPHeaderField: "X-Hermes-Session-Id")`，非空就用它覆盖本地 `pet_sessionId`（服务端可能改写）。
5. **只有请求成功（拿到正常 assistant 回复）才更新 `pet_lastExchangeAt`**；网络错误 / API 异常不要刷新计时（否则失败也算"说过话"）。用户自己发消息的时刻不必刷新，以免 AI 请求还在飞时被误判。
6. 日志（写进 `handleJSEvent`，会被转发到 `webview.log`，用于验收）：
   - 复用：`SESSION_REUSE sid=<id> idle=<秒>s timeout=<秒>s`
   - 新建：`SESSION_NEW sid=<id> reason=<empty|timeout|manual> idle=<秒>s timeout=<秒>s`
   - 服务端改写：`SESSION_SERVER_ID old=<old> new=<new>`
7. 菜单栏（status bar）加一项「🆕 开新会话」（`@objc func newSession()`）：立即换新 ID、`pet_lastExchangeAt` 清零、气泡提示「新会话开始～」，并记 `SESSION_NEW ... reason=manual`。
8. 设置面板加一个按钮「立即开新会话」（可选，和菜单同一逻辑）。
9. 不要给 `write` 之外的地方发多余 header；`baseURL` 为空走内置 gateway 时也要带会话头（`readGatewayKey()` 分支已存在）。

### 验收（本机自查，codex 也要能跑）

```bash
# 真实调用必须带上会话头；两条消息能记住前文（人工看 webview.log 里的 SESSION_* 行）
grep -a "SESSION_" webview.log | tail -5
```

---

## 需求 2：新增动作 + 新增表情素材（素材要"网上比较火"的桌宠动作）

调研结论（参考 dsh-whale-musume 的 90+ 状态、BongoCat Next、Shimeji/桌宠社区的常见互动）：**最火的桌宠动作**是这些——招手打招呼、比心/爱心眼、摸头反应、摇尾巴、露肚皮、睡觉打呼、伸懒腰、跳舞摇摆、蹦跳庆祝、生气鼓脸、星星眼崇拜、双手比耶、戴墨镜耍帅、猫耳喵爪、兔兔耳、喝咖啡/吃饭、探头偷看、打游戏。

本模型（c_0120）**已有**的动作组：`idle / aidale / selfie / selfieQuick / ketchup / openLid / bubble(=chuipaopao 吹泡泡) / splash(喷水) / crawl(爬动) / talk`。

### 2A 新增动作（motion3.json，至少 12 个，全部要有实际可见的骨骼/参数变化）

在 `model/motions/` 新建（命名英文、无空格、无中文，避免 url 编码问题）：

| 新动作组 | 表现（结合模型可用参数） | 参考热点 |
|---|---|---|
| `wave` | 招手打招呼：`phone7`(双手比耶) 起手 + 头部轻微左右 + `ParamMouthOpenY` | greet |
| `heartKiss` | 比心：`aixing`(爱心) + `Param9`(爱心显示) + `ParamCheek17` 爱心眼 + `love`，头轻微前倾 | meme-heart / valentine |
| `headpat` | 摸头反应：`ParamCheek17` + `Paramhh2`(脸红) + `ParamCheek16` 星星，头被按住一点下沉再回弹，`ParamCheek73`(心跳) | react-head |
| `tailWag` | 摇尾巴：主驱动 `ParamBreath`（它喂物理 PhysicsSetting13 → 尾巴 B_tail 摆动），配合 `ParamBreath3/4`，身体轻摆 | react-tail |
| `bellyUp` | 露肚皮躺：身体后仰 `ParamBodyAngleZ`、头仰、`ParamCheek22`(闭眼口水)，`Param73/74` 星星飘 | react-belly |
| `sleep` | 睡觉：`ParamCheek22` 闭眼 + 头侧倾 + `ParamMouthOpenY` 微开 + 缓慢 `ParamBreath` | sleep |
| `stretch` | 伸懒腰：`ParamBodyAngleX/Y` 上抬、`ParamAngleY` 仰头、`ParamCheek20`(呆眼眨眼)、末尾放松 | daily-stretch |
| `dance` | 跳舞：`ParamBodyAngleZ` 左右大幅交替 + `ParamAngleZ` 反向 + `ParamBreath` 尾巴甩 + `ParamCheek26`(花旋转) | meme-music |
| `hop` | 蹦跳庆祝：`Param13/Param14`(体y/体x) 上下 + `ParamBodyAngleY` + `Param73/74` 星星撒花 + `ParamCheek28` | celebrate |
| `angryPuff` | 生气鼓脸：`ParamCheek80` 生气 + `ParamBrowRAngle/LForm` 竖眉 + 歪嘴 `ParamBrowRForm2` + 身体发抖（高频小幅 `ParamBodyAngleX`） | angry |
| `worship` | 星星眼崇拜：`ParamCheek16` 星星眼 + 双手举起 `phone7` + 星星 `Param73/74` + `ParamCheek26` 花转 | meme-worship |
| `coolShades` | 墨镜耍帅：`ParamCheek71` 墨镜 + `ParamEyeLOpen/ROpen` 关闭 + 头偏 + `Paramhh3` 阴暗气场 | cool-shades |
| `catPaws` | 猫耳喵爪：`ParamCheek83` 猫耳 + `maoshou2..7` 猫爪拍两下 + `ParamCheek17` 爱心眼 | 猫猫贴纸 / 喵喵手 |
| `bunnyEars` | 兔兔耳：`ParamCheek82` 兔兔耳 + 歪头 + `ParamCheek76` wink | 兔兔贴纸 |
| `peek` | 探头偷看：`ParamBodyAngleX` 侧倾 + `ParamAngleX` 转头 + `ParamEyeBallX` 眼珠偏移 + `ParamCheek74` 问号 | home-peek |
| `coffee` | 喝咖啡/吃饭：`danbaofan`/`danbaoX/Y` 蛋包饭 + `ParamCheek21` 舔嘴 + `ParamMouthOpenY` | daily-coffee / daily-eat |

上表若某参数取值不合理可微调，但**只能使用模型里真实存在的参数 ID**。至少落地 12 个（多写不限）。

### 2B 新增表情素材（exp3.json，至少 12 个）

在 `model/expressions/` 新建（同样英文命名），把现有 44 个表情里没用上的"道具/贴纸"参数做成**组合特效表情**（组合 = 新素材），例如：

- `devilHornSmug` 恶魔角 + 邪笑（`ParamCheek74` 或眯眼 + `Paramhh3`）
- `angelHaloSmile` 天使光环/翅膀 + 微笑（翅膀参数见 cdi3 `ParamGroup14`/Parts，只能用参数，不要碰 Part 部件 opacity）
- `catHeartEyes` 猫耳 + 爱心眼 + 脸红
- `bunnyStarEyes` 兔兔耳 + 星星眼
- `shadesPeace` 墨镜 + 比耶（`ParamCheek71` + `phone7`）
- `flowerLove` 情绪花花旋转 + 爱心眼
- `heartBeatBlush` 心跳 + 脸红 + 星星眼
- `ghostOutTired` 吐魂 + 流汗 + 呆眼
- `dizzySweat` 晕晕 + 流汗
- `excitedWink` 兴奋 wink + 感叹号
- `lickLipsYum` 舔嘴 + 开心兴奋
- `gloomySulk` 阴暗 + 生气 + 泪

参数只能取 cdi3 里真实存在的 ID（`python3 tools/validate_motions.py` 会报错拦截不存在的参数）。

### 2C 接线（必须全做完，否则动作播不出来）

1. `model/c_0120.model3.json` 的 `FileReferences.Motions` 增加新动作组（每组的 `File` 相对路径 `motions/<name>.motion3.json`，`FadeInTime/FadeOutTime` 参考现有 0.35/0.5，循环动作 `Loop:true` 写在 motion3 的 Meta 里）；`FileReferences.Expressions` 增加新表情条目（`{"Name": "<filename without .exp3.json>", "File": "expressions/<name>.exp3.json"}`，注意顺序和已有条目并存）。
2. `index.html`：
   - `MOTION_GROUPS` 白名单加入全部新组名（否则 `__setMotion` 会拒绝）
   - `MOTION_GROUPS` 之外的随机池（canvas click 的 `groups` 数组、以及 `MOTION_GROUPS` 附近）更新为包含新动作
   - `EXPR_MAP` 增加新表情的中文关键词映射（如 `'比心':'heartKiss'` 之类；注意 `EXPR_MAP` 是表情名，新表情文件名可直接作为 key）
   - `MOTION_MAP` 增加新情绪→新动作映射（把"崇拜/心动/生气/困/开心"等默认动作换成新的更贴切动作；保留原有兼容映射）
3. `shell.swift`：
   - `motionAliases` 增加新组的中文别名（如 招手/wave、比心/heartKiss、摸头/headpat、摇尾巴/tailWag、睡觉/sleep、伸懒腰/stretch、跳舞/dance、蹦跳/hop、生气/angryPuff、崇拜/worship、墨镜/coolShades、猫爪/catPaws、兔耳/bunnyEars、探头/peek、喝咖啡/coffee）
   - `play_motion` 工具的 `enum` 列表加入全部新中文名
   - 系统提示里【可用的工具】的 `play_motion` 可选值列表同步更新
   - `@objc func playMotion()` 菜单随机动作池 + 自主漫游 `RANDOM_GESTURE` 手势池加入新动作（不要把 `talk`/`crawl` 塞进随机池）
4. 不要改动已有的 `talk` 说话锁定逻辑、`pendingAfterTalk` 排队、`__stopTalkingMotion`（说话期间新动作必须仍然走排队）。
5. 新动作不要循环到"永远不停"：`Loop:true` 的动作会被 `__setMotion` 一直播放直到下一次动作/说话，这是既有行为，保持即可；但每个新动作时长 1.5–4 秒，别写 0.2 秒的空动作。

---

## 校验器

`tools/validate_motions.py`（已在仓库，别删）严格校验 Cubism 3 规范：

```bash
python3 tools/validate_motions.py        # 全量：54+ 个文件
python3 tools/validate_motions.py model/motions/sleep.motion3.json   # 单个
```

它会抓：Segments 写错（漏段类型 → Cubism 静默忽略该曲线）、时间越界/倒退、参数不存在、Meta 计数不符、exp3 的 Blend/Value 非法。

> ⚠️ 已知历史 bug：`crawl.motion3.json` 的 4 条 `maoshou*` 曲线写成了裸 time/value 对（被 Cubism 静默忽略），`Meta.TotalSegmentCount` 也不对。**顺手修掉**（改成正确的 0/1/2/3 段编码，总时长保持 2.2s），让校验器全绿。

## 编译校验（VM 上也要跑）

```bash
export CLANG_MODULE_CACHE_PATH=/tmp/whalepet-clang-cache
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk -O shell.swift -o /tmp/WhalePet_bin 2>&1 | grep -cE ' error'
# 必须输出 0
```

## 完成标准

- [ ] `python3 tools/validate_motions.py` → 全部通过（0 失败）
- [ ] `swiftc` 编译 0 error
- [ ] `model3.json` 新动作/新表情条目齐全，JSON 合法
- [ ] `git commit`（中文/英文提交信息均可）+ `git push origin HEAD:main`
- [ ] 最后输出：新动作组清单、新表情清单、改动文件清单、校验器与编译结果
