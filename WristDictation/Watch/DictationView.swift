import SwiftUI

struct DictationView: View {
    let libraryID: UUID

    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var store: WatchStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @GestureState private var peeking = false
    @State private var showAnswers = false
    @State private var confirmExit = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 6) {
                header
                Spacer(minLength: 2)
                statusBlock
                Spacer(minLength: 2)
                controls
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)

            if peeking, let text = engine.peekText {
                peekOverlay(text)
            }
        }
        .gesture(peekGesture)
        .onAppear {
            if engine.phase == .idle || engine.phase == .completed {
                if let library = store.library(id: libraryID) {
                    engine.start(library: library, settings: store.settings)
                }
            }
        }
        .onDisappear {
            // 这里**只能暂停，不能 stop()**。
            //
            // stop() 会归档答案单并 `store.clear()` 掉快照，等于这一轮直接作废。
            // 而视图消失有三种情况：按表冠返回列表、按侧边键调出控制中心看电量、
            // 切换 App。用户只是想看一眼电量，回头还得接着听——V1.6.1 实测
            // 00:41:33 按侧边键看电量，这一轮 27/50 就这样没了。
            //
            // 真正结束本轮走左上角的 × →「结束并返回」，那条路会先 stop()，
            // 走到这里时 phase 已经是 .idle，pause() 自动空转。
            if engine.phase != .idle {
                AppLog.log("view.disappear phase=\(engine.phase.rawValue) → 暂停保留进度")
                engine.pause()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 记下场景切换，用来分辨"控制中心顶上来"到底是 inactive 还是 background。
            // 排查时这条比猜有用。
            AppLog.log("scene.phase=\(phase == .active ? "active" : (phase == .background ? "background" : "inactive"))")

            if phase == .active {
                // 省电模式在空档期不渲染音频，进程可能被系统挂起，定时器随之停摆。
                // 回到前台时补一次过期的等待，避免"卡在某个词"。
                engine.catchUpIfNeeded()
                // 后台自动暂停的那一次，回来自动接上（用户手动暂停的不动）。
                engine.resumeIfAutoPaused()
            } else if phase == .background {
                // 按表冠离开 App = 真的退到后台。这里必须暂停：
                // TTS 在后台只会回调 didStart，不出声也不回调 didFinish，
                // 状态机会永远卡在 .speaking，界面显示"播放中"却没声音。
                // 注意屏幕熄灭只是 .inactive，不走这条分支——放下手腕照常播报。
                engine.pauseForBackground()
            }
        }
        .fullScreenCover(isPresented: $showAnswers) {
            AnswerSheetView(items: engine.playedItems,
                            libraryName: engine.libraryName,
                            elapsed: engine.elapsedText)
        }
        .confirmationDialog("结束本轮？", isPresented: $confirmExit) {
            // 不再是 destructive：结束**不再销毁进度**，首页会多一条「继续上次」。
            // 真要放弃进度，首页那条记录右边有「放弃上次进度」。
            Button("结束并返回") {
                engine.stop()
                dismiss()
            }
            Button("继续听写", role: .cancel) {}
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
            Button {
                confirmExit = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            Text(engine.libraryName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(engine.progressText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    // MARK: 状态

    private var statusBlock: some View {
        VStack(spacing: 4) {
            Text(engine.phase.label)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(engine.phase == .paused ? Color.orange : Color.white)

            if let remaining = engine.remaining, remaining > 0 {
                Text(String(format: "%.1f 秒", remaining))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.cyan)
            } else if engine.phase == .speaking {
                Text("\(engine.currentRepeat) / \(engine.currentRepeatTarget)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
            } else if engine.phase == .waitingForAdvance {
                Text("按下一条继续")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if engine.phase == .completed {
                Button {
                    showAnswers = true
                } label: {
                    Text("查看答案")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            } else {
                Text(engine.elapsedText)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let notice = engine.notice, engine.phase != .completed {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 控制

    private var controls: some View {
        HStack(spacing: 8) {
            circleButton(system: "backward.fill", size: 16) {
                engine.previous()
            }

            transportButton

            circleButton(system: "forward.fill", size: 16) {
                engine.next()
            }
        }
        .padding(.bottom, 2)
    }

    /// 播放/暂停键。watchOS 11 起把它登记为「主要操作」，
    /// 于是双指互点（Double Tap）也会触发它——Series 9 / Ultra 2 才有这个手势。
    ///
    /// 注意 action 走的是 `handleDoubleTap()` 而不是 `togglePlayPause()`：
    /// `handGestureShortcut` 的语义就是"替我按这个按钮"，系统和媒体通道可能
    /// 同一次双击各投递一遍，必须共用一串去抖才不会翻两次状态。
    @ViewBuilder
    private var transportButton: some View {
        if #available(watchOS 11.0, *) {
            transportControl
                .handGestureShortcut(.primaryAction)
        } else {
            transportControl
        }
    }

    private var transportControl: some View {
        circleButton(system: engine.phase == .paused ? "play.fill" : "pause.fill", size: 20) {
            engine.handleDoubleTap()
        }
    }

    private func circleButton(system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 长按偷看

    private var peekGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($peeking) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
    }

    private func peekOverlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 6) {
                Text("答案")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 10)
            }
        }
        .transition(.opacity)
    }
}
