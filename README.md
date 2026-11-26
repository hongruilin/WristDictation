# 腕上听写 · WristDictation

> 一块手表，3500 个常用字，一个不许带手机的车间。

iPhone 负责编词库，Apple Watch 负责**完全离线**地把词念出来。你只需要抬腕、听、写。

纯原生 Swift / SwiftUI，零第三方依赖。iOS 17+ / watchOS 10+。当前版本 **1.7.0**。

> **注意**：目前只在 **Apple Watch Ultra 2 + iPhone 15 Pro Max** 上做过真机验证，其它机型未实测，详见[兼容性](#兼容性)。

---

## 它为什么存在

2026 年，我在工厂上班。车间不许带手机，手机得锁在柜子里。

同一时间我也在准备自考的「大学语文」。长年用拼音输入法打字，提笔忘字已经很严重了，而这门考试里有不少要动笔写字的地方，作文就是其中一个。所以我得在短时间内把中国 3500 个常用字练到能默写出来——不是认得，是能写出来。唯一可行的办法是让耳朵反复听，手上跟着写。

我把应用商店翻了一遍，没有能用的：

| 类型 | 为什么不行 |
|---|---|
| 背单词 App | 为英文单词卡设计，中文单字体验差，而且**必须盯着屏幕** |
| 播客 / 音乐播放器 | 只能整段顺序播，没有「每个字重复几遍、间隔几秒」这种控制 |
| 手表端 App | 绝大多数是手机的遥控器，手机不在身边就废了 |

我需要的其实很简单：一个能装 3500 条词、能设「每字念 2 遍、间隔 15 秒」、戴在手腕上离线跑完一轮的东西。

市面上没有，那就自己写一个。

**腕上听写**不是背单词软件。它是一台只会念词的复读机：手机是编辑器，手表是播放器；平时不传数据，只有手机改了什么才同步一次，之后手表自己活。

---

## 能力

### 词库

- 多个词库，独立参数、独立播放模式
- 批量粘贴：一行一条，粘贴进去就是 3500 条
- 导入 `txt` / `csv` / `json`，自动识别 **UTF-8 / GB18030**——Excel 导出的中文 CSV 不会变成乱码
- 导入逐行校验：第几行、错在哪，一条一条列出来，不是「导入失败」四个字
- 自动去重（全角空格、首尾标点会先归一化再比对）

### 播报

- **三层参数继承**：全局 → 词库 → 词条。每层只写你想改的字段，其余向上继承
- 每词重复 **1–20** 次
- 同词间隔 / 换词间隔 **0–600 秒**
- 手动推进：你不按，它就一直等
- 顺序 / 随机，随机**不改变**每个词的播报次数

### 手表端

- **完全离线**：词库落到手表沙盒后，手机不在身边、断连、飞行模式都能完整播完一轮
- AirPods：播放 / 暂停、上一条 / 下一条
- 双指互点：捏一下暂停，再捏一下继续（watchOS 11+，Series 9 / Ultra 2 及以上）
- 熄屏继续播：放下手腕不会中断，这是默认行为
- 抬腕回来自动接上（离开 App 时会暂停）

### 进度

- **答案单**：每轮结束归档一条记录，标出没听到 / 跳过的词
- **断点续播**：中途退出会存快照，回首页出现「继续上次 · 第 N 条」

### 同步

- 全量下发 + 一跳回执：手机改任何一处，整包替换（简单优先，3500 条也就几百 KB）
- 手表状态上报做了内容去重，参数没变就不刷新时间戳，避免无意义的包在链路上来回跑

---

## 它是怎么工作的

```
iPhone                                WatchConnectivity              Apple Watch
──────                                ─────────────────              ───────────
IOSStore  ──── 全量词库包 ─────────────────────────────────▶  WatchStore
   ▲                                                          （原子落盘）
   │                                                                │
   └──── 回执 + 生效参数 + 手表可用语音列表 ◀──── 一跳返回 ◀──── WatchSyncManager
                                                                    │
                                                                    ▼
                                                          DictationEngine（状态机）
                                                            ├─ SpeechService（AVSpeechSynthesizer）
                                                            ├─ AudioSessionController（会话 + 静音轨）
                                                            └─ RemoteCommandBridge（耳机键 + 手势）
                                                                    │
                                                                    ▼
                                                              AirPods / 扬声器
```

三个刻意的设计选择：

1. **手表是独立的。** 同步只发生在「手机改了什么」的时候。播报完全不依赖手机。
2. **全量替换而非增量 diff。** 词库规模上限是几千条，增量合并的复杂度换不来收益。
3. **参数用「显式设置」而非「等于默认值」判断继承。** 用户把某个词设成和上层一样的值，那是他的意图，不能被上层改动穿透。

---

## 兼容性

| 项 | 最低要求 | 实际验证过的环境 |
|---|---|---|
| iPhone | iOS 17 | iPhone 15 Pro Max |
| Apple Watch | watchOS 10 | Apple Watch Ultra 2（`Watch7,5`） |
| Xcode | 15+ | 27.2 |

**这个项目只在 Apple Watch Ultra 2 + iPhone 15 Pro Max 上做过真机验证。**

代码里没有针对机型的判断——唯一的 `#available` 是双指互点所需的 watchOS 11。所以凡是能升级到 watchOS 10 的手表（Series 4 及以后）都可以安装，但**没有在其它型号上实测过**。

这一点值得说清楚，因为手表端的核心链路全是平台行为：音频路由、静音保活轨、耳机命令的投递时机，在不同机型、不同系统版本上都可能有差异。遇到问题请提 issue，并附上 `run.log`（拉取方法见 [docs/INSTALL.md](docs/INSTALL.md#六拉日志)）。

**界面尺寸也是按 Ultra 2（49mm）排的。** 中间键 46×46pt、主词 22–24pt，都是为大屏调的。40/41mm 的小表上可能出现拥挤、文字截断或按钮被挤压——**没有做小屏适配，也没有实测**。如果你在小表上跑，把截图发来，这部分可以一起改。

功能上唯一的机型差异：

| 功能 | 要求 |
|---|---|
| 双指互点（暂停/继续） | watchOS 11+ **且硬件支持**：Series 9 / Ultra 2 及以后 |
| 中间键点击 | 全部机型 |
| 离线播报、AirPods 按键、熄屏续播、断点续播 | 不依赖特定机型 |

不支持的机型上，双指互点这个手势本身就不存在（不是 App 的问题），中间键照常可点，其它功能不受影响。

---

## 快速开始

### 1. 改 Bundle ID

打开 `WristDictation/Config/Shared.xcconfig`，把 `yourname` 换成你自己的：

```
APP_BUNDLE_ID = com.yourname.wristdictation
```

Watch App 会自动使用 `<APP_BUNDLE_ID>.watchkitapp`，不用另配。

> 别用 `com.example.*`——`example.com` 是保留域名，Apple Developer 后台注册 App ID 会被拒。

### 2. 打开工程、选团队

```bash
open WristDictation.xcodeproj
```

两个 Target（`WristDictation` / `WristDictationWatch`）都要在 **Signing & Capabilities** 里选一次你的 Team。工程里 `DEVELOPMENT_TEAM` 是空的，这是故意的——仓库不该带别人的团队号。

### 3. 跑起来

**必须真机。** 模拟器没有真实的音频路由、没有 AirPods 按键、没有双指互点，这几条恰好是这个 App 最难的部分。

第一次建议按这个顺序：

1. 选 `WristDictation` scheme + 你的 iPhone，运行 → 手机上出现「腕上听写」
2. 在手机端建词库、粘几条词、设好参数
3. 选 `WristDictationWatch` scheme + 你的 Apple Watch，运行 → 手表上出现同名 App
4. 手机上点「同步到手表」，等手表回执
5. 手表上打开 App，开始

### 4. 命令行

```bash
# 手表端
xcodebuild -project WristDictation.xcodeproj -scheme WristDictationWatch \
  -configuration Debug -destination 'id=<WATCH_UDID>' \
  -derivedDataPath build build

xcrun devicectl device install app --device <WATCH_UDID> \
  build/Build/Products/Debug-watchos/WristDictationWatch.app
```

查 UDID：

```bash
xcrun devicectl list devices
```

想让脚本直接带团队号，不必改仓库：

```bash
WD_TEAM_ID=ABCDE12345 python3 Tools/gen_project.py
```

### 关于 7 天有效期

用**免费 Apple ID** 签名，描述文件只有 **7 天**，到期后手表上的 App 直接打不开（图标还在，点了就退出）。续期只能开 Xcode 按一次 `⌘R`。

**命令行重装不会续期**——`xcodebuild` 会复用 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 里的缓存，到期时间一天都不会变。要么开 Xcode，要么删掉缓存里的 `.mobileprovision` 再构建。

有付费开发者账号（$99/年）就没这回事，描述文件一年有效。

---

## 导入格式

### TXT

一行一条，空行忽略：

```
天
地
玄
黄
```

### CSV

支持带表头，列名可以是中文或英文；不带表头则第 1 列当词条：

```csv
词条,播报次数,同词间隔,下一词间隔
天,3,8,20
地,2,5,15
```

识别顺序：`词条/文本/内容/text/word`、`播报次数/次数/repeat`、`同词间隔/samewordgap`、`下一词间隔/nextwordgap`。
分隔符自动识别逗号、制表符、分号。

### JSON

```json
{
  "name": "3500 常用字",
  "mode": "sequential",
  "entries": [
    { "text": "天", "repeatCount": 2, "nextWordGap": 15 },
    { "text": "地" }
  ]
}
```

`samples/` 下有一份可以直接导入的示例。

---

## 参数的三层继承

```
全局（手机端「播报设置」）
  └─ 词库（这个库的默认值）
       └─ 词条（这一个词的例外）
```

每一层存的都是**可空值**。`nil` = 这层没说话，继续往上找；有值 = 这层说了算。

为什么不能用「值等于默认值就当没设置」？因为那样用户把某个词显式设成 8 秒，上层从 8 秒改成 5 秒时，这个词会莫名其妙跟着变。**显式设置是意图，必须留住。**

---

## 目录结构

```
WristDictation/
├── Shared/          # 两个 Target 都编译
│   ├── Models.swift         词库 / 词条 / 参数层 / 快照
│   ├── Parameters.swift     三层继承与取值边界
│   ├── SyncPayload.swift    同步协议与版本号
│   ├── DictionaryIO.swift   导入导出、编码探测
│   └── AppLog.swift         落盘日志（512KB 轮转）
├── iOS/
│   ├── IOSStore.swift       词库存储 + 同步发起
│   ├── LibraryListView.swift / DictionaryDetailView.swift
│   ├── LibrarySettingsView.swift   播报设置（含省电模式）
│   ├── ImportSheet.swift / WordEditorView.swift
│   └── PhoneRemoteBridge.swift
├── Watch/
│   ├── DictationEngine.swift       状态机（最难的部分都在这）
│   ├── SpeechService.swift         TTS 封装
│   ├── AudioSessionController.swift 音频会话 + 静音保活轨
│   ├── RemoteCommandBridge.swift   耳机键 / 手势，去抖
│   ├── WatchSyncManager.swift / WatchStore.swift
│   ├── PlaybackStateStore.swift    快照读写
│   └── DictationView.swift / WatchHomeView.swift / AnswerSheetView.swift
└── Config/
    ├── Shared.xcconfig   ← 改 Bundle ID 和团队号
    ├── iOS-Info.plist
    └── Watch-Info.plist  （WKBackgroundModes = audio）

Tools/
├── gen_project.py   # 生成 .xcodeproj（源文件清单变了要重跑）
└── sign_ipa.sh      # 未签名 IPA 重签脚本（可选）
```

`.xcodeproj` 是用脚本生成的。24 位对象 ID 由 `md5(key)[:24]` 派生，所以重复生成是幂等的、diff 友好。**增删源文件后要重跑**：

```bash
python3 Tools/gen_project.py
```

版本号也在脚本顶部：`APP_MARKETING_VERSION` / `APP_BUILD_VERSION`。

---

## 文档

| 文件 | 内容 |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 数据流、状态机、同步协议、快照一致性 |
| [docs/PITFALLS.md](docs/PITFALLS.md) | **watchOS 上踩过的 12 个坑**，每条都带真机日志证据。想写手表音频/耳机键的人建议先读 |
| [docs/INSTALL.md](docs/INSTALL.md) | 装机与排查：签名、安装、拉日志 |
| [docs/PRD-v1.2.md](docs/PRD-v1.2.md) | 最初的产品需求文档，保留设计取舍的来龙去脉 |
| [CHANGELOG.md](CHANGELOG.md) | 每个版本只解决一件事 |

---

## 已知限制

这些都是**平台行为**，不是 bug，别去"修"：

1. **手表 App 没运行时，手机无法让它立刻收包。** watchOS 的调度规则。手机端会显示「已发送，等手表确认」，下次打开手表 App 自动落地
2. **后台不播报。** `AVSpeechSynthesizer` 在后台只回调 `didStart`，不出声也不回调 `didFinish`。所以离开 App 就暂停，回来再接上
3. **免费账号 7 天签名**，到期重装。覆盖安装保留词库和进度
4. **省电模式会牺牲间隔期的耳机键。** 打开后间隔期停掉静音轨，省电但耳机键可能不响应。默认关闭
5. **外放时没有耳机键，这是设计而非缺陷。** 扬声器路由只有一条音频单元，静音保活轨会和合成器抢资源、抢输就整轮静音（`!res`）。所以外放走合成器自带会话（一定有声音），戴耳机才启用自有会话 + Now Playing（耳机键可用）。想强制走后者，在手表「播报设置 > 播放引擎 > 后台保活」里打开
6. **词库不内置。** 3500 字表请自行导入——版权和版本都该由你决定
7. **模拟器验不了核心链路。** 耳机键、双指互点、真实 TTS 路由都只在真机上成立

---

## 技术上有意思的地方

如果你是为了写 watchOS 音频 App 来的，这几条值得先看（细节和日志证据都在 [docs/PITFALLS.md](docs/PITFALLS.md)）：

- `AVAudioSession` 加 `.duckOthers` 会隐式带上 `MixWithOthers`，会话永远成不了 Now Playing，耳机命令**一条都收不到**
- watchOS 靠"有没有音频在渲染"判断播放状态。要耳机键常驻，就得有一条 8kHz 全零 WAV 循环播放
- 同一条静音轨在**外放时会翻车**：外放只有一条音频单元，保活轨和合成器抢，抢输就是 `-561145203`（`!res`，硬件资源不足），此后 `setActive` 永远失败、App 侧救不回来。**按路由分工**才是正解
- 暂停后系统投递的仍然是 `pauseCommand`。**看状态，不要看命令名**
- 合成器能在没有输出路由的会话上"播完"并正常回调 `didFinish`——**进度条在走不等于有声音**
- 音频会话激活失败后直接重试没用，必须先 `setActive(false)` 硬重置
- 快照「存进去」不等于「读得出来」：异步写 + 同步读 = 读到上一版

---

## 路线图

- [ ] 词库模板：内置几份常见字表（需确认授权）
- [ ] 答案单导出成文本，方便对错
- [ ] 错字重练：从上一轮的答案单直接生成新词库
- [ ] 语音之外的提示音方案（省电模式下的耳机键）

---

## 许可

[MIT](LICENSE)，版权人为 **WristDictation Contributors**（不署名到个人）。

- **可自用**：装在自己和家人的设备上，改多少都行
- **可商用**：拿去卖、拿去做付费服务、拿去改造成内部培训工具，都不需要申请授权、不需要付费、不需要告知作者
- **可再分发**：可以原样转、可以改完再发布，也可以换个名字发

唯一的要求是保留 `LICENSE` 里的版权声明和许可声明。软件按「现状」提供，不附带任何担保。

如果它正好解决了你的问题，欢迎回来说一声。

---

## English

**WristDictation** is an offline dictation trainer for Apple Watch. You build word lists on the iPhone; the watch plays them back entirely on its own — no phone, no network, no screen-watching.

It exists because its author worked in a factory where phones were forbidden. Years of typing with pinyin input had left him unable to recall how to write common characters by hand — and a self-study Chinese exam (大学语文) ahead of him required writing, including an essay. So all 3,500 common characters had to be drilled back into handwriting in a short time. Nothing in the App Store did "repeat each word N times, wait M seconds, keep playing on my wrist with the screen off."

Pure Swift / SwiftUI, no dependencies. iOS 17+ / watchOS 10+. Requires a real device — the headphone remote, double-tap gesture, and TTS routing cannot be validated in the simulator.

See [docs/PITFALLS.md](docs/PITFALLS.md) for the hard-won watchOS audio knowledge.
