import Contacts
import CoreLocation
import MapKit
import SwiftUI

struct ContactMapPane: View {
    let title: String
    let address: DraftAddress
    let close: () -> Void

    private struct Place: Identifiable {
        let id: Int
        let label: String
        let coordinate: CLLocationCoordinate2D
    }

    @State private var places: [Place] = []
    @State private var isLoading = true
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Map")
                .accessibilityLabel("Close Map")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ZStack {
                Map(position: $position) {
                    ForEach(places) { place in
                        Marker(place.label, coordinate: place.coordinate)
                    }
                }
                .mapStyle(.standard)

                if isLoading {
                    ProgressView()
                } else if places.isEmpty {
                    Text("Couldn't find this address on the map")
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(height: 320)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        // Follows edits to the address, once typing pauses (geocoding is rate limited).
        .task(id: address) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await geocodeAddress()
        }
    }

    private func geocodeAddress() async {
        isLoading = true
        places = []
        let placemarks = try? await CLGeocoder().geocodePostalAddress(address.postalAddress)
        guard !Task.isCancelled else { return }
        if let location = placemarks?.first?.location {
            let label = ContactLabel.text(address.label)
            places = [Place(id: 0, label: label.isEmpty ? address.mailingText : label, coordinate: location.coordinate)]
        }
        isLoading = false
    }
}
