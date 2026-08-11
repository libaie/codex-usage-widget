import AppKit
import Darwin
import Foundation

if CommandLine.arguments.contains("--scan-worker") {
    _exit(ScanWorker.runFromEnvironment())
}

let demo = CommandLine.arguments.contains("--demo")
var lock: WriterLock?
if !demo {
    do {
        lock = try WriterLock(url: ApplicationPaths.supportDirectory.appendingPathComponent("writer.lock"))
    } catch {
        _exit(1)
    }
    guard lock?.acquired == true else { _exit(0) }
    ScanSupervisor.cleanupOrphans()
}

let application = NSApplication.shared
let delegate = WidgetAppDelegate(demo: demo)
application.delegate = delegate
application.setActivationPolicy(.accessory)
withExtendedLifetime((delegate, lock)) { application.run() }
