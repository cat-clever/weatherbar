// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation
import Combine

enum PlaceError: Error {
    case limitReached(Int)
    case duplicate
    case cannotRemoveCurrentLocation
}

@MainActor
final class PlaceStore: ObservableObject {
    @Published private(set) var places: [Place] = []
    @Published private(set) var activeID: UUID?

    var active: Place? { places.first { $0.id == activeID } }
    var canAddMore: Bool { places.count < maxPlaces }

    private let maxPlaces = 12
    private let defaults: UserDefaults
    private let listKey = "places.v2"
    private let activeKey = "activePlaceID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - 持久化

    private func load() {
        if let data = defaults.data(forKey: listKey),
           let decoded = try? JSONDecoder().decode([Place].self, from: data) {
            places = decoded
        }
        if places.isEmpty {
            places = [Place(name: "当前位置", latitude: Place.fallback.latitude,
                            longitude: Place.fallback.longitude, isCurrentLocation: true),
                      Place.fallback]
        }
        if let raw = defaults.string(forKey: activeKey),
           let id = UUID(uuidString: raw),
           places.contains(where: { $0.id == id }) {
            activeID = id
        } else {
            activeID = places.first?.id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(places) {
            defaults.set(data, forKey: listKey)
        }
        defaults.set(activeID?.uuidString, forKey: activeKey)
    }

    // MARK: - 变更

    func setActive(_ id: UUID) {
        guard places.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    @discardableResult
    func add(_ place: Place) -> Result<Void, PlaceError> {
        if let existing = places.first(where: { $0.isSameLocation(as: place) }) {
            setActive(existing.id)
            return .failure(.duplicate)
        }
        guard canAddMore else { return .failure(.limitReached(maxPlaces)) }
        places.append(place)
        activeID = place.id
        persist()
        return .success(())
    }

    func remove(_ id: UUID) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        guard !places[index].isCurrentLocation else { return }
        places.remove(at: index)
        if activeID == id {
            activeID = places.first?.id
        }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        places.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func updateCurrentLocation(_ place: Place) {
        guard let index = places.firstIndex(where: { $0.isCurrentLocation }) else {
            var copy = place
            copy.isCurrentLocation = true
            places.insert(copy, at: 0)
            if activeID == nil { activeID = copy.id }
            persist()
            return
        }
        var updated = place
        updated.id = places[index].id
        updated.isCurrentLocation = true
        places[index] = updated
        persist()
    }
}
