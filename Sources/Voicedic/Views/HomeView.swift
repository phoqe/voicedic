import Charts
import SwiftUI

struct HomeView: View {
    static let windowID = "home"

    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.largeTitle.weight(.semibold))
                    Text(model.statusText).foregroundStyle(.secondary)
                }
                StatTiles(stats: model.stats)
                ActivityChart(stats: model.stats)
                RecentDictations(model: model)
            }
            .padding(28)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var greeting: String {
        guard let firstName = NSFullUserName().split(separator: " ").first else { return "Welcome back" }
        return "Welcome back, \(firstName)"
    }
}

// MARK: - Stats

private struct StatTiles: View {
    let stats: StatsStore

    var body: some View {
        let streak = stats.currentStreak

        HStack(spacing: 12) {
            StatTile(
                title: "Streak", symbol: "flame.fill", tint: streak > 0 ? .orange : .secondary,
                value: figure(streak.formatted(), unit: streak == 1 ? "day" : "days"),
                detail: streakDetail(streak))
            StatTile(
                title: "Words", symbol: "text.word.spacing",
                value: figure(Self.compact(stats.totalWords)),
                detail: "\(stats.words(on: .now).formatted()) today")
            StatTile(
                title: "Pace", symbol: "speedometer",
                value: figure(stats.wordsPerMinute.map { $0.formatted() } ?? "–", unit: "wpm"),
                detail: "Average speed")
            StatTile(
                title: "Time saved", symbol: "hourglass",
                value: figure(Self.duration(minutes: stats.minutesSaved)),
                detail: "vs. typing at \(Int(StatsStore.typingWordsPerMinute)) wpm")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func streakDetail(_ streak: Int) -> String {
        if streak > 0, !stats.dictatedToday { return "Dictate today to keep it" }
        let longest = stats.longestStreak
        if longest == 0 { return "Dictate to start one" }
        return "Longest: \(longest) \(longest == 1 ? "day" : "days")"
    }

    private func figure(_ number: String, unit: String? = nil) -> Text {
        guard let unit else { return Text(number) }
        return Text("\(number) \(Text(unit).font(.title3).foregroundStyle(.secondary))")
    }

    private static func compact(_ count: Int) -> String {
        count >= 100_000 ? count.formatted(.number.notation(.compactName)) : count.formatted()
    }

    private static func duration(minutes: Double) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

private struct StatTile: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary
    let value: Text
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            value
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Activity

private struct ActivityChart: View {
    let stats: StatsStore
    @State private var hoveredDate: Date?

    var body: some View {
        let days = stats.recentDays(30)
        let hovered = hoveredDate.flatMap { date in
            days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 30 days").font(.headline)
                Spacer()
                Group {
                    if let hovered {
                        Text("\(hovered.date.formatted(.dateTime.weekday().month().day())): \(wordCount(hovered.words))")
                    } else {
                        Text(wordCount(days.reduce(0) { $0 + $1.words }))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Chart(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.words), width: .ratio(0.7))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous))
                    .foregroundStyle(Color.accentColor)
                    .opacity(hovered == nil || hovered?.id == day.id ? 1 : 0.4)
            }
            .chartXAxis {
                // Weekly labels ending today, at midday so they sit under their bars.
                AxisMarks(values: weeklyLabelDates(days)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), anchor: .top)
                }
            }
            // Room for today's label, which is wider than its bar.
            .chartXScale(range: .plotDimension(endPadding: 14))
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let words = value.as(Int.self) {
                            Text(words, format: .number.notation(.compactName))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(.rect)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                hoveredDate = proxy.value(atX: location.x - geometry[plotFrame].origin.x, as: Date.self)
                            case .ended:
                                hoveredDate = nil
                            }
                        }
                }
            }
            .frame(height: 150)
        }
        .padding(16)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }

    private func weeklyLabelDates(_ days: [DayTotal]) -> [Date] {
        days.reversed().enumerated()
            .filter { $0.offset % 7 == 0 }
            .map { Calendar.current.date(byAdding: .hour, value: 12, to: $0.element.date)! }
    }

    private func wordCount(_ words: Int) -> String {
        "\(words.formatted()) \(words == 1 ? "word" : "words")"
    }
}

// MARK: - Recent dictations

private struct RecentDictations: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent dictations").font(.headline)

            if model.history.entries.isEmpty {
                Text(
                    model.prefs.keepHistory
                        ? "Nothing yet. Hold \(model.prefs.shortcut.displayName) and start talking."
                        : "History is off. Turn it on in Settings to see your dictations here."
                )
                .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groups, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Self.title(for: group.day))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().padding(.leading, 14) }
                                    DictationRow(entry: entry, copy: model.copyToClipboard)
                                }
                            }
                            .background(.fill.quaternary, in: .rect(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    /// History is newest first, so each day's entries are already together.
    private var groups: [(day: Date, entries: [HistoryEntry])] {
        var groups: [(day: Date, entries: [HistoryEntry])] = []
        for entry in model.history.entries {
            let day = Calendar.current.startOfDay(for: entry.date)
            if groups.last?.day == day {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups
    }

    private static func title(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct DictationRow: View {
    let entry: HistoryEntry
    let copy: (String) -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).textSelection(.enabled)
                if let app = entry.appName {
                    Text(app).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copy(entry.text)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy(entry.text) }
            Button("Copy Raw Transcript") { copy(entry.raw) }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
