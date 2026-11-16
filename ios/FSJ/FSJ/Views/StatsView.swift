import SwiftUI

/// Stats tab: jump families first, then rotations within a family.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var family: JumpFamily?
    @State private var rotations = 1

    var body: some View {
        Group {
            if let family {
                FamilyStatsView(family: family, rotations: $rotations) {
                    self.family = nil
                }
                .transition(.move(edge: .trailing))
            } else {
                familyList
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.25), value: family)
        .background(Palette.bg.ignoresSafeArea())
        .onChange(of: model.tab) { _, tab in
            if tab != .stats { family = nil }
        }
    }

    private var familyList: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Stats")
            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 0) {
                        ForEach(Array(JumpFamily.allCases.enumerated()), id: \.element) { index, f in
                            familyRow(f)
                                .rowSeparator(index > 0)
                        }
                    }
                    .card()

                    Text(Format.attempts(model.store.jumps.count))
                        .font(.ui(13))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
    }

    private func familyRow(_ f: JumpFamily) -> some View {
        let count = model.store.count(in: f)
        let codes = model.store.codesWithData(in: f)
        return Button {
            rotations = codes.last?.rotations ?? 1
            family = f
        } label: {
            HStack(spacing: 14) {
                Text(f.name)
                    .font(.ui(17, .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.ui(14, .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .accessibilityLabel("\(f.name), \(count == 0 ? "no attempts" : Format.attempts(count))")
    }
}

/// One family: pick rotations, then mean, median, std dev, min, max, spread and attempts.
struct FamilyStatsView: View {
    var family: JumpFamily
    @Binding var rotations: Int
    var onBack: () -> Void

    @Environment(AppModel.self) private var model

    private var code: JumpCode { JumpCode(family: family, rotations: rotations) }

    var body: some View {
        let jumps = model.store.jumps(for: code)
        let stats = JumpStats(jumps.map(\.airtime))

        VStack(spacing: 0) {
            ScreenHeader(backTitle: "Stats", onBack: onBack)
            ScrollView {
                VStack(spacing: 18) {
                    Text(family.name)
                        .font(.ui(30, .bold))
                        .tracking(-0.6)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)

                    if family.hasRotations {
                        rotationPicker
                    }

                    if let stats {
                        StatsGrid(stats: stats)
                        SpreadChart(times: jumps.map(\.airtime), stats: stats)
                        attempts(jumps)
                    } else {
                        Text("No \(code.description) attempts yet")
                            .font(.ui(15))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .padding(.horizontal, 16)
                            .card()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private var rotationPicker: some View {
        HStack(spacing: 8) {
            ForEach(Array(JumpCode.rotationRange), id: \.self) { n in
                let c = JumpCode(family: family, rotations: n)
                let on = rotations == n
                let has = !model.store.jumps(for: c).isEmpty
                ChoiceButton(title: c.description, selected: on, fontSize: 18) {
                    rotations = n
                }
                .opacity(has || on ? 1 : 0.45)
                .accessibilityLabel(c.spokenName)
            }
        }
    }

    private func attempts(_ jumps: [SavedJump]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(jumps.enumerated().reversed()), id: \.element.id) { index, jump in
                JumpRow(
                    leading: "#\(index + 1)",
                    leadingWidth: 32,
                    leadingFont: .mono(13),
                    leadingColor: Palette.muted,
                    date: jump.date,
                    airtime: jump.airtime
                )
                .rowSeparator(index != jumps.count - 1)
            }
        }
        .card()
    }
}

/// 3 x 2 grid: Mean, Median, Std dev / Min, Max, Attempts.
private struct StatsGrid: View {
    var stats: JumpStats

    var body: some View {
        let cells: [(String, String)] = [
            ("Mean", "\(Format.ms(stats.mean)) ms"),
            ("Median", "\(Format.ms(stats.median)) ms"),
            ("Std dev", stats.standardDeviation.map { "\(Format.msTenths($0)) ms" } ?? "n/a"),
            ("Min", "\(Format.ms(stats.min)) ms"),
            ("Max", "\(Format.ms(stats.max)) ms"),
            ("Attempts", "\(stats.count)"),
        ]
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        let cell = cells[row * 3 + col]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cell.0)
                                .font(.ui(12, .medium))
                                .foregroundStyle(Palette.muted)
                            Text(cell.1)
                                .font(.mono(20, .medium))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 16)
                        .overlay(alignment: .leading) {
                            if col > 0 { Rectangle().fill(Palette.line).frame(width: 1) }
                        }
                        .overlay(alignment: .top) {
                            if row > 0 { Rectangle().fill(Palette.line).frame(height: 1) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .card()
    }
}

/// Dots for each attempt, a red line at the mean, a band for mean +/- 1 SD.
private struct SpreadChart: View {
    var times: [Double]
    var stats: JumpStats

    var body: some View {
        let lo = (floor((stats.min - 0.03) * 50) / 50)
        let hi = (ceil((stats.max + 0.03) * 50) / 50)
        let sd = stats.standardDeviation ?? 0

        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (v: Double) -> CGFloat in
                    CGFloat((min(hi, max(lo, v)) - lo) / (hi - lo)) * w
                }
                let bandStart = x(stats.mean - sd)
                let bandEnd = x(stats.mean + sd)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Palette.track)
                        .frame(width: w, height: 2)
                        .offset(y: 11)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.band)
                        .frame(width: max(0, bandEnd - bandStart), height: 16)
                        .offset(x: bandStart, y: 4)
                    ForEach(Array(times.enumerated()), id: \.offset) { _, t in
                        Circle()
                            .fill(Palette.text)
                            .opacity(0.55)
                            .frame(width: 10, height: 10)
                            .offset(x: x(t) - 5, y: 7)
                    }
                    Rectangle()
                        .fill(Palette.red)
                        .frame(width: 2, height: 24)
                        .offset(x: x(stats.mean) - 1)
                }
            }
            .frame(height: 24)

            HStack {
                Text("\(Format.ms(lo)) ms")
                Spacer()
                Text("\(Format.ms(hi)) ms")
            }
            .font(.mono(12))
            .foregroundStyle(Palette.muted)

            HStack(spacing: 14) {
                legend("Attempt") {
                    Circle().fill(Palette.text).opacity(0.55).frame(width: 8, height: 8)
                }
                legend("Mean") {
                    Rectangle().fill(Palette.red).frame(width: 2, height: 12)
                }
                legend("Mean \u{00B1} 1 SD") {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.band).frame(width: 16, height: 8)
                }
                Spacer(minLength: 0)
            }
            .font(.ui(12))
            .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spread from \(Format.ms(stats.min)) to \(Format.ms(stats.max)) milliseconds")
    }

    private func legend<Mark: View>(_ text: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 6) {
            mark()
            Text(text)
        }
    }
}

#Preview {
    StatsView().environment(AppModel.preview())
}
