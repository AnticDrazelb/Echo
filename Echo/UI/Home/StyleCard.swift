import SwiftUI

/// Gradient chip summarising a look: shadow → midtone → highlight colors.
struct DNASwatch: View {
    let dna: StyleDNA

    var body: some View {
        LinearGradient(colors: colors, startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    var colors: [Color] {
        (0..<3).map { z in
            let lab = SIMD3<Float>(dna.zoneLuma[z], dna.zoneTintA[z] * 2.2, dna.zoneTintB[z] * 2.2)
            let c = Oklab.toSRGBClamped(lab)
            return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        }
    }
}

struct StyleCard: View {
    @Environment(StyleLibrary.self) private var library
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .aspectRatio(0.78, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottomTrailing) { badge.padding(10) }

            Text(style.name)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 14)
            HStack(spacing: 5) {
                Text(style.recipe != nil ? "Blend" : "Long Press")
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 15))
            .foregroundStyle(Theme.secondaryText)
            .padding(.top, 4)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.stroke))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    @ViewBuilder
    private var preview: some View {
        if let image = library.preview(for: style) {
            Color.clear.overlay(
                Image(uiImage: image).resizable().scaledToFill()
            )
            .transition(.opacity)
        } else {
            ZStack {
                DNASwatch(dna: style.dna).opacity(0.5)
                ProgressView().tint(.white.opacity(0.6))
            }
        }
    }

    private var badge: some View {
        Group {
            if let reference = library.reference(for: style) {
                Image(uiImage: reference).resizable().scaledToFill()
            } else {
                DNASwatch(dna: style.dna)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
