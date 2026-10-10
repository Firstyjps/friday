import CoreLocation
import CoreWLAN
import Foundation

/// ตำแหน่งผู้ใช้ (ย่าน/อำเภอ/จังหวัด) + Wi-Fi ที่ต่ออยู่ → ส่งให้ server ใช้ใน [ตำแหน่งตอนนี้] และ system_info
/// 10 ต.ค.: ผู้ใช้ขอหาร้านแถวนี้ Friday ไม่รู้ตำแหน่ง เลยเดาเองว่าอยู่ดำเนินสะดวก
/// ขอสิทธิ์ Location ครั้งแรก (macOS ถาม 1 ครั้ง) · อัปเดตตอนเปิดแอป ทุก 15 นาที และทุกครั้งที่ปลุก · ไม่ log พิกัด (privacy)
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastSent = Date.distantPast
    private var timer: Timer?

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: Log.write("location: ไม่ได้รับสิทธิ์ (System Settings → Privacy & Security → Location Services → Friday)")
        default: manager.requestLocation()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// ขออัปเดต (เช่น ตอนปลุก) — ไม่ถี่กว่า 2 นาที
    func refresh() {
        guard Date().timeIntervalSince(lastSent) > 120 else { return }
        let s = manager.authorizationStatus
        if s == .authorizedAlways || s == .authorized { manager.requestLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            let s = self.manager.authorizationStatus
            Log.write("location: สิทธิ์ = \(s.rawValue)")
            if s == .authorizedAlways || s == .authorized { self.manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in await self.send(loc) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in Log.write("location: หาตำแหน่งไม่ได้ \(error.localizedDescription)") }
    }

    private func send(_ loc: CLLocation) async {
        var place = ""
        if let p = try? await geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "th_TH")).first {
            // ย่าน (ตำบล) · อำเภอ/เขต · จังหวัด — ไม่ส่งเลขที่บ้าน/ถนน
            let parts = [p.subLocality, p.locality, p.administrativeArea].compactMap { $0 }.filter { !$0.isEmpty }
            place = parts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " ")
        }
        let wifi = CWWiFiClient.shared().interface()?.ssid() ?? ""
        lastSent = Date()
        await ServerAPI.location(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                 acc: loc.horizontalAccuracy, place: place, wifi: wifi)
        Log.write("location: อัปเดตแล้ว (\(place.isEmpty ? "ไม่มีชื่อย่าน" : "มีชื่อย่าน"), ±\(Int(loc.horizontalAccuracy)) ม.)")
    }
}
