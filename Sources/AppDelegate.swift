import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var blurController: BlurOverlayController!
    private var isEnabled = false
    private var globalMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        blurController = BlurOverlayController()
        setupStatusBar()
        setupGlobalShortcut()
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

        let quit = NSMenuItem(title: "Quit FocusBlur", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func setupGlobalShortcut() {
        // Ctrl+Option+B to toggle blur globally
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 11 &&
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
                DispatchQueue.main.async {
                    self?.toggleBlur()
                }
            }
        }
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

    @objc private func quitApp() {
        blurController.deactivate()
        NSApp.terminate(nil)
    }
}
