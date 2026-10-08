import Combine
import Foundation

@MainActor
final class ResetReminderController: ObservableObject {
    @Published private(set) var record: ResetReminderRecord?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    var onPresent: ((OfficialResetAnnouncement) -> Void)?
    private let defaults: UserDefaults
    private let backend: any ResetReminderBackend
    private let key = "officialResetAppointmentV1"
    init(defaults: UserDefaults = .standard, backend: any ResetReminderBackend = SystemResetReminderBackend()) {
        self.defaults = defaults; self.backend = backend
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(ResetReminderRecord.self, from: data),
           OfficialResetAnnouncement.validSource(saved.plan.event.sourceURL) { record = saved }
    }
    func present(_ event: OfficialResetAnnouncement) { error = nil; onPresent?(event) }
    func save(_ plan: ResetReminderPlan, now: Date = .now) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let validated = try ResetReminderPlan.make(event: plan.event, selectedDate: plan.selectedDate,
                lead: plan.lead, destination: plan.destination, now: now)
            if record?.plan == validated { return }
            let external = try await backend.put(validated, replacing: record)
            record = ResetReminderRecord(plan: validated, externalID: external)
            persist()
        } catch { self.error = error.localizedDescription }
    }
    func cancel() async {
        guard !busy, let existing = record else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await backend.cancel(existing); record = nil; defaults.removeObject(forKey: key) }
        catch { self.error = error.localizedDescription }
    }
    private func persist() { if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key) } }
    func needsUpdate(for event: OfficialResetAnnouncement, now: Date = .now) -> Bool {
        guard let record, event.phase == .scheduled,
              event.latestExpectedAt.map({ $0 > now }) == true else { return false }
        return event.reminderDates != record.plan.event.reminderDates
    }
}
