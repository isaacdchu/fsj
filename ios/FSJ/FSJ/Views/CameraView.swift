import SwiftUI

/// Camera tab: film the jump while the pods record, then mark takeoff and landing.
struct CameraView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if case .mark(let clip, let podAirtime, let pods) = model.cameraPhase {
                MarkJumpView(clip: clip, podAirtime: podAirtime, pods: pods)
            } else {
                viewfinder
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        // The tab bar stays while filming so the preview doesn't change size;
        // ContentView ignores tab taps until the clip is saved.
        .toolbar(isMarking ? .hidden : .visible, for: .tabBar)
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
                            Text(camera.usesFrontCamera ? "Front camera" : "Back camera")
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
                    if model.cameraPhase == .idle {
                        flipButton
                    }
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
                recordCircle
            }
            .buttonStyle(PressStyle())
            .disabled(!ready)
            .opacity(ready ? 1 : 0.35)
            .accessibilityLabel("Record video and start pods")
        case .filming:
            Button { model.cameraStop() } label: {
                recordCircle
                    .phaseAnimator([1.0, 0.25]) { content, opacity in
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

    private var isMarking: Bool {
        if case .mark = model.cameraPhase { return true }
        return false
    }

    /// Switches between the back and front camera. Hidden while filming.
    private var flipButton: some View {
        Button {
            Task { await model.camera.flip() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.ui(18, .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(model.camera.state == .preparing)
        .accessibilityLabel("Flip camera")
        .accessibilityValue(model.camera.usesFrontCamera ? "Front camera" : "Back camera")
    }

    /// Plain red circle with a white ring. The same button records and
    /// stops; it pulses while filming.
    private var recordCircle: some View {
        Circle()
            .fill(Palette.red)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 4))
            .frame(width: 67, height: 67)
            .contentShape(Circle())
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
    /// Pod data on the video's clock; nil if the pods couldn't be synced.
    var pods: SyncedPods?

    @Environment(AppModel.self) private var model
    @State private var frame = 0
    @State private var takeoff: Int?
    @State private var landing: Int?
    @State private var frames = FrameLoader()
    @State private var family: JumpFamily?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private var code: JumpCode? {
        family.map { JumpCode(family: $0, rotations: model.cameraRotations) }
    }

    private var canSave: Bool { ready && code != nil }

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
        return (clip.ms(at: landing) - clip.ms(at: takeoff)) / 1000
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Mark the jump")
            ScrollView {
                VStack(spacing: 14) {
                    viewer
                    scrubber
                    podTrace
                    stepper
                    markButtons
                    comparison
                    rotationPicker
                    jumpPicker
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
        .sensoryFeedback(.selection, trigger: family)
        .sensoryFeedback(.selection, trigger: model.cameraRotations)
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

    // MARK: Pod data

    /// x position of a phone-clock time on a strip as wide as the scrubber.
    private func x(host t: Double, width w: CGFloat) -> CGFloat {
        guard clip.lastFrame > 0 else { return 0 }
        return CGFloat(clip.framePosition(ofHost: t) / Double(clip.lastFrame)) * w
    }

    private static let traceMaxG = 3.0

    @ViewBuilder
    private var podTrace: some View {
        if let pods {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    traceLegend("L", color: Palette.text)
                    traceLegend("R", color: Palette.muted)
                    Spacer()
                    Text("Pod data, synced \u{00B1}\(Self.wholeMs(pods.uncertainty)) ms")
                        .font(.ui(12))
                        .foregroundStyle(Palette.muted)
                }
                traceCanvas(pods)
                Text(offsetsLabel(pods))
                    .font(.mono(12))
                    .foregroundStyle(Palette.muted)
            }
        } else {
            Text("Pod clocks not synced, so the pod data can't be lined up with the video.")
                .font(.ui(12))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func traceLegend(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(label).font(.mono(12, .medium)).foregroundStyle(Palette.muted)
        }
    }

    private func traceCanvas(_ pods: SyncedPods) -> some View {
        let ink = Palette.text, soft = Palette.muted, red = Palette.red, line = Palette.line
        let frame = frame, takeoff = takeoff, landing = landing
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Canvas { ctx, _ in
                // Shade where the pods were in the air.
                for trace in pods.traces {
                    guard let f = trace.flight else { continue }
                    let a = x(host: f.lowerBound, width: w), b = x(host: f.upperBound, width: w)
                    ctx.fill(Path(CGRect(x: a, y: 0, width: b - a, height: h)), with: .color(red.opacity(0.12)))
                }
                // 1 g reference.
                let oneG = h - h / Self.traceMaxG
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: oneG)); $0.addLine(to: CGPoint(x: w, y: oneG)) },
                           with: .color(line), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                for trace in pods.traces {
                    var path = Path()
                    var started = false
                    for (t, g) in zip(trace.hostTimes, trace.g) {
                        let px = x(host: t, width: w)
                        guard px >= -4, px <= w + 4 else { continue }
                        let p = CGPoint(x: px, y: h - CGFloat(min(g, Self.traceMaxG) / Self.traceMaxG) * h)
                        if started { path.addLine(to: p) } else { path.move(to: p) }
                        started = true
                    }
                    ctx.stroke(path, with: .color(trace.side == .left ? ink : soft), lineWidth: 1.5)
                }
                // The video marks and the playhead.
                for mark in [takeoff, landing].compactMap({ $0 }) {
                    let mx = clip.lastFrame == 0 ? 0 : CGFloat(mark) / CGFloat(clip.lastFrame) * w
                    ctx.fill(Path(CGRect(x: mx - 1, y: 0, width: 2, height: h)), with: .color(red))
                }
                let px = clip.lastFrame == 0 ? 0 : CGFloat(frame) / CGFloat(clip.lastFrame) * w
                ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: h)), with: .color(ink))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard w > 0 else { return }
                        let p = min(max(value.location.x / w, 0), 1)
                        self.frame = Int((p * CGFloat(clip.lastFrame)).rounded())
                    }
            )
        }
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pod acceleration lined up with the video")
    }

    /// How far the pods' takeoff and landing are from the marked frames.
    private func offsetsLabel(_ pods: SyncedPods) -> String {
        guard let podTakeoff = pods.takeoff, let podLanding = pods.landing else {
            return "Pods found no jump"
        }
        guard let takeoff, let landing else { return "Mark takeoff and landing to compare" }
        let t = Self.signedMs(podTakeoff - clip.hostTime(at: takeoff))
        let l = Self.signedMs(podLanding - clip.hostTime(at: landing))
        return "Pods vs video: takeoff \(t) ms, landing \(l) ms"
    }

    private static func wholeMs(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func signedMs(_ seconds: Double) -> String {
        let ms = wholeMs(seconds)
        return ms > 0 ? "+\(ms)" : ms < 0 ? "\u{2212}\(-ms)" : "0"
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

    // MARK: Tag the jump

    private var rotationPicker: some View {
        let isWaltz = family == .waltz
        let selected = isWaltz ? 1 : model.cameraRotations
        return VStack(spacing: 10) {
            SectionLabel("Rotations")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(JumpCode.rotationRange), id: \.self) { n in
                    let locked = isWaltz && n != 1
                    ChoiceButton(title: "\(n)", selected: selected == n) {
                        model.cameraRotations = n
                    }
                    .disabled(locked)
                    .opacity(locked ? 0.3 : 1)
                    .accessibilityLabel("\(n) rotation\(n == 1 ? "" : "s")")
                }
            }
        }
    }

    private var jumpPicker: some View {
        VStack(spacing: 10) {
            SectionLabel("Jump")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(JumpFamily.allCases) { f in
                    ChoiceButton(title: f.code, selected: family == f, height: 56) {
                        family = f
                    }
                    .accessibilityLabel(f.name)
                }
            }
        }
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
                    if let videoAirtime, let code { model.cameraSave(code, videoAirtime: videoAirtime) }
                } label: {
                    Text("Save video")
                        .font(.ui(17, .semibold))
                        .foregroundStyle(Palette.onInk)
                        .frame(width: unit * 2, height: 54)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.ink))
                }
                .buttonStyle(PressStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.35)
                .accessibilityHint(code.map { "Saves the video and the jump as \($0.spokenName)" } ?? "Mark the jump and pick it first")
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
    let times = (0..<320).map { Double($0) / 100 }
    let pods = SyncedPods(traces: PodSide.allCases.map { side in
        let flight = (side == .left ? 1.255 : 1.250)...(side == .left ? 1.785 : 1.790)
        return PodTrace(
            side: side,
            hostTimes: times,
            g: times.map { flight.contains($0) ? 0.05 : 1 },
            flight: flight,
            uncertainty: 0.003
        )
    })
    model.cameraPhase = .mark(clip: .simulated, podAirtime: 0.533, pods: pods)
    return CameraView().environment(model)
}
