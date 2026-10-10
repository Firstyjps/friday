import EventKit
import Foundation

/// นัดหมายวันนี้–พรุ่งนี้จากปฏิทินของ Mac → server ใส่ใน [นัดหมาย] ตอนเริ่มคุย และใน system_info
/// ขอสิทธิ์ปฏิทินครั้งแรก (macOS ถาม 1 ครั้ง) · อัปเดตตอนเปิดแอป ทุก 15 นาที และทุกครั้งที่ปลุก · ไม่ log ชื่อนัด (privacy)
@MainActor
final class CalendarFeed {
    private let store = EKEventStore()
    private var granted = false
    private var lastSent = Date.distantPast
    private var timer: Timer?

    func start() {
        Task {
            do { granted = try await store.requestFullAccessToEvents() }
            catch { Log.write("calendar: ขอสิทธิ์ไม่ได้ \(error.localizedDescription)") }
            Log.write("calendar: สิทธิ์ = \(granted ? "ได้" : "ไม่ได้ (System Settings → Privacy & Security → Calendars → Friday)")")
            if granted { await send() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.send() }
        }
    }

    /// ตอนปลุก — ไม่ถี่กว่า 2 นาที
    func refresh() {
        guard granted, Date().timeIntervalSince(lastSent) > 120 else { return }
        Task { await send() }
    }

    private func send() async {
        guard granted else { return }
        let cal = Calendar.current, now = Date()
        let from = cal.date(byAdding: .hour, value: -1, to: now)!
        let to = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!     // ถึงสิ้นวันพรุ่งนี้
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(20)
        let day = DateFormatter(); day.locale = Locale(identifier: "th_TH"); day.dateFormat = "EEEE d MMM"
        let time = DateFormatter(); time.locale = Locale(identifier: "th_TH"); time.dateFormat = "HH:mm"
        let lines = events.map { e -> String in
            let when = cal.isDateInToday(e.startDate) ? "วันนี้" : cal.isDateInTomorrow(e.startDate) ? "พรุ่งนี้" : day.string(from: e.startDate)
            let span = e.isAllDay ? "ทั้งวัน" : "\(time.string(from: e.startDate))–\(time.string(from: e.endDate))"
            let place = (e.location ?? "").split(separator: "\n").first.map { " @ \($0)" } ?? ""
            return "\(when) \(span) \(e.title ?? "(ไม่มีชื่อ)")\(place)"
        }
        lastSent = Date()
        await ServerAPI.calendar(lines)
        Log.write("calendar: อัปเดตแล้ว (\(lines.count) นัด)")
    }
}
