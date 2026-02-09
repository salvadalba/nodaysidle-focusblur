import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var blurController: BlurOverlayController!
    private var isEnabled = false
    private var globalMonitor: Any?
    private var shakeDetector: MouseShakeDetector!
    private var settingsController: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default settings
        UserDefaults.standard.register(defaults: [
            "intensity": 0.7,
            "grayscale": false,
            "tintEnabled": false,
            "tintR": 0.2, "tintG": 0.4, "tintB": 0.9,
            "tintOpacity": 0.15,
            "excludedJSON": "[]",
            "loginItem": false
        ])

        blurController = BlurOverlayController()
        settingsController = SettingsWindowController()
        setupStatusBar()
        setupGlobalShortcut()
        setupShakeDetector()
        requestAccessibility()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "FocusBlur")
        }

        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Enable Blur", action: #selector(toggleBlur), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit FocusBlur", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func setupGlobalShortcut() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 11 &&
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
                DispatchQueue.main.async {
                    self?.toggleBlur()
                }
            }
        }
    }

    private func setupShakeDetector() {
        shakeDetector = MouseShakeDetector()
        shakeDetector.onShake = { [weak self] in
            self?.toggleBlur()
        }
        shakeDetector.start()
    }

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("FocusBlur: Waiting for accessibility permission…")
        }
    }

    @objc private func toggleBlur() {
        isEnabled.toggle()
        if isEnabled {
            blurController.activate()
        } else {
            blurController.deactivate()
        }
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let icon = isEnabled ? "viewfinder.circle.fill" : "viewfinder"
        statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "FocusBlur")
        if let item = statusItem.menu?.items.first {
            item.title = isEnabled ? "Disable Blur" : "Enable Blur"
        }
    }

    @objc private func openPreferences() {
        settingsController.show()
    }

    @objc private func quitApp() {
        blurController.deactivate()
        NSApp.terminate(nil)
    }
}
