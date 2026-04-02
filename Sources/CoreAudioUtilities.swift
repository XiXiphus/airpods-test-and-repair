import CoreAudio
import Foundation

func audioObjectStringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutableBytes(of: &value) { rawBuffer in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, rawBuffer.baseAddress!)
    }
    guard status == noErr else { return nil }
    return value as String
}

func audioObjectUInt32Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func audioObjectFloat64Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func outputChannelCount(for deviceID: AudioDeviceID) -> Int? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return nil }

    let rawPointer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawPointer.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else { return nil }
    let bufferList = UnsafeMutableAudioBufferListPointer(rawPointer.assumingMemoryBound(to: AudioBufferList.self))
    let channels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    return channels > 0 ? channels : nil
}

func defaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    ) == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return deviceID
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
        guard
            let name = audioObjectStringProperty(objectID: did, selector: kAudioObjectPropertyName),
            let uid = audioObjectStringProperty(objectID: did, selector: kAudioDevicePropertyDeviceUID),
            let transportType = audioObjectUInt32Property(objectID: did, selector: kAudioDevicePropertyTransportType),
            outputChannelCount(for: did) != nil
        else { continue }

        let modelUID = audioObjectStringProperty(objectID: did, selector: kAudioDevicePropertyModelUID) ?? ""
        result.append(
            AudioOutputDevice(
                id: did,
                name: name,
                uid: uid,
                modelUID: modelUID,
                transportType: transportType,
                isOutput: true
            )
        )
    }
    return result
}

func defaultOutputDevice() -> AudioOutputDevice? {
    guard let deviceID = defaultOutputDeviceID() else { return nil }
    return listAudioOutputDevices().first(where: { $0.id == deviceID })
}

func nominalSampleRate(for deviceID: AudioDeviceID) -> Int? {
    guard let sampleRate = audioObjectFloat64Property(objectID: deviceID, selector: kAudioDevicePropertyNominalSampleRate) else {
        return nil
    }
    return Int(sampleRate.rounded())
}

func audioOutputMatchScore(for candidate: AudioOutputDevice, target: AirPodsDevice) -> Int {
    audioOutputMatchScore(
        for: candidate,
        targetName: target.name,
        targetMACAddress: target.macAddress
    )
}

func audioOutputMatchScore(
    for candidate: AudioOutputDevice,
    targetName: String,
    targetMACAddress: String
) -> Int {
    let normalizedTargetName = normalizeAudioDeviceName(targetName)
    let normalizedTargetMAC = normalizeHardwareIdentifier(targetMACAddress)
    let candidateName = normalizeAudioDeviceName(candidate.name)
    let candidateUID = normalizeHardwareIdentifier(candidate.uid)
    let candidateModelUID = normalizeHardwareIdentifier(candidate.modelUID)

    let hasExactNameMatch = candidateName == normalizedTargetName
    let hasPartialNameMatch = candidateName.contains(normalizedTargetName) || normalizedTargetName.contains(candidateName)
    let hasMACMatch =
        !normalizedTargetMAC.isEmpty &&
        (candidateUID.contains(normalizedTargetMAC) || candidateModelUID.contains(normalizedTargetMAC))
    let hasAirPodsSignal =
        candidateName.contains("airpods") ||
        candidateUID.contains("airpods") ||
        candidateModelUID.contains("airpods")

    guard hasExactNameMatch || hasPartialNameMatch || hasMACMatch || hasAirPodsSignal else {
        return 0
    }

    var score = 0
    if candidate.isBluetoothTransport { score += 40 }
    if hasAirPodsSignal { score += 20 }
    if hasPartialNameMatch { score += 80 }
    if hasExactNameMatch { score += 80 }
    if hasMACMatch { score += 200 }
    return score
}

func bestMatchingAudioOutput(
    forBluetoothName name: String,
    macAddress: String,
    among outputs: [AudioOutputDevice]
) -> (device: AudioOutputDevice, score: Int)? {
    outputs
        .compactMap { candidate -> (AudioOutputDevice, Int)? in
            let score = audioOutputMatchScore(
                for: candidate,
                targetName: name,
                targetMACAddress: macAddress
            )
            return score > 0 ? (candidate, score) : nil
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.isBluetoothTransport && !rhs.0.isBluetoothTransport
        }
        .first
}

func matchAudioOutputDevice(for device: AirPodsDevice) -> AudioOutputMatch {
    let rankedMatches = listAudioOutputDevices()
        .compactMap { candidate -> (AudioOutputDevice, Int)? in
            let score = audioOutputMatchScore(for: candidate, target: device)
            return score > 0 ? (candidate, score) : nil
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.isBluetoothTransport && !rhs.0.isBluetoothTransport
        }

    guard let best = rankedMatches.first else { return .notFound }

    let topMatches = rankedMatches
        .filter { $0.1 == best.1 }
        .map(\.0)

    if topMatches.count > 1 {
        if let defaultOutputID = defaultOutputDeviceID(),
           let selected = topMatches.first(where: { $0.id == defaultOutputID }) {
            return .matched(selected)
        }
        return .ambiguous(topMatches)
    }
    return .matched(best.0)
}

@discardableResult
func switchOutputDevice(to device: AudioOutputDevice) -> Bool {
    var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = device.id
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
    )
    return status == noErr
}

@discardableResult
func switchOutputDevice(toNameContaining keyword: String) -> Bool {
    let devices = listAudioOutputDevices()
    let normalizedKeyword = normalizeAudioDeviceName(keyword)
    guard let target = devices.first(where: {
        normalizeAudioDeviceName($0.name).contains(normalizedKeyword)
    }) else { return false }
    return switchOutputDevice(to: target)
}

func fallbackAudioOutputDevice(excluding deviceName: String) -> AudioOutputDevice? {
    let devices = listAudioOutputDevices()
    let normalizedTarget = normalizeAudioDeviceName(deviceName)
    let priorityKeywords = ["macbook", "built-in", "内置", "speaker", "speakers", "扬声器"]

    func isTargetDevice(_ candidate: AudioOutputDevice) -> Bool {
        let normalizedCandidate = normalizeAudioDeviceName(candidate.name)
        return normalizedCandidate == normalizedTarget
            || normalizedCandidate.contains(normalizedTarget)
            || normalizedTarget.contains(normalizedCandidate)
    }

    if let preferred = devices.first(where: { candidate in
        let normalizedCandidate = normalizeAudioDeviceName(candidate.name)
        return !isTargetDevice(candidate)
            && priorityKeywords.contains(where: { normalizedCandidate.contains($0) })
    }) {
        return preferred
    }

    if let nonAirPods = devices.first(where: { candidate in
        let normalizedCandidate = normalizeAudioDeviceName(candidate.name)
        return !isTargetDevice(candidate) && !normalizedCandidate.contains("airpods")
    }) {
        return nonAirPods
    }

    return devices.first(where: { !isTargetDevice($0) })
}
