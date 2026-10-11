// Flickwise — native macOS menu bar app. Entry point.
//   Flickwise                       run the app
//   Flickwise --selftest            headless checks (history DB, settings, WAV, text helpers)
//   Flickwise --transcribe a.wav    run the Gemini pipeline on a file and print the result
import AppKit

let args = CommandLine.arguments
if args.count > 1, args[1].hasPrefix("--") {
    let status = SelfTest.run(args)
    WhisperEngine.shared.shutdown()
    exit(status)
}

MainActor.assumeIsolated {                 // top-level code runs on the main thread
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
