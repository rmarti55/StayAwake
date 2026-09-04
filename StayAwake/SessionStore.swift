import AppKit
import Combine
import Foundation

struct TimelineSegment: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let isAwake: Bool

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}

final class SessionStore: ObservableObject {
    @Published private(set) var now = Date()
    @Published private(set) var bootTime = Date()
    @Published private(set) var lastWakeTime = Date()
    @Published private(set) var timelineSegments: [TimelineSegment] = []

    private var events: [PowerEvent] = []
    private var isSeeding = false
    private static let powerLogQueue = DispatchQueue(label: "com.stayawake.powerlog", qos: .utility)
    private var liveUpdateTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var powerOffObserver: NSObjectProtocol?

    private static let timelineWindow: TimeInterval = 86_400
    private static let dedupeTolerance: TimeInterval = 2

    init() {
        bootTime = Self.readBootTime()
        loadPersistedEvents()
        recomputeDerivedState()
        registerWorkspaceObservers()
        loadPowerHistoryAsync()
    }

    deinit {
        stopLiveUpdates()
        removeWorkspaceObservers()
    }

    var upSinceReboot: TimeInterval {
        now.timeIntervalSince(bootTime)
    }

    var awakeSinceSleep: TimeInterval {
        now.timeIntervalSince(lastWakeTime)
    }

    func startLiveUpdates() {
        now = Date()
        recomputeDerivedState()
        retrySeedIfNeeded()

        guard liveUpdateTimer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            self.recomputeDerivedState()
        }
        RunLoop.main.add(timer, forMode: .common)
        liveUpdateTimer = timer
    }

    func stopLiveUpdates() {
        liveUpdateTimer?.invalidate()
        liveUpdateTimer = nil
    }

    private func retrySeedIfNeeded() {
        guard events.isEmpty else { return }
        seedFromPowerLogAsync()
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordLiveEvent(kind: .sleep)
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordLiveEvent(kind: .wake)
        }

        powerOffObserver = center.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordLiveEvent(kind: .shutdown)
        }
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
        }
        if let powerOffObserver {
            center.removeObserver(powerOffObserver)
        }
    }

    private func recordLiveEvent(kind: PowerEventKind) {
        let event = PowerEvent(date: Date(), kind: kind)
        appendEvents([event])
        recomputeDerivedState()
        persistEvents()
    }

    private func loadPowerHistoryAsync() {
        guard !isSeeding else { return }
        isSeeding = true

        let bootTime = bootTime
        Self.powerLogQueue.async { [weak self] in
            let cutoff = max(bootTime, Date().addingTimeInterval(-Self.timelineWindow))
            let seeded = PowerLogParser.fetchEvents(since: cutoff)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isSeeding = false
                self.appendEvents(seeded)
                self.recomputeDerivedState()
                self.persistEvents()
                print("StayAwake: seeded \(seeded.count) power events from pmset")
            }
        }
    }

    private func seedFromPowerLogAsync() {
        loadPowerHistoryAsync()
    }

    private func appendEvents(_ newEvents: [PowerEvent]) {
        for event in newEvents {
            guard event.date >= bootTime else { continue }

            let isDuplicate = events.contains { existing in
                existing.kind == event.kind &&
                    abs(existing.date.timeIntervalSince(event.date)) <= Self.dedupeTolerance
            }
            guard !isDuplicate else { continue }

            events.append(event)
        }

        events.sort { $0.date < $1.date }
        pruneEvents()
    }

    private func pruneEvents() {
        let keepSince = max(bootTime, Date().addingTimeInterval(-Self.timelineWindow))
        events.removeAll { $0.date < keepSince }
    }

    private func recomputeDerivedState() {
        lastWakeTime = computeLastWakeTime()
        timelineSegments = buildTimelineSegments(at: now)
    }

    private func computeLastWakeTime() -> Date {
        var lastWake = bootTime

        for event in events where event.date >= bootTime {
            switch event.kind {
            case .wake:
                lastWake = event.date
            case .sleep, .darkWake, .shutdown, .restart:
                break
            }
        }

        return lastWake
    }

    private func buildTimelineSegments(at referenceDate: Date) -> [TimelineSegment] {
        let windowStart = referenceDate.addingTimeInterval(-Self.timelineWindow)
        let effectiveStart = max(windowStart, bootTime)

        var stateIsAwake = inferAwakeState(at: effectiveStart)
        var cursor = effectiveStart
        var segments: [TimelineSegment] = []

        let windowEvents = events.filter { $0.date >= effectiveStart && $0.date <= referenceDate }

        for event in windowEvents {
            guard cursor < event.date else { continue }

            segments.append(TimelineSegment(start: cursor, end: event.date, isAwake: stateIsAwake))
            cursor = event.date
            stateIsAwake = nextAwakeState(current: stateIsAwake, event: event)
        }

        if cursor < referenceDate {
            segments.append(TimelineSegment(start: cursor, end: referenceDate, isAwake: stateIsAwake))
        }

        return segments.filter { $0.duration > 0 }
    }

    private func inferAwakeState(at date: Date) -> Bool {
        var isAwake = true

        for event in events where event.date <= date {
            isAwake = nextAwakeState(current: isAwake, event: event)
        }

        return isAwake
    }

    private func nextAwakeState(current: Bool, event: PowerEvent) -> Bool {
        switch event.kind {
        case .sleep, .darkWake, .shutdown:
            return false
        case .wake, .restart:
            return true
        }
    }

    private func loadPersistedEvents() {
        guard
            let url = Self.persistenceURL,
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([PowerEvent].self, from: data)
        else {
            return
        }

        events = decoded.filter { $0.date >= bootTime }
    }

    private func persistEvents() {
        guard let url = Self.persistenceURL else { return }

        if events.isEmpty, Self.persistenceHasEvents() {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(events)
            try data.write(to: url, options: .atomic)
        } catch {
            print("StayAwake: Failed to persist session events: \(error)")
        }
    }

    private static func persistenceHasEvents() -> Bool {
        guard
            let url = persistenceURL,
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([PowerEvent].self, from: data)
        else {
            return false
        }

        return !decoded.isEmpty
    }

    private static var persistenceURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("StayAwake/events.json")
    }

    private static func readBootTime() -> Date {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else {
            return Date()
        }
        return Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec))
    }
}
