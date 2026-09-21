import CoreLocation
import HealthKit

@MainActor
final class HealthImporter {
    private let store = HKHealthStore()
    private let meterPerSecond = HKUnit.meter().unitDivided(by: .second())
    private let rpm = HKUnit.count().unitDivided(by: .minute())
    private let distanceType = HKQuantityType(.distanceCycling)
    private let speedType = HKQuantityType(.cyclingSpeed)
    private let cadenceType = HKQuantityType(.cyclingCadence)
    private let powerType = HKQuantityType(.cyclingPower)
    private let energyType = HKQuantityType(.activeEnergyBurned)
    private let heartType = HKQuantityType(.heartRate)

    func save(_ activity: FITActivity) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ImportError.unavailable }
        let types = shareTypes(activity)
        try await store.requestAuthorization(toShare: types, read: [])
        guard types.allSatisfy({ store.authorizationStatus(for: $0) == .sharingAuthorized }) else {
            throw ImportError.permission
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        let device = HKDevice(name: "iGPSPORT", manufacturer: "iGPSPORT", model: "FIT",
                              hardwareVersion: nil, firmwareVersion: nil, softwareVersion: "1.0",
                              localIdentifier: nil, udiDeviceIdentifier: nil)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: device)
        let locations = routeLocations(activity)
        let route = locations.count >= 2 ? HKWorkoutRouteBuilder(healthStore: store, device: device) : nil
        do {
            try await builder.beginCollection(at: activity.start)
            if let route {
                let size = 100
                var index = 0
                while index < locations.count {
                    try await route.insertRouteData(Array(locations[index..<min(index + size, locations.count)]))
                    index += size
                }
            }
            try await addSamples(activity, to: builder)
            try await addEvents(activity, to: builder)
            try await builder.addMetadata(metadata(activity))
            try await builder.endCollection(at: activity.end)
            guard let workout = try await builder.finishWorkout() else { throw ImportError.saveFailed }
            if let route { _ = try await route.finishRoute(with: workout, metadata: nil) }
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    private func shareTypes(_ activity: FITActivity) -> Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if activity.calories != nil { types.insert(energyType) }
        if activity.distance != nil { types.insert(distanceType) }
        if !activity.heartRates.isEmpty { types.insert(heartType) }
        if activity.samples.contains(where: { $0.speed != nil }) { types.insert(speedType) }
        if activity.samples.contains(where: { $0.cadence != nil }) { types.insert(cadenceType) }
        if activity.samples.contains(where: { $0.power != nil }) { types.insert(powerType) }
        if activity.locations.count >= 2 { types.insert(HKSeriesType.workoutRoute()) }
        return types
    }

    private func addSamples(_ activity: FITActivity, to builder: HKWorkoutBuilder) async throws {
        var samples: [HKSample] = []
        if let distance = activity.distance {
            samples.append(HKQuantitySample(type: distanceType,
                                            quantity: HKQuantity(unit: .meter(), doubleValue: distance),
                                            start: activity.start, end: activity.end))
        }
        if let calories = activity.calories {
            samples.append(HKQuantitySample(type: energyType,
                                            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: calories),
                                            start: activity.start, end: activity.end))
        }
        samples += activity.heartRates.map {
            HKQuantitySample(type: heartType, quantity: HKQuantity(unit: rpm, doubleValue: $0.bpm),
                             start: $0.date, end: $0.date)
        }
        samples += activity.samples.compactMap { sample in
            guard let speed = sample.speed, speed > 0 else { return nil }
            return HKQuantitySample(type: speedType, quantity: HKQuantity(unit: meterPerSecond, doubleValue: speed),
                                    start: sample.date, end: sample.date)
        }
        samples += activity.samples.compactMap { sample in
            guard let cadence = sample.cadence, cadence > 0 else { return nil }
            return HKQuantitySample(type: cadenceType, quantity: HKQuantity(unit: rpm, doubleValue: cadence),
                                    start: sample.date, end: sample.date)
        }
        samples += activity.samples.compactMap { sample in
            guard let power = sample.power, power >= 0 else { return nil }
            return HKQuantitySample(type: powerType, quantity: HKQuantity(unit: .watt(), doubleValue: power),
                                    start: sample.date, end: sample.date)
        }
        guard !samples.isEmpty else { return }
        let size = 100
        var index = 0
        while index < samples.count {
            try await builder.addSamples(Array(samples[index..<min(index + size, samples.count)]))
            index += size
        }
    }

    private func addEvents(_ activity: FITActivity, to builder: HKWorkoutBuilder) async throws {
        var events: [HKWorkoutEvent] = []
        var paused = false
        for event in activity.timerEvents {
            guard event.paused != paused else { continue }
            paused = event.paused
            events.append(HKWorkoutEvent(type: event.paused ? .pause : .resume,
                                         dateInterval: DateInterval(start: event.date, duration: 0),
                                         metadata: nil))
        }
        if events.isEmpty {
            let rest = activity.elapsed - activity.duration
            if rest > 1 {
                let pauseAt = activity.end.addingTimeInterval(-rest)
                if pauseAt > activity.start {
                    events.append(HKWorkoutEvent(type: .pause,
                                                 dateInterval: DateInterval(start: pauseAt, duration: 0),
                                                 metadata: nil))
                }
            }
        }
        for lap in activity.splits {
            var info: [String: Any] = [:]
            if let speed = lap.avgSpeed {
                info[HKMetadataKeyAverageSpeed] = HKQuantity(unit: meterPerSecond, doubleValue: speed)
            }
            if let speed = lap.maxSpeed {
                info[HKMetadataKeyMaximumSpeed] = HKQuantity(unit: meterPerSecond, doubleValue: speed)
            }
            events.append(HKWorkoutEvent(type: .lap,
                                         dateInterval: DateInterval(start: lap.start, duration: max(lap.duration, 0)),
                                         metadata: info.isEmpty ? nil : info))
        }
        events.sort { $0.dateInterval.start < $1.dateInterval.start }
        if !events.isEmpty { try await builder.addWorkoutEvents(events) }
    }

    private func routeLocations(_ activity: FITActivity) -> [CLLocation] {
        var last: Date?
        var result: [CLLocation] = []
        for point in activity.locations {
            if let last, point.date <= last { continue }
            last = point.date
            result.append(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                altitude: point.altitude ?? 0,
                horizontalAccuracy: max(point.accuracy ?? 5, 1),
                verticalAccuracy: point.altitude == nil ? -1 : 5,
                course: -1,
                speed: point.speed ?? -1,
                timestamp: point.date
            ))
        }
        return result
    }

    private func metadata(_ activity: FITActivity) -> [String: Any] {
        var info: [String: Any] = [
            HKMetadataKeyIndoorWorkout: false,
            HKMetadataKeyWorkoutBrandName: "iGPSPORT"
        ]
        if let speed = activity.avgSpeed ?? computedAvgSpeed(activity) {
            info[HKMetadataKeyAverageSpeed] = HKQuantity(unit: meterPerSecond, doubleValue: speed)
        }
        if let speed = activity.maxSpeed ?? activity.samples.compactMap(\.speed).max() {
            info[HKMetadataKeyMaximumSpeed] = HKQuantity(unit: meterPerSecond, doubleValue: speed)
        }
        if let ascent = activity.ascent {
            info[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: Double(ascent))
        }
        if let descent = activity.descent {
            info[HKMetadataKeyElevationDescended] = HKQuantity(unit: .meter(), doubleValue: Double(descent))
        }
        if let temperature = activity.avgTemperature {
            info[HKMetadataKeyWeatherTemperature] = HKQuantity(unit: .degreeCelsius(), doubleValue: temperature)
        }
        return info
    }

    private func computedAvgSpeed(_ activity: FITActivity) -> Double? {
        guard let distance = activity.distance, activity.duration > 0 else { return nil }
        return distance / activity.duration
    }
}

private enum ImportError: LocalizedError {
    case unavailable, permission, saveFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "当前设备无法使用 Apple 健康。"
        case .permission: "请允许写入本次骑行所需的健康数据，然后重新导入。可在系统设置的健康权限中修改。"
        case .saveFailed: "骑行未能保存，请重试。"
        }
    }
}
