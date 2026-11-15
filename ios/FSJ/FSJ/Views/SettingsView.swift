import SwiftUI

/// Settings tab: connect each pod, light/dark, clear all data.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .light
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Settings")
            ScrollView {
                VStack(spacing: 22) {
                    section("Pods") {
                        VStack(spacing: 0) {
                            ForEach(Array(PodSide.allCases.enumerated()), id: \.element) { index, side in
                                PodRow(side: side)
                                    .rowSeparator(index > 0)
                            }
                        }
                        .card()
                    }
                    section("Appearance") { themePicker }
                    section("Data") { dataCard }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .onChange(of: model.tab) { _, _ in confirmingClear = false }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            SectionLabel(title)
            content()
        }
    }

    private var themePicker: some View {
        HStack(spacing: 4) {
            ForEach(AppTheme.allCases, id: \.self) { option in
                let on = theme == option
                Button {
                    theme = option
                } label: {
                    Text(option == .light ? "Light" : "Dark")
                        .font(.ui(15, .semibold))
                        .foregroundStyle(on ? Palette.onInk : Palette.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Palette.ink : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .card(radius: 14)
    }

    private var dataCard: some View {
        let count = model.store.jumps.count
        return VStack(spacing: 0) {
            HStack {
                Text("Saved jumps")
                Spacer()
                Text("\(count)")
                    .font(.mono(16))
                    .foregroundStyle(Palette.muted)
            }
            .font(.ui(16))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if confirmingClear {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete all \(count) saved jumps?")
                            .font(.ui(16, .semibold))
                        Text("Every airtime and stat is removed from this phone. This can't be undone.")
                            .font(.ui(14))
                            .foregroundStyle(Palette.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button {
                            confirmingClear = false
                        } label: {
                            Text("Cancel")
                                .font(.ui(15, .semibold))
                                .foregroundStyle(Palette.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.lineStrong))
                        }
                        Button {
                            model.store.clearAll()
                            confirmingClear = false
                        } label: {
                            Text("Delete all")
                                .font(.ui(15, .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.red))
                        }
                    }
                    .buttonStyle(PressStyle())
                }
                .padding(16)
                .rowSeparator(true)
                .accessibilityElement(children: .contain)
            } else {
                Button {
                    confirmingClear = true
                } label: {
                    Text("Clear all data")
                        .font(.ui(16, .semibold))
                        .foregroundStyle(Palette.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowPressStyle())
                .disabled(count == 0)
                .opacity(count == 0 ? 0.4 : 1)
                .rowSeparator(true)
            }
        }
        .card()
        .sensoryFeedback(.warning, trigger: confirmingClear) { _, new in new }
    }
}

private struct PodRow: View {
    var side: PodSide
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.pods.status(of: side)
        HStack(spacing: 14) {
            StatusDot(color: status.connection == .connected ? Palette.green : Palette.off, size: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(side.name)
                    .font(.ui(16, .semibold))
                Text(statusText(status))
                    .font(.ui(13))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            switch status.connection {
            case .connected:
                Button { model.pods.disconnect(side) } label: {
                    Text("Disconnect")
                        .font(.ui(14, .semibold))
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.lineStrong))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Disconnect \(side.name)")
            case .disconnected:
                Button { model.pods.connect(side) } label: {
                    Text("Connect")
                        .font(.ui(14, .semibold))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.ink))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Connect \(side.name)")
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Palette.text)
                    Text("Connecting")
                        .font(.ui(14))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 6)
                .frame(height: 40)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 14)
    }

    private func statusText(_ status: PodStatus) -> String {
        switch status.connection {
        case .connected:
            status.batteryPercent.map { "Connected, \($0)% battery" } ?? "Connected"
        case .connecting:
            "Searching over Bluetooth"
        case .disconnected:
            "Not connected"
        }
    }
}

#Preview {
    SettingsView().environment(AppModel.preview(connected: false))
}
