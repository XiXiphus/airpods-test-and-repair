import Foundation
import SwiftUI

private struct OutputSafetyState {
    var volume: Int
    var isMuted: Bool
}

extension DiagnosticEngine {
    func step(_ text: String, progress: Double) {
        log(text)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.fixStepText = text
                self.fixProgress = progress
            }
        }
    }

    func beginFix() {
        fixGeneration += 1
        isFixing = true
        fixDone = false
        fixProgress = 0
        fixStepText = ""
    }

    func endFix() {
        let savedGeneration = fixGeneration
        DispatchQueue.main.async {
            withAnimation {
                self.fixProgress = 1.0
                self.fixDone = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard self.fixGeneration == savedGeneration else { return }
                withAnimation {
                    self.isFixing = false
                    self.fixDone = false
                    self.fixProgress = 0
                    self.fixStepText = ""
                }
            }
        }
    }

    private func currentOutputSafetyState() -> OutputSafetyState? {
        let volumeResult = runShell("osascript -e 'output volume of (get volume settings)'")
        guard volumeResult.succeeded else {
            log(
                lt(
                    en: "Failed to read system volume\(commandFailureSuffix(volumeResult))",
                    zh: "读取系统音量失败\(commandFailureSuffix(volumeResult))",
                    ja: "システム音量の読み取りに失敗しました\(commandFailureSuffix(volumeResult))"
                ),
                isError: true
            )
            return nil
        }

        let mutedResult = runShell("osascript -e 'output muted of (get volume settings)'")
        guard mutedResult.succeeded else {
            log(
                lt(
                    en: "Failed to read mute state\(commandFailureSuffix(mutedResult))",
                    zh: "读取静音状态失败\(commandFailureSuffix(mutedResult))",
                    ja: "ミュート状態の読み取りに失敗しました\(commandFailureSuffix(mutedResult))"
                ),
                isError: true
            )
            return nil
        }

        guard let volume = Int(volumeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            log(
                lt(
                    en: "Could not parse the current system volume: \(volumeResult.output)",
                    zh: "无法解析当前系统音量：\(volumeResult.output)",
                    ja: "現在のシステム音量を解析できませんでした: \(volumeResult.output)"
                ),
                isError: true
            )
            return nil
        }

        return OutputSafetyState(
            volume: min(max(volume, 0), 100),
            isMuted: mutedResult.output == "true"
        )
    }

    @discardableResult
    private func setSystemOutputMuted(_ muted: Bool, failureMessage: String) -> Bool {
        let command = muted
            ? "osascript -e 'set volume with output muted'"
            : "osascript -e 'set volume without output muted'"
        return runCommand(command, failureMessage: failureMessage)
    }

    @discardableResult
    private func setSystemOutputVolume(_ volume: Int, failureMessage: String) -> Bool {
        let clampedVolume = min(max(volume, 0), 100)
        return runCommand(
            "osascript -e 'set volume output volume \(clampedVolume)'",
            failureMessage: failureMessage
        )
    }

    private func reinforceQuietOutputProtection() {
        _ = setSystemOutputMuted(
            true,
            failureMessage: lt(
                en: "Failed to enable protective mute",
                zh: "进入保护静音失败",
                ja: "保護ミュートの有効化に失敗しました"
            )
        )
    }

    private func applyCorrectiveOutputAdjustments(
        to state: inout OutputSafetyState,
        basedOn diagnosis: AudioDiagnosis
    ) {
        if diagnosis.isMuted {
            state.isMuted = false
        }
        if let volume = diagnosis.volumePercent, volume < 10 {
            state.volume = max(state.volume, 50)
        }
    }

    private func restoreOutputSafetyState(_ state: OutputSafetyState) {
        _ = setSystemOutputVolume(
            state.volume,
            failureMessage: lt(
                en: "Failed to restore system volume",
                zh: "恢复系统音量失败",
                ja: "システム音量の復元に失敗しました"
            )
        )
        _ = setSystemOutputMuted(
            state.isMuted,
            failureMessage: lt(
                en: "Failed to restore mute state",
                zh: "恢复静音状态失败",
                ja: "ミュート状態の復元に失敗しました"
            )
        )
    }

    private func restartCoreAudioService() -> Bool {
        let nonInteractiveSudo = runShell("sudo -n killall coreaudiod")
        if nonInteractiveSudo.succeeded {
            return true
        }

        let directKill = runShell("killall coreaudiod")
        if directKill.succeeded {
            return true
        }

        let preferredFailure = nonInteractiveSudo.output.isEmpty ? directKill : nonInteractiveSudo
        log(
            lt(
                en: "Failed to restart the audio service\(commandFailureSuffix(preferredFailure))",
                zh: "无法重启音频服务\(commandFailureSuffix(preferredFailure))",
                ja: "音声サービスを再起動できませんでした\(commandFailureSuffix(preferredFailure))"
            ),
            isError: true
        )
        return false
    }

    private func sanitizedBluetoothAddress(for device: AirPodsDevice) -> String? {
        let safeMac = device.macAddress
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ";", with: "")
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "$", with: "")
        return safeMac.isEmpty ? nil : safeMac
    }

    private func logOutputResolutionFailure(for device: AirPodsDevice, match: AudioOutputMatch) {
        switch match {
        case .matched:
            log(
                lt(
                    en: "The headset became available, but macOS still did not switch the output route",
                    zh: "耳机输出已经出现，但 macOS 仍未切换音频路由",
                    ja: "ヘッドセット出力は利用可能になりましたが、macOS が音声ルートを切り替えませんでした"
                ),
                isError: true
            )
        case .ambiguous:
            log(
                lt(
                    en: "Multiple audio outputs match \(selectedDeviceLabel(for: device)). Select it in System Settings first.",
                    zh: "检测到多个与 \(selectedDeviceLabel(for: device)) 匹配的音频输出，请先在系统声音设置里选中目标设备",
                    ja: "\(selectedDeviceLabel(for: device)) に一致する音声出力が複数あります。先にシステム設定で対象を選んでください。"
                ),
                isError: true
            )
        case .notFound:
            log(
                lt(
                    en: "No audio output was found for \(selectedDeviceLabel(for: device))",
                    zh: "未找到 \(selectedDeviceLabel(for: device)) 的音频输出",
                    ja: "\(selectedDeviceLabel(for: device)) の音声出力が見つかりません"
                ),
                isError: true
            )
        }
    }

    private func waitForResolvedOutput(for device: AirPodsDevice, timeout: TimeInterval) -> AudioOutputMatch {
        let deadline = Date().addingTimeInterval(timeout)
        var lastMatch = matchAudioOutputDevice(for: device)
        while Date() < deadline {
            if case .matched = lastMatch {
                return lastMatch
            }
            Thread.sleep(forTimeInterval: 0.35)
            lastMatch = matchAudioOutputDevice(for: device)
        }
        return lastMatch
    }

    @discardableResult
    private func askBluetoothToClaimDevice(for device: AirPodsDevice) -> Bool {
        guard resolvedToolURL(named: "blueutil") != nil else {
            noteMissingBlueutilIfNeeded()
            return false
        }
        guard let safeMac = sanitizedBluetoothAddress(for: device) else {
            return false
        }

        log(
            lt(
                en: "The headset is not active on this Mac yet. Requesting Bluetooth handoff...",
                zh: "目标耳机还没有切到这台 Mac，尝试请求蓝牙切换...",
                ja: "ヘッドセットはまだこの Mac で有効ではありません。Bluetooth の切り替えを要求しています..."
            )
        )

        let connectResult = runBlueutil(["--connect", safeMac])
        guard connectResult.succeeded else {
            let isPermissionError = connectResult.output.contains("absence of access") || connectResult.status == 134
            if isPermissionError {
                log(
                    lt(
                        en: "Bluetooth access denied. Grant permission in System Settings → Privacy & Security → Bluetooth for AirPods Fix, then retry.",
                        zh: "蓝牙权限被拒绝，请在「系统设置 → 隐私与安全性 → 蓝牙」中允许 AirPods Fix 访问蓝牙，然后重试",
                        ja: "Bluetooth アクセスが拒否されました。「システム設定 → プライバシーとセキュリティ → Bluetooth」で AirPods Fix にアクセスを許可してから再試行してください。"
                    ),
                    isError: true
                )
            } else {
                log(
                    lt(
                        en: "Failed to request Bluetooth handoff\(commandFailureSuffix(connectResult))",
                        zh: "请求蓝牙切换失败\(commandFailureSuffix(connectResult))",
                        ja: "Bluetooth の切り替え要求に失敗しました\(commandFailureSuffix(connectResult))"
                    ),
                    isError: true
                )
            }
            return false
        }

        log(
            lt(
                en: "Bluetooth handoff requested. Waiting for the headset output to appear...",
                zh: "已请求蓝牙切换，等待耳机输出出现在这台 Mac 上...",
                ja: "Bluetooth の切り替えを要求しました。ヘッドセット出力がこの Mac に現れるのを待っています..."
            )
        )
        return true
    }

    @discardableResult
    private func switchResolvedOutputToDefault(_ audioOutput: AudioOutputDevice) -> Bool {
        if defaultOutputDeviceID() == audioOutput.id {
            return true
        }
        guard switchOutputDevice(to: audioOutput) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.35)
        let verified = defaultOutputDeviceID() == audioOutput.id
        return verified
    }

    @discardableResult
    private func switchToSelectedAirPodsOutput(_ device: AirPodsDevice) -> Bool {
        let initialMatch = matchAudioOutputDevice(for: device)
        if case .matched(let audioOutput) = initialMatch,
           switchResolvedOutputToDefault(audioOutput) {
            return true
        }

        let shouldAttemptBluetoothHandoff: Bool
        switch initialMatch {
        case .matched(let audioOutput):
            shouldAttemptBluetoothHandoff = defaultOutputDeviceID() != audioOutput.id
        case .ambiguous, .notFound:
            shouldAttemptBluetoothHandoff = true
        }

        var finalMatch = initialMatch
        if shouldAttemptBluetoothHandoff && askBluetoothToClaimDevice(for: device) {
            finalMatch = waitForResolvedOutput(for: device, timeout: 4.0)
            if case .matched(let refreshedOutput) = finalMatch,
               switchResolvedOutputToDefault(refreshedOutput) {
                return true
            }
        }

        logOutputResolutionFailure(for: device, match: finalMatch)
        return false
    }

    @discardableResult
    private func refreshAudioRoute(
        for device: AirPodsDevice,
        fallbackStep: String,
        fallbackProgress: Double,
        targetStep: String,
        targetProgress: Double,
        settleStep: String,
        settleProgress: Double
    ) -> Bool {
        reinforceQuietOutputProtection()
        step(fallbackStep, progress: fallbackProgress)
        if let fallback = fallbackAudioOutputDevice(excluding: device.name) {
            reinforceQuietOutputProtection()
            if switchOutputDevice(to: fallback) {
                log(
                    lt(
                        en: "Switched to \(fallback.name)",
                        zh: "已切换到 \(fallback.name)",
                        ja: "\(fallback.name) に切り替えました"
                    )
                )
                Thread.sleep(forTimeInterval: 1.0)
            } else {
                log(
                    lt(
                        en: "Failed to switch to \(fallback.name). Will keep trying to reselect \(device.name).",
                        zh: "切换到 \(fallback.name) 失败，继续尝试重选 \(device.name)",
                        ja: "\(fallback.name) への切り替えに失敗しました。\(device.name) の再選択を続けます。"
                    ),
                    isError: true
                )
            }
        } else {
            log(
                lt(
                    en: "No fallback output was found. Reselecting \(device.name) directly.",
                    zh: "未找到可用的备用输出，直接重选 \(device.name)",
                    ja: "使える代替出力が見つからないため、\(device.name) を直接再選択します。"
                )
            )
        }

        step(targetStep, progress: targetProgress)
        reinforceQuietOutputProtection()
        let ok = switchToSelectedAirPodsOutput(device)
        if ok {
            log(
                lt(
                    en: "Switched to \(selectedDeviceLabel(for: device))",
                    zh: "已切换到 \(selectedDeviceLabel(for: device))",
                    ja: "\(selectedDeviceLabel(for: device)) に切り替えました"
                )
            )
        } else {
            log(
                lt(
                    en: "Failed to switch to \(selectedDeviceLabel(for: device))",
                    zh: "切换到 \(selectedDeviceLabel(for: device)) 失败",
                    ja: "\(selectedDeviceLabel(for: device)) への切り替えに失敗しました"
                ),
                isError: true
            )
        }

        step(settleStep, progress: settleProgress)
        reinforceQuietOutputProtection()
        Thread.sleep(forTimeInterval: 1.0)
        return ok
    }

    func fix() {
        guard let dev = device else { return }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let startingDiagnosis = self.diagnoseAudio(for: dev)
            let originalOutputState = currentOutputSafetyState()
            var desiredOutputState = originalOutputState
            if var state = desiredOutputState {
                applyCorrectiveOutputAdjustments(to: &state, basedOn: startingDiagnosis)
                desiredOutputState = state
            }
            defer {
                if let state = desiredOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(
                lt(en: "Protecting current output...", zh: "保护当前输出...", ja: "現在の出力を保護しています..."),
                progress: 0.05
            )
            reinforceQuietOutputProtection()
            let ok = refreshAudioRoute(
                for: dev,
                fallbackStep: lt(en: "Switching to fallback output...", zh: "切换到备用输出...", ja: "代替出力に切り替えています..."),
                fallbackProgress: 0.3,
                targetStep: lt(en: "Switching back to the target headset...", zh: "切换输出到目标耳机...", ja: "対象ヘッドセットへ戻しています..."),
                targetProgress: 0.6,
                settleStep: lt(en: "Waiting for the audio path to settle...", zh: "等待音频通道建立...", ja: "音声経路の確立を待っています..."),
                settleProgress: 0.75
            )

            if let state = desiredOutputState {
                step(
                    lt(en: "Restoring user output settings...", zh: "恢复用户音量设置...", ja: "ユーザーの出力設定を復元しています..."),
                    progress: 0.85
                )
                restoreOutputSafetyState(state)
            }
            step(lt(en: "Verifying result...", zh: "验证修复结果...", ja: "結果を確認しています..."), progress: 0.9)
            self.diagnoseAudio(for: dev)

            if ok {
                step(lt(en: "Audio route refreshed", zh: "音频路由已刷新", ja: "音声ルートを更新しました"), progress: 1.0)
            } else {
                step(
                    lt(
                        en: "Output switching failed. Try restarting audio or reconnecting Bluetooth.",
                        zh: "切换失败，试「重启音频」或「重连蓝牙」",
                        ja: "切り替えに失敗しました。音声サービス再起動または Bluetooth 再接続を試してください。"
                    ),
                    progress: 1.0
                )
            }
            endFix()
        }
    }

    func restartAudioService() {
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let originalOutputState = currentOutputSafetyState()
            defer {
                if let state = originalOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(lt(en: "Protecting current output...", zh: "保护当前输出...", ja: "現在の出力を保護しています..."), progress: 0.05)
            reinforceQuietOutputProtection()
            step(lt(en: "Stopping the audio service...", zh: "停止音频服务...", ja: "音声サービスを停止しています..."), progress: 0.15)
            reinforceQuietOutputProtection()
            guard restartCoreAudioService() else {
                step(lt(en: "Failed to restart the audio service", zh: "重启音频服务失败", ja: "音声サービスの再起動に失敗しました"), progress: 1.0)
                endFix()
                return
            }

            step(lt(en: "Waiting for the service to restart...", zh: "等待服务重启...", ja: "サービスの再起動を待っています..."), progress: 0.35)
            Thread.sleep(forTimeInterval: 1.5)
            step(lt(en: "Audio service is recovering...", zh: "音频服务恢复中...", ja: "音声サービスの復旧中..."), progress: 0.55)
            Thread.sleep(forTimeInterval: 1.5)

            step(lt(en: "Verifying audio state...", zh: "验证音频状态...", ja: "音声状態を確認しています..."), progress: 0.8)
            Thread.sleep(forTimeInterval: 0.5)
            if let state = originalOutputState {
                restoreOutputSafetyState(state)
            }
            if let dev = device {
                self.diagnoseAudio(for: dev)
            }

            step(lt(en: "Audio service restarted", zh: "音频服务已重启", ja: "音声サービスを再起動しました"), progress: 1.0)
            endFix()
        }
    }

    func connectToThisMac() {
        guard ensureBlueutilAvailable(for: lt(en: "Connect to this Mac", zh: "连接到本机", ja: "この Mac に接続")) else { return }
        guard let dev = device else {
            log(lt(en: "No target device", zh: "未选择目标设备", ja: "対象デバイスがありません"), isError: true); return
        }
        guard let safeMac = sanitizedBluetoothAddress(for: dev) else {
            log(lt(en: "Bluetooth address is invalid or missing", zh: "蓝牙地址无效或缺失", ja: "Bluetooth アドレスが無効か不足しています"), isError: true); return
        }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let originalOutputState = currentOutputSafetyState()
            defer {
                if let state = originalOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(lt(en: "Requesting Bluetooth connection...", zh: "请求蓝牙连接...", ja: "Bluetooth 接続を要求しています..."), progress: 0.1)
            reinforceQuietOutputProtection()
            let connectResult = runBlueutil(["--connect", safeMac])
            guard connectResult.succeeded else {
                let isPermissionError = connectResult.output.contains("absence of access") || connectResult.status == 134
                if isPermissionError {
                    log(
                        lt(
                            en: "Bluetooth access denied. Grant permission in System Settings → Privacy & Security → Bluetooth for AirPods Fix, then retry.",
                            zh: "蓝牙权限被拒绝，请在「系统设置 → 隐私与安全性 → 蓝牙」中允许 AirPods Fix，然后重试",
                            ja: "Bluetooth アクセスが拒否されました。「システム設定 → プライバシーとセキュリティ → Bluetooth」で許可してください。"
                        ),
                        isError: true
                    )
                } else {
                    log(
                        lt(
                            en: "Failed to connect\(commandFailureSuffix(connectResult))",
                            zh: "连接失败\(commandFailureSuffix(connectResult))",
                            ja: "接続に失敗しました\(commandFailureSuffix(connectResult))"
                        ),
                        isError: true
                    )
                }
                step(lt(en: "Connection failed", zh: "连接失败", ja: "接続に失敗しました"), progress: 1.0)
                endFix()
                return
            }

            step(lt(en: "Waiting for Bluetooth handshake...", zh: "等待蓝牙握手...", ja: "Bluetooth ハンドシェイクを待っています..."), progress: 0.3)
            Thread.sleep(forTimeInterval: 2.0)
            step(lt(en: "Establishing audio path...", zh: "建立音频通道...", ja: "音声経路を確立しています..."), progress: 0.5)
            Thread.sleep(forTimeInterval: 2.0)

            step(lt(en: "Switching audio output...", zh: "切换音频输出...", ja: "音声出力を切り替えています..."), progress: 0.7)
            _ = switchToSelectedAirPodsOutput(dev)
            Thread.sleep(forTimeInterval: 1.0)

            if let state = originalOutputState {
                step(lt(en: "Restoring volume...", zh: "恢复音量...", ja: "音量を復元しています..."), progress: 0.85)
                restoreOutputSafetyState(state)
            }

            step(lt(en: "Verifying connection...", zh: "验证连接...", ja: "接続を確認しています..."), progress: 0.9)
            let finalDiag = self.diagnoseAudio(for: dev)

            if finalDiag.isDefaultOutput {
                step(lt(en: "Connected successfully", zh: "连接成功", ja: "接続に成功しました"), progress: 1.0)
            } else if finalDiag.isAudioOutputAvailable {
                step(
                    lt(
                        en: "Connected, but macOS did not switch the output automatically. Select the headset in Sound settings, then retry repair if needed.",
                        zh: "已连接，但 macOS 没有自动切换输出。请先在声音设置中选中耳机，必要时再重试修复。",
                        ja: "接続されましたが、macOS が出力を自動で切り替えませんでした。サウンド設定でヘッドセットを選択してから、必要なら再度修復してください。"
                    ),
                    progress: 1.0
                )
            } else {
                step(lt(en: "Connection requested, but the audio output hasn't appeared yet. Try scanning again in a few seconds.", zh: "已请求连接，但音频输出尚未出现，稍后重新扫描试试", ja: "接続を要求しましたが、音声出力がまだ現れません。数秒後にもう一度スキャンしてください。"), progress: 1.0)
            }
            endFix()
        }
    }

    func reconnectBluetooth() {
        guard ensureBlueutilAvailable(for: lt(en: "Bluetooth reconnect", zh: "蓝牙重连", ja: "Bluetooth 再接続")) else { return }
        guard let dev = device else {
            log(lt(en: "No repair target was found", zh: "未找到可修复的设备", ja: "修復対象のデバイスが見つかりません"), isError: true); return
        }
        guard let safeMac = sanitizedBluetoothAddress(for: dev) else {
            log(lt(en: "Bluetooth address is invalid or missing", zh: "蓝牙地址无效或缺失", ja: "Bluetooth アドレスが無効か不足しています"), isError: true); return
        }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let originalOutputState = currentOutputSafetyState()
            defer {
                if let state = originalOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(lt(en: "Protecting current output...", zh: "保护当前输出...", ja: "現在の出力を保護しています..."), progress: 0.05)
            reinforceQuietOutputProtection()
            step(lt(en: "Disconnecting the target headset...", zh: "断开目标耳机...", ja: "対象ヘッドセットを切断しています..."), progress: 0.1)
            reinforceQuietOutputProtection()
            let disconnectResult = runBlueutil(["--disconnect", safeMac])
            let disconnectSucceeded = disconnectResult.succeeded
            if !disconnectSucceeded {
                log(
                    lt(
                        en: "Failed to disconnect the Bluetooth device\(commandFailureSuffix(disconnectResult))",
                        zh: "断开蓝牙设备失败\(commandFailureSuffix(disconnectResult))",
                        ja: "Bluetooth デバイスの切断に失敗しました\(commandFailureSuffix(disconnectResult))"
                    ),
                    isError: true
                )
            }

            step(lt(en: "Waiting for disconnect...", zh: "等待断开完成...", ja: "切断完了を待っています..."), progress: 0.2)
            Thread.sleep(forTimeInterval: 1.5)
            step(lt(en: "Disconnected. Preparing to reconnect...", zh: "已断开，准备重连...", ja: "切断しました。再接続を準備しています..."), progress: 0.3)
            Thread.sleep(forTimeInterval: 1.5)

            step(lt(en: "Reconnecting the target headset...", zh: "重新连接目标耳机...", ja: "対象ヘッドセットを再接続しています..."), progress: 0.4)
            reinforceQuietOutputProtection()
            let reconnectResult = runBlueutil(["--connect", safeMac])
            guard reconnectResult.succeeded else {
                log(
                    lt(
                        en: "Failed to reconnect the Bluetooth device\(commandFailureSuffix(reconnectResult))",
                        zh: "重新连接蓝牙设备失败\(commandFailureSuffix(reconnectResult))",
                        ja: "Bluetooth デバイスの再接続に失敗しました\(commandFailureSuffix(reconnectResult))"
                    ),
                    isError: true
                )
                step(
                    disconnectSucceeded
                        ? lt(en: "Bluetooth reconnect failed", zh: "蓝牙重连失败", ja: "Bluetooth の再接続に失敗しました")
                        : lt(en: "Bluetooth disconnect/reconnect failed", zh: "蓝牙断开/重连失败", ja: "Bluetooth の切断/再接続に失敗しました"),
                    progress: 1.0
                )
                endFix()
                return
            }

            step(lt(en: "Waiting for Bluetooth handshake...", zh: "等待蓝牙握手...", ja: "Bluetooth ハンドシェイクを待っています..."), progress: 0.5)
            Thread.sleep(forTimeInterval: 2)
            step(lt(en: "Establishing audio path...", zh: "建立音频通道...", ja: "音声経路を確立しています..."), progress: 0.65)
            Thread.sleep(forTimeInterval: 2)
            step(lt(en: "Stabilizing connection...", zh: "连接稳定中...", ja: "接続を安定化しています..."), progress: 0.8)
            Thread.sleep(forTimeInterval: 1)

            step(lt(en: "Verifying connection...", zh: "验证连接状态...", ja: "接続状態を確認しています..."), progress: 0.9)
            if let state = originalOutputState {
                restoreOutputSafetyState(state)
            }
            self.diagnoseAudio(for: dev)

            step(lt(en: "Bluetooth reconnect finished", zh: "蓝牙重连完成", ja: "Bluetooth の再接続が完了しました"), progress: 1.0)
            endFix()
        }
    }

    func runSmartRepair() {
        guard let dev = device else { return }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in

            step(lt(en: "Repair started: reading current audio state...", zh: "开始修复：读取当前音频状态...", ja: "修復開始: 現在の音声状態を読み取っています..."), progress: 0.03)
            let currentDiagnosis = self.diagnoseAudio(for: dev)
            let originalOutputState = currentOutputSafetyState()
            var desiredOutputState = originalOutputState
            if var state = desiredOutputState {
                applyCorrectiveOutputAdjustments(to: &state, basedOn: currentDiagnosis)
                desiredOutputState = state
            }
            defer {
                if let state = desiredOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(lt(en: "Repair started: protecting current output...", zh: "开始修复：保护当前输出...", ja: "修復開始: 現在の出力を保護しています..."), progress: 0.05)
            reinforceQuietOutputProtection()
            _ = refreshAudioRoute(
                for: dev,
                fallbackStep: lt(en: "Refreshing the audio route...", zh: "刷新音频路由...", ja: "音声ルートを更新しています..."),
                fallbackProgress: 0.20,
                targetStep: lt(en: "Reselecting the target headset output...", zh: "重选目标耳机输出...", ja: "対象ヘッドセット出力を再選択しています..."),
                targetProgress: 0.24,
                settleStep: lt(en: "Waiting for the audio path to settle...", zh: "等待音频通道建立...", ja: "音声経路の確立を待っています..."),
                settleProgress: 0.28
            )

            if let state = desiredOutputState {
                step(lt(en: "Restoring user output settings...", zh: "恢复用户音量设置...", ja: "ユーザーの出力設定を復元しています..."), progress: 0.29)
                restoreOutputSafetyState(state)
            }
            step(lt(en: "Soft repair finished. Verifying state...", zh: "软修复完成，验证状态...", ja: "ソフト修復が完了しました。状態を確認しています..."), progress: 0.30)
            let softDiagnosis = self.diagnoseAudio(for: dev)

            if !softDiagnosis.hasIssue {
                step(lt(en: "Soft repair resolved the issue", zh: "软修复已解决问题", ja: "ソフト修復で問題が解決しました"), progress: 1.0)
                endFix()
                return
            }

            reinforceQuietOutputProtection()
            step(lt(en: "Soft repair was not enough. Restarting the audio service...", zh: "软修复未解决，重启音频服务...", ja: "ソフト修復では解決しませんでした。音声サービスを再起動しています..."), progress: 0.35)
            let audioRestarted = restartCoreAudioService()

            if audioRestarted {
                step(lt(en: "Waiting for the service to restart...", zh: "等待服务重启...", ja: "サービスの再起動を待っています..."), progress: 0.45)
                Thread.sleep(forTimeInterval: 1.5)
                step(lt(en: "Audio service is recovering...", zh: "音频服务恢复中...", ja: "音声サービスの復旧中..."), progress: 0.55)
                Thread.sleep(forTimeInterval: 1.5)
            } else {
                step(lt(en: "Could not restart the audio service. Will continue with Bluetooth reconnect...", zh: "无法重启音频服务，继续尝试蓝牙重连...", ja: "音声サービスを再起動できなかったため、Bluetooth 再接続を続けます..."), progress: 0.60)
            }

            if let state = desiredOutputState {
                step(lt(en: "Restoring user output settings...", zh: "恢复用户音量设置...", ja: "ユーザーの出力設定を復元しています..."), progress: 0.59)
                restoreOutputSafetyState(state)
            }
            step(lt(en: "Medium repair finished. Verifying state...", zh: "中修复完成，验证状态...", ja: "中程度の修復が完了しました。状態を確認しています..."), progress: 0.60)
            let mediumDiagnosis = self.diagnoseAudio(for: dev)

            if !mediumDiagnosis.hasIssue {
                step(lt(en: "Medium repair resolved the issue", zh: "中修复已解决问题", ja: "中程度の修復で問題が解決しました"), progress: 1.0)
                endFix()
                return
            }

            guard ensureBlueutilAvailable(for: lt(en: "Bluetooth reconnect", zh: "蓝牙重连", ja: "Bluetooth 再接続")) else {
                step(lt(en: "blueutil is unavailable, so Bluetooth reconnect cannot run", zh: "未找到 blueutil，无法执行蓝牙重连", ja: "blueutil がないため Bluetooth 再接続を実行できません"), progress: 1.0)
                endFix()
                return
            }

            guard let safeMac = sanitizedBluetoothAddress(for: dev) else {
                step(lt(en: "Medium repair was not enough, but the Bluetooth address is unavailable", zh: "中修复未解决，但无法获取蓝牙地址", ja: "中程度の修復では解決しませんでしたが、Bluetooth アドレスを取得できません"), progress: 1.0)
                endFix()
                return
            }

            reinforceQuietOutputProtection()
            step(lt(en: "Medium repair was not enough. Disconnecting Bluetooth...", zh: "中修复未解决，断开蓝牙...", ja: "中程度の修復では解決しませんでした。Bluetooth を切断しています..."), progress: 0.65)
            let disconnectResult = runBlueutil(["--disconnect", safeMac])
            let disconnectSucceeded = disconnectResult.succeeded
            if !disconnectSucceeded {
                log(
                    lt(
                        en: "Failed to disconnect the Bluetooth device\(commandFailureSuffix(disconnectResult))",
                        zh: "断开蓝牙设备失败\(commandFailureSuffix(disconnectResult))",
                        ja: "Bluetooth デバイスの切断に失敗しました\(commandFailureSuffix(disconnectResult))"
                    ),
                    isError: true
                )
            }

            step(lt(en: "Waiting for Bluetooth disconnect...", zh: "等待蓝牙断开...", ja: "Bluetooth の切断を待っています..."), progress: 0.72)
            Thread.sleep(forTimeInterval: 1.5)
            step(lt(en: "Reconnecting the target headset...", zh: "重新连接目标耳机...", ja: "対象ヘッドセットを再接続しています..."), progress: 0.78)
            reinforceQuietOutputProtection()
            let reconnectResult = runBlueutil(["--connect", safeMac])
            guard reconnectResult.succeeded else {
                log(
                    lt(
                        en: "Failed to reconnect the Bluetooth device\(commandFailureSuffix(reconnectResult))",
                        zh: "重新连接蓝牙设备失败\(commandFailureSuffix(reconnectResult))",
                        ja: "Bluetooth デバイスの再接続に失敗しました\(commandFailureSuffix(reconnectResult))"
                    ),
                    isError: true
                )
                step(
                    disconnectSucceeded
                        ? lt(en: "Hard repair failed", zh: "硬修复执行失败", ja: "ハード修復に失敗しました")
                        : lt(en: "Hard repair could not complete the Bluetooth reconnect", zh: "硬修复未能完成蓝牙重连", ja: "ハード修復で Bluetooth 再接続を完了できませんでした"),
                    progress: 1.0
                )
                endFix()
                return
            }

            step(lt(en: "Waiting for Bluetooth handshake and audio path...", zh: "等待蓝牙握手与音频通道建立...", ja: "Bluetooth ハンドシェイクと音声経路の確立を待っています..."), progress: 0.88)
            Thread.sleep(forTimeInterval: 4.0)

            if let state = desiredOutputState {
                step(lt(en: "Restoring user output settings...", zh: "恢复用户音量设置...", ja: "ユーザーの出力設定を復元しています..."), progress: 0.93)
                restoreOutputSafetyState(state)
            }
            step(lt(en: "Hard repair finished. Verifying state...", zh: "硬修复完成，验证状态...", ja: "ハード修復が完了しました。状態を確認しています..."), progress: 0.95)
            let finalDiagnosis = self.diagnoseAudio(for: dev)

            if finalDiagnosis.hasIssue {
                step(lt(en: "All repair attempts finished, but the issue remains. Hardware should be checked next.", zh: "所有修复尝试完毕，仍有问题，建议检查硬件", ja: "すべての修復を試しましたが、まだ問題があります。次はハードウェアを確認してください。"), progress: 1.0)
            } else {
                step(lt(en: "Hard repair resolved the issue. The headset is back to normal.", zh: "硬修复已解决问题，目标耳机恢复正常", ja: "ハード修復で問題が解決しました。ヘッドセットは正常に戻りました。"), progress: 1.0)
            }
            endFix()
        }
    }
}
