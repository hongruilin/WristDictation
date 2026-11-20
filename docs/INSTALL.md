# 装机与排查

这份文档假设你有一台 Mac、一部 iPhone、一块配好对的 Apple Watch。**必须真机**——模拟器没有音频路由、没有耳机键、没有双指互点，而这三样恰好是这个 App 的全部难点。

> **已验证范围**：本项目只在 **Apple Watch Ultra 2 + iPhone 15 Pro Max** 上装过、跑过。
> 其它机型理论上能装（watchOS 10 及以上），但没有实测。
> 机型差异与功能降级见 [README 的兼容性一节](../README.md#兼容性)。

---

## 一、一次性配置

### 1. 登录 Apple ID

Xcode → **Settings** → **Accounts** → 左下 `+` → Apple ID。
免费账号也能用，只是描述文件 7 天到期（见第四节）。

### 2. 改 Bundle ID

`WristDictation/Config/Shared.xcconfig`：

```
APP_BUNDLE_ID = com.yourname.wristdictation
```

两个 Target 共用这一个值，Watch App 自动加 `.watchkitapp` 后缀。

> **别用 `com.example.*`**：`example.com` 是保留域名，Apple Developer 后台会拒绝注册这个 App ID。

### 3. 给两个 Target 各选一次 Team

Xcode 左侧文件树点项目 → **TARGETS** 里依次选 `WristDictation` 和 `WristDictationWatch` → **Signing & Capabilities** → Team 选你的名字。

两个都要选。只选一个的话，另一个构建时报：

```
Signing for "WristDictationWatch" requires a development team.
```

### 4. 让 Xcode 认领手表（最容易卡住的一步）

手表上的「开发者模式」开关**默认不存在**。Apple 的说法是：*Developer Mode only appears in Settings if you initiate pairing or if you previously connected the device to Xcode.*

所以必须先让 Xcode 认领这块表：

1. 菜单 **Window → Devices and Simulators**（`⌘⇧2`；Xcode 26 之后可能叫 **Device Hub**）
2. 左栏 **Devices** 里点你的 iPhone
3. 右侧会出现 `Preparing Apple Watch for development…`
4. **这段时间手表要戴在手上、解锁、屏幕亮着**，每隔十几秒点一下别让它息屏
5. 首次可能要等 5–15 分钟。等到右侧出现 **Paired Watches** 就算成功

没出现 `Paired Watches` 的话，按顺序试：确认 iPhone 的 Watch App 里能看到这块表 → 把手表放充电器上等 30 秒 → 拔插数据线 → iPhone 开个人热点，Mac 和手表都连这个热点。

### 5. 手表开 Developer Mode

认领成功后，手表上才会出现这个菜单：

设置 → 隐私与安全性 → 滑到最底部 → **开发者模式** → 打开 → 重启 → 解锁后确认 → 输密码

成功标志：设置里多出一个 **Developer** 菜单。

> 如果点进「隐私与安全性」要求输 4 位「屏幕使用时间密码」，输什么都不对——这是 watchOS 的已知缺陷。解法：iPhone → 设置 → 隐私与安全性 → 开发者模式 → **清除受信任的电脑**，然后重新用数据线连一次。

---

## 二、装

**顺序不能反：先手机，后手表。**

手表 App 在 Info.plist 里声明了宿主是哪个 iPhone App（`WKCompanionAppBundleIdentifier`）。手机上没装宿主时，系统会拒绝安装手表端。

### 手机端

选中 `WristDictation` scheme，destination 选你的 iPhone，`⌘R`。

### 手表端

选中 `WristDictationWatch` scheme，destination 选**你的手表**（不是 "Any watchOS Device"），`⌘R`。

装完回头再跑一次手机端，让手机知道手表上已经有了。

---

## 三、命令行

```bash
# 查设备
xcrun devicectl list devices

# 手机端
xcodebuild -project WristDictation.xcodeproj -scheme WristDictation \
  -configuration Debug -destination 'id=<IPHONE_UDID>' \
  -derivedDataPath build build

xcrun devicectl device install app --device <IPHONE_UDID> \
  build/Build/Products/Debug-iphoneos/WristDictation.app

# 手表端
xcodebuild -project WristDictation.xcodeproj -scheme WristDictationWatch \
  -configuration Debug -destination 'id=<WATCH_UDID>' \
  -derivedDataPath build build

xcrun devicectl device install app --device <WATCH_UDID> \
  build/Build/Products/Debug-watchos/WristDictationWatch.app
```

想让脚本带上团队号，不必改仓库：

```bash
WD_TEAM_ID=ABCDE12345 python3 Tools/gen_project.py
```

> 注意：重跑 `gen_project.py` 会重写 `project.pbxproj`。如果你在 Xcode 里手动改过 Team，重跑后会变回空值，需要重选一次。

---

## 四、7 天有效期

免费 Apple ID 的描述文件只有 **7 天**。到期后：

- 图标还在，点开就退出
- 手表端同样打不开

续期只能开 Xcode `⌘R` 一次（要用登录的账号会话换新 profile）。

**命令行重装不会续期。** `xcodebuild` 会复用 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 里的缓存，实测重装后到期时间一天都没变。要强制换新，删掉缓存里对应的 `.mobileprovision` 再构建。

覆盖安装**保留沙盒数据**，词库、参数、断点续播都不会丢。

---

## 五、出错对照表

按屏幕上的英文原文查：

| 现象 | 原因 | 怎么办 |
|---|---|---|
| Team 下拉里没有 **Personal Team** | 账号没登上 | Accounts 里删掉重加 |
| **No signing certificate "iOS Development" found** | 证书还没生成 | 保持联网，Xcode 会自动建；或 Accounts → Manage Certificates 手动 `+` |
| **Failed to register bundle identifier** | App ID 被占用 | 换一个 `APP_BUNDLE_ID` 前缀 |
| **The request was denied because the device is not registered** | 手表 UDID 没进团队设备列表 | 让它自动签名重试；免费账号设备名额只有 3 个，去 developer.apple.com 删旧设备 |
| **Personal development teams do not support the … capability** | 撞上免费账号不支持的能力 | 本项目没用受限能力，出现说明配置被改了 |
| 手表 destination 只有 **Any watchOS Device** | 手表没被认到 | 回第一节第 4 步，再开 Developer Mode |
| **developer disk image could not be mounted** | 安装时手表息屏了 | 解锁、保持亮屏，重新 `⌘R` |
| **Could not launch … failed to launch in time** | 手表太慢，首次常见 | 再按一次 `⌘R`；连续失败就放充电器上试 |
| 手表 App 点开就闪退 | 多为后台模式声明不被接受 | 手表上长按图标删掉，重新 `⌘R` |
| 手机上出现两个同名 App | 之前装过别的包（不同 Bundle ID） | 删掉旧的那个 |
| **Multiple commands produce …** | 工程被改坏了 | `python3 Tools/gen_project.py` 重新生成（会清掉 Team 设置） |
| `Failed to install embedded profile … 0xe8008012` | 描述文件里没有手表 UDID | 让 Xcode 重新生成描述文件（有时需要删缓存） |

---

## 六、拉日志

这是排查的第一步，比猜快一百倍。

```bash
xcrun devicectl device copy from --device <WATCH_UDID> \
  --domain-type appDataContainer \
  --domain-identifier com.yourname.wristdictation.watchkitapp \
  --source "Library/Application Support/WristDictation/run.log" \
  --destination ./run.log
```

看到 `Locked` 之类的错误，说明手表锁着，解锁后重试。

手机端的日志在手机沙盒的同名路径，把 `--device` 和 `--domain-identifier` 换掉即可（`com.yourname.wristdictation`）。

日志关键词见 [ARCHITECTURE.md](ARCHITECTURE.md#日志)。

---

## 七、装完先验这几项

按顺序，每步都要通：

1. 手表 App 能打开，显示词库列表
2. 手机改一条词 → 点同步 → 手表列表里能看到
3. 手表开始播报，**有声音**
4. 熄屏（放下手腕）后仍在播
5. AirPods 按一下能暂停，再按能继续
6. 中途按 ×「结束并返回」，回首页能看到「继续上次」

任何一步不对，先拉日志，再对照 [PITFALLS.md](PITFALLS.md) 的症状速查表。
