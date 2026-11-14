import AppKit

// Headless self-checks; they must stay ahead of the app bootstrap so they never open a window
// or ask for a permission.
if CommandLine.arguments.contains("--ocr-selftest") {
    exit(OCRSelfTest.run())
}
if CommandLine.arguments.contains("--make-icon") {
    exit(IconMaker.run())
}
if CommandLine.arguments.contains("--dictionary-check") {
    exit(DictionaryCheck.run())
}
if CommandLine.arguments.contains("--pipeline-selftest") {
    // The translation queue lives on the main queue, so the check runs inside a serviced one.
    Task { @MainActor in exit(await PipelineSelfTest.run()) }
    dispatchMain()
}

// The process starts on the main thread; the delegate has to outlive `run()`.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.setActivationPolicy(.regular)
    withExtendedLifetime(controller) { application.run() }
}
