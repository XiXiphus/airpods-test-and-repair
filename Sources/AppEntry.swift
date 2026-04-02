import Cocoa
import SwiftUI

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
        window.title = "AirPods Fix"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor

        let fitting = hostingView.fittingSize
        window.setContentSize(NSSize(width: 380, height: fitting.height))
        window.center()
        window.makeKeyAndOrderFront(nil)

        sizeObserver = hostingView.observe(\.intrinsicContentSize, options: [.new]) { [weak self] view, _ in
            guard let self = self, let window = self.window else { return }
            let newSize = view.fittingSize
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

@main
enum AirPodsFixMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
