import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func safeSymbolEffectPulse(isActive: Bool) -> some View {
        if #available(macOS 14, *) {
            self.symbolEffect(.pulse, isActive: isActive)
        } else {
            self
        }
    }

    @ViewBuilder
    func onLogCountChange(_ value: Int, perform action: @escaping () -> Void) -> some View {
        if #available(macOS 14, *) {
            self.onChange(of: value) { action() }
        } else {
            self.onChange(of: value) { _ in action() }
        }
    }
}

enum DS {
    static let cardBg = Color(NSColor.controlBackgroundColor)
    static let surfaceBg = Color(NSColor.windowBackgroundColor)
    static let subtleBorder = Color.primary.opacity(0.06)
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
}

struct BatteryRing: View {
    let label: String
    let percent: Int
    let icon: String

    private var color: Color {
        if percent > 50 { return .green }
        if percent > 20 { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 4)
                    .frame(width: 38, height: 38)
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100.0)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(-90))
                Text("\(percent)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}

struct DiagRow: View {
    let icon: String
    let label: String
    let value: String
    let status: RowStatus

    enum RowStatus { case ok, warn, neutral }

    private var statusColor: Color {
        switch status {
        case .ok: return .green
        case .warn: return .red
        case .neutral: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 4)
    }
}

struct ActionButton: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let style: ButtonType
    let action: () -> Void
    @State private var isHovered = false

    enum ButtonType { case primary, secondary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if let sub = subtitle {
                        Text(sub)
                            .font(.system(size: 10))
                            .foregroundColor(style == .primary ? .white.opacity(0.7) : .secondary)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: style == .secondary ? 1 : 0)
            )
            .shadow(color: style == .primary ? Color.accentColor.opacity(isHovered ? 0.3 : 0.15) : .clear, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.9 : 1.0))
        case .secondary:
            return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.06 : 0.03))
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .primary
        }
    }

    private var borderColor: Color {
        style == .secondary ? DS.subtleBorder : .clear
    }
}
