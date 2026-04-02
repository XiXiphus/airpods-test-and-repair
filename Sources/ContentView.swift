import SwiftUI

struct ContentView: View {
    @StateObject var engine = DiagnosticEngine()
    @State private var showLog = false

    private func selectedDeviceTitle(_ device: AirPodsDevice) -> String {
        engine.allDevices.count > 1 ? device.pickerLabel : device.name
    }

    private func t(en: String, zh: String, ja: String) -> String {
        localized(engine.language, en: en, zh: zh, ja: ja)
    }

    var body: some View {
        VStack(spacing: DS.sectionSpacing) {
            headerSection
            if let dev = engine.device {
                deviceSection(dev)
                if engine.diagnosis.isAudioOutputAvailable {
                    diagnosisSection(dev)
                    audioTestSection
                    if engine.isFixing || engine.fixDone {
                        fixProgressSection
                    }
                    actionsSection
                } else {
                    notConnectedSection(dev)
                    if engine.isFixing || engine.fixDone {
                        fixProgressSection
                    }
                }
            } else if !engine.isScanning {
                emptySection
            }
            if showLog || !engine.logs.isEmpty {
                logSection
            }
        }
        .padding(16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.surfaceBg)
    }

    var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "airpodspro")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("AirPods Fix")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.bluetoothOn ? Color.blue : Color.gray.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(
                        engine.bluetoothOn
                            ? t(en: "Bluetooth Connected", zh: "蓝牙已连接", ja: "Bluetooth接続済み")
                            : t(en: "Bluetooth Disconnected", zh: "蓝牙未连接", ja: "Bluetooth未接続")
                    )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
            }
            Spacer()
            if engine.isScanning || engine.isFixing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }
            Picker(
                "Language",
                selection: Binding(
                    get: { engine.language },
                    set: { engine.setLanguage($0) }
                )
            ) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.menuLabel).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 90)
            .disabled(engine.isScanning || engine.isFixing)
            Button(action: { engine.scan() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(engine.isScanning || engine.isFixing)
        }
    }

    func deviceSection(_ dev: AirPodsDevice) -> some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDeviceTitle(dev))
                        .font(.system(size: 13, weight: .semibold))
                    Text(engine.diagnosis.modeLabel(in: engine.language))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.diagnosis.hasIssue ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                    Text(
                        engine.diagnosis.hasIssue
                            ? t(en: "Issue", zh: "异常", ja: "要確認")
                            : t(en: "OK", zh: "正常", ja: "正常")
                    )
                    .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((engine.diagnosis.hasIssue ? Color.red : Color.green).opacity(0.1))
                .clipShape(Capsule())
            }

            if engine.allDevices.count > 1 {
                HStack(spacing: 10) {
                    Text(t(en: "Target Device", zh: "目标设备", ja: "対象デバイス"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker(
                        t(en: "Target Device", zh: "目标设备", ja: "対象デバイス"),
                        selection: Binding(
                            get: { engine.device?.id ?? "" },
                            set: { engine.selectDevice(withID: $0) }
                        )
                    ) {
                        ForEach(engine.allDevices) { candidate in
                            Text(candidate.pickerLabel).tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(engine.isScanning || engine.isFixing)
                }

                Divider().opacity(0.5)
            }

            HStack(spacing: 20) {
                if dev.batteryLeft != "-", let pct = Int(dev.batteryLeft.replacingOccurrences(of: "%", with: "")) {
                    BatteryRing(label: t(en: "Left", zh: "左耳", ja: "左"), percent: pct, icon: "ear")
                }
                if dev.batteryRight != "-", let pct = Int(dev.batteryRight.replacingOccurrences(of: "%", with: "")) {
                    BatteryRing(label: t(en: "Right", zh: "右耳", ja: "右"), percent: pct, icon: "ear")
                }
                if dev.batteryCase != "-", let pct = Int(dev.batteryCase.replacingOccurrences(of: "%", with: "")) {
                    BatteryRing(label: t(en: "Case", zh: "充电盒", ja: "ケース"), percent: pct, icon: "case")
                }
            }
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
    }

    func diagnosisSection(_ dev: AirPodsDevice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t(en: "Diagnosis", zh: "诊断", ja: "診断"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)

            DiagRow(
                icon: engine.diagnosis.isDefaultOutput ? "checkmark.circle.fill" : "xmark.circle.fill",
                label: t(en: "Output Device", zh: "输出设备", ja: "出力デバイス"),
                value: engine.diagnosis.isDefaultOutput
                    ? selectedDeviceTitle(dev)
                    : t(en: "Not \(selectedDeviceTitle(dev))", zh: "非 \(selectedDeviceTitle(dev))", ja: "\(selectedDeviceTitle(dev)) ではない"),
                status: engine.diagnosis.isDefaultOutput ? .ok : .warn
            )
            Divider().opacity(0.5)
            DiagRow(
                icon: "waveform",
                label: t(en: "Audio Mode", zh: "音频模式", ja: "音声モード"),
                value: engine.diagnosis.modeLabel(in: engine.language),
                status: engine.diagnosis.sampleRateHz == nil || engine.diagnosis.channelCount == nil
                    ? .neutral
                    : (engine.diagnosis.isReducedQualityMode ? .warn : .ok)
            )
            Divider().opacity(0.5)
            DiagRow(
                icon: engine.diagnosis.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: t(en: "Mute", zh: "静音", ja: "ミュート"),
                value: engine.diagnosis.isMuted
                    ? t(en: "Muted", zh: "已静音", ja: "ミュート中")
                    : t(en: "Off", zh: "关闭", ja: "オフ"),
                status: engine.diagnosis.isMuted ? .warn : .ok
            )
            Divider().opacity(0.5)

            let vol = Int(engine.diagnosis.volume) ?? 0
            DiagRow(
                icon: "speaker.wave.1.fill",
                label: t(en: "Volume", zh: "音量", ja: "音量"),
                value: "\(engine.diagnosis.volume)%",
                status: vol < 5 ? .warn : .ok
            )
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
    }

    var audioTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t(en: "Audio Tests", zh: "音频测试", ja: "音声テスト"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 10) {
                Image(systemName: engine.isPlayingTest ? "speaker.wave.3.fill" : "speaker.wave.2")
                    .font(.system(size: 14))
                    .foregroundColor(engine.isPlayingTest ? .accentColor : .secondary)
                    .frame(width: 20)
                    .safeSymbolEffectPulse(isActive: engine.isPlayingTest)
                Text(t(en: "Speaker Test", zh: "扬声器测试", ja: "スピーカーテスト"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { engine.playTestSound() }) {
                    Text(engine.isPlayingTest ? t(en: "Playing...", zh: "播放中...", ja: "再生中...") : t(en: "Play", zh: "播放", ja: "再生"))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(engine.isPlayingTest ? 0.1 : 0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(engine.isPlayingTest)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Image(systemName: engine.isMicMonitoring ? "mic.fill" : "mic")
                    .font(.system(size: 14))
                    .foregroundColor(engine.isMicMonitoring ? .red : .secondary)
                    .frame(width: 20)
                Text(t(en: "Microphone Test", zh: "麦克风测试", ja: "マイクテスト"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    if engine.isMicMonitoring {
                        engine.stopMicMonitor()
                    } else {
                        engine.startMicMonitor()
                    }
                }) {
                    Text(engine.isMicMonitoring ? t(en: "Stop", zh: "停止", ja: "停止") : t(en: "Start", zh: "开始", ja: "開始"))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(engine.isMicMonitoring ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                        .foregroundColor(engine.isMicMonitoring ? .red : .accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if engine.isMicMonitoring {
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))

                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: levelGradient(for: engine.micLevel),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * CGFloat(engine.micLevel)))
                                .animation(.easeOut(duration: 0.08), value: engine.micLevel)

                            if engine.micPeak > 0.01 {
                                Rectangle()
                                    .fill(Color.red.opacity(0.6))
                                    .frame(width: 2)
                                    .offset(x: max(0, geo.size.width * CGFloat(engine.micPeak) - 1))
                                    .animation(.easeOut(duration: 0.15), value: engine.micPeak)
                            }
                        }
                    }
                    .frame(height: 14)

                    HStack {
                        Text(t(en: "Quiet", zh: "安静", ja: "静か"))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                        Spacer()
                        Text(micLevelText(engine.micLevel, language: engine.language))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(micLevelColor(engine.micLevel))
                        Spacer()
                        Text(t(en: "Loud", zh: "响亮", ja: "大きい"))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: engine.isMicMonitoring)
    }

    private func levelGradient(for level: Float) -> [Color] {
        if level < 0.4 { return [.green.opacity(0.7), .green] }
        if level < 0.7 { return [.green, .yellow, .orange] }
        return [.green, .yellow, .orange, .red]
    }

    private func micLevelText(_ level: Float, language: AppLanguage) -> String {
        if level < 0.05 { return localized(language, en: "No Signal", zh: "无信号", ja: "信号なし") }
        if level < 0.2 { return localized(language, en: "Weak", zh: "微弱", ja: "弱い") }
        if level < 0.4 { return localized(language, en: "Normal", zh: "正常", ja: "通常") }
        if level < 0.7 { return localized(language, en: "Loud", zh: "较响", ja: "大きめ") }
        return localized(language, en: "Very Loud", zh: "很响", ja: "かなり大きい")
    }

    private func micLevelColor(_ level: Float) -> Color {
        if level < 0.05 { return .secondary }
        if level < 0.4 { return .green }
        if level < 0.7 { return .orange }
        return .red
    }

    var fixProgressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if engine.fixDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
                Text(engine.fixStepText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(engine.fixDone ? .green : .primary)
                Spacer()
                Text("\(Int(engine.fixProgress * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            engine.fixDone
                                ? Color.green
                                : Color.accentColor
                        )
                        .frame(width: geo.size.width * engine.fixProgress)
                        .animation(.easeInOut(duration: 0.3), value: engine.fixProgress)
                }
            }
            .frame(height: 6)
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.25), value: engine.isFixing)
    }

    var actionsSection: some View {
        VStack(spacing: 10) {
            Text(t(en: "Everything looks right but there is still no sound? Try repair.", zh: "都设置好了就是不出声音？修复一下", ja: "設定は合っているのに音が出ませんか？修復を試してください。"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            ActionButton(
                title: engine.isFixing ? t(en: "Repairing...", zh: "修复中...", ja: "修復中...") : t(en: "One-Click Repair", zh: "一键修复耳机音频", ja: "ワンクリック修復"),
                subtitle: t(en: "Tries in order: refresh route → restart audio service → reconnect Bluetooth", zh: "依次尝试：刷新音频路由 → 重启音频服务 → 重连蓝牙", ja: "順番に実行: 音声ルート更新 → 音声サービス再起動 → Bluetooth再接続"),
                icon: "arrow.clockwise.circle",
                style: .primary,
                action: { engine.runSmartRepair() }
            )
            .disabled(engine.isScanning || engine.isFixing)
        }
    }

    func notConnectedSection(_ dev: AirPodsDevice) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                Text(t(en: "Not connected to this Mac", zh: "未连接到本机", ja: "この Mac に未接続"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
            }

            Text(t(
                en: "This headset is nearby but its audio is not routed to this Mac. Connect it to start using or repairing.",
                zh: "检测到耳机在附近，但音频未路由到本机。连接后即可使用或修复。",
                ja: "ヘッドセットは近くにありますが、音声はこの Mac にルーティングされていません。接続して使用または修復してください。"
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ActionButton(
                title: engine.isFixing
                    ? t(en: "Connecting...", zh: "连接中...", ja: "接続中...")
                    : t(en: "Connect to this Mac", zh: "连接到本机", ja: "この Mac に接続"),
                subtitle: t(en: "Claim audio from other devices via Bluetooth", zh: "通过蓝牙从其他设备抢占音频", ja: "Bluetooth で他のデバイスから音声を取得"),
                icon: "link.circle",
                style: .primary,
                action: { engine.connectToThisMac() }
            )
            .disabled(engine.isScanning || engine.isFixing)
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
    }

    var emptySection: some View {
        VStack(spacing: 14) {
            Image(systemName: "airpodspro")
                .font(.system(size: 44, weight: .thin))
                .foregroundColor(.secondary.opacity(0.4))
            Text(
                engine.bluetoothOn
                    ? t(en: "No compatible headset found", zh: "未找到兼容耳机", ja: "対応するヘッドセットが見つかりません")
                    : t(en: "Bluetooth Is Off", zh: "蓝牙未开启", ja: "Bluetoothがオフです")
            )
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.secondary)
            Text(t(en: "Make sure the headset is out of the case and close to your Mac", zh: "确保 AirPods 已取出并靠近 Mac", ja: "ヘッドセットをケースから出し、Mac の近くに置いてください"))
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
    }

    var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showLog ? 90 : 0))
                        .foregroundColor(.secondary)
                    Text(t(en: "Logs", zh: "日志", ja: "ログ"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(engine.logs.count)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .buttonStyle(.plain)

            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(engine.logs) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(entry.time)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.5))
                                    Text(entry.message)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(entry.isError ? .red : .primary.opacity(0.7))
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 120)
                    .background(Color.black.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onLogCountChange(engine.logs.count) {
                        if let last = engine.logs.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }
}
