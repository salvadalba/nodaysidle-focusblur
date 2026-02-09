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
        let container: NSView
        let blurView: NSVisualEffectView
        let grayView: NSView
        let tintView: NSView
        let mask: CAShapeLayer
    }

    private var overlays: [Overlay] = []
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastFrame: NSRect = .zero
    private(set) var isActive = false

    private let ud = UserDefaults.standard

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
            let localSize = NSRect(origin: .zero, size: frame.size)

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

            // Container holds all effect layers; mask is applied here
            let container = NSView(frame: localSize)
            container.wantsLayer = true
            container.autoresizingMask = [.width, .height]

            let mask = CAShapeLayer()
            mask.fillRule = .evenOdd
            container.layer?.mask = mask

            // 1. Blur view
            let blurView = NSVisualEffectView(frame: localSize)
            blurView.autoresizingMask = [.width, .height]
            blurView.material = .fullScreenUI
            blurView.blendingMode = .behindWindow
            blurView.state = .active
            blurView.wantsLayer = true
            container.addSubview(blurView)

            // 2. Grayscale overlay (desaturates via Core Image background filter)
            let grayView = NSView(frame: localSize)
            grayView.autoresizingMask = [.width, .height]
            grayView.wantsLayer = true
            grayView.layerUsesCoreImageFilters = true
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setDefaults()
                filter.setValue(0.0, forKey: kCIInputSaturationKey)
                grayView.layer?.backgroundFilters = [filter]
            }
            grayView.isHidden = true
            container.addSubview(grayView)

            // 3. Tint color overlay
            let tintView = NSView(frame: localSize)
            tintView.autoresizingMask = [.width, .height]
            tintView.wantsLayer = true
            tintView.layer?.backgroundColor = NSColor.clear.cgColor
            tintView.isHidden = true
            container.addSubview(tintView)

            window.contentView = container
            window.orderFrontRegardless()

            overlays.append(Overlay(
                window: window,
                container: container,
                blurView: blurView,
                grayView: grayView,
                tintView: tintView,
                mask: mask
            ))
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
            self?.lastFrame = .zero
            self?.updateMask()
        }

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

    // MARK: - Update loop

    private func updateMask() {
        guard isActive else { return }

        // Read settings every frame (UserDefaults caches in memory — fast)
        let intensity = max(0.05, ud.double(forKey: "intensity"))
        let grayscale = ud.bool(forKey: "grayscale")
        let tintEnabled = ud.bool(forKey: "tintEnabled")
        let tintR = ud.double(forKey: "tintR")
        let tintG = ud.double(forKey: "tintG")
        let tintB = ud.double(forKey: "tintB")
        let tintOpacity = max(0.05, ud.double(forKey: "tintOpacity"))

        let frame = activeWindowFrame()

        // Skip mask update if window hasn't moved
        let frameChanged: Bool
        if let f = frame {
            frameChanged = !NSEqualRects(f, lastFrame)
        } else {
            frameChanged = !NSEqualRects(lastFrame, .zero)
        }
        if frameChanged {
            lastFrame = frame ?? .zero
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for overlay in overlays {
            // Apply intensity
            overlay.blurView.alphaValue = intensity

            // Grayscale
            overlay.grayView.isHidden = !grayscale

            // Tint
            if tintEnabled {
                overlay.tintView.isHidden = false
                overlay.tintView.layer?.backgroundColor = NSColor(
                    red: tintR, green: tintG, blue: tintB, alpha: tintOpacity
                ).cgColor
            } else {
                overlay.tintView.isHidden = true
            }

            // Mask (only rebuild path if frame changed)
            if frameChanged {
                let screenSize = overlay.window.frame.size
                let screenOrigin = overlay.window.frame.origin
                let path = CGMutablePath()
                path.addRect(CGRect(origin: .zero, size: screenSize))

                if let f = frame {
                    let local = CGRect(
                        x: f.origin.x - screenOrigin.x,
                        y: f.origin.y - screenOrigin.y,
                        width: f.width,
                        height: f.height
                    )
                    let screenBounds = CGRect(origin: .zero, size: screenSize)
                    if screenBounds.intersects(local) {
                        let padded = local.insetBy(dx: -4, dy: -4)
                        path.addRect(padded)
                    }
                }

                overlay.mask.path = path
            }
        }

        CATransaction.commit()
    }

    // MARK: - Active window detection

    private func activeWindowFrame() -> NSRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        // Skip our own app
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        // Check exclusion list
        if let bid = frontApp.bundleIdentifier {
            let json = ud.string(forKey: "excludedJSON") ?? "[]"
            let excluded = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            if excluded.contains(bid) { return nil }
        }

        let pid = frontApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let win = windowRef else { return nil }

        let el = win as! AXUIElement

        var posRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              let pv = posRef else { return nil }
        var pos = CGPoint.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)

        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sv = sizeRef else { return nil }
        var size = CGSize.zero
        AXValueGetValue(sv as! AXValue, .cgSize, &size)

        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaY = primary.frame.height - pos.y - size.height

        return NSRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
    }
}
