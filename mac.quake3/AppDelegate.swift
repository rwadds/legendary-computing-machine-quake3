//
//  AppDelegate.swift
//  mac.quake3

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet var window: NSWindow!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Q3Engine.shared.initialize()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        Q3Engine.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

}
