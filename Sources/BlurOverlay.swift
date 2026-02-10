import Cocoa
import ApplicationServices

final class PassthroughWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BlurOverlayController {
    private struct ScreenOverlay {
        let blurWindow: PassthroughWindow
        let blurView: NSVisualEffectView
        let dimWindow: PassthroughWindow
        let dimView: NSView
        let dimMask: CAShapeLayer
    }

    private var overlays: [ScreenOverlay] = []
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
        forceUpdateMask()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        stopTracking()
        destroyOverlays()
    }

    // MARK: - Overlays

    private func createOverlays() {
        let level1 = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        let level2 = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)

        for screen in NSScreen.screens {
            let sf = screen.frame

            // --- Blur window (uses maskImage for cutout) ---
            let bWin = makeWindow(frame: sf, level: level1)
            let blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: sf.size))
            blurView.autoresizingMask = [.width, .height]
            blurView.material = .hudWindow
            blurView.blendingMode = .behindWindow
            blurView.state = .active
            // maskImage = nil means full blur (no cutout) — correct initial state

            bWin.contentView = blurView
            bWin.orderFrontRegardless()

            // --- Dim/tint window (regular view, CAShapeLayer mask works fine) ---
            let dWin = makeWindow(frame: sf, level: level2)
            let dimView = NSView(frame: NSRect(origin: .zero, size: sf.size))
            dimView.autoresizingMask = [.width, .height]
            dimView.wantsLayer = true
            dimView.layerUsesCoreImageFilters = true

            let dimMask = CAShapeLayer()
            dimMask.fillRule = .evenOdd
            let dimInit = CGMutablePath()
            dimInit.addRect(CGRect(origin: .zero, size: sf.size))
            dimMask.path = dimInit
            dimView.layer!.mask = dimMask

            dWin.contentView = dimView
            dWin.orderFrontRegardless()

            overlays.append(ScreenOverlay(
                blurWindow: bWin, blurView: blurView,
                dimWindow: dWin, dimView: dimView, dimMask: dimMask
            ))
        }
    }

    private func makeWindow(frame: NSRect, level: NSWindow.Level) -> PassthroughWindow {
        let w = PassthroughWindow(
            contentRect: frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        w.level = level
        w.isOpaque = false
        w.hasShadow = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return w
    }

    private func destroyOverlays() {
        overlays.forEach {
            $0.blurView.maskImage = nil
            $0.blurWindow.orderOut(nil)
            $0.dimWindow.orderOut(nil)
        }
        overlays.removeAll()
        lastFrame = .zero
    }

    // MARK: - Tracking

    private func startTracking() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.forceUpdateMask()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateLoop()
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

    // MARK: - Mask image for NSVisualEffectView

    /// Creates a mask image: white = blur visible, transparent = blur hidden (cutout).
    private func makeMaskImage(size: CGSize, cutout: NSRect) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: size).fill()
        NSColor.clear.set()
        cutout.fill(using: .copy)
        img.unlockFocus()
        return img
    }

    // MARK: - Update

    private func forceUpdateMask() {
        lastFrame = NSRect(x: -1, y: -1, width: 0, height: 0)
        updateLoop()
    }

    private func updateLoop() {
        guard isActive else { return }

        let intensity = max(0.05, ud.double(forKey: "intensity"))
        let grayscale = ud.bool(forKey: "grayscale")
        let tintEnabled = ud.bool(forKey: "tintEnabled")

        let frame = activeWindowFrame()

        let changed: Bool
        if let f = frame {
            changed = !NSEqualRects(f, lastFrame)
        } else {
            changed = !NSEqualRects(lastFrame, .zero)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for overlay in overlays {
            // Blur intensity
            overlay.blurView.alphaValue = intensity

            // Grayscale
            if grayscale {
                if overlay.dimView.layer?.backgroundFilters?.isEmpty ?? true {
                    if let filter = CIFilter(name: "CIColorControls") {
                        filter.setDefaults()
                        filter.setValue(0.0, forKey: kCIInputSaturationKey)
                        overlay.dimView.layer?.backgroundFilters = [filter]
                    }
                }
            } else {
                if !(overlay.dimView.layer?.backgroundFilters?.isEmpty ?? true) {
                    overlay.dimView.layer?.backgroundFilters = []
                }
            }

            // Tint
            if tintEnabled {
                let r = ud.double(forKey: "tintR")
                let g = ud.double(forKey: "tintG")
                let b = ud.double(forKey: "tintB")
                let a = max(0.05, ud.double(forKey: "tintOpacity"))
                overlay.dimView.layer?.backgroundColor = NSColor(red: r, green: g, blue: b, alpha: a).cgColor
            } else {
                overlay.dimView.layer?.backgroundColor = NSColor.clear.cgColor
            }

            // Mask update
            if changed {
                let screenSize = overlay.blurWindow.frame.size
                let screenOrigin = overlay.blurWindow.frame.origin

                // Blur: use maskImage (the correct API for NSVisualEffectView)
                if let f = frame {
                    let local = CGRect(
                        x: f.origin.x - screenOrigin.x,
                        y: f.origin.y - screenOrigin.y,
                        width: f.width,
                        height: f.height
                    ).insetBy(dx: -6, dy: -6)

                    if CGRect(origin: .zero, size: screenSize).intersects(local) {
                        overlay.blurView.maskImage = makeMaskImage(size: screenSize, cutout: local)
                    } else {
                        overlay.blurView.maskImage = nil // full blur
                    }
                } else {
                    overlay.blurView.maskImage = nil // full blur, no active window
                }

                // Dim: use CAShapeLayer mask (works fine on regular views)
                let dimPath = CGMutablePath()
                dimPath.addRect(CGRect(origin: .zero, size: screenSize))
                if let f = frame {
                    let local = CGRect(
                        x: f.origin.x - screenOrigin.x,
                        y: f.origin.y - screenOrigin.y,
                        width: f.width,
                        height: f.height
                    ).insetBy(dx: -6, dy: -6)
                    if CGRect(origin: .zero, size: screenSize).intersects(local) {
                        dimPath.addRect(local)
                    }
                }
                overlay.dimMask.path = dimPath
            }
        }

        if changed {
            lastFrame = frame ?? .zero
        }

        CATransaction.commit()
    }

    // MARK: - Active window detection

    private func activeWindowFrame() -> NSRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

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
