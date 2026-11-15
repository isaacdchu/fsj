import SwiftUI

/// After Stop: show the airtime, pick rotations and jump, then Save or Discard.
struct TagJumpView: View {
    var airtime: Double

    @Environment(AppModel.self) private var model
    @State private var family: JumpFamily?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private var code: JumpCode? {
        family.map { JumpCode(family: $0, rotations: model.tagRotations) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Tag this jump")
            ScrollView {
                VStack(spacing: 22) {
                    airtimeBlock
                    rotationPicker
                    jumpPicker
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            actionBar
        }
        .sensoryFeedback(.selection, trigger: family)
        .sensoryFeedback(.selection, trigger: model.tagRotations)
    }

    private var airtimeBlock: some View {
        VStack(spacing: 2) {
            Text("Airtime")
                .font(.ui(13, .semibold))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.seconds(airtime))
                    .font(.mono(72, .medium))
                    .monospacedDigit()
                    .tracking(-2.9)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("s")
                    .font(.ui(22, .medium))
                    .foregroundStyle(Palette.muted)
            }
            Text("From pod data, takeoff to landing")
                .font(.ui(14))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Airtime \(Format.seconds(airtime)) seconds, from pod data")
    }

    private var rotationPicker: some View {
        let isWaltz = family == .waltz
        let selected = isWaltz ? 1 : model.tagRotations
        return VStack(spacing: 10) {
            SectionLabel("Rotations")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(JumpCode.rotationRange), id: \.self) { n in
                    let locked = isWaltz && n != 1
                    ChoiceButton(title: "\(n)", selected: selected == n) {
                        model.tagRotations = n
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
                    ChoiceButton(title: f.code, selected: family == f, height: 60) {
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
                Button { model.discard() } label: {
                    Text("Discard")
                        .font(.ui(17, .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(width: unit, height: 54)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong))
                }
                .buttonStyle(PressStyle())

                Button {
                    if let code { model.save(code) }
                } label: {
                    Text("Save")
                        .font(.ui(17, .semibold))
                        .foregroundStyle(Palette.onInk)
                        .frame(width: unit * 2, height: 54)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.ink))
                }
                .buttonStyle(PressStyle())
                .disabled(code == nil)
                .opacity(code == nil ? 0.35 : 1)
                .accessibilityHint(code.map { "Saves as \($0.spokenName)" } ?? "Pick a jump first")
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

#Preview {
    TagJumpView(airtime: 0.534).environment(AppModel.preview(phase: .review(airtime: 0.534)))
}
