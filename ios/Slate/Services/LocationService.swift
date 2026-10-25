import CoreLocation
import Foundation

/// Finds the city the phone is in, once, for "creators near you". Asks permission the first time (while using the
/// app, and only an approximate position), and keeps nothing: the answer is a city name and a point rounded to about a
/// kilometre, and the caller decides what to do with it.
@MainActor
final class DeviceLocationFinder: NSObject, CLLocationManagerDelegate {
    enum Failure: LocalizedError {
        case denied
        case notFound

        var errorDescription: String? {
            switch self {
            case .denied:
                "Location is off for Slate Pro. You can turn it on in Settings, or choose a city instead."
            case .notFound:
                "Slate Pro couldn't tell where you are just now. Try again, or choose a city instead."
            }
        }
    }

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        // A city is all that's needed, and a coarse fix is quicker and kinder to the battery.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// The city the phone is in. Throws `Failure.denied` when location is off, or `notFound` when it can't tell.
    func currentPlace() async throws -> ClientPlace {
        let location = try await locate()
        let point = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        var name = ""
        if let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            name = [mark.locality, mark.administrativeArea ?? mark.country].compactMap { $0 }.joined(separator: ", ")
        }
        return ClientPlace(name: name.isEmpty ? "Near you" : name, point: point)
    }

    private func locate() async throws -> CLLocation {
        // A second request while one is waiting replaces it, so the first can't be left hanging.
        finish(.failure(Failure.notFound))
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            startIfAllowed()
        }
    }

    private func startIfAllowed() {
        guard waiting != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(Failure.denied))
        default:
            // Not asked yet: the answer arrives in locationManagerDidChangeAuthorization.
            break
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation = waiting else { return }
        waiting = nil
        continuation.resume(with: result)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.startIfAllowed() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in self.finish(.success(latest)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(Failure.notFound)) }
    }
}
