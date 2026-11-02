// MouseSimulationManager.swift
// Controller4Mac
//
// Phase 2: Translates raw GameController thumbstick floats into relative
// macOS mouse movements and face-button presses into left-click events,
// all via CoreGraphics CGEvent injection.
//
// Architecture overview:
//   ControllerManager  ──push──▶  MouseSimulationManager
//       (raw floats)                 (CGEvent posting)
//
//   The ControllerManager calls four entry points on this object:
//     • updateStick(x:y:)           — left thumbstick  → cursor movement
//     • updateScroll(x:y:)          — right thumbstick → scroll wheel
//     • handleBottomButton(isPressed:) — A/B (bottom face) → left click
//     • handleRightButton(isPressed:)  — B/A (right face)  → right click
//
//   Internally, a 60fps CADisplayLink-style Timer accumulates the current
//   stick vector and applies it as a relative delta to the system cursor
//   position on every tick.

import Foundation
import CoreGraphics   // CGEvent, CGPoint, CGEventType
import AppKit         // NSScreen (for clamping cursor to screen bounds)

final class MouseSimulationManager {

    // MARK: - Configuration

    /// Pixels-per-second at full stick deflection (1.0).
    /// Adjust this to taste; 800 feels roughly like a medium-speed mouse.
    var sensitivity: Double = 800.0

    /// Stick values below this magnitude (per axis) are treated as zero.
    /// Prevents cursor drift from imprecise stick centring.
    var deadZone: Float = 0.10

    /// Scroll speed multiplier. Higher = faster scrolling.
    /// CGEvent scrollWheel uses discrete "lines" (integer), so this
    /// controls how many lines-per-second at full stick deflection.
    var scrollSensitivity: Double = 15.0

    // MARK: - Private — Stick State

    /// Most-recently reported stick values, updated from the GCController
    /// value-changed handler (may arrive on a background thread).
    private var stickX: Float = 0
    private var stickY: Float = 0

    /// Most-recently reported right-stick values for scroll simulation.
    private var scrollStickX: Float = 0
    private var scrollStickY: Float = 0

    /// Fractional scroll accumulator — CGEvent scrollWheel takes integers,
    /// so we bank sub-pixel remainders between frames for smooth low-speed scrolling.
    private var scrollAccumulatorX: Double = 0
    private var scrollAccumulatorY: Double = 0

    /// Serialises stick reads/writes between the GC callback thread and
    /// the display-link timer thread.
    private let stickLock = NSLock()

    // MARK: - Private — Timer

    /// High-frequency timer that drives cursor movement at ~60fps.
    private var moveTimer: Timer?

    /// Seconds between timer ticks. 1/60 ≈ 16.67ms.
    private let timerInterval: TimeInterval = 1.0 / 60.0

    /// Timestamp of the previous timer tick; used to compute an accurate
    /// delta-time rather than assuming exactly `timerInterval` elapsed.
    private var lastTick: Date = .now

    // MARK: - Init / Deinit

    init() {
        startMoveTimer()
    }

    deinit {
        stopMoveTimer()
    }

    // MARK: - Public Entry Points (called from ControllerManager)

    /// Called by `ControllerManager` whenever the left thumbstick value changes.
    /// This method is safe to call from any thread.
    ///
    /// - Parameters:
    ///   - x: Horizontal axis, -1.0 (full left) … +1.0 (full right).
    ///   - y: Vertical axis,   -1.0 (full down) … +1.0 (full up).
    func updateStick(x: Float, y: Float) {
        stickLock.lock()
        stickX = x
        stickY = y
        stickLock.unlock()
    }

    /// Called by `ControllerManager` whenever the right thumbstick value changes.
    /// This method is safe to call from any thread.
    ///
    /// - Parameters:
    ///   - x: Horizontal axis, -1.0 (full left) … +1.0 (full right).
    ///   - y: Vertical axis,   -1.0 (full down) … +1.0 (full up).
    func updateScroll(x: Float, y: Float) {
        stickLock.lock()
        scrollStickX = x
        scrollStickY = y
        stickLock.unlock()
    }

    /// Called by `ControllerManager` on every bottom-face-button state change.
    /// Posts a `leftMouseDown` or `leftMouseUp` at the current cursor position.
    ///
    /// - Parameter isPressed: `true` when the button is first pressed,
    ///                        `false` when it is released.
    func handleBottomButton(isPressed: Bool) {
        let position = currentCursorPosition()
        let eventType: CGEventType = isPressed ? .leftMouseDown : .leftMouseUp

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: position,
            mouseButton: .left
        ) else {
            print("[MouseSimulationManager] ⚠️  Failed to create \(isPressed ? "mouseDown" : "mouseUp") event.")
            return
        }

        event.post(tap: .cghidEventTap)
        print("[MouseSimulationManager] \(isPressed ? "Left \u{25bc} DOWN" : "Left \u{25b2} UP") at \(position)")
    }

    /// Called by `ControllerManager` on every right-face-button state change.
    /// Posts `rightMouseDown` or `rightMouseUp` at the current cursor position,
    /// which causes the system to present context menus correctly.
    ///
    /// - Parameter isPressed: `true` when pressed, `false` when released.
    func handleRightButton(isPressed: Bool) {
        let position  = currentCursorPosition()
        let eventType: CGEventType = isPressed ? .rightMouseDown : .rightMouseUp

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: position,
            mouseButton: .right
        ) else {
            print("[MouseSimulationManager] ⚠️  Failed to create right-click event.")
            return
        }

        event.post(tap: .cghidEventTap)
        print("[MouseSimulationManager] \(isPressed ? "Right \u{25bc} DOWN" : "Right \u{25b2} UP") at \(position)")
    }

    // MARK: - Timer Management

    private func startMoveTimer() {
        stopMoveTimer()
        lastTick = .now

        // Schedule on the main run loop so it keeps firing while modal panels
        // are open (common mode). The actual CGEvent posting is lightweight
        // enough to never stall the main thread perceptibly.
        let timer = Timer(timeInterval: timerInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        moveTimer = timer
    }

    private func stopMoveTimer() {
        moveTimer?.invalidate()
        moveTimer = nil
    }

    // MARK: - Per-Frame Tick

    /// Called ~60 times per second. Reads the current stick vector, applies
    /// deadzone + sensitivity, and posts a `.mouseMoved` CGEvent.
    private func tick() {
        // Compute accurate delta-time.
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        // Snapshot stick state under lock.
        stickLock.lock()
        let rawX = stickX
        let rawY = stickY
        let rawScrollX = scrollStickX
        let rawScrollY = scrollStickY
        stickLock.unlock()

        // ── Right Stick → Scroll Wheel ──────────────────────────────────────
        let sX = abs(rawScrollX) > deadZone ? rawScrollX : 0
        let sY = abs(rawScrollY) > deadZone ? rawScrollY : 0

        if sX != 0 || sY != 0 {
            // Accumulate fractional scroll values so slow deflections still
            // produce movement over multiple frames.
            // Y is negated: stick +up should scroll content up (positive scrollWheel value).
            scrollAccumulatorY += Double(sY) * scrollSensitivity * dt
            scrollAccumulatorX += Double(-sX) * scrollSensitivity * dt

            let intY = Int32(scrollAccumulatorY)
            let intX = Int32(scrollAccumulatorX)

            if intY != 0 || intX != 0 {
                // Consume the integer portion, keep the remainder.
                scrollAccumulatorY -= Double(intY)
                scrollAccumulatorX -= Double(intX)

                if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil,
                                             units: .line,
                                             wheelCount: 3,
                                             wheel1: intY,
                                             wheel2: intX,
                                             wheel3: 0) {
                    scrollEvent.post(tap: CGEventTapLocation.cghidEventTap)
                }
            }
        } else {
            // Reset accumulators when stick returns to center.
            scrollAccumulatorX = 0
            scrollAccumulatorY = 0
        }

        // Apply per-axis deadzone.
        let x = abs(rawX) > deadZone ? rawX : 0
        let y = abs(rawY) > deadZone ? rawY : 0

        // If both axes are within the deadzone, nothing to do.
        guard x != 0 || y != 0 else { return }

        // Compute pixel delta for this frame.
        // Y is negated because GCController Y is +up, but screen Y is +down.
        let deltaX = Double(x) * sensitivity * dt
        let deltaY = Double(-y) * sensitivity * dt

        // Clamp new position to screen bounds so the cursor can't escape.
        let current = currentCursorPosition()
        let bounds  = screenBounds()

        let newX = (current.x + deltaX).clamped(to: bounds.minX ... bounds.maxX)
        let newY = (current.y + deltaY).clamped(to: bounds.minY ... bounds.maxY)
        let newPosition = CGPoint(x: newX, y: newY)

        // Post the move event.
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: newPosition,
            mouseButton: .left
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    /// Returns the current system cursor position in global screen coordinates.
    private func currentCursorPosition() -> CGPoint {
        // CGEvent with zero location is the cheapest way to read current pos.
        return CGEvent(source: nil)?.location ?? .zero
    }

    /// Returns a rect covering all connected screens, used for cursor clamping.
    private func screenBounds() -> CGRect {
        // NSScreen.screens union gives us the full virtual desktop across
        // multiple monitors, so the cursor can traverse all displays.
        let rects = NSScreen.screens.map { $0.frame }
        return rects.reduce(.null) { $0.union($1) }
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
