import SwiftUI

/// Title (or a back button) on the left, pod pills on the right.
struct ScreenHeader: View {
    var title: String = ""
    var backTitle: String?
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.ui(19, .semibold))
                        Text(backTitle ?? "Back")
                            .font(.ui(17, .medium))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.text)
                .padding(.leading, -10)
            } else {
                Text(title)
                    .font(.ui(17, .semibold))
                    .tracking(-0.17)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            PodPills()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

/// "L 82%" / "R off" pills. Dots pulse red while the pods stream.
struct PodPills: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PodSide.allCases) { side in
                let status = model.pods.status(of: side)
                let on = status.connection == .connected
                HStack(spacing: 6) {
                    StatusDot(
                        color: on ? (model.isStreaming ? Palette.red : Palette.green) : Palette.off,
                        size: 6,
                        pulsing: on && model.isStreaming
                    )
                    Text(pillText(side, status))
                        .monospacedDigit()
                }
                .font(.ui(12, .medium))
                .foregroundStyle(Palette.soft)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Palette.surface))
                .overlay(Capsule().strokeBorder(Palette.line))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(pillLabel(side, status))
            }
        }
    }

    private func pillText(_ side: PodSide, _ status: PodStatus) -> String {
        guard status.connection == .connected else { return "\(side.rawValue) off" }
        guard let pct = status.batteryPercent else { return "\(side.rawValue) on" }
        return "\(side.rawValue) \(pct)%"
    }

    private func pillLabel(_ side: PodSide, _ status: PodStatus) -> String {
        guard status.connection == .connected else { return "\(side.name), not connected" }
        if let pct = status.batteryPercent { return "\(side.name), \(pct) percent battery" }
        return "\(side.name), connected"
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat
    var pulsing = false

    var body: some View {
        let dot = Circle().fill(color).frame(width: size, height: size)
        if pulsing {
            dot.phaseAnimator([1.0, 0.25]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
        } else {
            dot
        }
    }
}

/// Small grey label above a section.
struct SectionLabel: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.ui(13, .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// White (or dark) rounded card with a hairline border.
    func card(radius: CGFloat = 16) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.surface))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line))
    }

    /// Hairline on top of every row but the first in a card.
    func rowSeparator(_ show: Bool) -> some View {
        overlay(alignment: .top) {
            if show {
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
    }
}

/// Shrinks a touch while pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Highlights a list row while pressed.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.track : Color.clear)
    }
}

/// A square-ish toggle button: ink when selected, card otherwise.
struct ChoiceButton: View {
    var title: String
    var selected: Bool
    var height: CGFloat = 52
    var fontSize: CGFloat = 20
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.mono(fontSize, .semibold))
                .foregroundStyle(selected ? Palette.onInk : Palette.text)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Palette.ink : Palette.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Palette.ink : Palette.line)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One saved jump: code, when, airtime.
struct JumpRow: View {
    var leading: String
    var leadingWidth: CGFloat = 44
    var leadingFont: Font = .mono(17, .semibold)
    var leadingColor: Color = Palette.text
    var date: Date
    var airtime: Double

    var body: some View {
        HStack(spacing: 14) {
            Text(leading)
                .font(leadingFont)
                .foregroundStyle(leadingColor)
                .frame(width: leadingWidth, alignment: .leading)
            Text(Format.jumpDate(date))
                .font(.ui(14))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(Format.ms(airtime)) ms")
                .font(.mono(16))
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
