import SwiftUI

/// Visual readout of a look's Style DNA.
struct DNAView: View {
    let dna: StyleDNA

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ToneCurveView(dna: dna)
                    .frame(height: 120)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<3, id: \.self) { z in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(zoneColor(z))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                            Text(["Shadows", "Mids", "Highlights"][z])
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    HueBars(dna: dna).frame(height: 26)
                }
                .frame(width: 118)
            }
            HStack(spacing: 10) {
                Meter(label: "Grain", value: dna.grain)
                Meter(label: "Halation", value: dna.halation)
                Meter(label: "Vignette", value: dna.vignette)
            }
            HStack {
                Label(dna.isMonochrome ? "Monochrome" : "Saturation \(Int(min(dna.chroma / 0.12, 1.5) * 100))%", systemImage: "drop.halffull")
                Spacer()
                Label(sizeText, systemImage: "lock.shield")
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var sizeText: String {
        let bytes = (try? SharedStyle(Style(name: "", dna: dna)).encoded().count) ?? 0
        return "\(bytes) bytes · no pixels stored"
    }

    private func zoneColor(_ z: Int) -> Color {
        let c = Oklab.toSRGBClamped(SIMD3(dna.zoneLuma[z], dna.zoneTintA[z] * 2.5, dna.zoneTintB[z] * 2.5))
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

struct ToneCurveView: View {
    let dna: StyleDNA

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let points = dna.luminance.enumerated().map { i, l in
                CGPoint(x: CGFloat(i) / CGFloat(dna.luminance.count - 1) * w, y: (1 - CGFloat(l)) * h)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w, y: 0))
                }
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                Path { p in
                    p.addLines(points)
                }
                .stroke(Theme.waveGradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                Text("Tone")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct HueBars: View {
    let dna: StyleDNA

    var body: some View {
        GeometryReader { geo in
            let n = StyleDNA.hueSectors
            let maxValue = max(0.001, (0..<n).map(value).max() ?? 0.001)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<n, id: \.self) { s in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(s))
                        .frame(height: max(2, geo.size.height * CGFloat(value(s) / maxValue)))
                }
            }
        }
    }

    private func value(_ s: Int) -> Float {
        dna.isMonochrome ? 0 : dna.hueChroma[s] * (0.3 + dna.huePopulation[s])
    }

    private func color(_ s: Int) -> Color {
        let h = (Float(s) + 0.5) / Float(StyleDNA.hueSectors) * 2 * .pi
        let c = Oklab.toSRGBClamped(SIMD3(0.7, cosf(h) * 0.13, sinf(h) * 0.13))
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

struct Meter: View {
    let label: String
    let value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.waveGradient)
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(value, 0), 1))))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }
}
