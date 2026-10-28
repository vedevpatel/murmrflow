import SwiftUI
import Charts

private enum Theme {
    static let accent = Color(red: 0.35, green: 0.31, blue: 0.82)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
}

private enum Tab: String, CaseIterable, Identifiable {
    case home = "Home", history = "History", dictionary = "Dictionary", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

/// Numbers shown on the home screen, derived from the stored dictations.
private struct Metrics {
    static let typingWPM = 80.0

    let entries: [DictationEntry]
    private let cal = Calendar.current

    var totalWords: Int { entries.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { entries.reduce(0) { $0 + $1.seconds } }
    var wpm: Int { totalSeconds > 0 ? Int((Double(totalWords) / (totalSeconds / 60)).rounded()) : 0 }

    var last7Words: Int {
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))!
        return entries.filter { $0.date >= start }.reduce(0) { $0 + $1.words }
    }

    /// Seconds saved compared with typing the same words at `typingWPM`.
    var secondsSaved: Double { max(0, Double(totalWords) / Self.typingWPM * 60 - totalSeconds) }

    var streak: Int {
        let days = Set(entries.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }

    var perDay: [(day: Date, words: Int)] {
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }
        return (0..<14).reversed().map { offset in
            let d = cal.date(byAdding: .day, value: -offset, to: today)!
            return (d, byDay[d]?.reduce(0) { $0 + $1.words } ?? 0)
        }
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return m > 0 ? "\(m)m" : "\(Int(s))s"
    }
}

struct DashboardView: View {
    @ObservedObject var store: StatsStore
    @ObservedObject private var cleanup = CleanupSettings.shared
    @State private var tab: Tab = .home

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch tab {
                case .home: HomeView(metrics: Metrics(entries: store.entries))
                case .history: HistoryView(entries: store.entries, savesText: store.saveText)
                case .dictionary: DictionaryView()
                case .settings: SettingsView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 880, minHeight: 600)
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { store.reload() }
    }

    /// What the selected mode does with a dictation, and where it goes.
    private var modeCaption: Label<Text, Image> {
        if !cleanup.enabled { return Label("Rules on this Mac, pasted as you talk", systemImage: "lock.fill") }
        if !cleanup.hasKey { return Label("Add a Groq key in Settings to use AI cleanup", systemImage: "exclamationmark.triangle") }
        return Label("Rewritten by Groq after you stop talking", systemImage: "cloud")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                Text("Murmrflow").font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 38).padding(.bottom, 20).padding(.horizontal, 12)

            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .font(.system(size: 14, weight: tab == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tab == item ? Theme.accent.opacity(0.14) : .clear))
                        .foregroundStyle(tab == item ? Theme.accent : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Mode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Mode", selection: $cleanup.enabled) {
                    Text("Basic").tag(false)
                    Text("AI cleanup").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                modeCaption.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }
}

private struct HomeView: View {
    let metrics: Metrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome back").font(.system(size: 30, weight: .semibold))
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 14) {
                    StatCard(icon: "text.word.spacing", title: "Total words", value: metrics.totalWords.formatted(), note: "\(metrics.last7Words.formatted()) in last 7 days")
                    StatCard(icon: "speedometer", title: "Speed", value: metrics.wpm == 0 ? "—" : "\(metrics.wpm) wpm", note: "vs. \(Int(Metrics.typingWPM)) wpm typing")
                    StatCard(icon: "flame", title: "Streak", value: "\(metrics.streak) day\(metrics.streak == 1 ? "" : "s")", note: "Days in a row")
                    StatCard(icon: "hourglass", title: "Time saved", value: Metrics.duration(metrics.secondsSaved), note: "Compared with typing")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Words per day").font(.headline)
                    Chart(metrics.perDay, id: \.day) { item in
                        BarMark(x: .value("Day", item.day, unit: .day), y: .value("Words", item.words))
                            .cornerRadius(4)
                            .foregroundStyle(Theme.accent.gradient)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(); AxisValueLabel() } }
                    .frame(height: 220)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
            }
            .padding(.horizontal, 32).padding(.top, 38).padding(.bottom, 28)
        }
    }
}

private struct StatCard: View {
    let icon: String, title: String, value: String, note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
}

private struct HistoryView: View {
    let entries: [DictationEntry]
    let savesText: Bool

    private var groups: [(day: Date, items: [DictationEntry])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0]!.sorted { $0.date > $1.date }) }
    }

    private func title(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("History").font(.system(size: 30, weight: .semibold))
                if !savesText {
                    Label("Transcript text isn't being saved, so only word counts appear. Turn it on in Settings.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if entries.isEmpty {
                    Text("Nothing yet. Hold Right Option and start talking.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title(group.day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider() }
                                HistoryRow(entry: entry)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, 38).padding(.bottom, 28)
        }
    }
}

private struct HistoryRow: View {
    let entry: DictationEntry
    /// Shows the transcript as spoken, before cleanup rewrote it.
    @State private var showsRaw = false

    private var shownText: String? { showsRaw ? entry.rawText : entry.text }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let text = shownText {
                    Text(text).textSelection(.enabled)
                } else {
                    Text("\(entry.words) words").foregroundStyle(.secondary)
                }
                let caption = [entry.appName, showsRaw ? "Original transcript" : nil].compactMap { $0 }.joined(separator: " · ")
                if !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if entry.rawText != nil {
                Button { showsRaw.toggle() } label: {
                    Image(systemName: showsRaw ? "arrow.uturn.forward" : "arrow.uturn.backward")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(showsRaw ? "Redo AI edit" : "Undo AI edit")
            }
            if let text = shownText {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

private struct DictionaryView: View {
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @State private var term = ""
    @State private var heardAs = ""
    @FocusState private var termFocused: Bool

    private func add() {
        dictionary.add(term: term, heardAs: heardAs)
        term = ""
        heardAs = ""
        termFocused = true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Dictionary").font(.system(size: 30, weight: .semibold))
                Text("Names and terms written your way in every dictation. Add how the transcript tends to mishear a word, like \"murmur flow\" for Murmrflow, and it is replaced even with cleanup off. With cleanup on, the model also fixes mishearings it can tell are close.")
                    .font(.callout).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Word or name", text: $term).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                            .focused($termFocused)
                        TextField("Often heard as (optional, comma-separated)", text: $heardAs).textFieldStyle(.roundedBorder)
                        Button("Add", action: add)
                            .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .onSubmit(add)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))

                if dictionary.entries.isEmpty {
                    Text("No words yet.").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(dictionary.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.term).font(.body.weight(.medium)).textSelection(.enabled)
                                if !entry.heardAs.isEmpty {
                                    Text("heard as " + entry.heardAs.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                                }
                                if entry.learned == true {
                                    Text("learned from your edits").font(.caption).foregroundStyle(Theme.accent)
                                }
                                Spacer(minLength: 0)
                                Button { dictionary.remove(entry) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
                }
            }
            .padding(.horizontal, 32).padding(.top, 38).padding(.bottom, 28)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: StatsStore
    @ObservedObject private var cleanup = CleanupSettings.shared
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.system(size: 30, weight: .semibold))

                VStack(alignment: .leading, spacing: 10) {
                    Text("AI cleanup").font(.headline)
                    Text("Switch between Basic and AI cleanup in the sidebar or from the menu bar. In AI cleanup mode, Murmrflow removes filler words and false starts, applies self-corrections like \"Thursday, no, Wednesday\", fixes punctuation and formats lists, then pastes the result once you stop talking. The transcript and the name of the app you're typing into are sent to Groq; audio never leaves this Mac. If Groq is slow or unreachable, the transcript is tidied by the Basic rules instead.")
                        .font(.callout).foregroundStyle(.secondary)
                    SecureField("Groq API key", text: $cleanup.apiKey).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    HStack(spacing: 8) {
                        TextField("Model", text: $cleanup.model).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        if cleanup.model != CleanupSettings.defaultModel {
                            Button("Reset") { cleanup.model = CleanupSettings.defaultModel }
                        }
                    }
                    Text("If this model is rate-limited, Murmrflow switches to \(CleanupSettings.fallbackModels.filter { $0 != cleanup.model }.joined(separator: ", then ")).")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Get a key at console.groq.com", destination: URL(string: "https://console.groq.com/keys")!).font(.callout)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Learn from my edits", isOn: $store.learnFromEdits).font(.headline)
                    Text("For two minutes after a paste, Murmrflow rereads the text it pasted to see what you fixed. A misheard name or term you correct is added to your Dictionary; small spelling, punctuation and wording fixes are saved on this Mac as short snippets and shown to the cleanup model next time. Only changes made while you were typing in that app count, so edits by collaborators or the app itself are skipped; which keys you press is never recorded. Rewrites, new text you type and pasted lists are ignored.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Save transcript text", isOn: $store.saveText).font(.headline)
                    Text("Keeps what you dictated in a local database so you can browse and copy it in History, and so it can be used later for things like custom vocabulary or rewrite features. Off by default; word counts and timing are always kept. The database stays on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Your data").font(.headline)
                    Text(store.directory.path).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }
                        Button("Delete all history…", role: .destructive) { confirmDelete = true }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
            }
            .padding(.horizontal, 32).padding(.top, 38).padding(.bottom, 28)
        }
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmDelete) {
            Button("Delete everything", role: .destructive) { store.deleteAll() }
        } message: {
            Text("This removes every stored dictation, including word counts. It can't be undone.")
        }
    }
}
