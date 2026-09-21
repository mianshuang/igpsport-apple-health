import Foundation

/// One representative location/hour, not a weather track. No account or API key.
enum OpenMeteo {
    struct Sample: Equatable {
        let temperature: Double?
        let humidity: Double?
        let code: Int?
        let pressure: Double?
    }

    struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]?
            let relative_humidity_2m: [Double?]?
            let weather_code: [Int?]?
            let surface_pressure: [Double?]?
        }
        let hourly: Hourly
    }

    static func url(date: Date, latitude: Double, longitude: Double, now: Date = Date()) -> URL {
        let recent = date >= now.addingTimeInterval(-7 * 86400)
        var parts = URLComponents(string: recent
            ? "https://api.open-meteo.com/v1/forecast"
            : "https://archive-api.open-meteo.com/v1/archive")!
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd"
        // Include both candidate hours, including the next UTC day at midnight.
        let hour = floor(date.timeIntervalSince1970 / 3600) * 3600
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "start_date", value: format.string(from: Date(timeIntervalSince1970: hour))),
            URLQueryItem(name: "end_date", value: format.string(from: Date(timeIntervalSince1970: hour + 3600))),
            URLQueryItem(name: "hourly", value: "temperature_2m,relative_humidity_2m,weather_code,surface_pressure"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        return parts.url!
    }

    static func sample(data: Data, at date: Date) throws -> Sample {
        let hourly = try JSONDecoder().decode(Response.self, from: data).hourly
        let target = date.timeIntervalSince1970
        guard let index = hourly.time.indices.min(by: {
            abs(hourly.time[$0] - target) < abs(hourly.time[$1] - target)
        }), abs(hourly.time[index] - target) <= 1800 else {
            throw Failure.unavailable
        }
        func value<T>(_ values: [T?]?) -> T? {
            guard let values, values.indices.contains(index) else { return nil }
            return values[index]
        }
        let rawTemperature: Double? = value(hourly.temperature_2m)
        let rawHumidity: Double? = value(hourly.relative_humidity_2m)
        let rawPressure: Double? = value(hourly.surface_pressure)
        let rawCode: Int? = value(hourly.weather_code)
        let temperature = rawTemperature.flatMap { $0.isFinite ? $0 : nil }
        let humidity = rawHumidity.flatMap { $0.isFinite && (0...100).contains($0) ? $0 / 100 : nil }
        let pressure = rawPressure.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let code = rawCode.flatMap { conditionName($0) == nil ? nil : $0 }
        guard temperature != nil || humidity != nil || pressure != nil || code != nil else {
            throw Failure.unavailable
        }
        return Sample(temperature: temperature, humidity: humidity, code: code, pressure: pressure)
    }

    static func conditionName(_ code: Int) -> String? {
        switch code {
        case 0: "Clear"
        case 1: "Mainly Clear"
        case 2: "Partly Cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing Drizzle"
        case 61, 63, 65: "Rain"
        case 66, 67: "Freezing Rain"
        case 71, 73, 75, 77, 85, 86: "Snow"
        case 80, 81, 82: "Rain Showers"
        case 95, 96, 99: "Thunderstorm"
        default: nil
        }
    }

    enum Failure: LocalizedError {
        case unavailable, http(Int)
        var errorDescription: String? {
            switch self {
            case .unavailable: "骑行中点附近暂无天气数据"
            case .http(429): "天气服务请求过于频繁，请稍后重试"
            case .http(let code): "天气服务暂不可用（HTTP \(code)）"
            }
        }
    }
}

/// In-app weather preview keeps humidity as 0–1. Fitness workout details treat
/// `HKMetadataKeyWeatherHumidity` as percentage points (Apple Watch samples
/// store 36% as percent doubleValue 36, which prints as "3600 %").
enum WorkoutDisplay {
    static func name(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "户外骑行" : trimmed
    }

    static func humidityPercent(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return (fraction * 100).rounded()
    }
}
