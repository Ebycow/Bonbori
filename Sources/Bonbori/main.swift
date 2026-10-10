// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MainController()
        controller.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.player.stopRecording()
        controller?.player.stop()
        EPGStore.shared.flush()
        // give the close/release packets a moment to go out
        Thread.sleep(forTimeInterval: 0.1)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
