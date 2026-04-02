import Foundation

// MARK: - String normalization

func normalizeAudioDeviceName(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "\u{201C}", with: "\"")
        .replacingOccurrences(of: "\u{201D}", with: "\"")
        .replacingOccurrences(of: ":", with: "")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizeHardwareIdentifier(_ value: String) -> String {
    normalizeAudioDeviceName(value)
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")
}

func lineIndentation(_ line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.count
}

func bluetoothDeviceBlocks(from output: String) -> [(name: String, lines: [String])] {
    let allLines = output.components(separatedBy: "\n")
    var blocks: [(name: String, lines: [String])] = []
    var index = 0

    while index < allLines.count {
        let line = allLines[index]
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        let indentation = lineIndentation(line)

        guard trimmedLine.hasSuffix(":"), indentation >= 8 else {
            index += 1
            continue
        }

        let name = String(trimmedLine.dropLast())
        var blockLines: [String] = []
        var nextIndex = index + 1

        while nextIndex < allLines.count {
            let nextLine = allLines[nextIndex]
            let trimmedNextLine = nextLine.trimmingCharacters(in: .whitespaces)
            let nextIndentation = lineIndentation(nextLine)

            if trimmedNextLine.hasSuffix(":"), nextIndentation <= indentation {
                break
            }

            blockLines.append(trimmedNextLine)
            nextIndex += 1
        }

        blocks.append((name: name, lines: blockLines))
        index = nextIndex
    }

    return blocks
}

// MARK: - Process / shell

struct ShellCommandResult {
    let output: String
    let status: Int32

    var succeeded: Bool { status == 0 }
}

func commandSearchPaths() -> [String] {
    let preferred = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)

    var result: [String] = []
    for path in preferred + environmentPaths where !path.isEmpty {
        if !result.contains(path) {
            result.append(path)
        }
    }
    return result
}

func bundledToolURL(named name: String) -> URL? {
    guard let resourceURL = Bundle.main.resourceURL else { return nil }
    let candidate = resourceURL.appendingPathComponent("bin/\(name)")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

func resolvedToolURL(named name: String) -> URL? {
    if let bundled = bundledToolURL(named: name) {
        return bundled
    }

    for basePath in commandSearchPaths() {
        let candidate = URL(fileURLWithPath: basePath).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }

    return nil
}

func runProcess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String] = [:]
) -> ShellCommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    if !environment.isEmpty {
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment
    }
    do {
        try process.run()
    } catch {
        return ShellCommandResult(output: error.localizedDescription, status: -1)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return ShellCommandResult(output: output, status: process.terminationStatus)
}

func runShell(_ command: String) -> ShellCommandResult {
    runProcess(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-c", command],
        environment: ["PATH": commandSearchPaths().joined(separator: ":")]
    )
}

func runTool(named name: String, arguments: [String]) -> ShellCommandResult {
    guard let executableURL = resolvedToolURL(named: name) else {
        return ShellCommandResult(output: "\(name) not found", status: 127)
    }
    return runProcess(executableURL: executableURL, arguments: arguments)
}

func runBlueutil(_ arguments: [String]) -> ShellCommandResult {
    runTool(named: "blueutil", arguments: arguments)
}

func shell(_ command: String) -> String {
    runShell(command).output
}
