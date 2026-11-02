// ContentView.swift
// Controller4Mac
//
// Phase 4: Redesigned as a compact menu bar popover panel (MenuBarContentView).
// The original windowed layout is preserved below as ContentView (typealias)
// in case a full window is ever needed again.
//
// Layout: fixed 300pt wide floating panel with three status rows and a quit button.
// All data flows from @EnvironmentObject — no logic lives in this file.

import SwiftUI

// MARK: - Menu Bar Content View

struct MenuBarContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var accessibility: AccessibilityManager
    @EnvironmentObject private var controller: ControllerManager
    @EnvironmentObject private var profile: ProfileManager

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().opacity(0.15)
            statusRows
            Divider().opacity(0.15)
            chordHintRow
            Divider().opacity(0.15)
            quitButton
        }
        .frame(width: 300)
        .background(
            // Deep dark glass background with vibrancy.
            ZStack {
                Color(hex: "#0F0F1A")
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .opacity(0.6)
            }
        )
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "#7B61FF"), Color(hex: "#A78BFA")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Controller4Mac")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            // Live profile badge — tappable to toggle.
            Button {
                let next: ProfileState = profile.currentProfile == .desktop ? .blank : .desktop
                profile.setProfile(next)
            } label: {
                Text(profile.currentProfile.rawValue)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(profileBadgeColor.opacity(0.25))
                    .foregroundColor(profileBadgeColor)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(profileBadgeColor.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Click to toggle profile")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Status Rows

    private var statusRows: some View {
        VStack(spacing: 0) {
            // ── Accessibility ───────────────────────────────────────────────
            MenuStatusRow(
                icon: "hand.raised.fill",
                iconColor: accessibility.isGranted ? Color(hex: "#22C55E") : Color(hex: "#EF4444"),
                label: "Accessibility",
                value: accessibility.isGranted ? "Granted" : "Denied",
                valueColor: accessibility.isGranted ? Color(hex: "#22C55E") : Color(hex: "#EF4444"),
                trailingButton: accessibility.isGranted ? nil : ("Open Settings", {
                    accessibility.openSystemSettings()
                })
            )

            Divider().opacity(0.08).padding(.leading, 44)

            // ── Controller ──────────────────────────────────────────────────
            MenuStatusRow(
                icon: controller.isConnected ? "gamecontroller.fill" : "gamecontroller",
                iconColor: controller.isConnected ? Color(hex: "#3B82F6") : Color(hex: "#6B7280"),
                label: "Controller",
                value: controller.isConnected
                    ? (controller.controllerName ?? "Connected")
                    : "Disconnected",
                valueColor: controller.isConnected ? Color(hex: "#3B82F6") : Color(hex: "#6B7280"),
                trailingButton: nil
            )

            Divider().opacity(0.08).padding(.leading, 44)

            // ── Profile ─────────────────────────────────────────────────────
            MenuStatusRow(
                icon: profile.currentProfile == .desktop
                    ? "desktopcomputer"
                    : "gamecontroller.fill",
                iconColor: profileBadgeColor,
                label: "Profile",
                value: profile.currentProfile == .desktop
                    ? "Desktop (mouse active)"
                    : "Blank (pass-through)",
                valueColor: profileBadgeColor,
                trailingButton: nil
            )
        }
    }

    // MARK: - Chord Hint Row

    private var chordHintRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.25))
            Text("L1 + Start + Down  →  Cmd+Q (quit app)")
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(Color.white.opacity(0.3))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: - Quit Button

    private var quitButton: some View {
        Button(role: .destructive) {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                Text("Quit Controller4Mac")
                    .font(.system(.subheadline, design: .rounded))
            }
            .foregroundColor(Color(hex: "#EF4444"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .background(Color(hex: "#EF4444").opacity(0.06))
    }

    // MARK: - Helpers

    private var profileBadgeColor: Color {
        profile.currentProfile == .desktop
            ? Color(hex: "#7B61FF")
            : Color(hex: "#F59E0B")
    }
}

// MARK: - Menu Status Row Component

private struct MenuStatusRow: View {

    let icon: String
    let iconColor: Color
    let label: String
    let value: String
    let valueColor: Color
    let trailingButton: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 12) {

            // Icon bubble
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(iconColor)
            }

            // Labels
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.5))
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(valueColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Live pulse dot
            PulseDot(color: iconColor)

            // Optional trailing action
            if let (label, action) = trailingButton {
                Button(action: action) {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(hex: "#7B61FF").opacity(0.2))
                        .foregroundColor(Color(hex: "#A78BFA"))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(hex: "#7B61FF").opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Status Dot

private struct PulseDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

// MARK: - NSVisualEffectView Bridge

/// Brings macOS vibrancy/blur into SwiftUI for the panel background.
private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material    = material
        view.blendingMode = blendingMode
        view.state       = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material     = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Color Hex Extension

extension Color {
    /// Initialises a SwiftUI Color from a CSS-style hex string (e.g. "#1A1A2E").
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red:   Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: 1
        )
    }
}

// MARK: - Preview

#Preview {
    let pm = ProfileManager()
    return MenuBarContentView()
        .environmentObject(AccessibilityManager())
        .environmentObject(pm)
        .environmentObject(ControllerManager(profileManager: pm))
}

