import CoreAudio
import Foundation

// MARK: - Localization

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        }
    }

    var shortLabel: String {
        switch self {
        case .english: return "EN"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        }
    }
}

func localized(_ language: AppLanguage, en: String, zh: String, ja: String) -> String {
    switch language {
    case .english: return en
    case .chinese: return zh
    case .japanese: return ja
    }
}

// MARK: - Headset / diagnosis models

struct AirPodsDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let batteryLeft: String
    let batteryRight: String
    let batteryCase: String
    let macAddress: String

    init(name: String, batteryLeft: String, batteryRight: String, batteryCase: String, macAddress: String) {
        self.name = name
        self.batteryLeft = batteryLeft
        self.batteryRight = batteryRight
        self.batteryCase = batteryCase
        self.macAddress = macAddress
        let normalizedMAC = normalizeHardwareIdentifier(macAddress)
        self.id = normalizedMAC.isEmpty ? normalizeAudioDeviceName(name) : normalizedMAC
    }

    var shortAddress: String? {
        let normalizedMAC = normalizeHardwareIdentifier(macAddress)
        guard normalizedMAC.count >= 4 else { return nil }
        return String(normalizedMAC.suffix(4)).uppercased()
    }

    var pickerLabel: String {
        guard let shortAddress else { return name }
        return "\(name) · \(shortAddress)"
    }
}

struct AudioDiagnosis {
    var isDefaultOutput = false
    var isAudioOutputAvailable = false
    var outputChannels = "?"
    var sampleRate = "?"
    var volume = "?"
    var isMuted = false

    var channelCount: Int? { Int(outputChannels) }
    var sampleRateHz: Int? { Int(sampleRate) }
    var volumePercent: Int? { Int(volume) }

    var isLowVolume: Bool {
        (volumePercent ?? 50) < 5
    }

    var isReducedQualityMode: Bool {
        guard let ch = channelCount, let sr = sampleRateHz else { return false }
        return ch < 2 || sr < 44100
    }

    var hasIssue: Bool {
        !isAudioOutputAvailable || !isDefaultOutput || isMuted || isLowVolume || isReducedQualityMode
    }

    func modeLabel(in language: AppLanguage) -> String {
        guard isAudioOutputAvailable else {
            return localized(language, en: "Not connected", zh: "未连接到本机", ja: "未接続")
        }
        guard let ch = channelCount, let sr = sampleRateHz else {
            return localized(language, en: "Unknown", zh: "未知", ja: "不明")
        }
        if ch >= 2 && sr >= 44100 {
            return localized(
                language,
                en: "Stereo \(sr / 1000)kHz",
                zh: "立体声 \(sr / 1000)kHz",
                ja: "ステレオ \(sr / 1000)kHz"
            )
        }
        if ch == 1 && sr == 24000 {
            return localized(
                language,
                en: "Mono 24kHz",
                zh: "单声道 24kHz",
                ja: "モノラル 24kHz"
            )
        }
        if ch == 1 && (sr == 8000 || sr == 16000) {
            return localized(
                language,
                en: "Call mode \(sr / 1000)kHz",
                zh: "通话模式 \(sr / 1000)kHz",
                ja: "通話モード \(sr / 1000)kHz"
            )
        }
        return localized(
            language,
            en: "\(ch == 1 ? "Mono" : "Stereo") \(sr / 1000)kHz",
            zh: "\(ch == 1 ? "单声道" : "立体声") \(sr / 1000)kHz",
            ja: "\(ch == 1 ? "モノラル" : "ステレオ") \(sr / 1000)kHz"
        )
    }
}

// MARK: - CoreAudio device snapshot

struct AudioOutputDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let modelUID: String
    let transportType: UInt32
    let isOutput: Bool

    var isBluetoothTransport: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioOutputMatch {
    case matched(AudioOutputDevice)
    case ambiguous([AudioOutputDevice])
    case notFound
}
