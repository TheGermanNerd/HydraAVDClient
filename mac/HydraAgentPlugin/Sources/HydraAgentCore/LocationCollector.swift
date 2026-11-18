import CoreLocation
import Foundation

final class LocationCollector: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutWork: DispatchWorkItem?

    func requestFix(timeout seconds: TimeInterval = 8) async -> CLLocation? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.begin(continuation, seconds: seconds)
            }
        }
    }

    private func begin(_ continuation: CheckedContinuation<CLLocation?, Never>, seconds: TimeInterval) {
        if self.continuation != nil {
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer

        let work = DispatchWorkItem { [weak self] in
            self?.finish(nil)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)

        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            finish(nil)
        }
    }

    private func finish(_ location: CLLocation?) {
        timeoutWork?.cancel()
        timeoutWork = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: location)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        case .notDetermined:
            break
        @unknown default:
            finish(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        CollectorDiagnostics.recordError?("Location lookup failed: \(error.localizedDescription)")
        finish(nil)
    }
}
