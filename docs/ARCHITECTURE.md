# 架构

## 一句话

手机是编辑器，手表是播放器。二者之间只传一次数据，之后手表完全独立。

```
┌──────────────── iPhone ────────────────┐        ┌──────────────── Apple Watch ────────────────┐
│                                        │        │                                              │
│  LibraryListView                       │        │   WatchHomeView                              │
│  DictionaryDetailView   ──┐            │        │     ├─ 继续上次（快照）                       │
│  LibrarySettingsView      │            │        │     └─ DictationView                         │
│  ImportSheet / WordEditor │            │        │            │                                 │
│                           ▼            │        │            ▼                                 │
│                       IOSStore ────────┼──┐     │      DictationEngine（状态机）                │
│                     （词库 + 设置）     │  │     │        ├── SpeechService                    │
│                           ▲            │  │     │        ├── AudioSessionController            │
│                           │            │  │     │        ├── RemoteCommandBridge               │
│                    PhoneRemoteBridge ◀─┘  │     │        └── PlaybackStateStore                │
│                                        │        │            │                                 │
└────────────────────────────────────────┘        │            ▼                                 │
              │                                   │      WatchStore（原子落盘）                   │
              │  applicationContext / transferFile│            ▲                                 │
              └─────────── WatchConnectivity ─────┼────────────┘                                 │
                                                  │      WatchSyncManager（校验 + 回执）          │
                                                  └──────────────────────────────────────────────┘
```

---

## 手机端

| 文件 | 职责 |
|---|---|
| `IOSStore.swift` | 词库与设置的持久化、变更后推进同步 |
| `PhoneRemoteBridge.swift` | `WCSession` 生命周期、发送、接收回执与状态上报 |
| `LibraryListView` / `DictionaryDetailView` | 词库列表、词条列表 |
| `LibrarySettingsView` | 播报参数、语音选择、省电模式 |
| `ImportSheet` / `WordEditorView` | 导入与单条编辑 |

手机端不做任何播报逻辑——它连 `AVSpeechSynthesizer` 都不引用。

---

## 手表端四个核心类

职责边界很清楚，混了就出 bug：

| 类 | 只管 | 绝不管 |
|---|---|---|
| `DictationEngine` | 状态机、队列推进、计时、快照 | 音频会话、TTS 细节、按键 |
| `SpeechService` | 调合成器、暴露 `isSpeaking` / `didStartCurrent` | 会话激活、状态迁移 |
| `AudioSessionController` | 会话 category/激活、静音保活轨、后台会话 | 什么时候开口 |
| `RemoteCommandBridge` | 注册耳机命令、手势、去抖、回主线程 | 播放语义（交给引擎判断） |

一句话：**引擎决定"什么时候播什么"，其余三个只负责"能不能播得出来"。**

---

## 数据模型

```
WordLibrary                    词库
├── id / name / mode / updatedAt
├── defaults: ParameterLayer   词库层参数
└── entries: [VocabularyEntry]
        ├── id / text / isEnabled
        └── overrides: ParameterLayer   词条层参数

AppSettings                    全局设置（全局层参数 + 语音 + 省电）
```

### 三层参数继承

```swift
struct ParameterLayer {
    var repeatCount: Int?      // nil = 这层没说话
    var sameWordGap: Double?
    var nextWordGap: Double?
    var isManualAdvance: Bool?

    func merged(over base: ParameterLayer) -> ParameterLayer {
        ParameterLayer(repeatCount: repeatCount ?? base.repeatCount, ...)
    }
}
```

生效值 = `词条.merged(over: 词库).merged(over: 全局)`。

**关键点：每一层存的都是可空值。** 不能用"值等于默认值"来推断"没设置"——否则用户把某个词显式设成 8 秒，上层从 8 改成 5 时这个词会跟着变。显式设置是意图。

### 取值范围

| 参数 | 范围 | 说明 |
|---|---|---|
| `repeatCount` | 1–20 | 每个词念几遍 |
| `sameWordGap` | 0–600 秒 | 同词两遍之间 |
| `nextWordGap` | 0–600 秒 | 换下一个词之前 |
| `isManualAdvance` | bool | 开了就只等手动推进 |

---

## 同步协议

### 包结构

```swift
struct SyncEnvelope {
    var schemaVersion: Int     // 协议版本，不兼容时拒绝
    var dataVersion: Int       // 内容版本，单调递增
    var contentHash: String    // 整包 SHA256
    var createdAt: Date
    var payload: SyncPayload   // libraries + settings
}
```

### 通道分流

`applicationContext` 的实际容量约 256KB。按 200KB 分流：

```swift
let channel: Channel = envelopeData.count <= 200 * 1024 ? .applicationContext : .file
```

小的走 `applicationContext`（快、只保留最新一包），大的走 `transferFile`（慢，但保证送达）。

### 落盘规则

手表收到包后：

1. 校验 `schemaVersion`
2. 重算 payload 的 SHA256，与 `contentHash` 比对
3. `dataVersion` 不比本地新 → **只回执，不落盘**（重复投递是常态）
4. 通过 → 写临时文件 → 原子替换 → 回执

回执（`SyncAck`）里的 `applied` 表示"这一包是否真的落了盘"，手机端据此显示"已生效"而不是"已发送"。

### 为什么还要手表上报状态

侧载安装时 `WCSession.isWatchAppInstalled` / `isReachable` 长期为 `false`（平台行为）。手机端无法据此判断同步到底有没有落地。

所以手表主动回传 `WatchStateReport`：实际生效的重复次数、间隔、语音名、省电开关。手机端展示的是**手表真实生效的值**，不是自己以为发出去的值。

上报做了内容去重（`sameContent(as:)`，排除 `reportedAt`）：内容没变就不刷新时间戳，同步层会把重复包挡掉。

---

## 播报状态机

```
        ┌──────────────────────────────────────────┐
        │                                          │
     .idle ──start──▶ .preparing ──▶ .speaking ──▶ .repeatWaiting
                                        ▲              │
                                        │        （还有剩余重复次数）
                                        └──────────────┘
                                                       │ 次数用完
                                                       ▼
                                              .nextWordWaiting / .waitingForAdvance
                                                       │
                                        ┌──────────────┴──────────────┐
                                  还有下一个词                    没有下一个词
                                        │                             │
                                        └──▶ .preparing              ▼
                                                                  .completed

  任意状态 ──pause()──▶ .paused ──resume()──▶ 恢复原状态
  任意状态 ──stop()───▶ .idle（保留快照，可续播）
```

### 两种定时器，各管一段

| 定时器 | 周期 | 只在 | 作用 |
|---|---|---|---|
| `ticker` | 0.2 秒 | 全程 | 倒计时、到点触发下一动作 |
| 播报看门狗 | 0.5 秒 | **一次开口内** | 检测"合成器不响了" |

看门狗由 `beginSpeaking()` 启动，`handleSpeechFinished()` 第一行停掉。**间隔期它根本不在跑**，所以间隔设 15 秒还是 300 秒都与它无关。

判死分两段的原因和阈值见 [PITFALLS.md](PITFALLS.md) 第 11 节。

### 队列与索引

队列保存的是**词条 ID**，不是文本——词库在手机上被改过之后，ID 仍然能对上；文本会漂移。

```
queue: [UUID]
currentIndex: Int      当前词在队列中的位置
currentRepeat: Int     当前词已经念了几遍
```

`currentIndex + 1` 发生在"这个词彻底结束、要换下一个"的时刻，不在播报开始时。

---

## 快照与恢复

`SessionSnapshot` 每次状态迁移都落盘（`session.json`，临时文件 + 原子替换）：

```swift
struct SessionSnapshot {
    var libraryID: UUID
    var queueEntryIDs: [UUID]     // 存 ID 不存文本
    var currentIndex: Int
    var currentRepeat: Int
    var phaseRaw: String          // 停在哪个阶段
    var remainingSeconds: Double?
    var playedItems: [PlayedItem]
    var isActive: Bool            // false = 这一轮已经播完，不该续播
}
```

三条缺一不可的规则：

1. **写异步、读同步。** `save` 用 `ioQueue.async`；`load` 必须 `ioQueue.sync`，否则刚存完就读会拿到上一版
2. **回首页要重读。** `onAppear`、`fullScreenCover onDismiss`、`scenePhase == .active` 三条路各管一种返回方式
3. **`stop()` 不清空快照。** 只有 `finish()`（整轮播完）才写 `isActive: false`

恢复时按保存的阶段修正索引：`nextWordWaiting` / `waitingForAdvance` 才 `+1`（那个词已经念完了），`repeatWaiting` 不动（还没念够）。

---

## 日志

`AppLog` 落盘到 App 沙盒的 `Library/Application Support/WristDictation/run.log`，512KB 轮转到 `run.1.log`，句柄常驻（不每次 open/close）。

格式是 `[HH:mm:ss.SSS] 事件名 关键字段`，关键词可以直接 grep：

| 关键词 | 含义 |
|---|---|
| `engine.start` / `engine.completed` | 一轮开始 / 结束 |
| `speak idx=` | 请求开口 |
| `tts.didStart` / `didFinish` / `didCancel` | 合成器回调 |
| `tts.stalled no-start` / `silent` | 看门狗判死，两种成因 |
| `audio.activate ok/failed` | 会话激活结果 |
| `audio.interruption began/ended` | 系统打断 |
| `remote.command transport` | 收到耳机键 |
| `gesture.command` | 收到双指互点 |
| `sync.receive` / `sync.done` | 同步收到 / 落盘 |
| `engine.backgroundPause` / `Resume` | 前后台切换 |

拉日志：

```bash
xcrun devicectl device copy from --device <WATCH_UDID> \
  --domain-type appDataContainer \
  --domain-identifier com.yourname.wristdictation.watchkitapp \
  --source "Library/Application Support/WristDictation/run.log" \
  --destination ./run.log
```

---

## 代码地图

想改功能，从这几处入手：

| 想改什么 | 看哪里 |
|---|---|
| 播报节奏、重复次数 | `DictationEngine.advance()` / `fireWait()` |
| 加一种触发方式（按键、手势） | `RemoteCommandBridge.transport(_:source:)`，然后汇到引擎的 `handleTransport` |
| 换 TTS 引擎 | 实现 `SpeechService` 协议即可，引擎只依赖 `speak/stop/isSpeaking/didStartCurrent` |
| 省电策略 | `AudioSessionController`，所有停音频的分支必须挂在 `powerSaving` 开关下 |
| 同步字段 | `Shared/SyncPayload.swift`，注意加字段要用 `decodeIfPresent` 保证旧包可读 |
| 词库导入格式 | `DictionaryIO.parse*` |
| 工程配置 / 版本号 | `Tools/gen_project.py` |
