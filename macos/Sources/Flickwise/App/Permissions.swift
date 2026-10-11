// Permissions — Accessibility (key monitor + typing) and Microphone, plus login item.
import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openAccessibilitySettings() }
    }

    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone() {
        switch microphone {
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .authorized: break
        default: openMicrophoneSettings()
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.error("Launch at login: \(error.localizedDescription)")
        }
    }
}
