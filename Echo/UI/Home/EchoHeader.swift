import SwiftUI

/// The "e" mark with its signature wave, gently animated.
struct EchoWave: View {
    var strands = 22
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, time: t)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let w = size.width, h = size.height
        var glow = context
        glow.addFilter(.blur(radius: 14))
        for k in 0..<strands {
            let f = Double(k) / Double(max(strands - 1, 1))
            var path = Path()
            let steps = 80
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let env = pow(x, 0.9)
                let amp = h * (0.16 + 0.22 * env) * (0.55 + 0.9 * f)
                let phase = time * 0.55 + f * 0.9
                let y = h * 0.62
                    - amp * sin(x * .pi * 1.55 + phase * 0.6)
                    - x * h * 0.12
                    + (f - 0.5) * h * 0.22 * env
                let p = CGPoint(x: x * w, y: y)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            let centrality = 1 - abs(f - 0.5) * 1.5
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.15, green: 0.45, blue: 1).opacity(0), location: 0),
                    .init(color: Color(red: 0.15, green: 0.45, blue: 1).opacity(0.95 * centrality), location: 0.18),
                    .init(color: Color(red: 0.48, green: 0.34, blue: 1).opacity(0.8 * centrality), location: 0.6),
                    .init(color: Color(red: 0.72, green: 0.38, blue: 1).opacity(0.6 * centrality), location: 0.92),
                    .init(color: Color(red: 0.72, green: 0.38, blue: 1).opacity(0), location: 1),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: 0)
            )
            context.stroke(path, with: shading, lineWidth: 1.1)
            if k % 4 == 0 { glow.stroke(path, with: shading, lineWidth: 5) }
        }
    }
}

struct EchoHeader<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack(alignment: .topLeading) {
            EchoWave()
                .frame(height: 190)
                .padding(.leading, 70)
                .offset(y: 4)
            Text("e")
                .font(.system(size: 104, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.offWhite)
                .shadow(color: Theme.accent.opacity(0.35), radius: 24)
                .offset(x: -2, y: 44)
                .accessibilityLabel("Echo")
            HStack {
                Spacer()
                trailing
            }
            .padding(.top, 12)
        }
        .frame(height: 200)
    }
}
