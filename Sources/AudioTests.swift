import AppKit
import AVFoundation
import Foundation
import SwiftUI

extension DiagnosticEngine {
    func playTestSound() {
        isPlayingTest = true
        log(lt(en: "Playing test sound...", zh: "播放测试音...", ja: "テスト音を再生しています..."))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let sound = NSSound(named: "Ping") {
                sound.play()
                Thread.sleep(forTimeInterval: 1.0)
            }
            if let sound = NSSound(named: "Glass") {
                sound.play()
                Thread.sleep(forTimeInterval: 1.0)
            }
            log(lt(en: "Test sound finished", zh: "测试音播放完毕", ja: "テスト音の再生が完了しました"))
            DispatchQueue.main.async { self.isPlayingTest = false }
        }
    }

    func startMicMonitor() {
        guard !isMicMonitoring else { return }
        micRetryCount = 0
        launchMicEngine()
    }

    func launchMicEngine() {
        if let old = audioEngine {
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }

        log(lt(en: "Starting microphone monitor...", zh: "启动麦克风监测...", ja: "マイク監視を開始しています..."))

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.inputFormat(forBus: 0)
        log(
            lt(
                en: "Microphone format: \(Int(nativeFormat.sampleRate))Hz / \(nativeFormat.channelCount)ch",
                zh: "麦克风格式: \(Int(nativeFormat.sampleRate))Hz / \(nativeFormat.channelCount)ch",
                ja: "マイク形式: \(Int(nativeFormat.sampleRate))Hz / \(nativeFormat.channelCount)ch"
            )
        )

        var silentFrames = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

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

            let db = 20 * log10(max(maxRMS, 0.000001))
            let normalized = max(0, min(1, (db + 50) / 50))

            if maxRMS < 0.0001 {
                silentFrames += 1
                if silentFrames > 30 && self.micRetryCount < 2 {
                    silentFrames = 0
                    self.micRetryCount += 1
                    DispatchQueue.main.async {
                        self.log(
                            self.lt(
                                en: "Silence detected. Restarting microphone engine (attempt \(self.micRetryCount))...",
                                zh: "检测到静音，重启麦克风引擎 (第\(self.micRetryCount)次)...",
                                ja: "無音を検出しました。マイクエンジンを再起動します（\(self.micRetryCount)回目）..."
                            )
                        )
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
            log(lt(en: "Microphone monitor is running...", zh: "麦克风监测中...", ja: "マイク監視中..."))

            peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.micPeak = max(self.micPeak - 0.1, 0)
            }
        } catch {
            log(
                lt(
                    en: "Failed to start microphone monitor: \(error.localizedDescription)",
                    zh: "麦克风启动失败: \(error.localizedDescription)",
                    ja: "マイク監視の開始に失敗しました: \(error.localizedDescription)"
                ),
                isError: true
            )
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
        log(lt(en: "Microphone monitor stopped", zh: "麦克风监测已停止", ja: "マイク監視を停止しました"))
    }
}
