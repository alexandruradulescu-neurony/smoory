import SwiftUI
import WidgetKit

struct SmooryWidget: Widget {
    let kind: String = "SmooryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BriefTimelineProvider()) { entry in
            SmooryWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Smoory")
        .description("Today's focus and upcoming reminders.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct SmooryWidgetEntryView: View {
    let entry: BriefEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}
