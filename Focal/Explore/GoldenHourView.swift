import SwiftUI
import CoreLocation
import Combine

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocationCoordinate2D?
    @Published var error: String?
    @Published var loading = false
    private let manager = CLLocationManager()
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }
    func request() {
        error = nil; loading = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: loading = false; error = "Location access is denied. Enter coordinates manually or allow access in iPhone Settings."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard loading else { return }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse { manager.requestLocation() }
        else if manager.authorizationStatus != .notDetermined { loading = false; error = "Location access is unavailable. You can enter coordinates manually." }
    }
    func locationManager(_ manager: CLLocationManager,didUpdateLocations locations: [CLLocation]) { location = locations.last?.coordinate; loading = false }
    func locationManager(_ manager: CLLocationManager,didFailWithError error: Error) { self.error = error.localizedDescription; loading = false }
}

struct GoldenHourView: View {
    @StateObject private var provider = LocationProvider()
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var date = Date()
    private var coordinates: (Double,Double)? {
        guard let lat = Double(latitude.replacingOccurrences(of: ",",with: ".")), let lon = Double(longitude.replacingOccurrences(of: ",",with: ".")), (-90...90).contains(lat),(-180...180).contains(lon) else { return nil }
        return (lat,lon)
    }
    var body: some View {
        Form {
            Section("Location") {
                Button("Use my location",systemImage: "location") { provider.request() }.disabled(provider.loading)
                if provider.loading { ProgressView("Getting location…") }
                TextField("Latitude (−90 to 90)",text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude (−180 to 180)",text: $longitude).keyboardType(.numbersAndPunctuation)
                if let error = provider.error { Text(error).font(.caption).foregroundStyle(.red) }
                Button("Open iPhone Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Section("Estimated golden light") {
                DatePicker("Day",selection: $date,displayedComponents: .date)
                if let (lat,lon) = coordinates {
                    let intervals = SolarCalculator.goldenWindows(on: date,latitude: lat,longitude: lon)
                    if intervals.isEmpty { Text("No golden-light window on this day at these coordinates.") }
                    ForEach(intervals,id: \.start) { interval in
                        HStack { Text(interval.start,style: .time); Text("–"); Text(interval.end,style: .time) }
                    }
                    if Calendar.current.isDateInToday(date), let elevation = SolarCalculator.elevation(at: Date(),latitude: lat,longitude: lon) { Text(String(format: "Current sun elevation: %.1f°",elevation)) }
                } else { Text("Choose a location or enter valid coordinates.").foregroundStyle(.secondary) }
            }
            Section {
                Text("Approximate sun elevation between −4° and +6°. Times use your iPhone’s timezone. Clouds, terrain and buildings affect usable light. This is an offline solar calculation, not a forecast. Location is used only here and is not added to photos or uploaded.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Golden hour").navigationBarTitleDisplayMode(.inline).tint(Palette.yellow)
            .onChange(of: provider.location?.latitude) { _,_ in
                if let point = provider.location { latitude = String(format: "%.4f",point.latitude); longitude = String(format: "%.4f",point.longitude) }
            }
    }
}
