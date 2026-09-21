import Foundation

struct FITActivity: Sendable {
    struct HeartRate: Sendable {
        let date: Date
        let bpm: Double
    }
    struct TimerEvent: Sendable {
        let date: Date
        let paused: Bool
    }
    struct Sample: Sendable {
        let date: Date
        let latitude: Double?
        let longitude: Double?
        let altitude: Double?
        let speed: Double?
        let cadence: Double?
        let power: Double?
        let distance: Double?
        let heartRate: Double?
        let temperature: Double?
        let accuracy: Double?

        var hasCoordinate: Bool { latitude != nil && longitude != nil }
        var hasData: Bool {
            hasCoordinate || altitude != nil || speed != nil || cadence != nil
                || power != nil || distance != nil || heartRate != nil || temperature != nil
        }
    }
    struct Location: Sendable {
        let date: Date
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let speed: Double?
        let accuracy: Double?
    }
    struct Lap: Sendable {
        let start: Date
        let end: Date
        let duration: TimeInterval
        let elapsed: TimeInterval
        let distance: Double?
        let calories: Double?
        let avgSpeed: Double?
        let maxSpeed: Double?
        let avgHeartRate: Double?
        let maxHeartRate: Double?
        let avgCadence: Double?
        let avgPower: Double?
        let ascent: Double?
    }

    let sport: Int
    let subSport: Int
    let start: Date
    let end: Date
    /// FIT `total_timer_time`：不含暂停的真实运动时间。
    let duration: TimeInterval
    /// FIT `total_elapsed_time`：含休息的墙钟总耗时。
    let elapsed: TimeInterval
    let distance: Double?
    let calories: Double?
    let avgSpeed: Double?
    let maxSpeed: Double?
    let avgHeartRate: Double?
    let maxHeartRate: Double?
    let avgCadence: Double?
    let maxCadence: Double?
    let avgPower: Double?
    let maxPower: Double?
    let ascent: Double?
    let descent: Double?
    let avgTemperature: Double?
    let maxTemperature: Double?
    let samples: [Sample]
    let timerEvents: [TimerEvent]
    let laps: [Lap]
    let recordFieldNumbers: [Int]
    let sessionFieldNumbers: [Int]
    let lapFieldNumbers: [Int]
    let messageCounts: [Int: Int]

    var sportName: String { "骑行" }

    var heartRates: [HeartRate] {
        samples.compactMap { sample in
            guard let bpm = sample.heartRate, bpm > 0 else { return nil }
            return HeartRate(date: sample.date, bpm: bpm)
        }
    }

    var locations: [Location] {
        samples.compactMap { sample in
            guard let latitude = sample.latitude, let longitude = sample.longitude else { return nil }
            return Location(date: sample.date, latitude: latitude, longitude: longitude,
                            altitude: sample.altitude, speed: sample.speed, accuracy: sample.accuracy)
        }
    }

    /// 设备圈段；没有圈段时按累计距离切 1 公里，供时段配速写入健康。
    var splits: [Lap] {
        if !laps.isEmpty { return laps }
        return Self.kilometerSplits(samples: samples, start: start)
    }
}

enum FITError: LocalizedError, Equatable {
    case invalidFile, corrupted, missingSession, multipleSessions, notOutdoorCycling
    var errorDescription: String? {
        switch self {
        case .invalidFile: "无法读取这个 FIT 文件，请选择 iGPSPORT 导出的原始 .fit 文件。"
        case .corrupted: "FIT 文件不完整或校验失败，请重新导出。"
        case .missingSession: "文件中没有完整的骑行记录。"
        case .multipleSessions: "仅支持单次骑行，请分别导出后导入。"
        case .notOutdoorCycling: "仅支持 iGPSPORT 户外骑行记录。"
        }
    }
}

/// Decodes FIT activity files. Unknown messages and developer fields are skipped by declared size.
struct FITParser {
    private struct Field {
        let number: Int
        let size: Int
        let type: UInt8
    }
    private struct Definition {
        let global: Int
        let bigEndian: Bool
        let fields: [Field]
        let developerSize: Int
    }
    private let bytes: [UInt8]
    private var offset = 0
    private var limit: Int

    init(data: Data) {
        bytes = Array(data)
        limit = data.count
    }

    mutating func parse() throws -> FITActivity {
        guard bytes.count >= 14, bytes[0] >= 12,
              Array(bytes[8..<12]) == Array(".FIT".utf8) else { throw FITError.invalidFile }
        let headerSize = Int(bytes[0])
        let payloadSize = Int(Self.integer(Array(bytes[4..<8]), bigEndian: false))
        guard headerSize <= bytes.count, payloadSize <= bytes.count - headerSize - 2 else {
            throw FITError.corrupted
        }
        let dataEnd = headerSize + payloadSize
        guard Self.crc(bytes[0..<(dataEnd + 2)]) == 0 else { throw FITError.corrupted }
        offset = headerSize
        limit = dataEnd
        var definitions: [Int: Definition] = [:]
        var timestamp: UInt64?
        var sessions: [[Int: Double]] = []
        var samples: [FITActivity.Sample] = []
        var events: [FITActivity.TimerEvent] = []
        var laps: [FITActivity.Lap] = []
        var recordFields = Set<Int>()
        var sessionFields = Set<Int>()
        var lapFields = Set<Int>()
        var messageCounts: [Int: Int] = [:]
        while offset < limit {
            let header = try read(1)[0]
            let compressed = header & 0x80 != 0
            let local = Int(compressed ? (header >> 5) & 3 : header & 15)
            if !compressed && header & 0x40 != 0 {
                _ = try read(1)
                let bigEndian = try read(1)[0] == 1
                let global = Int(Self.integer(try read(2), bigEndian: bigEndian))
                let count = Int(try read(1)[0])
                var fields: [Field] = []
                for _ in 0..<count {
                    let field = try read(3)
                    fields.append(Field(number: Int(field[0]), size: Int(field[1]), type: field[2]))
                }
                var developerSize = 0
                if header & 0x20 != 0 {
                    let count = Int(try read(1)[0])
                    for _ in 0..<count { developerSize += Int(try read(3)[1]) }
                }
                definitions[local] = Definition(global: global, bigEndian: bigEndian,
                                                 fields: fields, developerSize: developerSize)
                continue
            }
            guard let definition = definitions[local] else { throw FITError.corrupted }
            var values: [Int: Double] = [:]
            if compressed {
                guard let previous = timestamp else { throw FITError.corrupted }
                let low = UInt64(header & 31)
                let next = (previous & ~31) + low + (low < previous & 31 ? 32 : 0)
                values[253] = Double(next)
                timestamp = next
            }
            for field in definition.fields {
                if compressed && field.number == 253 { continue }
                let data = try read(field.size)
                if let value = Self.number(data, type: field.type, bigEndian: definition.bigEndian) {
                    values[field.number] = value
                }
            }
            _ = try read(definition.developerSize)
            if let full = values[253] { timestamp = UInt64(full.rounded()) }
            messageCounts[definition.global, default: 0] += 1
            switch definition.global {
            case 18:
                sessionFields.formUnion(values.keys)
                sessions.append(values)
            case 19:
                lapFields.formUnion(values.keys)
                if let lap = Self.lap(from: values) { laps.append(lap) }
            case 20:
                recordFields.formUnion(values.keys)
                if let sample = Self.sample(from: values), sample.hasData { samples.append(sample) }
            case 21:
                if values[0] == 0, let time = values[253], let kind = values[1] {
                    if kind == 0 { events.append(.init(date: Self.date(time), paused: false)) }
                    if [1, 4, 8, 9].contains(Int(kind.rounded())) {
                        events.append(.init(date: Self.date(time), paused: true))
                    }
                }
            default: break
            }
        }
        guard sessions.count <= 1 else { throw FITError.multipleSessions }
        guard let session = sessions.first, let startValue = session[2] else { throw FITError.missingSession }
        let start = Self.date(startValue)
        let elapsed = session[7].map { $0 / 1000 }
        let timer = session[8].map { $0 / 1000 }
        let end = elapsed.map { start.addingTimeInterval($0) } ?? session[253].map(Self.date)
        guard let end, end > start else { throw FITError.missingSession }
        let moving = timer ?? elapsed ?? end.timeIntervalSince(start)
        let wall = elapsed ?? end.timeIntervalSince(start)
        guard moving > 0, moving <= wall + 1 else { throw FITError.corrupted }
        let inRange: (Date) -> Bool = { $0 >= start.addingTimeInterval(-1) && $0 <= end.addingTimeInterval(1) }
        let sport = session[5].map { Int($0.rounded()) } ?? 0
        let subSport = session[6].map { Int($0.rounded()) } ?? 0
        guard sport == 2, subSport != 6 else { throw FITError.notOutdoorCycling }
        return FITActivity(
            sport: sport,
            subSport: subSport,
            start: start,
            end: end,
            duration: moving,
            elapsed: wall,
            distance: session[9].map { $0 / 100 },
            calories: session[11],
            avgSpeed: Self.speed(session, enhanced: 124, raw: 14),
            maxSpeed: Self.speed(session, enhanced: 125, raw: 15),
            avgHeartRate: session[16],
            maxHeartRate: session[17],
            avgCadence: session[18],
            maxCadence: session[19],
            avgPower: session[20],
            maxPower: session[21],
            ascent: session[22],
            descent: session[23],
            avgTemperature: session[57],
            maxTemperature: session[58],
            samples: samples.filter { inRange($0.date) }.sorted { $0.date < $1.date },
            timerEvents: events.filter { inRange($0.date) }.sorted { $0.date < $1.date },
            laps: laps.filter { inRange($0.start) }.sorted { $0.start < $1.start },
            recordFieldNumbers: recordFields.sorted(),
            sessionFieldNumbers: sessionFields.sorted(),
            lapFieldNumbers: lapFields.sorted(),
            messageCounts: messageCounts
        )
    }

    private mutating func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= limit - offset else { throw FITError.corrupted }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    private static func sample(from values: [Int: Double]) -> FITActivity.Sample? {
        guard let time = values[253] else { return nil }
        var latitude = degrees(values[0], limit: 90)
        var longitude = degrees(values[1], limit: 180)
        if let lat = latitude, let lon = longitude, abs(lat) < 1e-8, abs(lon) < 1e-8 {
            latitude = nil
            longitude = nil
        }
        return FITActivity.Sample(
            date: date(time),
            latitude: latitude,
            longitude: longitude,
            altitude: altitude(values),
            speed: speed(values, enhanced: 73, raw: 6),
            cadence: values[4].flatMap { $0 > 0 ? $0 : nil },
            power: values[7],
            distance: values[5].map { $0 / 100 },
            heartRate: values[3].flatMap { $0 > 0 ? $0 : nil },
            temperature: values[13],
            accuracy: values[31]
        )
    }

    private static func lap(from values: [Int: Double]) -> FITActivity.Lap? {
        guard let startValue = values[2] else { return nil }
        let start = date(startValue)
        let elapsed = values[7].map { $0 / 1000 }
        let duration = values[8].map { $0 / 1000 } ?? elapsed
        let end = elapsed.map { start.addingTimeInterval($0) } ?? values[253].map(date)
        guard let end, let duration, duration > 0, end >= start else { return nil }
        return FITActivity.Lap(
            start: start,
            end: end,
            duration: duration,
            elapsed: elapsed ?? duration,
            distance: values[9].map { $0 / 100 },
            calories: values[11],
            avgSpeed: speed(values, enhanced: 110, raw: 14),
            maxSpeed: speed(values, enhanced: 111, raw: 15),
            avgHeartRate: values[16],
            maxHeartRate: values[17],
            avgCadence: values[18],
            avgPower: values[20],
            ascent: values[22]
        )
    }

    private static func speed(_ values: [Int: Double], enhanced: Int, raw: Int) -> Double? {
        if let value = values[enhanced] { return value / 1000 }
        if let value = values[raw] { return value / 1000 }
        return nil
    }

    private static func altitude(_ values: [Int: Double]) -> Double? {
        if let value = values[78] { return value / 5 - 500 }
        if let value = values[2] { return value / 5 - 500 }
        return nil
    }

    private static func degrees(_ raw: Double?, limit: Double) -> Double? {
        guard let raw else { return nil }
        let degrees = raw * (180.0 / 2_147_483_648.0)
        guard degrees.isFinite, abs(degrees) <= limit else { return nil }
        return degrees
    }

    private static func number(_ data: [UInt8], type: UInt8, bigEndian: Bool) -> Double? {
        let base = type & 31
        switch base {
        case 0, 2, 10:
            guard data.count == 1 else { return nil }
            let value = data[0]
            if base == 10 { return value == 0 ? nil : Double(value) }
            return value == 0xFF ? nil : Double(value)
        case 4, 11:
            guard data.count == 2 else { return nil }
            let value = integer(data, bigEndian: bigEndian)
            if base == 11 { return value == 0 ? nil : Double(value) }
            return value == 0xFFFF ? nil : Double(value)
        case 6, 12:
            guard data.count == 4 else { return nil }
            let value = integer(data, bigEndian: bigEndian)
            if base == 12 { return value == 0 ? nil : Double(value) }
            return value == 0xFFFF_FFFF ? nil : Double(value)
        case 15:
            guard data.count == 8 else { return nil }
            let value = integer(data, bigEndian: bigEndian)
            return value == UInt64.max ? nil : Double(value)
        case 1:
            guard data.count == 1 else { return nil }
            let value = Int8(bitPattern: data[0])
            return value == .max ? nil : Double(value)
        case 3:
            guard data.count == 2 else { return nil }
            let value = Int16(bitPattern: UInt16(truncatingIfNeeded: integer(data, bigEndian: bigEndian)))
            return value == .max ? nil : Double(value)
        case 5:
            guard data.count == 4 else { return nil }
            let value = Int32(bitPattern: UInt32(truncatingIfNeeded: integer(data, bigEndian: bigEndian)))
            return value == .max ? nil : Double(value)
        case 8:
            guard data.count == 4 else { return nil }
            let bits = UInt32(truncatingIfNeeded: integer(data, bigEndian: bigEndian))
            let value = Float(bitPattern: bits)
            return value.isFinite ? Double(value) : nil
        case 9:
            guard data.count == 8 else { return nil }
            let bits = integer(data, bigEndian: bigEndian)
            let value = Double(bitPattern: bits)
            return value.isFinite ? value : nil
        default:
            return nil
        }
    }

    private static func integer(_ data: [UInt8], bigEndian: Bool) -> UInt64 {
        let ordered = bigEndian ? data : Array(data.reversed())
        return ordered.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func date(_ value: Double) -> Date {
        Date(timeIntervalSince1970: 631_065_600 + value.rounded())
    }

    static func crc(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }
}

extension FITActivity {
    static func kilometerSplits(samples: [Sample], start: Date) -> [Lap] {
        let points = samples.compactMap { sample -> (Date, Double)? in
            guard let distance = sample.distance else { return nil }
            return (sample.date, distance)
        }
        guard let total = points.last?.1, total >= 1000 else { return [] }
        var laps: [Lap] = []
        var mark = 1000.0
        var lapStart = start
        var previousDistance = 0.0
        for (date, distance) in points {
            while distance >= mark {
                let duration = date.timeIntervalSince(lapStart)
                guard duration > 0 else { break }
                let splitDistance = min(1000, distance - previousDistance)
                laps.append(Lap(start: lapStart, end: date, duration: duration, elapsed: duration,
                                distance: splitDistance, calories: nil,
                                avgSpeed: splitDistance / duration, maxSpeed: nil,
                                avgHeartRate: nil, maxHeartRate: nil, avgCadence: nil, avgPower: nil, ascent: nil))
                lapStart = date
                previousDistance = mark
                mark += 1000
            }
        }
        return laps
    }
}
