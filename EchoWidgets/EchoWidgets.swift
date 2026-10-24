import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct EchoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StyleCardsWidget()
        ExportLiveActivity()
    }
}

private let echoBlue = Color(red: 0, green: 0.478, blue: 1)
private let echoViolet = Color(red: 0.686, green: 0.322, blue: 0.871)

// MARK: - StandBy / Home Screen style cards

struct StyleCardEntry: TimelineEntry {
    let date: Date
    let card: WidgetCard?
    let image: UIImage?
}

struct StyleCardsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StyleCardEntry {
        StyleCardEntry(date: .now, card: nil, image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (StyleCardEntry) -> Void) {
        completion(entries(count: 1).first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StyleCardEntry>) -> Void) {
        let list = entries(count: 12)
        completion(Timeline(entries: list.isEmpty ? [placeholder(in: context)] : list, policy: .atEnd))
    }

    /// One card every 20 minutes, rotating through the library.
    private func entries(count: Int) -> [StyleCardEntry] {
        guard let index = EchoShared.cardsIndex,
              let data = try? Data(contentsOf: index),
              let cards = try? JSONDecoder().decode([WidgetCard].self, from: data),
              !cards.isEmpty
        else { return [] }
        let start = Int(Date().timeIntervalSince1970 / 1200) % cards.count
        return (0..<count).map { i in
            let card = cards[(start + i) % cards.count]
            let image = EchoShared.cardImage(card.id).flatMap { UIImage(contentsOfFile: $0.path) }
            return StyleCardEntry(date: Date().addingTimeInterval(Double(i) * 1200), card: card, image: image)
        }
    }
}

struct StyleCardsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EchoStyleCards", provider: StyleCardsProvider()) { entry in
            StyleCardView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(EchoShared.openURL(style: entry.card?.id))
        }
        .configurationDisplayName("Style Cards")
        .description("Your looks as ambient art. Shines in StandBy while charging.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct StyleCardView: View {
    let entry: StyleCardEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = entry.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let card = entry.card {
                LinearGradient(
                    colors: card.swatch.map { Color(red: $0[0], green: $0[1], blue: $0[2]) },
                    startPoint: .bottomLeading, endPoint: .topTrailing
                )
            } else {
                LinearGradient(colors: [.black, echoBlue.opacity(0.6), echoViolet.opacity(0.7)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.card?.name ?? "Echo")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(entry.card == nil ? "Open Echo to sync your styles" : "Tap to shoot with this look")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(14)
        }
    }
}

// MARK: - Export Live Activity

struct ExportLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExportActivityAttributes.self) { context in
            ExportLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Thumbnail(data: context.attributes.thumbnail, size: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state.progress))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.attributes.kind) · \(context.attributes.styleName)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        ProgressView(value: context.state.progress)
                            .tint(echoBlue)
                        Button(intent: CancelExportIntent()) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .tint(.white.opacity(0.25))
                        .accessibilityLabel("Cancel export")
                    }
                }
            } compactLeading: {
                Thumbnail(data: context.attributes.thumbnail, size: 22)
            } compactTrailing: {
                Text(percent(context.state.progress))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(echoBlue)
            } minimal: {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
                    .tint(echoBlue)
            }
            .widgetURL(EchoShared.openURL(style: nil))
            .keylineTint(echoBlue)
        }
    }
}

struct ExportLockScreenView: View {
    let context: ActivityViewContext<ExportActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(data: context.attributes.thumbnail, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(context.attributes.kind) · \(context.attributes.styleName)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Spacer()
                    Text(percent(context.state.progress))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                ProgressView(value: context.state.progress)
                    .tint(LinearGradient(colors: [echoBlue, echoViolet], startPoint: .leading, endPoint: .trailing))
                Text(context.state.detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Button(intent: CancelExportIntent()) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.15), in: Circle())
            .accessibilityLabel("Cancel export")
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

private struct Thumbnail: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [echoBlue, echoViolet], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Text("e").font(.system(size: size * 0.5, weight: .semibold, design: .rounded)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private func percent(_ value: Double) -> String {
    "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
}
