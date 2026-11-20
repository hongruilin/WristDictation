# watchOS 上踩过的坑

这份文档里的每一条都对应一次真机故障，都改过代码，都在日志里留下过证据。写这类 App 的人可以少走一些弯路。

前面是"必须遵守的规矩"，后面是"怎么排查"。

---

## 一、让系统认为你正在播放

这一组是整件事的地基。手表上的耳机键、锁屏控制、系统"正在播放"卡片，全都取决于**系统是否认为你是当前正在播放的 App**。

### 1. 音频会话必须 `options: []`

```swift
// 对
try session.setCategory(.playback, mode: .spokenAudio, options: [])

// 错：一条耳机命令都收不到
try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
```

SDK 里写得很清楚：*"Setting this option will also make your session mixable with others (MixWithOthers will be set)"*。一旦是混音会话，你就**永远不会**成为 Now Playing App，`MPRemoteCommandCenter` 的 handler 一次都不会被调用。

`.duckOthers` 只对 `mode == .default` 合法，配 `.spokenAudio` 本身就是无效组合。

**症状**：AirPods 双击明明设置了"播放/暂停"，按下去毫无反应，App 里也没有任何日志。

### 2. 必须持续渲染音频，哪怕没有声音

watchOS 判断"这个 App 在不在播放"依据的是**有没有音频在渲染**，不是你有没有在播内容。

听写天然有十几秒的空档。空档里如果没有音频渲染，系统就认为你停了：耳机键失效、Now Playing 卡片消失。

解法是循环播放一条 **8kHz、全零采样的 WAV**：

```swift
let player = try AVAudioPlayer(data: silentWAVData)
player.numberOfLoops = -1
player.volume = 0      // 注意：volume = 0 仍然算"在渲染"
player.play()
```

这不是省电的写法——它让音频管线和蓝牙链路一直醒着，占这个 App 六七成的耗电。但**去掉它，耳机键立刻失效**。

### 3. transport 命令要看状态，不要看命令名

最反直觉的一条。

暂停之后，静音轨还在播，系统**始终认为你在播放**。所以 AirPods 按下去，投递过来的永远是 `pauseCommand`，从来不是 `playCommand`。

如果你的处理是"收到 pause 就 pause"，那就是死锁：再也按不回来。

```swift
// 对：看状态
func handleTransport(_ intent: TransportIntent) {
    switch intent {
    case .play:  if phase == .paused { resume() }
    case .pause: if phase == .paused { resume() } else { pause() }   // 本质是 toggle
    case .toggle: phase == .paused ? resume() : pause()
    }
}
```

**症状**：暂停能按，恢复按不动；双击切上一条/下一条却有反应（因为那是另外的命令）。

### 4. 双指互点要和耳机键共用同一条去抖

`handGestureShortcut(.primaryAction)` 的语义是"替用户按下这个按钮"。但如果按钮的 action 直接调 `togglePlayPause()`，会出问题：

本 App 是 Now Playing 应用，一次双指互点有可能**既**触发手势力、**又**被系统当成媒体命令再投递一遍。两条路径各翻一次状态，等于没反应。

正确做法是两条路都汇到同一个去抖入口（例如 0.5 秒内只接受一次 transport 意图）。

另外两条限制：`handGestureShortcut` 需要 **watchOS 11+**，且**只在屏幕亮着、App 在前台时有效**。熄屏后只能走媒体命令那条路。

### 5. 耳机回调不保证在主线程

watchOS 在后台被耳机唤醒时，`MPRemoteCommandCenter` 的 handler 可能在非主线程。引擎的 `@Published` 属性直接驱动 SwiftUI，非主线程改它会卡死主线程（表现是整机卡一下，或者直接被 watchdog 杀掉）。

所有回调统一 `DispatchQueue.main.async` 兜住；跨线程的节流时间戳用锁保护。

---

## 二、生命周期：什么时候该暂停，什么时候绝对不能

### 6. `runtimeInvalidated` 里不能 `pause()`

`WKExtendedRuntimeSession` 的 `self-care` 类型，在"退到前台以外"（放下手腕、熄屏）时**必然被撤销**。这是常态，不是错误。

如果在这个回调里暂停，用户每次放下手臂都会中断播报。

进程存活靠的是 `WKBackgroundModes` 里的 `audio` + 静音轨，不是这个会话。

### 7. `.background` 必须暂停，`.inactive` 绝对不能暂停

| scenePhase | 含义 | 该做什么 |
|---|---|---|
| `.active` | 亮屏在前台 | 正常播 |
| `.inactive` | **熄屏 / 放下手腕** | **继续播**，什么都不做 |
| `.background` | 按表冠离开 App | **暂停** |

把 `.inactive` 当成"离开"是最容易犯的错——那会让整个 App 在放下手腕的瞬间停下，而这恰好是听写的主场景。

### 8. 后台的 TTS 是哑的

`AVSpeechSynthesizer` 在 App 进入后台后被调用时：

- 会回调 `didStart`
- **不出声**
- **不回调 `didFinish`**

实测：按表冠回表盘后，定时器照常触发 `speak`，`didStart` 之后 **3 分 26 秒**没有任何回调，状态机卡在 `.speaking`，界面显示"播放中"却没声音，直到手动暂停才收到 `didCancel`。

所以不要指望"后台继续播"。`.background` 时主动暂停，回前台再接上。

---

## 三、语音链路不可靠的三种形态

这三种的**外部表现完全一样**：界面显示播放中，没有声音，进度条照走。但成因和修法完全不同。

### 9. 形态一：开口了，但没有输出

合成器能在**没有输出路由**的会话上正常工作：按内部时钟走完 utterance，正常回调 `didStart` / `didFinish`。

也就是说，**TTS 能播完，不等于有声音**。进度条在走，答案单在归档，一切指标正常，用户听到的是彻底安静。

所以必须单独验证会话真的激活成功：

```
audio.activate failed: Session activation failed
```

这一行如果出现，就不要相信任何"播放成功"的判断。

### 10. 形态二：会话卡在打断中间态

一次典型的现场（2026-11-20）：

| 指标 | 值 |
|---|---|
| `interruption began` | **809 条** |
| `interruption ended` | **0 条** |
| `setActive` 连续失败 | 21 次 |
| `speak` 次数 vs `didStart` | 460 vs 397（63 次开口没拿到管线） |

打断从未结束，会话卡在中间态，怎么重试都失败。这种状态 App 层修不了，**重启手表**才恢复。

App 能做的是：**失败就停下来告诉用户**，而不是静默播完 50 个词。

```swift
// 失败后：先显式关闭，再重建。直接重试无效——僵尸会话不会自己走出来。
try? session.setActive(false)
try session.setCategory(.playback, mode: .spokenAudio, options: [])
try session.setActive(true)
```

再加指数退避（2/4/8/16/30 秒），别每 0.2 秒撞一次系统；连续 3 次失败就暂停并提示。

### 11. 形态三：合成器停了，但不回调

还有一种：合成器确实不响了，但 `didFinish` 永远不来。状态机会永远卡住。

解法是看门狗。但**判死逻辑必须分两段**：

```swift
if !speech.didStartCurrent {
    // 还没开口：isSpeaking == false 完全正常（系统在加载语音包、排队抢路由）
    // 不计 miss，只跑总超时（12 秒）
    if now - speakAt > 12 { recover(.noStart) }
} else {
    // 已经开口了却不出声：连续 4 次（2 秒）为假才算死
    if !speech.isSpeaking { miss += 1 } else { miss = 0 }
    if miss >= 4 { recover(.silent) }
}
```

一开始只写了后半段，等于拿"2 秒应该够了吧"去赌冷启动速度。冷启动慢一点就会**静默跳词**——用户不会知道漏了一个。

另外：看门狗的生命周期是**一次开口**，不是一整轮。`beginSpeaking()` 启动，`handleSpeechFinished()` 第一行停掉。词间间隔（哪怕设成 300 秒）期间它根本不在跑，倒计时归另一个 0.2 秒的 ticker。

**这两条时间轴互不相交，永远不要拿播报间隔去比较或调整超时值。**

---

## 四、主线程与性能

### 12. `nowPlayingInfo` 不能高频重写

`MPNowPlayingInfoCenter.nowPlayingInfo` 每写一次都是一趟到 `mediaremoted` 的跨进程调用。

曾经在 0.1 秒的 tick 里每次都写（10Hz）。结果：守护进程被拖住 → 主线程卡死 → **watchdog 强杀 App**。

最迷惑的地方是：**没有 crash log**。因为不是崩溃，是被系统终止。

现在的策略：

- 只在"信息被系统清空"或"标题/播放态真的变了"时才写
- 两层节流：tick 每 5 秒问一次，函数内部还有 30 秒最小写间隔
- 读 `nowPlayingInfo` 读的是本地属性，不花钱

同理，`AVAudioSession.setActive(true)` 也是阻塞调用，不能每次开口都做一次。

### 13. 别在 tick 里堆 `@Published` 赋值

熄屏后视图不渲染，但 `@Published` 的更新照样会跑，还会阻止 SoC 降频。5Hz 的 tick 里只更新真正变化的值（文本先比较再赋值）。

---

## 五、工程配置

### 14. Watch target 用 `application`，不要用 `watchapp2`

Xcode 27 的 `watchapp2` 产品类型带 thin-stub 二进制机制（`PRODUCT_TYPE_HAS_STUB_BINARY = YES`），命令行构建时会同时产生 `CreateUniversalBinary` 和 `CopyAndPreserveArchs` 两条输出同一可执行文件的命令，直接报：

```
Multiple commands produce ...
```

改任何设置都绕不过。用标准 `com.apple.product-type.application` 就好——运行期识别手表 App 依据的是 Info.plist 里的 `WKApplication` / `WKCompanionAppBundleIdentifier`，与产品类型无关。

本项目保留了一个开关：

```bash
WATCH_LEGACY_PRODUCT_TYPE=1 python3 Tools/gen_project.py
```

### 15. `OTHER_SWIFT_FLAGS` 要带 `-disable-sandbox`

SwiftUI 宏需要启动 `swift-plugin-server`。如果构建环境本身已经在沙箱里，嵌套 sandbox 会被拒，编译报错。

### 16. 命令行重装不会续期描述文件

免费账号的描述文件 7 天到期。`xcodebuild` 会复用
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 里的缓存，**重装后到期时间一天都不会变**。

续期只能：开 Xcode 按一次 `⌘R`，或者删掉缓存里的 `.mobileprovision` 再构建。

---

## 六、数据

### 17. 全量同步 + 幂等，不要做增量

几千条词的数据量下，增量合并的复杂度换不来任何收益。做法：

- 单调递增的 `dataVersion`
- 整包 SHA256 校验
- 临时文件 + 原子替换
- 版本不比本地新就只回执、不落盘

`applicationContext` 有约 256KB 的实际上限，所以按 200KB 分流：小的走 `applicationContext`，大的走 `transferFile`（慢，但保证送达）。

### 18. 随机模式只洗牌，不改参数

出过一次 bug：随机模式把每个词的 `repeatCount` 改成了 1。两种模式的次数和间隔必须完全一致，只有顺序不同。

### 19. 快照"存进去"不等于"读得出来"

断点续播看起来简单，实际有三处坑，缺一个就会时好时坏：

1. **写入是异步的，读取必须同步。** `save` 走 `ioQueue.async`，`load` 直接读文件 → 刚存完就读，拿到的是上一版。`load` 要 `ioQueue.sync`。
2. **视图回到首页时要重读。** `onAppear`、`fullScreenCover` 的 `onDismiss`、`scenePhase == .active` 三条返回路径各管一种情况，只在初始化时读一次，练完回来永远是空。
3. **"结束"不等于"作废"。** 用户按 × 十次有九次是想先歇一下，不是要把这一轮扔掉。

还有一个索引细节：`currentIndex + 1` 是在"等待结束"时做的，而暂停/退出发生在它之前。恢复时要按保存的阶段修正索引——`nextWordWaiting` / `waitingForAdvance` 才 +1，`repeatWaiting`（当前词还没念够）不能动。

---

## 七、排查方法论

比任何一条具体结论都重要。

### 先拉日志，再猜原因

这个项目的每一次误判，都是因为先猜了原因：

- "耳机键没反应" → 怀疑蓝牙/硬件，实际是会话开了混音
- "侧边键毁了一轮" → 怀疑视图生命周期，实际是按表冠
- "闪退" → 找 crash log，实际是被 watchdog 杀掉

拉日志的命令在 [INSTALL.md](INSTALL.md)。日志里一般一眼就能看出因果。

### 没有 crash log ≠ 没出事

App 被系统终止（watchdog / jetsam）**不会产生 `.ips` 崩溃报告**。找不到崩溃日志时，先怀疑主线程被阻塞，而不是怀疑"没崩"。

### 判断卡顿要算 deadline 差值，不要看两条日志的间距

"这条日志和上一条隔了 3 秒，所以卡了 3 秒"——错的。日志之间可能本来就该隔 3 秒。

要算的是：**预定的截止时间是几点，实际执行是几点**。0.1 秒的差值就足以判定是竞速还是卡顿。

### 症状速查

| 症状 | 大概率的根因 |
|---|---|
| 耳机键完全没反应 | 会话混音了 / 没有音频在渲染 |
| 暂停后按不回播放 | transport 按命令名而不是状态处理 |
| 播到一半整机卡住然后退出，无 crash log | tick 里高频写 `nowPlayingInfo` 或高频 `setActive` |
| 显示播放中、进度在走、没声音 | 会话没激活成功（TTS 不看输出路由） |
| 放下手腕就停 | `runtimeInvalidated` 里调了 `pause()`，或把 `.inactive` 当成了离开 |
| 按表冠回来是"假播放" | 后台调了 TTS，只回调 `didStart` |
| 间隔期偶发跳词 | 看门狗把"加载语音包"误判成了卡死 |
| 练完回首页看不到"继续上次" | 快照只在初始化读一次 / `stop()` 里清空了 / 异步写同步读的竞态 |
