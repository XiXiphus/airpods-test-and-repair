import Cocoa
import SwiftUI
import AVFoundation
import CoreAudio

// MARK: - 数据模型

struct AirPodsDevice: Identifiable {
    let id = UUID()
    let name: String
    let batteryLeft: String
    let batteryRight: String
    let batteryCase: String
    let macAddress: String
}

struct AudioDiagnosis {
    var isDefaultOutput = false
    var outputChannels = "?"
    var sampleRate = "?"
    var volume = "?"
    var isMuted = false
    var hasIssue: Bool {
        return !isDefaultOutput || isMuted || (Int(volume) ?? 50) < 5
    }
    var modeLabel: String {
        guard let ch = Int(outputChannels), let sr = Int(sampleRate) else { return "未知" }
        if ch >= 2 && sr >= 44100 { return "立体声 \(sr/1000)kHz" }
        if ch == 1 && sr == 24000 { return "单声道 24kHz" }
        if ch == 1 && (sr == 8000 || sr == 16000) { return "通话模式 \(sr/1000)kHz" }
        return "\(ch == 1 ? "单声道" : "立体声") \(sr/1000)kHz"
    }
}

// MARK: - Shell 工具

func shell(_ command: String) -> String {
    let process = Process()
    let pipe = Pipe()
    process.launchPath = "/bin/bash"
    process.arguments = ["-c", "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; " + command]
    process.standardOutput = pipe
    process.standardError = pipe
    process.launch()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// MARK: - CoreAudio 设备切换

struct AudioOutputDevice {
    let id: AudioDeviceID
    let name: String
    let isOutput: Bool
}

func listAudioOutputDevices() -> [AudioOutputDevice] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

    var result: [AudioOutputDevice] = []
    for did in deviceIDs {
        // 获取设备名
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(did, &nameAddr, 0, nil, &nameSize, &cfName) == noErr else { continue }

        // 检查是否有输出通道
        var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(did, &streamAddr, 0, nil, &streamSize)

        if streamSize > 0 {
            result.append(AudioOutputDevice(id: did, name: cfName as String, isOutput: true))
        }
    }
    return result
}

@discardableResult
func switchOutputDevice(toNameContaining keyword: String) -> Bool {
    let devices = listAudioOutputDevices()
    // 用归一化匹配 (处理 Unicode 引号)
    let normalizedKeyword = keyword
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
    guard let target = devices.first(where: {
        $0.name.replacingOccurrences(of: "\u{2018}", with: "'")
              .replacingOccurrences(of: "\u{2019}", with: "'")
              .contains(normalizedKeyword)
    }) else { return false }

    var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = target.id
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
    )
    return status == noErr
}

// MARK: - 诊断引擎

class DiagnosticEngine: ObservableObject {
    @Published var device: AirPodsDevice?
    @Published var diagnosis = AudioDiagnosis()
    @Published var logs: [LogEntry] = []
    @Published var isScanning = false
    @Published var isFixing = false
    @Published var bluetoothOn = true
    @Published var allDevices: [AirPodsDevice] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let message: String
        let isError: Bool
    }

    init() { scan() }

    func log(_ msg: String, isError: Bool = false) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let entry = LogEntry(time: fmt.string(from: Date()), message: msg, isError: isError)
        DispatchQueue.main.async { self.logs.append(entry) }
    }

    func scan() {
        isScanning = true
        logs.removeAll()
        log("开始扫描...")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let btPower = shell("blueutil --power 2>&1 || echo FAIL")
            let btSysProf = shell("system_profiler SPBluetoothDataType 2>/dev/null | head -5")
            let hasBTOn = btPower.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                || btSysProf.contains("State: On")
            log("蓝牙: \(hasBTOn ? "已开启" : "未开启")")
            DispatchQueue.main.async { self.bluetoothOn = hasBTOn }
            if !hasBTOn {
                log("蓝牙未开启", isError: true)
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            let btInfo = shell("system_profiler SPBluetoothDataType 2>/dev/null")
            var devices: [AirPodsDevice] = []
            let lines = btInfo.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if line.contains("AirPods") && line.hasSuffix(":") {
                    let name = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
                    var battL = "-", battR = "-", battC = "-", mac = ""
                    let searchEnd = min(i + 20, lines.count)
                    for j in (i+1)..<searchEnd {
                        let l = lines[j].trimmingCharacters(in: .whitespaces)
                        if l.starts(with: "Left Battery Level:") { battL = l.components(separatedBy: ": ").last ?? "-" }
                        if l.starts(with: "Right Battery Level:") { battR = l.components(separatedBy: ": ").last ?? "-" }
                        if l.starts(with: "Case Battery Level:") { battC = l.components(separatedBy: ": ").last ?? "-" }
                        if l.starts(with: "Address:") { mac = l.components(separatedBy: ": ").last ?? "" }
                    }
                    if battL != "-" || battR != "-" {
                        devices.append(AirPodsDevice(name: name, batteryLeft: battL, batteryRight: battR, batteryCase: battC, macAddress: mac))
                    }
                }
            }

            DispatchQueue.main.async {
                self.allDevices = devices
                self.device = devices.first
            }

            if devices.isEmpty {
                self.log("未找到已连接的 AirPods", isError: true)
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            self.log("已连接: \(devices.first!.name)")
            self.diagnoseAudio(deviceName: devices.first!.name)
            DispatchQueue.main.async { self.isScanning = false }
        }
    }

    func diagnoseAudio(deviceName: String) {
        let audioInfo = shell("system_profiler SPAudioDataType 2>/dev/null")
        var diag = AudioDiagnosis()

        // 按设备名切分: 找到设备名所在行，往下收集属性直到下一个设备名
        let lines = audioInfo.components(separatedBy: "\n")

        // 归一化设备名用于匹配 (处理 Unicode 智能引号等)
        func normalize(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{2018}", with: "'")
             .replacingOccurrences(of: "\u{2019}", with: "'")
             .replacingOccurrences(of: "\u{201C}", with: "\"")
             .replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        let normalizedName = normalize(deviceName)

        // 找到所有设备名出现的位置
        var deviceBlocks: [(start: Int, isTarget: Bool)] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 设备名行: 顶格缩进 + 冒号结尾，不含其他冒号
            if trimmed.hasSuffix(":") && !trimmed.contains("Devices:") && !trimmed.contains("Audio:") {
                let isTarget = normalize(trimmed).contains(normalizedName)
                deviceBlocks.append((start: i, isTarget: isTarget))
            }
        }

        // 对每个目标设备块，收集到下一个设备块为止的属性
        for (idx, block) in deviceBlocks.enumerated() {
            guard block.isTarget else { continue }
            let nextStart = idx + 1 < deviceBlocks.count ? deviceBlocks[idx + 1].start : lines.count
            let blockLines = lines[(block.start)..<nextStart]
            let blockText = blockLines.joined(separator: "\n")

            // 只看包含 Output 的段
            guard blockText.contains("Output Channels") || blockText.contains("Default Output Device") else { continue }

            if blockText.contains("Default Output Device: Yes") {
                diag.isDefaultOutput = true
            }
            for line in blockLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "Output Channels:") {
                    diag.outputChannels = trimmed.components(separatedBy: ": ").last ?? "?"
                }
                if trimmed.starts(with: "Current SampleRate:") {
                    diag.sampleRate = trimmed.components(separatedBy: ": ").last ?? "?"
                }
            }
            if diag.isDefaultOutput { break }
        }
        diag.volume = shell("osascript -e 'output volume of (get volume settings)' 2>/dev/null")
        let mutedStr = shell("osascript -e 'output muted of (get volume settings)' 2>/dev/null")
        diag.isMuted = mutedStr == "true"
        log("模式: \(diag.modeLabel) | 音量: \(diag.volume)%\(diag.isMuted ? " (静音)" : "")")
        if !diag.isDefaultOutput { log("AirPods 非当前输出设备", isError: true) }
        if diag.isMuted { log("系统已静音", isError: true) }
        DispatchQueue.main.async { self.diagnosis = diag }
    }

    // MARK: 修复进度

    @Published var fixProgress: Double = 0       // 0~1
    @Published var fixStepText: String = ""      // 当前步骤描述
    @Published var fixDone: Bool = false          // 修复完成

    private func step(_ text: String, progress: Double) {
        log(text)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.fixStepText = text
                self.fixProgress = progress
            }
        }
    }

    private func beginFix() {
        isFixing = true
        fixDone = false
        fixProgress = 0
        fixStepText = ""
    }

    private func endFix() {
        DispatchQueue.main.async {
            withAnimation {
                self.fixProgress = 1.0
                self.fixDone = true
            }
            // 3 秒后清除完成状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    self.isFixing = false
                    self.fixDone = false
                    self.fixProgress = 0
                    self.fixStepText = ""
                }
            }
        }
    }

    // 软修复: 修静音/音量/输出设备，不动 coreaudiod，不断蓝牙
    // 核心: 先切回本机扬声器，再切回 AirPods，强制刷新音频路由
    func fix() {
        guard let dev = device else { return }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in

            step("检查静音状态...", progress: 0.05)
            Thread.sleep(forTimeInterval: 0.3)
            if diagnosis.isMuted {
                step("取消静音...", progress: 0.1)
                _ = shell("osascript -e 'set volume without output muted'")
            }

            step("检查音量...", progress: 0.15)
            Thread.sleep(forTimeInterval: 0.3)
            if let vol = Int(diagnosis.volume), vol < 10 {
                step("调高音量至 50%...", progress: 0.2)
                _ = shell("osascript -e 'set volume output volume 50'")
            }

            // 核心步骤: 切换音频输出到 AirPods
            // 先切到本机扬声器，再切回 AirPods，强制重建音频路由
            step("切换到本机扬声器...", progress: 0.3)
            let switched = switchOutputDevice(toNameContaining: "MacBook")
                || switchOutputDevice(toNameContaining: "Built-in")
                || switchOutputDevice(toNameContaining: "内置")
            if switched {
                log("已切换到本机扬声器")
            } else {
                log("未找到本机扬声器，跳过 toggle", isError: false)
            }

            step("等待音频路由切换...", progress: 0.45)
            Thread.sleep(forTimeInterval: 1.0)

            step("切换输出到 AirPods...", progress: 0.6)
            let ok = switchOutputDevice(toNameContaining: "AirPods")
            if ok {
                log("已切换到 AirPods")
            } else {
                log("切换到 AirPods 失败", isError: true)
            }

            step("等待音频通道建立...", progress: 0.75)
            Thread.sleep(forTimeInterval: 1.0)

            step("验证修复结果...", progress: 0.9)
            self.diagnoseAudio(deviceName: dev.name)

            if ok {
                step("音频路由已刷新", progress: 1.0)
            } else {
                step("切换失败，试「重启音频」或「重连蓝牙」", progress: 1.0)
            }
            endFix()
        }
    }

    // 中修复: 重启 coreaudiod
    func restartAudioService() {
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            step("停止音频服务...", progress: 0.15)
            _ = shell("sudo killall coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true")

            step("等待服务重启...", progress: 0.35)
            Thread.sleep(forTimeInterval: 1.5)
            step("音频服务恢复中...", progress: 0.55)
            Thread.sleep(forTimeInterval: 1.5)

            step("验证音频状态...", progress: 0.8)
            Thread.sleep(forTimeInterval: 0.5)
            if let dev = device {
                self.diagnoseAudio(deviceName: dev.name)
            }

            step("音频服务已重启", progress: 1.0)
            endFix()
        }
    }

    // 硬修复: 断开重连蓝牙
    func reconnectBluetooth() {
        guard let dev = device, !dev.macAddress.isEmpty else {
            log("无法获取蓝牙地址", isError: true); return
        }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            step("断开 AirPods...", progress: 0.1)
            _ = shell("blueutil --disconnect \"\(dev.macAddress)\"")

            step("等待断开完成...", progress: 0.2)
            Thread.sleep(forTimeInterval: 1.5)
            step("已断开，准备重连...", progress: 0.3)
            Thread.sleep(forTimeInterval: 1.5)

            step("重新连接 AirPods...", progress: 0.4)
            _ = shell("blueutil --connect \"\(dev.macAddress)\"")

            step("等待蓝牙握手...", progress: 0.5)
            Thread.sleep(forTimeInterval: 2)
            step("建立音频通道...", progress: 0.65)
            Thread.sleep(forTimeInterval: 2)
            step("连接稳定中...", progress: 0.8)
            Thread.sleep(forTimeInterval: 1)

            step("验证连接状态...", progress: 0.9)
            self.diagnoseAudio(deviceName: dev.name)

            step("蓝牙重连完成", progress: 1.0)
            endFix()
        }
    }

    // MARK: 播放测试音

    @Published var isPlayingTest = false

    func playTestSound() {
        isPlayingTest = true
        log("播放测试音...")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // 用系统音效测试，简短清脆
            if let sound = NSSound(named: "Ping") {
                sound.play()
                Thread.sleep(forTimeInterval: 1.0)
            }
            // 再来一个不同的音效确认
            if let sound = NSSound(named: "Glass") {
                sound.play()
                Thread.sleep(forTimeInterval: 1.0)
            }
            log("测试音播放完毕")
            DispatchQueue.main.async { self.isPlayingTest = false }
        }
    }

    // MARK: 麦克风监测

    @Published var micLevel: Float = 0
    @Published var micPeak: Float = 0
    @Published var isMicMonitoring = false
    private var audioEngine: AVAudioEngine?
    private var micTimer: Timer?
    private var peakDecayTimer: Timer?

    private var micRetryCount = 0

    func startMicMonitor() {
        guard !isMicMonitoring else { return }
        micRetryCount = 0
        launchMicEngine()
    }

    private func launchMicEngine() {
        // 清理旧引擎
        if let old = audioEngine {
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }

        log("启动麦克风监测...")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.inputFormat(forBus: 0)
        log("麦克风格式: \(Int(nativeFormat.sampleRate))Hz / \(nativeFormat.channelCount)ch")

        var silentFrames = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            // 取所有通道的最大 RMS
            var maxRMS: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                var sum: Float = 0
                let data = channelData[ch]
                for i in 0..<count {
                    let sample = data[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(count))
                maxRMS = max(maxRMS, rms)
            }

            // 转换为 0~1 范围 (-50dB ~ 0dB)
            let db = 20 * log10(max(maxRMS, 0.000001))
            let normalized = max(0, min(1, (db + 50) / 50))

            // 检测连续静音 (权限刚授予时引擎拿不到数据)
            if maxRMS < 0.0001 {
                silentFrames += 1
                // 连续 ~2 秒静音且没重试过，自动重启引擎
                if silentFrames > 30 && self.micRetryCount < 2 {
                    silentFrames = 0
                    self.micRetryCount += 1
                    DispatchQueue.main.async {
                        self.log("检测到静音，重启麦克风引擎 (第\(self.micRetryCount)次)...")
                        self.launchMicEngine()
                    }
                    return
                }
            } else {
                silentFrames = 0
            }

            DispatchQueue.main.async {
                self.micLevel = normalized
                if normalized > self.micPeak {
                    self.micPeak = normalized
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
            isMicMonitoring = true
            log("麦克风监测中...")

            // Peak 衰减定时器
            peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.micPeak = max(self.micPeak - 0.1, 0)
            }
        } catch {
            log("麦克风启动失败: \(error.localizedDescription)", isError: true)
        }
    }

    func stopMicMonitor() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isMicMonitoring = false
        peakDecayTimer?.invalidate()
        peakDecayTimer = nil
        micLevel = 0
        micPeak = 0
        log("麦克风监测已停止")
    }
}

// MARK: - 设计系统

enum DS {
    static let cardBg = Color(NSColor.controlBackgroundColor)
    static let surfaceBg = Color(NSColor.windowBackgroundColor)
    static let subtleBorder = Color.primary.opacity(0.06)
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
}

// MARK: - 电量条组件

struct BatteryRing: View {
    let label: String
    let percent: Int
    let icon: String

    private var color: Color {
        if percent > 50 { return .green }
        if percent > 20 { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // 背景圆环
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 4)
                    .frame(width: 38, height: 38)
                // 电量圆环
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100.0)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(-90))
                // 百分比
                Text("\(percent)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 状态行组件

struct DiagRow: View {
    let icon: String
    let label: String
    let value: String
    let status: RowStatus

    enum RowStatus { case ok, warn, neutral }

    private var statusColor: Color {
        switch status {
        case .ok: return .green
        case .warn: return .red
        case .neutral: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject var engine = DiagnosticEngine()
    @State private var showLog = false

    var body: some View {
        VStack(spacing: DS.sectionSpacing) {
            headerSection
            if let dev = engine.device {
                deviceSection(dev)
                diagnosisSection
                audioTestSection
                if engine.isFixing || engine.fixDone {
                    fixProgressSection
                }
                actionsSection
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

    // MARK: 头部

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
                Text("听得见吗")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.bluetoothOn ? Color.blue : Color.gray.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(engine.bluetoothOn ? "蓝牙已连接" : "蓝牙未连接")
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

    // MARK: 设备信息

    func deviceSection(_ dev: AirPodsDevice) -> some View {
        VStack(spacing: 8) {
            // 设备名 + 状态
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dev.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(engine.diagnosis.modeLabel)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.diagnosis.hasIssue ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                    Text(engine.diagnosis.hasIssue ? "异常" : "正常")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((engine.diagnosis.hasIssue ? Color.red : Color.green).opacity(0.1))
                .clipShape(Capsule())
            }

            // 电量圆环 - 横排
            HStack(spacing: 20) {
                BatteryRing(label: "左耳", percent: Int(dev.batteryLeft.replacingOccurrences(of: "%", with: "")) ?? 0, icon: "ear")
                BatteryRing(label: "右耳", percent: Int(dev.batteryRight.replacingOccurrences(of: "%", with: "")) ?? 0, icon: "ear")
                if dev.batteryCase != "-", let pct = Int(dev.batteryCase.replacingOccurrences(of: "%", with: "")) {
                    BatteryRing(label: "充电盒", percent: pct, icon: "case")
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

    // MARK: 诊断

    var diagnosisSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("诊断")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)

            DiagRow(
                icon: engine.diagnosis.isDefaultOutput ? "checkmark.circle.fill" : "xmark.circle.fill",
                label: "输出设备",
                value: engine.diagnosis.isDefaultOutput ? "AirPods" : "非 AirPods",
                status: engine.diagnosis.isDefaultOutput ? .ok : .warn
            )
            Divider().opacity(0.5)
            DiagRow(
                icon: "waveform",
                label: "音频模式",
                value: engine.diagnosis.modeLabel,
                status: .ok
            )
            Divider().opacity(0.5)
            DiagRow(
                icon: engine.diagnosis.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: "静音",
                value: engine.diagnosis.isMuted ? "已静音" : "关闭",
                status: engine.diagnosis.isMuted ? .warn : .ok
            )
            Divider().opacity(0.5)

            let vol = Int(engine.diagnosis.volume) ?? 0
            DiagRow(
                icon: "speaker.wave.1.fill",
                label: "音量",
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

    // MARK: 音频测试

    var audioTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音频测试")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            // 播放测试
            HStack(spacing: 10) {
                Image(systemName: engine.isPlayingTest ? "speaker.wave.3.fill" : "speaker.wave.2")
                    .font(.system(size: 14))
                    .foregroundColor(engine.isPlayingTest ? .accentColor : .secondary)
                    .frame(width: 20)
                    .symbolEffect(.pulse, isActive: engine.isPlayingTest)
                Text("扬声器测试")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { engine.playTestSound() }) {
                    Text(engine.isPlayingTest ? "播放中..." : "播放")
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

            // 麦克风测试
            HStack(spacing: 10) {
                Image(systemName: engine.isMicMonitoring ? "mic.fill" : "mic")
                    .font(.system(size: 14))
                    .foregroundColor(engine.isMicMonitoring ? .red : .secondary)
                    .frame(width: 20)
                Text("麦克风测试")
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
                    Text(engine.isMicMonitoring ? "停止" : "开始")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(engine.isMicMonitoring ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                        .foregroundColor(engine.isMicMonitoring ? .red : .accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // 麦克风电平条
            if engine.isMicMonitoring {
                VStack(spacing: 6) {
                    // 电平条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // 背景刻度
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))

                            // 电平
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

                            // Peak 标记
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

                    // 标签
                    HStack {
                        Text("安静")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                        Spacer()
                        Text(micLevelText(engine.micLevel))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(micLevelColor(engine.micLevel))
                        Spacer()
                        Text("响亮")
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

    private func micLevelText(_ level: Float) -> String {
        if level < 0.05 { return "无信号" }
        if level < 0.2 { return "微弱" }
        if level < 0.4 { return "正常" }
        if level < 0.7 { return "较响" }
        return "很响"
    }

    private func micLevelColor(_ level: Float) -> Color {
        if level < 0.05 { return .secondary }
        if level < 0.4 { return .green }
        if level < 0.7 { return .orange }
        return .red
    }

    // MARK: 修复进度

    var fixProgressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 步骤文字
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

            // 进度条
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

    // MARK: 操作按钮

    var actionsSection: some View {
        VStack(spacing: 10) {
            Text("都设置好了就是不出声音？修复一下")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            ActionButton(
                title: engine.isFixing ? "修复中..." : "重启音频服务",
                subtitle: "重启 coreaudiod，音频会短暂中断",
                icon: "arrow.clockwise.circle",
                style: .primary,
                action: { engine.restartAudioService() }
            )
            .disabled(engine.isScanning || engine.isFixing)
        }
    }

    // MARK: 空状态

    var emptySection: some View {
        VStack(spacing: 14) {
            Image(systemName: "airpodspro")
                .font(.system(size: 44, weight: .thin))
                .foregroundColor(.secondary.opacity(0.4))
            Text(engine.bluetoothOn ? "未找到 AirPods" : "蓝牙未开启")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("确保 AirPods 已取出并靠近 Mac")
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

    // MARK: 日志

    var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showLog ? 90 : 0))
                        .foregroundColor(.secondary)
                    Text("日志")
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
                    .onChange(of: engine.logs.count) {
                        if let last = engine.logs.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 操作按钮组件

struct ActionButton: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let style: ButtonType
    let action: () -> Void
    @State private var isHovered = false

    enum ButtonType { case primary, secondary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if let sub = subtitle {
                        Text(sub)
                            .font(.system(size: 10))
                            .foregroundColor(style == .primary ? .white.opacity(0.7) : .secondary)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: style == .secondary ? 1 : 0)
            )
            .shadow(color: style == .primary ? Color.accentColor.opacity(isHovered ? 0.3 : 0.15) : .clear, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.9 : 1.0))
        case .secondary:
            return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.06 : 0.03))
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .primary
        }
    }

    private var borderColor: Color {
        style == .secondary ? DS.subtleBorder : .clear
    }
}

// MARK: - App Entry

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var sizeObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hostingView = NSHostingView(rootView: ContentView())

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "听得见吗"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor

        // 初始大小适配内容
        let fitting = hostingView.fittingSize
        window.setContentSize(NSSize(width: 380, height: fitting.height))
        window.center()
        window.makeKeyAndOrderFront(nil)

        // 监听内容大小变化，自动调整窗口高度
        sizeObserver = hostingView.observe(\.intrinsicContentSize, options: [.new]) { [weak self] view, _ in
            guard let self = self, let window = self.window else { return }
            let newSize = view.fittingSize
            // 保持窗口顶部不动，向下/上调整
            var frame = window.frame
            let delta = newSize.height - frame.size.height + (frame.size.height - (window.contentView?.frame.height ?? frame.size.height))
            frame.origin.y -= delta
            frame.size.height += delta
            frame.size.width = 380
            window.setFrame(frame, display: true, animate: true)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
