import AppKit
import AVFoundation
import CoreAudio
import Foundation
import SwiftUI

// MARK: - Diagnostic engine

class DiagnosticEngine: ObservableObject {
    static let languageDefaultsKey = "selectedLanguage"

    @Published var device: AirPodsDevice?
    @Published var diagnosis = AudioDiagnosis()
    @Published var logs: [LogEntry] = []
    @Published var isScanning = false
    @Published var isFixing = false
    @Published var bluetoothOn = true
    @Published var allDevices: [AirPodsDevice] = []
    @Published var language = AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: DiagnosticEngine.languageDefaultsKey) ?? ""
    ) ?? .english

    @Published var fixProgress: Double = 0
    @Published var fixStepText: String = ""
    @Published var fixDone: Bool = false

    @Published var isPlayingTest = false

    @Published var micLevel: Float = 0
    @Published var micPeak: Float = 0
    @Published var isMicMonitoring = false

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let message: String
        let isError: Bool
    }

    private var hasLoggedMissingBlueutil = false
    private var audioDeviceChangeObserverInstalled = false
    private var activationObserver: Any?
    private var lastAutoScanTime: Date = .distantPast

    var audioEngine: AVAudioEngine?
    var peakDecayTimer: Timer?
    var micRetryCount = 0

    init() {
        scan()
        installAutoRefresh()
    }

    private func installAutoRefresh() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.autoScanIfNeeded()
        }
        installAudioDeviceChangeListener()
    }

    private func autoScanIfNeeded() {
        guard !isScanning, !isFixing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutoScanTime) > 3 else { return }
        lastAutoScanTime = now
        scan()
    }

    private func installAudioDeviceChangeListener() {
        guard !audioDeviceChangeObserverInstalled else { return }
        audioDeviceChangeObserverInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.autoScanIfNeeded()
        }
    }

    deinit {
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func log(_ msg: String, isError: Bool = false) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let entry = LogEntry(time: fmt.string(from: Date()), message: msg, isError: isError)
        DispatchQueue.main.async { self.logs.append(entry) }
    }

    func selectedDeviceLabel(for device: AirPodsDevice) -> String {
        allDevices.count > 1 ? device.pickerLabel : device.name
    }

    func lt(en: String, zh: String, ja: String) -> String {
        localized(language, en: en, zh: zh, ja: ja)
    }

    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        UserDefaults.standard.set(language.rawValue, forKey: DiagnosticEngine.languageDefaultsKey)
        DispatchQueue.main.async {
            self.language = language
        }
    }

    func blueutilGuidance() -> String {
        lt(
            en: "blueutil not found; use the prebuilt release, or install blueutil first (`brew install blueutil`)",
            zh: "未找到 blueutil；请使用预编译发布版，或先安装 blueutil（brew install blueutil）",
            ja: "blueutil が見つかりません。配布版を使うか、先に blueutil をインストールしてください（`brew install blueutil`）"
        )
    }

    func noteMissingBlueutilIfNeeded() {
        guard !hasLoggedMissingBlueutil else { return }
        hasLoggedMissingBlueutil = true
        log(
            lt(
                en: "Bluetooth reconnect is limited. \(blueutilGuidance())",
                zh: "蓝牙重连功能受限，\(blueutilGuidance())",
                ja: "Bluetooth 再接続は制限されています。\(blueutilGuidance())"
            )
        )
    }

    func ensureBlueutilAvailable(for feature: String) -> Bool {
        guard resolvedToolURL(named: "blueutil") != nil else {
            log(
                lt(
                    en: "\(feature) requires blueutil. \(blueutilGuidance())",
                    zh: "\(feature) 需要 blueutil，\(blueutilGuidance())",
                    ja: "\(feature) には blueutil が必要です。\(blueutilGuidance())"
                ),
                isError: true
            )
            return false
        }
        return true
    }

    func commandFailureSuffix(_ result: ShellCommandResult) -> String {
        let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return localized(
                language,
                en: " (exit code \(result.status))",
                zh: "（退出码 \(result.status)）",
                ja: "（終了コード \(result.status)）"
            )
        }
        return localized(
            language,
            en: ": \(trimmedOutput)",
            zh: "：\(trimmedOutput)",
            ja: "：\(trimmedOutput)"
        )
    }

    @discardableResult
    func runCommand(_ command: String, failureMessage: String) -> Bool {
        let result = runShell(command)
        guard result.succeeded else {
            log("\(failureMessage)\(commandFailureSuffix(result))", isError: true)
            return false
        }
        return true
    }

    func selectDevice(withID id: String) {
        guard let selected = allDevices.first(where: { $0.id == id }) else { return }
        guard device?.id != selected.id else { return }
        DispatchQueue.main.async { self.device = selected }
        log(
            lt(
                en: "Switched target device: \(selectedDeviceLabel(for: selected))",
                zh: "切换目标设备: \(selectedDeviceLabel(for: selected))",
                ja: "対象デバイスを切り替えました: \(selectedDeviceLabel(for: selected))"
            )
        )
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            diagnoseAudio(for: selected)
        }
    }

    func scan() {
        isScanning = true
        logs.removeAll()
        log(lt(en: "Starting scan...", zh: "开始扫描...", ja: "スキャンを開始します..."))

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let previousDeviceID = device?.id
            let btPower = runBlueutil(["--power"])
            let btSysProf = runShell("system_profiler SPBluetoothDataType | head -5")
            if btPower.status == 127 {
                noteMissingBlueutilIfNeeded()
            }
            let hasBTOn = btPower.succeeded && btPower.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                || btSysProf.output.contains("State: On")
            log(
                lt(
                    en: "Bluetooth: \(hasBTOn ? "On" : "Off")",
                    zh: "蓝牙: \(hasBTOn ? "已开启" : "未开启")",
                    ja: "Bluetooth: \(hasBTOn ? "オン" : "オフ")"
                )
            )
            DispatchQueue.main.async { self.bluetoothOn = hasBTOn }
            if !hasBTOn {
                log(lt(en: "Bluetooth is off", zh: "蓝牙未开启", ja: "Bluetooth がオフです"), isError: true)
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            let btInfoResult = runShell("system_profiler SPBluetoothDataType")
            guard btInfoResult.succeeded else {
                log(
                    lt(
                        en: "Failed to read Bluetooth device info\(commandFailureSuffix(btInfoResult))",
                        zh: "读取蓝牙设备信息失败\(commandFailureSuffix(btInfoResult))",
                        ja: "Bluetooth デバイス情報の読み取りに失敗しました\(commandFailureSuffix(btInfoResult))"
                    ),
                    isError: true
                )
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            let audioOutputs = listAudioOutputDevices()
            struct BluetoothScanCandidate {
                let device: AirPodsDevice
                let matchedOutput: AudioOutputDevice
                let score: Int
            }

            var bestCandidateByOutputID: [AudioDeviceID: BluetoothScanCandidate] = [:]
            for block in bluetoothDeviceBlocks(from: btInfoResult.output) {
                var battL = "-", battR = "-", battC = "-", mac = ""
                for line in block.lines {
                    if line.starts(with: "Left Battery Level:") { battL = line.components(separatedBy: ": ").last ?? "-" }
                    if line.starts(with: "Right Battery Level:") { battR = line.components(separatedBy: ": ").last ?? "-" }
                    if line.starts(with: "Case Battery Level:") { battC = line.components(separatedBy: ": ").last ?? "-" }
                    if line.starts(with: "Address:") { mac = line.components(separatedBy: ": ").last ?? "" }
                }

                guard battL != "-" || battR != "-" else { continue }
                guard let bestMatch = bestMatchingAudioOutput(
                    forBluetoothName: block.name,
                    macAddress: mac,
                    among: audioOutputs
                ) else { continue }

                let candidate = BluetoothScanCandidate(
                    device: AirPodsDevice(
                        name: block.name,
                        batteryLeft: battL,
                        batteryRight: battR,
                        batteryCase: battC,
                        macAddress: mac
                    ),
                    matchedOutput: bestMatch.device,
                    score: bestMatch.score
                )

                if let existing = bestCandidateByOutputID[candidate.matchedOutput.id] {
                    if candidate.score > existing.score {
                        bestCandidateByOutputID[candidate.matchedOutput.id] = candidate
                    }
                } else {
                    bestCandidateByOutputID[candidate.matchedOutput.id] = candidate
                }
            }

            let devices = bestCandidateByOutputID.values
                .sorted { lhs, rhs in
                    if lhs.device.name != rhs.device.name {
                        return lhs.device.name.localizedStandardCompare(rhs.device.name) == .orderedAscending
                    }
                    return lhs.device.id < rhs.device.id
                }
                .map(\.device)

            let selectedDevice = devices.first(where: { $0.id == previousDeviceID }) ?? devices.first
            DispatchQueue.main.async {
                self.allDevices = devices
                self.device = selectedDevice
            }

            if devices.isEmpty {
                self.log(
                    lt(
                        en: "No connected headset was found",
                        zh: "未找到已连接的蓝牙耳机",
                        ja: "接続中のヘッドセットが見つかりません"
                    ),
                    isError: true
                )
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            if devices.count > 1 {
                self.log(
                    lt(
                        en: "Detected \(devices.count) compatible headsets. You can switch the target device in the device card.",
                        zh: "检测到 \(devices.count) 台可修复的蓝牙耳机，可在设备卡片中切换目标设备",
                        ja: "対応ヘッドセットを \(devices.count) 台検出しました。デバイスカードで対象を切り替えられます。"
                    )
                )
            }

            guard let selectedDevice else {
                self.log(
                    lt(
                        en: "No usable target device was found",
                        zh: "未找到可用的目标设备",
                        ja: "使用可能な対象デバイスが見つかりません"
                    ),
                    isError: true
                )
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            self.log(
                lt(
                    en: "Connected: \(self.selectedDeviceLabel(for: selectedDevice))",
                    zh: "已连接: \(self.selectedDeviceLabel(for: selectedDevice))",
                    ja: "接続済み: \(self.selectedDeviceLabel(for: selectedDevice))"
                )
            )
            self.diagnoseAudio(for: selectedDevice)
            DispatchQueue.main.async { self.isScanning = false }
        }
    }

    @discardableResult
    func diagnoseAudio(for device: AirPodsDevice) -> AudioDiagnosis {
        var diag = AudioDiagnosis()

        switch matchAudioOutputDevice(for: device) {
        case .matched(let audioOutput):
            if let channels = outputChannelCount(for: audioOutput.id) {
                diag.outputChannels = "\(channels)"
            }
            if let sampleRate = nominalSampleRate(for: audioOutput.id) {
                diag.sampleRate = "\(sampleRate)"
            }
            diag.isDefaultOutput = defaultOutputDeviceID() == audioOutput.id
        case .ambiguous:
            log(
                lt(
                    en: "Multiple audio outputs match \(selectedDeviceLabel(for: device)). Select the target in System Settings first.",
                    zh: "检测到多个与 \(selectedDeviceLabel(for: device)) 匹配的音频输出，请先在系统声音设置里选中目标设备",
                    ja: "\(selectedDeviceLabel(for: device)) に一致する音声出力が複数あります。先にシステム設定で対象を選んでください。"
                ),
                isError: true
            )
        case .notFound:
            log(
                lt(
                    en: "Could not find \(selectedDeviceLabel(for: device)) in the audio output list",
                    zh: "未在音频输出列表中找到 \(selectedDeviceLabel(for: device))",
                    ja: "音声出力一覧に \(selectedDeviceLabel(for: device)) が見つかりません"
                ),
                isError: true
            )
        }

        let volumeResult = runShell("osascript -e 'output volume of (get volume settings)'")
        if volumeResult.succeeded {
            diag.volume = volumeResult.output
        } else {
            log(
                lt(
                    en: "Failed to read system volume\(commandFailureSuffix(volumeResult))",
                    zh: "读取系统音量失败\(commandFailureSuffix(volumeResult))",
                    ja: "システム音量の読み取りに失敗しました\(commandFailureSuffix(volumeResult))"
                ),
                isError: true
            )
        }

        let mutedResult = runShell("osascript -e 'output muted of (get volume settings)'")
        if mutedResult.succeeded {
            diag.isMuted = mutedResult.output == "true"
        } else {
            log(
                lt(
                    en: "Failed to read mute state\(commandFailureSuffix(mutedResult))",
                    zh: "读取静音状态失败\(commandFailureSuffix(mutedResult))",
                    ja: "ミュート状態の読み取りに失敗しました\(commandFailureSuffix(mutedResult))"
                ),
                isError: true
            )
        }

        let modeLabel = diag.modeLabel(in: language)
        log(
            lt(
                en: "Mode: \(modeLabel) | Volume: \(diag.volume)%\(diag.isMuted ? " (muted)" : "")",
                zh: "模式: \(modeLabel) | 音量: \(diag.volume)%\(diag.isMuted ? " (静音)" : "")",
                ja: "モード: \(modeLabel) | 音量: \(diag.volume)%\(diag.isMuted ? " (ミュート)" : "")"
            )
        )
        if !diag.isDefaultOutput {
            log(
                lt(
                    en: "\(selectedDeviceLabel(for: device)) is not the current output device",
                    zh: "\(selectedDeviceLabel(for: device)) 非当前输出设备",
                    ja: "\(selectedDeviceLabel(for: device)) は現在の出力デバイスではありません"
                ),
                isError: true
            )
        }
        if diag.isMuted {
            log(lt(en: "System output is muted", zh: "系统已静音", ja: "システム出力はミュートです"), isError: true)
        }
        if diag.isDefaultOutput, diag.isReducedQualityMode {
            log(
                lt(
                    en: "Current output mode is degraded: \(modeLabel)",
                    zh: "当前输出模式异常：\(modeLabel)",
                    ja: "現在の出力モードが劣化しています: \(modeLabel)"
                ),
                isError: true
            )
        }
        DispatchQueue.main.async { self.diagnosis = diag }
        return diag
    }
}
