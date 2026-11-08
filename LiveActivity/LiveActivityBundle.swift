import Foundation
import SwiftUI
import WidgetKit

@main struct LiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LiveActivity()
        LoKeyTrioMediumWidget()
    }
}

// Home Screen widget data comes from the main app's existing LiveActivityManager.
// This intentionally does not access, calculate, or command insulin delivery.
private enum LoKeyWidgetStorage {
    static let kind = "LoKeyTrioMedium"
    static let snapshotKey = "lokeyTrio.medium.contentState.v1"
    static let iobHistoryKey = "lokeyTrio.medium.iobHistory.v1"
    static let hasIOBKey = "lokeyTrio.medium.hasIOB.v1"
    static let hasCOBKey = "lokeyTrio.medium.hasCOB.v1"
    static let forecastMinKey = "lokeyTrio.medium.forecastMin.v1"
    static let forecastMaxKey = "lokeyTrio.medium.forecastMax.v1"
    static let forecastDateKey = "lokeyTrio.medium.forecastDate.v1"

    static var defaults: UserDefaults? {
        guard let suite = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !suite.isEmpty
        else { return nil }
        return UserDefaults(suiteName: suite)
    }
}

private struct LoKeyIOBSample {
    let timestamp: TimeInterval
    let units: Double
}

private struct LoKeyMediumEntry: TimelineEntry {
    let date: Date
    let glucose: LiveActivityAttributes.ContentState?
    let iobHistory: [LoKeyIOBSample]
    let hasIOB: Bool
    let hasCOB: Bool
    let forecastMin: [Int]
    let forecastMax: [Int]
    let forecastDate: Date?

    var latestGlucoseDate: Date? {
        glucose?.detailedViewState.chart.first?.date
    }

    var isStale: Bool {
        guard let date = latestGlucoseDate else { return true }
        return self.date.timeIntervalSince(date) > 12 * 60 || date.timeIntervalSince(self.date) > 120
    }
}

private struct LoKeyMediumProvider: TimelineProvider {
    func placeholder(in _: Context) -> LoKeyMediumEntry { readEntry(at: Date()) }
    func getSnapshot(in _: Context, completion: @escaping (LoKeyMediumEntry) -> Void) {
        completion(readEntry(at: Date()))
    }
    func getTimeline(in _: Context, completion: @escaping (Timeline<LoKeyMediumEntry>) -> Void) {
        let now = Date()
        // Re-evaluate staleness even if iOS delays a push-based widget refresh.
        let entries = [readEntry(at: now), readEntry(at: now.addingTimeInterval(5 * 60))]
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(10 * 60))))
    }

    private func readEntry(at date: Date) -> LoKeyMediumEntry {
        let defaults = LoKeyWidgetStorage.defaults
        let state: LiveActivityAttributes.ContentState?
        if let blob = defaults?.data(forKey: LoKeyWidgetStorage.snapshotKey) {
            state = try? JSONDecoder().decode(LiveActivityAttributes.ContentState.self, from: blob)
        } else {
            state = nil
        }

        let iobHistory = (defaults?.array(forKey: LoKeyWidgetStorage.iobHistoryKey) as? [[String: Double]] ?? [])
            .compactMap { value -> LoKeyIOBSample? in
                guard let time = value["time"], let units = value["units"],
                      time.isFinite, units.isFinite
                else { return nil }
                return LoKeyIOBSample(timestamp: time, units: units)
            }
            .sorted { $0.timestamp < $1.timestamp }

        let forecastDateValue = defaults?.double(forKey: LoKeyWidgetStorage.forecastDateKey) ?? 0
        return LoKeyMediumEntry(
            date: date,
            glucose: state,
            iobHistory: iobHistory,
            hasIOB: defaults?.bool(forKey: LoKeyWidgetStorage.hasIOBKey) ?? false,
            hasCOB: defaults?.bool(forKey: LoKeyWidgetStorage.hasCOBKey) ?? false,
            forecastMin: defaults?.array(forKey: LoKeyWidgetStorage.forecastMinKey) as? [Int] ?? [],
            forecastMax: defaults?.array(forKey: LoKeyWidgetStorage.forecastMaxKey) as? [Int] ?? [],
            forecastDate: forecastDateValue > 0 ? Date(timeIntervalSince1970: forecastDateValue) : nil
        )
    }
}

private struct LoKeyTrioMediumWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LoKeyWidgetStorage.kind, provider: LoKeyMediumProvider()) { entry in
            LoKeyMediumView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.075, green: 0.09, blue: 0.16)
                }
        }
        .configurationDisplayName("LoKey Trio")
        .description("Glucose history, prediction range and insulin on board at a glance.")
        .supportedFamilies([.systemMedium])
    }
}

private struct LoKeyMediumView: View {
    let entry: LoKeyMediumEntry

    private let purple = Color(red: 0.75, green: 0.60, blue: 1.0)
    private let green = Color(red: 0.40, green: 0.85, blue: 0.58)
    private let secondary = Color(red: 0.70, green: 0.74, blue: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("LoKey Trio").font(.caption2.bold()).foregroundStyle(purple)
                Spacer()
                if entry.isStale {
                    Text("STALE").foregroundStyle(.orange)
                        .font(.system(size: 10, weight: .bold))
                }
                if let glucoseDate = entry.latestGlucoseDate {
                    Text(glucoseDate, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                } else {
                    Text("Waiting for glucose").font(.system(size: 10)).foregroundStyle(secondary)
                }
            }

            HStack(alignment: .center, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(entry.glucose?.bg ?? "--")
                            .font(.system(size: 37, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)
                            .foregroundStyle(entry.isStale ? .orange : purple)
                        if let direction = entry.glucose?.direction, !direction.isEmpty {
                            Text(direction)
                                .font(.title3.bold())
                                .foregroundStyle(entry.isStale ? .orange : green)
                        }
                    }
                    Text(entry.glucose?.unit ?? "mg/dL")
                        .font(.system(size: 10))
                        .foregroundStyle(secondary)
                    HStack(spacing: 7) {
                        Text("IOB")
                            .foregroundStyle(green)
                        Text(entry.hasIOB ? formattedUnits(entry.glucose?.detailedViewState.iob) + " U" : "--")
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 7) {
                        Text("COB").foregroundStyle(secondary)
                        Text(entry.hasCOB ? formattedCarbs(entry.glucose?.detailedViewState.cob) + " g" : "--")
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .frame(width: 125, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("GLUCOSE  /  IOB")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(secondary)
                    LoKeyDualChart(entry: entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 7) {
                        Circle().fill(purple).frame(width: 5, height: 5)
                        Text("BG").foregroundStyle(secondary)
                        Circle().fill(green).frame(width: 5, height: 5)
                        Text("IOB").foregroundStyle(secondary)
                        Spacer(minLength: 0)
                        Text("Now").foregroundStyle(secondary)
                    }
                    .font(.system(size: 8))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .widgetURL(URL(string: "Trio://"))
    }

    private func formattedUnits(_ value: Decimal?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", NSDecimalNumber(decimal: value).doubleValue)
    }

    private func formattedCarbs(_ value: Decimal?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f", NSDecimalNumber(decimal: value).doubleValue)
    }
}

// Purple: measured glucose history and, when available, the actual Oref
// min/max prediction range. Green: a separately scaled history of *IOB*,
// not pump delivery history. Nothing is simulated or interpolated as a dose.
private struct LoKeyDualChart: View {
    let entry: LoKeyMediumEntry

    var body: some View {
        Canvas { context, size in
            let now = entry.date.timeIntervalSince1970
            let historyStart = now - 60 * 60
            let horizonEnd = now + 2 * 60 * 60
            let history = (entry.glucose?.detailedViewState.chart ?? [])
                .map { (time: $0.date.timeIntervalSince1970, bg: NSDecimalNumber(decimal: $0.value).doubleValue) }
                .filter { $0.time >= historyStart && $0.time <= now + 60 }
                .sorted { $0.time < $1.time }

            let isPredictionFresh = entry.forecastDate.map {
                abs(now - $0.timeIntervalSince1970) < 20 * 60
            } ?? false
            var ranges: [(time: Double, low: Double, high: Double)] = []
            if isPredictionFresh, let forecastTime = entry.forecastDate?.timeIntervalSince1970 {
                for idx in 0 ..< min(24, entry.forecastMin.count, entry.forecastMax.count) {
                    let time = forecastTime + Double(idx + 1) * 5 * 60
                    guard time >= now, time <= horizonEnd else { continue }
                    ranges.append((
                        time: time,
                        low: Double(entry.forecastMin[idx]),
                        high: Double(entry.forecastMax[idx])
                    ))
                }
            }
            let allBG = history.map(\.bg) + ranges.flatMap { [$0.low, $0.high] }
            let lowBG = max(40.0, (allBG.min() ?? 70.0) - 20)
            let highBG = max(lowBG + 40, (allBG.max() ?? 180.0) + 20)
            let glucoseHeight = size.height * 0.68
            // Before Trio has a real Oref prediction, use the entire graph
            // for measured history rather than showing a mostly empty plot.
            let displayEnd = ranges.isEmpty ? now : horizonEnd
            func x(_ timestamp: Double) -> CGFloat {
                CGFloat((timestamp - historyStart) / (displayEnd - historyStart)) * size.width
            }
            func y(_ bg: Double) -> CGFloat {
                CGFloat((highBG - bg) / (highBG - lowBG)) * glucoseHeight
            }

            let nowX = x(now)
            var division = Path()
            division.move(to: CGPoint(x: nowX, y: 0))
            division.addLine(to: CGPoint(x: nowX, y: size.height))
            context.stroke(division, with: .color(.white.opacity(0.24)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            if ranges.count > 1 {
                var rangePath = Path()
                for (idx, range) in ranges.enumerated() {
                    let pt = CGPoint(x: x(range.time), y: y(range.high))
                    if idx == 0 { rangePath.move(to: pt) } else { rangePath.addLine(to: pt) }
                }
                for range in ranges.reversed() {
                    rangePath.addLine(to: CGPoint(x: x(range.time), y: y(range.low)))
                }
                rangePath.closeSubpath()
                context.fill(rangePath, with: .color(Color(red: 0.75, green: 0.60, blue: 1.0).opacity(0.22)))
            }

            if !history.isEmpty {
                var glucoseLine = Path()
                for (idx, reading) in history.enumerated() {
                    let point = CGPoint(x: x(reading.time), y: y(reading.bg))
                    if idx == 0 { glucoseLine.move(to: point) } else { glucoseLine.addLine(to: point) }
                }
                context.stroke(glucoseLine,
                               with: .color(Color(red: 0.75, green: 0.60, blue: 1.0)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            let samples = entry.iobHistory.filter {
                $0.timestamp >= historyStart && $0.timestamp <= now + 60
            }
            if !samples.isEmpty {
                let maxIOB = max(1, samples.map(\.units).max() ?? 1)
                var insulinLine = Path()
                for (idx, sample) in samples.enumerated() {
                    let fraction = max(0, min(1, sample.units / maxIOB))
                    let point = CGPoint(
                        x: x(sample.timestamp),
                        y: glucoseHeight + 6 + (1 - fraction) * (size.height - glucoseHeight - 8)
                    )
                    if idx == 0 { insulinLine.move(to: point) } else { insulinLine.addLine(to: point) }
                }
                context.stroke(insulinLine,
                               with: .color(Color(red: 0.40, green: 0.85, blue: 0.58)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityLabel("Historical glucose in purple, forecast range in purple, insulin on board history in green")
    }
}
