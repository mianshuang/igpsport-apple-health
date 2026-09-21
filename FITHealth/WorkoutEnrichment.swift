import Foundation
import HealthKit

struct EnrichmentSnapshot: Sendable {
    struct Weather: Sendable {
        var temperatureCelsius: Double?
        var humidity: Double?
        var condition: HKWeatherCondition?
        var conditionName: String?
        var pressureHPa: Double?
        var error: String?
    }

    struct METs: Sendable {
        var value: Double?
        var fromWatch: Bool
        var error: String?
    }

    var weather = Weather()
    var mets = METs(value: nil, fromWatch: false, error: nil)
}

enum WorkoutEnrichment {
    private static let weatherTimeout: TimeInterval = 12
    private static let metsTimeout: TimeInterval = 8
    private static let metsUnit = HKUnit.kilocalorie()
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
    private static let hectopascal = HKUnit.pascalUnit(with: .hecto)

    static func weather(for activity: FITActivity) async -> EnrichmentSnapshot.Weather {
        guard let point = RideSampling.weatherQueryPoint(start: activity.start, end: activity.end,
                                                         locations: activity.locations) else {
            RideLog.skip("Open-Meteo", "没有 GPS，无法按骑行中点查天气")
            return EnrichmentSnapshot.Weather(error: "没有 GPS，无法查询天气")
        }
        do {
            let sample = try await withTimeout(weatherTimeout) {
                var request = URLRequest(url: OpenMeteo.url(date: point.date, latitude: point.latitude,
                                                          longitude: point.longitude))
                request.timeoutInterval = weatherTimeout
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw OpenMeteo.Failure.unavailable }
                guard (200..<300).contains(http.statusCode) else { throw OpenMeteo.Failure.http(http.statusCode) }
                return try OpenMeteo.sample(data: data, at: point.date)
            }
            RideLog.ok("Open-Meteo", "已获取骑行中点的代表小时天气")
            return EnrichmentSnapshot.Weather(
                temperatureCelsius: sample.temperature, humidity: sample.humidity,
                condition: sample.code.flatMap(healthCondition),
                conditionName: sample.code.flatMap(OpenMeteo.conditionName), pressureHPa: sample.pressure)
        } catch {
            RideLog.skip("Open-Meteo", "天气查询失败", extra: error.localizedDescription)
            return EnrichmentSnapshot.Weather(error: error.localizedDescription)
        }
    }

    static func mets(for activity: FITActivity, store: HKHealthStore) async -> EnrichmentSnapshot.METs {
        RideLog.step("physicalEffort", "读取本次 FIT 时间范围内的 Apple Watch MET 样本")
        let watch: [(start: Date, end: Date, mets: Double)]
        do {
            watch = try await withTimeout(metsTimeout) {
                try await physicalEffortSamples(for: activity, store: store)
            }
        } catch {
            RideLog.skip("physicalEffort", "读取 Watch MET 失败或超时，改用速度回退",
                         extra: error.localizedDescription)
            watch = []
        }
        let result = RideSampling.averageMETs(
            watch: watch,
            samples: activity.samples,
            avgSpeed: activity.avgSpeed,
            start: activity.start,
            end: activity.end,
            duration: activity.duration,
            events: activity.timerEvents
        )
        guard let result, result.value.isFinite, result.value > 0 else {
            RideLog.skip("HKMetadataKeyAverageMETs", "没有 Watch MET，速度回退也算不出平均强度")
            return EnrichmentSnapshot.METs(value: nil, fromWatch: false, error: "无法计算平均强度")
        }
        RideLog.ok("HKMetadataKeyAverageMETs",
                   result.fromWatch ? "按 timer-running 对 Watch MET 做时间加权" : "没有 Watch MET，用码表速度按 Compendium 回退",
                   extra: String(format: "%.2f METs，%d 个 Watch 样本", result.value, watch.count))
        return EnrichmentSnapshot.METs(value: result.value, fromWatch: result.fromWatch, error: nil)
    }

    static func healthMetadata(_ snapshot: EnrichmentSnapshot) -> [String: Any] {
        var info: [String: Any] = [:]
        if let celsius = snapshot.weather.temperatureCelsius {
            info[HKMetadataKeyWeatherTemperature] = HKQuantity(unit: .degreeCelsius(), doubleValue: celsius)
        }
        if let humidity = snapshot.weather.humidity {
            info[HKMetadataKeyWeatherHumidity] = HKQuantity(unit: .percent(), doubleValue: humidity)
        }
        if let condition = snapshot.weather.condition, condition != .none {
            info[HKMetadataKeyWeatherCondition] = NSNumber(value: condition.rawValue)
        }
        if let hPa = snapshot.weather.pressureHPa, hPa > 0 {
            info[HKMetadataKeyBarometricPressure] = HKQuantity(unit: hectopascal, doubleValue: hPa)
        }
        if let mets = snapshot.mets.value, mets > 0 {
            info[HKMetadataKeyAverageMETs] = HKQuantity(unit: metsUnit, doubleValue: mets)
        }
        return info
    }

    private static func physicalEffortSamples(for activity: FITActivity,
                                              store: HKHealthStore) async throws -> [(start: Date, end: Date, mets: Double)] {
        let type = HKQuantityType(.physicalEffort)
        let predicate = HKQuery.predicateForSamples(withStart: activity.start, end: activity.end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let samples = try await descriptor.result(for: store)
        if samples.isEmpty {
            RideLog.skip("physicalEffort", "这段时间没有 Apple Watch MET 样本，将用速度回退")
        } else {
            RideLog.ok("physicalEffort", "已读到 Watch MET 样本", extra: "\(samples.count) 条")
        }
        return samples.map { sample in
            (sample.startDate, sample.endDate, sample.quantity.doubleValue(for: metsUnit))
        }
    }

    private static func healthCondition(_ code: Int) -> HKWeatherCondition? {
        switch code {
        case 0: .clear
        case 1: .fair
        case 2: .partlyCloudy
        case 3: .cloudy
        case 45, 48: .foggy
        case 51, 53, 55: .drizzle
        case 56, 57: .freezingDrizzle
        case 61, 63, 65, 80, 81, 82: .showers
        case 66, 67: .freezingRain
        case 71, 73, 75, 77, 85, 86: .snow
        case 95, 96, 99: .thunderstorms
        default: nil
        }
    }
}
