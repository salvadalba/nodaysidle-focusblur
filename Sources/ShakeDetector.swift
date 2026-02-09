import Cocoa

/// Detects rapid mouse shaking (back-and-forth) and fires a callback.
final class MouseShakeDetector {
    var onShake: (() -> Void)?

    // Tuning knobs
    private let timeWindow: TimeInterval = 0.55   // reversals must happen within this window
    private let minReversals: Int = 3              // direction changes needed to trigger
    private let minSegmentDistance: CGFloat = 30   // minimum px per movement segment (filters jitter)
    private let cooldown: TimeInterval = 0.8       // ignore shakes for this long after triggering

    // State
    private var monitor: Any?
    private var samples: [(x: CGFloat, time: TimeInterval)] = []
    private var lastDirection: Int = 0             // -1 left, +1 right, 0 unknown
    private var reversals: [TimeInterval] = []
    private var lastTrigger: TimeInterval = 0
    private var segmentStart: CGFloat = 0

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMove(event)
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        reset()
    }

    private func reset() {
        samples.removeAll()
        reversals.removeAll()
        lastDirection = 0
        segmentStart = 0
    }

    private func handleMove(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let x = NSEvent.mouseLocation.x

        // Prune old samples outside the time window
        samples.append((x: x, time: now))
        samples.removeAll { now - $0.time > timeWindow }
        reversals.removeAll { now - $0 > timeWindow }

        // Need at least 2 samples to determine direction
        guard samples.count >= 2 else {
            segmentStart = x
            return
        }

        let prev = samples[samples.count - 2]
        let dx = x - prev.x

        // Ignore tiny movements
        guard abs(dx) > 2 else { return }

        let direction = dx > 0 ? 1 : -1

        if lastDirection == 0 {
            lastDirection = direction
            segmentStart = prev.x
            return
        }

        // Direction reversal detected
        if direction != lastDirection {
            let segmentDistance = abs(x - segmentStart)

            // Only count if the segment was long enough (real shake, not jitter)
            if segmentDistance >= minSegmentDistance {
                reversals.append(now)
                segmentStart = x

                // Check if we have enough reversals to trigger
                if reversals.count >= minReversals && (now - lastTrigger) > cooldown {
                    lastTrigger = now
                    reset()
                    DispatchQueue.main.async { [weak self] in
                        self?.onShake?()
                    }
                }
            }

            lastDirection = direction
        }
    }
}
