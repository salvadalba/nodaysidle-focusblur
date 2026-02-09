import Cocoa
import ApplicationServices

// A window that never activates or steals focus
final class PassthroughWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BlurOverlayController {
    private struct Overlay {
        let window: PassthroughWindow
        let mask: CAShapeLayer
    }

    private var overlays: [Overlay] = []
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastFrame: NSRect = .zero
    private(set) var isActive = false

    // MARK: - Public

    func activate() {
        guard !isActive else { return }
        isActive = true
        createOverlays()
        startTracking()
        updateMask()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        stopTracking()
        destroyOverlays()
    }

    // MARK: - Overlay windows

    private func createOverlays() {
        for screen in NSScreen.screens {
            let frame = screen.frame

            let window = PassthroughWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
            window.isOpaque = false
            window.hasShadow = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.animationBehavior = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let blurView = NSVisualEffectView()
            blurView.frame = NSRect(origin: .zero, size: frame.size)
            blurView.autoresizingMask = [.width, .height]
            blurView.material = .fullScreenUI
            blurView.blendingMode = .behindWindow
            blurView.state = .active
            blurView.wantsLayer = true

            let mask = CAShapeLayer()
            mask.fillRule = .evenOdd
            blurView.layer?.mask = mask

            window.contentView = blurView
            window.orderFrontRegardless()

            overlays.append(Overlay(window: window, mask: mask))
        }
    }

    private func destroyOverlays() {
        overlays.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
        lastFrame = .zero
    }

    // MARK: - Tracking

    private func startTracking() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lastFrame = .zero  // force refresh
            self?.updateMask()
        }

        // 30 fps polling to track window movement/resize
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateMask()
        }
    }

    private func stopTracking() {
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activationObserver = nil
        }
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Mask

    private func updateMask() {
        guard isActive else { return }

        let frame = activeWindowFrame()

        // Skip if nothing changed
        if let f = frame, NSEqualRects(f, lastFrame) { return }
        if frame == nil && NSEqualRects(lastFrame, .zero) { return }
        lastFrame = frame ?? .zero

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for overlay in overlays {
            let screenSize = overlay.window.frame.size
            let screenOrigin = overlay.window.frame.origin
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: screenSize))

            if let f = frame {
                // Convert to overlay-window-local coordinates
                let local = CGRect(
                    x: f.origin.x - screenOrigin.x,
                    y: f.origin.y - screenOrigin.y,
                    width: f.width,
                    height: f.height
                )
                let screenBounds = CGRect(origin: .zero, size: screenSize)
                if screenBounds.intersects(local) {
                    // Add hole with slight padding for shadow clearance
                    let padded = local.insetBy(dx: -4, dy: -4)
                    path.addRect(padded)
                }
            }

            overlay.mask.path = path
        }

        CATransaction.commit()
    }

    // MARK: - Active window detection (Accessibility API)

    private func activeWindowFrame() -> NSRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        // Skip if our own app is frontmost
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let pid = frontApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let win = windowRef else { return nil }

        let el = win as! AXUIElement

        // Position (AX coords: origin at top-left of primary screen)
        var posRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              let pv = posRef else { return nil }
        var pos = CGPoint.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)

        // Size
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sv = sizeRef else { return nil }
        var size = CGSize.zero
        AXValueGetValue(sv as! AXValue, .cgSize, &size)

        // AX coords → Cocoa coords (flip Y axis)
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaY = primary.frame.height - pos.y - size.height

        return NSRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
    }
}
