import SwiftUI

/// Camera tab: film the jump while the pods record, then mark takeoff and landing.
struct CameraView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if case .mark(let clip, let podAirtime) = model.cameraPhase {
                MarkJumpView(clip: clip, podAirtime: podAirtime)
            } else {
                viewfinder
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .toolbar(model.cameraPhase == .idle ? .visible : .hidden, for: .tabBar)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isFilming)
        .task { await model.camera.prepare() }
        .onDisappear {
            if model.cameraPhase == .idle { model.camera.pause() }
        }
    }

    private var viewfinder: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Camera")
            ZStack {
                preview
                thirdsGrid
                overlays
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        let camera = model.camera
        if !camera.isSimulated, camera.state == .ready {
            CameraPreview(session: camera.capture.session)
        } else {
            Color(white: 0.067)
                .overlay {
                    Group {
                        if case .failed(let message) = camera.state {
                            Text(message)
                        } else {
                            Text("Camera preview")
                        }
                    }
                    .font(.ui(15))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(24)
                }
        }
    }

    private var thirdsGrid: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Overlays

    private var overlays: some View {
        ZStack {
            // Top row: timer while filming, frame rate on the right.
            VStack {
                HStack(alignment: .top) {
                    if case .filming(let since) = model.cameraPhase {
                        HStack(spacing: 8) {
                            StatusDot(color: Palette.red, size: 8, pulsing: true)
                            TimelineView(.periodic(from: since, by: 0.1)) { context in
                                Text(Format.timer(context.date.timeIntervalSince(since)))
                                    .monospacedDigit()
                            }
                        }
                        .font(.mono(15))
                        .videoBadge()
                    }
                    Spacer()
                    Text("\(Int(model.camera.fps.rounded())) fps")
                        .font(.mono(12, .medium))
                        .videoBadge()
                }
                Spacer()
            }
            .padding(14)

            if model.cameraPhase == .receiving {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Saving video and pod data")
                        .font(.ui(15, .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.6))
                .accessibilityElement(children: .combine)
            }

            VStack(spacing: 12) {
                Spacer()
                bottomControls
            }
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        switch model.cameraPhase {
        case .idle:
            let ready = model.bothPodsConnected && model.camera.state == .ready
            if let notice = model.cameraNotice {
                Text(notice.text)
                    .font(.ui(14, .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.6)))
                    .padding(.horizontal, 24)
            } else if !model.bothPodsConnected {
                Button("Connect both pods in Settings") { model.tab = .settings }
                    .font(.ui(14, .semibold))
                    .underline()
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.6)))
            }
            Button { model.cameraRecord() } label: {
                Text("Record")
                    .font(.ui(15, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(Palette.red))
                    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 4))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .disabled(!ready)
            .opacity(ready ? 1 : 0.35)
            .accessibilityLabel("Record video and start pods")
        case .filming:
            Button { model.cameraStop() } label: {
                Text("Stop")
                    .font(.ui(15, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(Palette.red))
                    .contentShape(Circle())
                    .phaseAnimator([1.0, 0.6]) { content, opacity in
                        content.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 0.8)
                    }
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Stop video and pods")
        default:
            EmptyView()
        }
    }
}

private extension View {
    /// Small dark label on top of the video.
    func videoBadge() -> some View {
        self
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.55)))
    }
}

/// After Stop: step through the clip, set takeoff and landing, then Save video or Discard.
struct MarkJumpView: View {
    var clip: VideoClip
    var podAirtime: Double?

    @Environment(AppModel.self) private var model
    @State private var frame = 0
    @State private var takeoff: Int?
    @State private var landing: Int?
    @State private var frames = FrameLoader()

    private var ready: Bool {
        guard let takeoff, let landing else { return false }
        return landing > takeoff
    }

    private var invalid: Bool {
        guard let takeoff, let landing else { return false }
        return landing <= takeoff
    }

    /// Seconds between the marks.
    private var videoAirtime: Double? {
        guard ready, let takeoff, let landing else { return nil }
        return Double(landing - takeoff) / clip.fps
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Mark the jump")
            ScrollView {
                VStack(spacing: 14) {
                    viewer
                    scrubber
                    stepper
                    markButtons
                    comparison
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            actionBar
        }
        .onAppear {
            frames.load(clip)
            frames.show(frame: frame)
        }
        .onChange(of: frame) { _, f in frames.show(frame: f) }
        .sensoryFeedback(.selection, trigger: frame)
    }

    // MARK: Viewer

    private var viewer: some View {
        ZStack {
            Color(white: 0.067)
            if let image = frames.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if clip.url == nil {
                SimulatedJumpFrame(frame: frame, clip: clip)
            }
            VStack {
                HStack {
                    Text("Frame \(frame)").videoBadge()
                    Spacer()
                    Text("\(Format.ms(clip.ms(at: frame) / 1000)) ms").videoBadge()
                }
                .font(.mono(13))
                .monospacedDigit()
                Spacer()
                HStack {
                    if let label = markLabel {
                        Text(label)
                            .font(.ui(13, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.red))
                    }
                    Spacer()
                }
            }
            .padding(12)
        }
        .aspectRatio(358.0 / 232.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video frame \(frame)\(markLabel.map { ", \($0)" } ?? "")")
    }

    private var markLabel: String? {
        if frame == takeoff { return "Takeoff" }
        if frame == landing { return "Landing" }
        return nil
    }

    // MARK: Scrubber

    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (f: Int) -> CGFloat in
                    clip.lastFrame == 0 ? 0 : CGFloat(f) / CGFloat(clip.lastFrame) * w
                }
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Palette.track)
                        .frame(width: w, height: 6)
                        .offset(y: 19)
                    if ready, let takeoff, let landing {
                        Rectangle()
                            .fill(Palette.red.opacity(0.45))
                            .frame(width: x(landing) - x(takeoff), height: 6)
                            .offset(x: x(takeoff), y: 19)
                    }
                    if let takeoff {
                        markTick.offset(x: x(takeoff) - 1, y: 10)
                    }
                    if let landing {
                        markTick.offset(x: x(landing) - 1, y: 10)
                    }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.text)
                        .frame(width: 4, height: 28)
                        .offset(x: x(frame) - 2, y: 8)
                }
                .frame(width: w, height: 44, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard w > 0 else { return }
                            let p = min(max(value.location.x / w, 0), 1)
                            frame = Int((p * CGFloat(clip.lastFrame)).rounded())
                        }
                )
            }
            .frame(height: 44)
            .accessibilityElement()
            .accessibilityLabel("Scrub through video")
            .accessibilityValue("Frame \(frame)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }

            HStack {
                Text("0 ms")
                Spacer()
                Text("\(Format.ms(clip.ms(at: clip.lastFrame) / 1000)) ms")
            }
            .font(.mono(12))
            .foregroundStyle(Palette.muted)
        }
    }

    private var markTick: some View {
        Rectangle()
            .fill(Palette.red)
            .frame(width: 2, height: 24)
    }

    // MARK: Step and mark

    private func step(_ by: Int) {
        frame = min(max(frame + by, 0), clip.lastFrame)
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            stepButton("chevron.left", label: "Back 1 frame") { step(-1) }
            Text("1 frame per tap")
                .font(.ui(14, .semibold))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
            stepButton("chevron.right", label: "Forward 1 frame") { step(1) }
        }
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(20, .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 64, height: 52)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }

    private var markButtons: some View {
        HStack(spacing: 10) {
            markButton("Set takeoff", mark: takeoff) { takeoff = frame }
            markButton("Set landing", mark: landing) { landing = frame }
        }
    }

    private func markButton(_ title: String, mark: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Palette.muted)
                Text(mark.map { "\(Format.ms(clip.ms(at: $0) / 1000)) ms" } ?? "--")
                    .font(.mono(18, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(mark == nil ? Palette.line : Palette.text)
            )
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Comparison and actions

    private var comparisonLabel: String {
        if let error = model.cameraSaveError { return error }
        if invalid { return "Landing must come after takeoff" }
        guard ready else { return "Airtime" }
        if let podAirtime { return "Airtime, pods measured \(Format.ms(podAirtime)) ms" }
        return "Airtime, pods found no jump"
    }

    private var comparison: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(comparisonLabel)
                .font(.ui(14))
                .foregroundStyle(model.cameraSaveError == nil ? Palette.muted : Palette.red)
            Spacer()
            Text(videoAirtime.map { "\(Format.ms($0)) ms" } ?? "--")
                .font(.mono(24, .semibold))
                .monospacedDigit()
                .foregroundStyle(invalid ? Palette.red : Palette.text)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var actionBar: some View {
        GeometryReader { geo in
            let unit = (geo.size.width - 10) / 3
            HStack(spacing: 10) {
                Button { model.cameraDiscard() } label: {
                    Text("Discard")
                        .font(.ui(17, .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(width: unit, height: 54)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong))
                }
                .buttonStyle(PressStyle())

                Button {
                    if let videoAirtime { model.cameraSave(airtime: videoAirtime) }
                } label: {
                    Text("Save video")
                        .font(.ui(17, .semibold))
                        .foregroundStyle(Palette.onInk)
                        .frame(width: unit * 2, height: 54)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.ink))
                }
                .buttonStyle(PressStyle())
                .disabled(!ready)
                .opacity(ready ? 1 : 0.35)
            }
        }
        .frame(height: 54)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Palette.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
    }
}

/// Stand-in picture for the made-up clip: a figure that rises and falls
/// between the simulated takeoff and landing frames.
private struct SimulatedJumpFrame: View {
    var frame: Int
    var clip: VideoClip

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let t0 = Double(VideoClip.simulatedTakeoff), t1 = Double(VideoClip.simulatedLanding)
            let p = (Double(frame) - t0) / (t1 - t0)
            let lift = (0...1).contains(p) ? 72 * 4 * p * (1 - p) : 0
            let scale = h / 232
            let cx = (40 + Double(frame) / Double(max(1, clip.lastFrame)) * 278) / 358 * w
            let ground = 196 * scale
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: w, height: 2)
                    .offset(y: ground - 1)
                Ellipse()
                    .fill(.white.opacity(0.2))
                    .frame(width: max(8, 24 - lift / 4) * scale, height: 6 * scale)
                    .offset(x: cx - max(8, 24 - lift / 4) * scale / 2, y: ground)
                Capsule()
                    .fill(Color(white: 0.9))
                    .frame(width: 14 * scale, height: 40 * scale)
                    .offset(x: cx - 7 * scale, y: (156 - lift) * scale)
                Circle()
                    .fill(Color(white: 0.9))
                    .frame(width: 16 * scale, height: 16 * scale)
                    .offset(x: cx - 8 * scale, y: (138 - lift) * scale)
            }
        }
    }
}

#Preview("Camera") {
    CameraView().environment(AppModel.preview())
}

#Preview("Mark") {
    let model = AppModel.preview()
    model.cameraPhase = .mark(clip: .simulated, podAirtime: 0.533)
    return CameraView().environment(model)
}
