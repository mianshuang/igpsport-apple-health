import CoreLocation
import HealthKit
import WeatherKit

enum WorkoutEnrichment {
    private static let weatherTimeout: TimeInterval = 12
    private static let metsTimeout: TimeInterval = 8
    private static let metsUnit = HKUnit.kilocalorie()
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))

    static func metadata(for activity: FITActivity, store: HKHealthStore) async -> [String: Any] {
        RideLog.step("WorkoutEnrichment", "用骑行中点查天气，并用 Watch MET 或速度回退计算平均强度")
        async let weather = weatherMetadata(activity)
        async let mets = metsMetadata(activity, store: store)
        var info: [String: Any] = [:]
        info.merge(await weather, uniquingKeysWith: { _, new in new })
        info.merge(await mets, uniquingKeysWith: { _, new in new })
        if info.isEmpty {
            RideLog.skip("WorkoutEnrichment", "天气和平均强度都没有补上，继续写入骑行本身")
        }
        return info
    }

    private static func weatherMetadata(_ activity: FITActivity) async -> [String: Any] {
        guard let point = RideSampling.weatherQueryPoint(start: activity.start, end: activity.end,
                                                         locations: activity.locations) else {
            RideLog.skip("WeatherKit", "没有 GPS，无法按骑行中点查天气")
            return [:]
        }
        RideLog.step("WeatherKit.hourly", "查中点这一小时的温度、湿度、天气状况、气压",
                     extra: "\(RideLog.date(point.date))，\(String(format: "%.4f, %.4f", point.latitude, point.longitude))")
        do {
            let hour = try await withTimeout(weatherTimeout) {
                try await fetchHour(at: point)
            }
            var info: [String: Any] = [:]
            let celsius = hour.temperature.converted(to: .celsius).value
            if celsius.isFinite {
                info[HKMetadataKeyWeatherTemperature] = HKQuantity(unit: .degreeCelsius(), doubleValue: celsius)
            }
            if hour.humidity.isFinite, (0...1).contains(hour.humidity) {
                info[HKMetadataKeyWeatherHumidity] = HKQuantity(unit: .percent(), doubleValue: hour.humidity)
            }
            let condition = healthCondition(hour.condition)
            if condition != .none {
                info[HKMetadataKeyWeatherCondition] = condition.rawValue
            }
            let hectopascals = hour.pressure.converted(to: .hectopascals).value
            if hectopascals.isFinite, hectopascals > 0 {
                info[HKMetadataKeyBarometricPressure] = HKQuantity(unit: .pascalUnit(with: .hecto),
                                                                   doubleValue: hectopascals)
            }
            RideLog.ok("WeatherKit.hourly", "已得到骑行中点的代表天气",
                       extra: String(format: "%.1f°C，湿度 %.0f%%，%@，%.0f hPa",
                                     celsius, hour.humidity * 100, hour.condition.description, hectopascals))
            return info
        } catch {
            RideLog.skip("WeatherKit.hourly", "天气查询失败或超时，不阻断写入",
                         extra: error.localizedDescription)
            return [:]
        }
    }

    private static func fetchHour(at point: (date: Date, latitude: Double, longitude: Double)) async throws -> HourWeather {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let forecast = try await WeatherService.shared.weather(
            for: location,
            including: .hourly(startDate: point.date.addingTimeInterval(-3600),
                               endDate: point.date.addingTimeInterval(1))
        )
        guard let hour = forecast.min(by: {
            abs($0.date.timeIntervalSince(point.date)) < abs($1.date.timeIntervalSince(point.date))
        }) else {
            throw WeatherUnavailable()
        }
        return hour
    }

    private static func metsMetadata(_ activity: FITActivity, store: HKHealthStore) async -> [String: Any] {
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
            return [:]
        }
        RideLog.ok("HKMetadataKeyAverageMETs",
                   result.fromWatch ? "按 timer-running 对 Watch MET 做时间加权" : "没有 Watch MET，用码表速度按 Compendium 回退",
                   extra: String(format: "%.2f METs，%d 个 Watch 样本", result.value, watch.count))
        return [
            HKMetadataKeyAverageMETs: HKQuantity(unit: metsUnit, doubleValue: result.value)
        ]
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

    private static func healthCondition(_ condition: WeatherCondition) -> HKWeatherCondition {
        switch condition {
        case .clear: return .clear
        case .mostlyClear: return .fair
        case .partlyCloudy: return .partlyCloudy
        case .mostlyCloudy: return .mostlyCloudy
        case .cloudy: return .cloudy
        case .foggy: return .foggy
        case .haze: return .haze
        case .smoky: return .smoky
        case .blowingDust: return .dust
        case .breezy, .windy: return .windy
        case .drizzle: return .drizzle
        case .rain: return .showers
        case .heavyRain: return .showers
        case .sunShowers: return .scatteredShowers
        case .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .thunderstorms:
            return .thunderstorms
        case .tropicalStorm: return .tropicalStorm
        case .hurricane: return .hurricane
        case .snow, .flurries, .sunFlurries, .heavySnow, .blowingSnow, .blizzard: return .snow
        case .sleet: return .sleet
        case .wintryMix: return .mixedSnowAndSleet
        case .freezingDrizzle: return .freezingDrizzle
        case .freezingRain: return .freezingRain
        case .hail: return .hail
        case .hot, .frigid: return .fair
        @unknown default: return .none
        }
    }
}

private struct WeatherUnavailable: Error {}
