import SwiftUI

enum Theme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let surface = Color(red: 0.105, green: 0.105, blue: 0.118)
    static let surfaceRaised = Color(red: 0.16, green: 0.16, blue: 0.176)
    static let stroke = Color.white.opacity(0.07)
    static let accent = Color(red: 0.04, green: 0.48, blue: 1.0)
    static let accentDeep = Color(red: 0.02, green: 0.36, blue: 0.82)
    static let violet = Color(red: 0.66, green: 0.36, blue: 1.0)
    static let secondaryText = Color.white.opacity(0.55)

    static let waveGradient = LinearGradient(
        colors: [Color(red: 0.12, green: 0.42, blue: 1.0), Color(red: 0.45, green: 0.32, blue: 1.0), violet],
        startPoint: .leading, endPoint: .trailing
    )
}

/// Large pill button used for primary actions.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Subtle press feedback for cards and chips.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Selectable capsule used for components and regions.
struct Chip: View {
    let title: String
    var systemImage: String?
    let isOn: Bool
    var tint: Color = Theme.accent
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView().controlSize(.mini).tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn ? .white : .white.opacity(0.62))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isOn ? tint : Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(isOn ? 0.12 : 0.04), lineWidth: 1)
            )
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Small floating confirmation ("Saved to Photos").
struct Toast: View {
    let text: String
    var systemImage = "checkmark.circle.fill"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}

extension View {
    func toast(_ text: Binding<String?>) -> some View {
        overlay(alignment: .top) {
            if let value = text.wrappedValue {
                Toast(text: value)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: value) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation(.easeInOut) { text.wrappedValue = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: text.wrappedValue)
    }
}
