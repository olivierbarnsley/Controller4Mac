// AccessibilityManager.swift
// Controller4Mac
//
// Phase 1: Checks and monitors macOS Accessibility permission.
//
// Why this is necessary:
//   CGEvent.post() — used in Phase 2 to simulate keystrokes and mouse events —
//   silently fails without Accessibility permission. There is no error thrown;
//   the events simply never arrive at the target application. An explicit check
//   here ensures the user is always aware of the permission state.
//
// How the re-poll timer works:
//   macOS does NOT post a notification when the user toggles an app's
//   Accessibility access in System Settings. The only reliable way to detect
//   the change without requiring a restart is a lightweight timer that calls
//   AXIsProcessTrustedWithOptions every second. The options dictionary is passed
//   with kAXTrustedCheckOptionPrompt: false on timer ticks to avoid re-showing
//   the system dialog repeatedly — the prompt is only shown on the initial
//   checkPermission() call.

import Foundation
import ApplicationServices // AXIsProcessTrustedWithOptions
import AppKit              // NSWorkspace.shared.open
import Combine

final class AccessibilityManager: ObservableObject {

    // MARK: - Published State

    /// `true` when the app has been granted Accessibility permission.
    /// The SwiftUI ContentView observes this to show the correct status.
    @Published var isGranted: Bool = false

    // MARK: - Private

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0

    // MARK: - Public API

    /// Call once on app launch (from Controller4MacApp.onAppear).
    /// Performs the first trustedCheck WITH the system prompt so the
    /// dialog appears automatically on first run.
    func checkPermission() {
        // Passing kAXTrustedCheckOptionPrompt: true triggers the system
        // permission dialog. If the user has already responded, this is a no-op.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        DispatchQueue.main.async {
            self.isGranted = trusted
        }

        // Start the background poll so the UI reflects changes made in
        // System Settings without an app restart.
        startPolling()
    }

    /// Opens the Accessibility pane in System Settings directly.
    /// Called when the user taps the "Open Settings" button in ContentView.
    func openSystemSettings() {
        // Deep-link URL for macOS Ventura+ (13.0+).
        // On older macOS the fallback "x-apple.systempreferences:" still works.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private Helpers

    private func startPolling() {
        // Avoid multiple timers if called more than once.
        stopPolling()

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Do NOT pass the prompt option here — we don't want the dialog
            // to flash repeatedly while the timer fires.
            let trusted = AXIsProcessTrustedWithOptions(nil)

            DispatchQueue.main.async {
                // Only trigger a UI update if the value actually changed.
                if self.isGranted != trusted {
                    self.isGranted = trusted
                    print("[AccessibilityManager] Permission changed → \(trusted ? "Granted ✅" : "Denied ❌")")
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        stopPolling()
    }
}
