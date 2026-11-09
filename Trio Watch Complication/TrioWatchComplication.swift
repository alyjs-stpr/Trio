import Foundation
import SwiftUI
import WidgetKit

// LoKey Trio Watch complications are display-only. The paired iPhone sends
// existing, real Trio glucose/IOB/COB values to the Watch app via WatchConnectivity.
// The Watch app writes a compact snapshot into an on-watch App Group container.
// This WidgetKit extension never initiates communication, treatment, or dosing.
private struct LoKeyWatchSnapshot: Codable {
    let glucose: String
    let trend: String
    let delta: String
    let units: String
    let iob: String
    let cob: String
    let glucoseTimestamp: TimeInterval
}

private enum LoKeyWatchSnapshotReader {
    static func read() -> LoKeyWatchSnapshot? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !group.isEmpty,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let data = try? Data(contentsOf: directory.appendingPathComponent("LoKeyTrioWatchComplication.v1.json"))
        else { return nil }
        return try? JSONDecoder().decode(LoKeyWatchSnapshot.self, from: data)
    }
}

// The watch face is never allowed to present old glucose as current.
// 12 minutes allows two normal 5-minute CGM windows plus transfer latency.
struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    fileprivate let snapshot: LoKeyWatchSnapshot?

    var ageMinutes: Int {
        guard let snapshot else { return 0 }
        return max(0, Int(date.timeIntervalSince1970 - snapshot.glucoseTimestamp) / 60)
    }

    var isFresh: Bool {
        guard let snapshot, snapshot.glucoseTimestamp.isFinite else { return false }
        let interval = date.timeIntervalSince1970 - snapshot.glucoseTimestamp
        return interval >= -120 && interval <= 12 * 60
    }

    var reading: String { isFresh ? (snapshot?.glucose ?? "--") : "--" }
    var trend: String { isFresh ? (snapshot?.trend ?? "") : "" }
    var ageLabel: String {
        guard snapshot != nil else { return "No data" }
        return isFresh ? "\(ageMinutes)m" : "STALE \(ageMinutes)m"
    }
}

struct TrioWatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(date: Date(), snapshot: nil)
    }
    func getSnapshot(in _: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        completion(TrioWatchComplicationEntry(date: Date(), snapshot: LoKeyWatchSnapshotReader.read()))
    }
    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let now = Date()
        let snapshot = LoKeyWatchSnapshotReader.read()
        // The future entries reliably transition the face to STALE even when
        // the system postpones another extension launch.
        let entries = [0, 5, 10, 15, 20, 30].map { minutes in
            TrioWatchComplicationEntry(date: now.addingTimeInterval(Double(minutes) * 60), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: TrioWatchComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            TrioAccessoryCircularView(entry: entry)
        case .accessoryRectangular:
            TrioAccessoryRectangularView(entry: entry)
        case .accessoryInline:
            Label {
                Text(entry.isFresh
                     ? "\(entry.reading) \(entry.trend) · \(entry.ageLabel)"
                     : "Trio · \(entry.ageLabel)")
                    .lineLimit(1)
            } icon: {
                Image(systemName: entry.isFresh ? "drop.fill" : "exclamationmark.triangle")
            }
            .widgetBackground(backgroundView: Color.clear)
        #if os(watchOS)
        case .accessoryCorner:
            TrioAccessoryCornerView(entry: entry)
        #endif
        default:
            Text(entry.reading)
                .widgetBackground(backgroundView: Color.clear)
        }
    }
}

#if os(watchOS)
struct TrioAccessoryCornerView: View {
    let entry: TrioWatchComplicationEntry

    var body: some View {
        Text(entry.reading)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(entry.isFresh ? Color.purple : Color.orange)
            .widgetCurvesContent()
            .widgetLabel {
                Text(entry.isFresh ? "\(entry.trend) · \(entry.ageLabel)" : entry.ageLabel)
            }
            .widgetBackground(backgroundView: Color.clear)
    }
}
#endif

struct TrioAccessoryCircularView: View {
    let entry: TrioWatchComplicationEntry

    var body: some View {
        VStack(spacing: 0) {
            Text(entry.reading)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(entry.isFresh ? "\(entry.trend) \(entry.ageLabel)" : "STALE")
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(entry.isFresh ? Color.purple : Color.orange)
        .widgetBackground(backgroundView: Color.clear)
        .accessibilityLabel(entry.isFresh
                            ? "Glucose \(entry.reading), \(entry.trend), \(entry.ageLabel) old"
                            : "Glucose unavailable, \(entry.ageLabel)")
    }
}

struct TrioAccessoryRectangularView: View {
    let entry: TrioWatchComplicationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.reading)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(entry.isFresh ? Color.purple : Color.orange)
                Text(entry.trend)
                    .font(.headline)
                Spacer(minLength: 0)
                Text(entry.ageLabel)
                    .font(.caption2)
                    .foregroundStyle(entry.isFresh ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            if entry.isFresh, let data = entry.snapshot {
                HStack(spacing: 5) {
                    Text("\(data.delta) \(data.units)")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                HStack(spacing: 10) {
                    Text("IOB \(data.iob.isEmpty ? "--" : data.iob) U")
                        .foregroundStyle(.green)
                    Text("COB \(data.cob.isEmpty ? "--" : data.cob) g")
                }
                .font(.caption2)
                .lineLimit(1)
            } else {
                Text("Open Trio for current glucose")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .widgetBackground(backgroundView: Color.clear)
    }
}

@main struct TrioWatchComplication: Widget {
    let kind = "TrioWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("LoKey Trio")
        .description("Glucose, trend and age on your watch face; IOB/COB where space permits.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
        return [.accessoryCorner, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        return [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }
}

extension View {
    func widgetBackground(backgroundView: some View) -> some View {
        if #available(watchOS 10.0, iOSApplicationExtension 17.0, iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}
