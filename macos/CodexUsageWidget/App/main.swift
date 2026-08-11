import AppKit
import Darwin
import Foundation

if CommandLine.arguments.contains("--scan-worker") {
    _exit(ScanWorker.runFromEnvironment())
}

final class CoreAppDelegate: NSObject, NSApplicationDelegate {}

let lock: WriterLock
do {
    lock = try WriterLock(url: ApplicationPaths.supportDirectory.appendingPathComponent("writer.lock"))
} catch {
    _exit(1)
}
guard lock.acquired else { _exit(0) }
ScanSupervisor.cleanupOrphans()

let application = NSApplication.shared
let delegate = CoreAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
withExtendedLifetime(lock) { application.run() }
