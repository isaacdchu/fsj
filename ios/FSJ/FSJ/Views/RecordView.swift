import SwiftUI

/// Record tab: Start/Stop the pods, then tag the jump.
struct RecordView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if case .review(let airtime) = model.phase {
                TagJumpView(airtime: airtime)
            } else {
                recorder
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .toolbar(model.phase == .idle ? .visible : .hidden, for: .tabBar)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isStreaming)
    }

    private var recorder: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Airtime")
            ScrollView {
                VStack(spacing: 16) {
                    hint
                        .frame(height: 72, alignment: .top)
                    bigButton
                        .frame(width: 216, height: 216)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 24)

                RecentList()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Hint area (fixed height so the button never moves)

    @ViewBuilder
    private var hint: some View {
        switch model.phase {
        case .recording(let since):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(color: Palette.red, size: 8, pulsing: true)
                    Text("Pods streaming")
                        .textCase(.uppercase)
                        .tracking(1)
                }
                .font(.ui(13, .semibold))
                .foregroundStyle(Palette.red)

                TimelineView(.periodic(from: since, by: 0.1)) { context in
                    Text(Format.timer(context.date.timeIntervalSince(since)))
                        .font(.mono(34, .medium))
                        .monospacedDigit()
                        .tracking(-0.7)
                }
            }
        case .receiving:
            hintText("Pods stopped. Computing airtime from their data.")
        case .idle:
            if let notice = model.notice {
                NoticeView(notice: notice)
            } else if model.bothPodsConnected {
                hintText("Start tells both pods to stream motion data to this phone. Stop ends the stream.")
                    .frame(maxWidth: 290)
            } else {
                VStack(spacing: 4) {
                    hintText("Both pods need to be connected.")
                    Button("Connect in Settings") { model.tab = .settings }
                        .font(.ui(15, .semibold))
                        .underline()
                        .foregroundStyle(Palette.text)
                        .buttonStyle(.plain)
                        .frame(minHeight: 32)
                }
            }
        case .review:
            EmptyView()
        }
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.ui(15))
            .foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
    }

    // MARK: Start / Stop (same frame in every state)

    @ViewBuilder
    private var bigButton: some View {
        switch model.phase {
        case .recording:
            ZStack {
                PulseRing()
                Button { model.stop() } label: {
                    circleLabel("Stop", fill: Palette.red, foreground: .white)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Stop pods")
            }
        case .receiving:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.text)
                Text("Receiving data")
                    .font(.ui(15, .semibold))
                    .foregroundStyle(Palette.soft)
            }
            .frame(width: 216, height: 216)
            .background(Circle().fill(Palette.surface))
            .overlay(Circle().strokeBorder(Palette.line))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Receiving data from pods")
        default:
            let ready = model.bothPodsConnected
            Button { model.start() } label: {
                circleLabel("Start", fill: Palette.ink, foreground: Palette.onInk)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 12)
            }
            .buttonStyle(PressStyle())
            .disabled(!ready)
            .opacity(ready ? 1 : 0.35)
            .accessibilityLabel("Start pods")
        }
    }

    private func circleLabel(_ title: String, fill: Color, foreground: Color) -> some View {
        Text(title)
            .font(.ui(22, .semibold))
            .tracking(-0.22)
            .foregroundStyle(foreground)
            .frame(width: 216, height: 216)
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }
}

/// Expanding red ring behind the Stop button.
private struct PulseRing: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(Palette.red, lineWidth: 2)
            .scaleEffect(expanded ? 1.28 : 1)
            .opacity(expanded ? 0 : 0.45)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

private struct NoticeView: View {
    var notice: RecordNotice

    var body: some View {
        switch notice.kind {
        case .saved:
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.ui(13, .bold))
                Text(notice.text)
                    .font(.ui(14, .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.ink))
            .transition(.opacity)
        case .problem:
            Text(notice.text)
                .font(.ui(15, .medium))
                .foregroundStyle(Palette.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
    }
}

/// Last three saved jumps, newest first.
private struct RecentList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recent = model.store.recent(3)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent").font(.ui(13, .semibold))
                Spacer()
                Text(Format.attempts(model.store.jumps.count)).font(.ui(13))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                if recent.isEmpty {
                    Text("No jumps saved yet")
                        .font(.ui(14))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, jump in
                        JumpRow(leading: jump.code.description, date: jump.date, airtime: jump.airtime)
                            .rowSeparator(index > 0)
                            .accessibilityLabel("\(jump.code.spokenName), \(Format.ms(jump.airtime)) milliseconds, \(Format.jumpDate(jump.date))")
                    }
                }
            }
            .card()
        }
    }
}

#Preview("Idle") {
    RecordView().environment(AppModel.preview())
}

#Preview("Recording") {
    RecordView().environment(AppModel.preview(phase: .recording(since: .now)))
}

#Preview("Pods off") {
    RecordView().environment(AppModel.preview(connected: false))
}
