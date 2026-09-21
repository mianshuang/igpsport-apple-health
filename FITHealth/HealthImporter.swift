import CoreLocation
import HealthKit

enum ImportPhase: Sendable {
    case authorizing, writing
}

final class HealthImporter {
    private let store = HKHealthStore()
    private let distanceType = HKQuantityType(.distanceCycling)
    private let speedType = HKQuantityType(.cyclingSpeed)
    private let cadenceType = HKQuantityType(.cyclingCadence)
    private let powerType = HKQuantityType(.cyclingPower)
    private let energyType = HKQuantityType(.activeEnergyBurned)
    private let heartType = HKQuantityType(.heartRate)

    func save(_ activity: FITActivity, onPhase: @escaping @Sendable (ImportPhase) -> Void = { _ in }) async throws {
        RideLog.phase("写入 Apple 健康")
        RideLog.step("HKHealthStore.isHealthDataAvailable()", "确认本机能否使用健康")
        guard HKHealthStore.isHealthDataAvailable() else {
            RideLog.fail("isHealthDataAvailable", "当前设备无法使用 Apple 健康")
            throw ImportError.unavailable
        }
        RideLog.ok("isHealthDataAvailable", "健康可用")
        let types = shareTypes(activity)
        RideLog.step("requestAuthorization(toShare:)", "向系统申请本次骑行需要写入的类型",
                     extra: types.map(typeName).sorted().joined(separator: "、"))
        onPhase(.authorizing)
        do {
            try await withTimeout(RideTiming.authorizeTimeout) {
                try await self.store.requestAuthorization(toShare: types, read: [])
            }
        } catch RideWaitError.timedOut(let seconds) {
            RideLog.fail("requestAuthorization", "等待授权超时", extra: RideTiming.secondsLabel(seconds))
            throw ImportError.timedOut(seconds)
        } catch {
            RideLog.fail("requestAuthorization", "授权失败或超时，需在系统弹窗里允许写入", extra: error.localizedDescription)
            throw ImportError.permission
        }
        for type in types {
            let status = store.authorizationStatus(for: type)
            let meaning = "检查 \(typeName(type)) 的写入权限"
            switch status {
            case .sharingAuthorized:
                RideLog.ok("authorizationStatus", meaning, extra: "已授权写入")
            case .sharingDenied:
                RideLog.fail("authorizationStatus", meaning, extra: "用户拒绝写入")
            case .notDetermined:
                RideLog.fail("authorizationStatus", meaning, extra: "尚未决定")
            @unknown default:
                RideLog.fail("authorizationStatus", meaning, extra: "未知状态")
            }
        }
        guard types.allSatisfy({ store.authorizationStatus(for: $0) == .sharingAuthorized }) else {
            RideLog.fail("requestAuthorization", "所需类型未全部授权，中止写入")
            throw ImportError.permission
        }
        let estimate = RideTiming.persistEstimate(activity: activity)
        let timeout = RideTiming.persistTimeout(estimate: estimate)
        RideLog.step("Task.detached", "后台写入健康", extra: "预计 \(RideTiming.secondsLabel(estimate))，超时 \(Int(timeout)) 秒")
        onPhase(.writing)
        let store = self.store
        do {
            try await withTimeout(timeout) {
                try await Task.detached(priority: .userInitiated) {
                    try await persist(activity, store: store)
                }.value
            }
        } catch RideWaitError.timedOut(let seconds) {
            RideLog.fail("persist", "写入超时", extra: RideTiming.secondsLabel(seconds))
            throw ImportError.timedOut(seconds)
        } catch is CancellationError {
            RideLog.fail("persist", "写入任务已取消")
            throw ImportError.timedOut(timeout)
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
}

private func persist(_ activity: FITActivity, store: HKHealthStore) async throws {
    var clock = RideStageClock()
    let meterPerSecond = HKUnit.meter().unitDivided(by: .second())
    let rpm = HKUnit.count().unitDivided(by: .minute())
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = .cycling
    configuration.locationType = .outdoor
    RideLog.step("HKWorkoutConfiguration", "固定为室外骑行，不会写成室内或其它运动")
    let device = HKDevice(name: "iGPSPORT", manufacturer: "iGPSPORT", model: "FIT",
                          hardwareVersion: nil, firmwareVersion: nil, softwareVersion: "1.0",
                          localIdentifier: nil, udiDeviceIdentifier: nil)
    let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: device)
    RideLog.ok("HKWorkoutBuilder", "创建运动收集器", extra: clock.extra())
    var routeBuilder: HKWorkoutRouteBuilder?
    do {
        RideLog.step("beginCollection(at:)", "打开收集窗口，起点是 FIT start_time")
        try await builder.beginCollection(at: activity.start)
        RideLog.ok("beginCollection(at:)", "已开始收集", extra: clock.extra(RideLog.date(activity.start)))
        try Task.checkCancellation()

        routeBuilder = try await insertRoute(activity, to: builder, clock: &clock)
        try await addDistance(activity, store: store, device: device, to: builder, clock: &clock)
        try await addTotals(activity, to: builder, clock: &clock)

        let rawSpeeds = activity.samples.compactMap { sample -> (Date, Double)? in
            guard let speed = sample.speed, speed > 0 else { return nil }
            return (sample.date, speed)
        }
        RideLog.step("RideSampling.downsample", "speedInterval=5，每 5 个有效速度点取平均，降低高频 cyclingSpeed",
                     extra: "原始 \(rawSpeeds.count) 点")
        let speeds = RideSampling.downsample(rawSpeeds)
        RideLog.ok("RideSampling.downsample", "速度采样已稀释",
                   extra: clock.extra("\(rawSpeeds.count) → \(speeds.count) 点"))

        try await addSeries(store: store, device: device, type: HKQuantityType(.cyclingSpeed),
                            unit: meterPerSecond, points: speeds, to: builder, clock: &clock,
                            call: "cyclingSpeed", meaning: "写入稀释后的骑行速度曲线，单位 m/s")
        try await addSeries(store: store, device: device, type: HKQuantityType(.heartRate),
                            unit: rpm, points: activity.heartRates.map { ($0.date, $0.bpm) }, to: builder, clock: &clock,
                            call: "heartRate", meaning: "写入心率采样；没有心率带则为空")
        try await addSeries(store: store, device: device, type: HKQuantityType(.cyclingCadence),
                            unit: rpm, points: activity.samples.compactMap { sample in
            guard let cadence = sample.cadence, cadence > 0 else { return nil }
            return (sample.date, cadence)
        }, to: builder, clock: &clock,
                            call: "cyclingCadence", meaning: "写入踏频采样；没有踏频器则为空")
        try await addSeries(store: store, device: device, type: HKQuantityType(.cyclingPower),
                            unit: .watt(), points: activity.samples.compactMap { sample in
            guard let power = sample.power, power >= 0 else { return nil }
            return (sample.date, power)
        }, to: builder, clock: &clock,
                            call: "cyclingPower", meaning: "写入功率采样；没有功率计则为空")

        try await addEvents(activity, to: builder, clock: &clock)

        let info = metadata(activity, meterPerSecond: meterPerSecond)
        RideLog.step("addMetadata", "写入均速/极速、爬升、品牌等整场元数据", extra: metadataSummary(info))
        try await builder.addMetadata(info)
        RideLog.ok("addMetadata", "元数据已挂到本次运动", extra: clock.extra())

        RideLog.step("endCollection(at:)", "关闭收集窗口，终点是 FIT 墙钟结束时间")
        try await builder.endCollection(at: activity.end)
        RideLog.ok("endCollection(at:)", "收集结束", extra: clock.extra(RideLog.date(activity.end)))
        try Task.checkCancellation()

        RideLog.step("finishWorkout()", "保存 HKWorkout。seriesBuilder 拿到的路线会随 WorkoutBuilder 一起 finish，不能再 finishRoute")
        guard let workout = try await builder.finishWorkout() else {
            RideLog.fail("finishWorkout()", "健康没有返回已保存的运动")
            throw ImportError.saveFailed
        }
        let savedMeters = workout.totalDistance?.doubleValue(for: .meter())
            ?? workout.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()?.doubleValue(for: .meter())
        RideLog.ok("finishWorkout()", "运动已入库。附着的 GPS 路线一并保存并关联",
                   extra: clock.extra([
                    "uuid=\(workout.uuid.uuidString)",
                    savedMeters.map { "健康距离 \(RideLog.km($0))" },
                    "运动时长 \(RideLog.hms(workout.duration))"
                   ].compactMap { $0 }.joined(separator: "，")))
        if routeBuilder != nil {
            RideLog.skip("finishRoute(with:)", "iOS 明确拒绝：附着在 WorkoutBuilder 上的 route builder 会随 finishWorkout 完成。再调用会抛 Invalid Argument")
        }
        RideLog.ok("persist", "本次户外骑行已写入健康", extra: clock.extra())
    } catch is CancellationError {
        RideLog.fail("persist", "写入超时或被取消，discardWorkout() 丢弃未完成的运动")
        builder.discardWorkout()
        throw CancellationError()
    } catch {
        RideLog.fail("persist", "写入中途失败，discardWorkout() 丢弃未完成的运动", extra: error.localizedDescription)
        builder.discardWorkout()
        throw error
    }
}

private func insertRoute(_ activity: FITActivity, to builder: HKWorkoutBuilder,
                         clock: inout RideStageClock) async throws -> HKWorkoutRouteBuilder? {
    let locations = routeLocations(activity)
    RideLog.step("routeLocations", "把 FIT GPS 转成 CLLocation，去掉时间倒退的点", extra: "\(locations.count) 点")
    guard locations.count >= 2 else {
        RideLog.skip("seriesBuilder(for: .workoutRoute())", "GPS 不足 2 点，不写路线")
        return nil
    }
    RideLog.step("seriesBuilder(for: .workoutRoute())", "从 WorkoutBuilder 取路线序列收集器，不是单独 new 一个 RouteBuilder")
    guard let route = builder.seriesBuilder(for: .workoutRoute()) as? HKWorkoutRouteBuilder else {
        RideLog.fail("seriesBuilder(for: .workoutRoute())", "没有拿到 HKWorkoutRouteBuilder，跳过路线")
        return nil
    }
    RideLog.ok("seriesBuilder(for: .workoutRoute())", "已拿到路线 builder，随后只 insertRouteData，先不 finish")
    let size = 1000
    RideLog.step("insertRouteData", "按批写入 GPS 点，路线此时只在内存里", extra: "\(locations.count) 点，每批 \(size)")
    var index = 0
    var batch = 0
    while index < locations.count {
        try Task.checkCancellation()
        let end = min(index + size, locations.count)
        batch += 1
        try await route.insertRouteData(Array(locations[index..<end]))
        index = end
    }
    RideLog.ok("insertRouteData", "全部路线点已插入 builder，随 finishWorkout 一并入库",
               extra: clock.extra("\(locations.count) 点，\(batch) 批"))
    return route
}

private func addDistance(_ activity: FITActivity, store: HKHealthStore, device: HKDevice,
                         to builder: HKWorkoutBuilder, clock: inout RideStageClock) async throws {
    let increments = RideSampling.distanceIncrements(activity.samples)
    let moving = RideSampling.movingIntervals(start: activity.start, end: activity.end, events: activity.timerEvents)
    var points = RideSampling.restrictIncrements(increments, to: moving)
    var incrementTotal = points.reduce(0.0) { $0 + $1.1 }
    if let target = activity.distance, target - incrementTotal > 1, var last = points.last {
        last.1 += target - incrementTotal
        points[points.count - 1] = last
        incrementTotal = target
    }
    if !points.isEmpty {
        RideLog.step("distanceCycling", "按码表累计里程的增量写入，避免一条总量被暂停时段按比例切掉",
                     extra: "\(points.count) 段，合计 \(RideLog.km(incrementTotal))")
        try await addCumulative(store: store, device: device, type: HKQuantityType(.distanceCycling),
                                unit: .meter(), points: points, to: builder, clock: &clock,
                                call: "distanceCycling", meaning: "骑行距离增量")
        return
    }
    guard let distance = activity.distance else {
        RideLog.skip("distanceCycling", "FIT 没有有效距离")
        return
    }
    let intervals = moving
    let movingTotal = max(intervals.reduce(0) { $0 + $1.duration }, 1)
    let samples: [HKSample] = intervals.map { interval in
        HKQuantitySample(type: HKQuantityType(.distanceCycling),
                         quantity: HKQuantity(unit: .meter(), doubleValue: distance * interval.duration / movingTotal),
                         start: interval.start, end: interval.end)
    }
    RideLog.step("distanceCycling", "没有逐点里程，按未暂停时段拆分 session 总距离", extra: RideLog.km(distance))
    try await builder.addSamples(samples)
    RideLog.ok("distanceCycling", "已按骑行时段写入距离", extra: clock.extra("\(samples.count) 条"))
}

private func addTotals(_ activity: FITActivity, to builder: HKWorkoutBuilder, clock: inout RideStageClock) async throws {
    guard let calories = activity.calories else {
        RideLog.skip("activeEnergyBurned", "FIT 没有有效热量")
        return
    }
    let intervals = RideSampling.movingIntervals(start: activity.start, end: activity.end, events: activity.timerEvents)
    let moving = max(intervals.reduce(0) { $0 + $1.duration }, 1)
    let samples: [HKSample] = intervals.map { interval in
        HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                         quantity: HKQuantity(unit: .kilocalorie(), doubleValue: calories * interval.duration / moving),
                         start: interval.start, end: interval.end)
    }
    RideLog.step("activeEnergyBurned", "按未暂停时段拆分活动能量，避免被休息比例切掉", extra: "\(Int(calories)) kcal，\(samples.count) 段")
    try await builder.addSamples(samples)
    RideLog.ok("addSamples(totals)", "热量已加入本次运动", extra: clock.extra("\(samples.count) 条"))
}

private func addSeries(store: HKHealthStore, device: HKDevice, type: HKQuantityType,
                       unit: HKUnit, points: [(Date, Double)], to builder: HKWorkoutBuilder,
                       clock: inout RideStageClock, call: String, meaning: String) async throws {
    guard let first = points.first else {
        RideLog.skip(call, "\(meaning)。本文件没有有效采样，跳过")
        return
    }
    RideLog.step(call, meaning, extra: "\(points.count) 点，从 \(RideLog.date(first.0)) 开始")
    let series = HKQuantitySeriesSampleBuilder(healthStore: store, quantityType: type, startDate: first.0, device: device)
    do {
        var last: Date?
        var inserted = 0
        var skipped = 0
        for (date, value) in points {
            if inserted % 250 == 0 { try Task.checkCancellation() }
            if let last, date <= last {
                skipped += 1
                continue
            }
            last = date
            try series.insert(HKQuantity(unit: unit, doubleValue: value), at: date)
            inserted += 1
        }
        RideLog.ok("\(call).insert", "序列点已写入 series builder", extra: "插入 \(inserted)，跳过倒退时间 \(skipped)")
    } catch is CancellationError {
        series.discard()
        throw CancellationError()
    } catch {
        RideLog.fail("\(call).insert", "序列插入失败，丢弃该 series", extra: error.localizedDescription)
        series.discard()
        throw error
    }
    RideLog.step("\(call).finishSeries", "先完成数量序列，再把得到的 sample 加进 Workout")
    let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
        series.finishSeries(metadata: nil) { samples, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: samples ?? []) }
        }
    }
    if samples.isEmpty {
        RideLog.skip("\(call).addSamples", "finishSeries 没有返回 sample")
        return
    }
    try await builder.addSamples(samples)
    RideLog.ok("\(call).addSamples", "该序列已挂到本次运动", extra: clock.extra("\(samples.count) 条 sample"))
}

private func addCumulative(store: HKHealthStore, device: HKDevice, type: HKQuantityType,
                           unit: HKUnit, points: [(DateInterval, Double)], to builder: HKWorkoutBuilder,
                           clock: inout RideStageClock, call: String, meaning: String) async throws {
    guard let first = points.first else {
        RideLog.skip(call, "\(meaning)。没有增量可写")
        return
    }
    RideLog.step(call, meaning, extra: "\(points.count) 段，从 \(RideLog.date(first.0.start)) 开始")
    let series = HKQuantitySeriesSampleBuilder(healthStore: store, quantityType: type, startDate: first.0.start, device: device)
    do {
        var last: Date?
        var inserted = 0
        for (interval, value) in points {
            if inserted % 250 == 0 { try Task.checkCancellation() }
            if let last, interval.start < last { continue }
            last = interval.end
            try series.insert(HKQuantity(unit: unit, doubleValue: value), for: interval)
            inserted += 1
        }
        RideLog.ok("\(call).insert", "累计增量已写入 series builder", extra: "插入 \(inserted) 段")
    } catch is CancellationError {
        series.discard()
        throw CancellationError()
    } catch {
        RideLog.fail("\(call).insert", "累计序列插入失败，丢弃该 series", extra: error.localizedDescription)
        series.discard()
        throw error
    }
    RideLog.step("\(call).finishSeries", "先完成数量序列，再把得到的 sample 加进 Workout")
    let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
        series.finishSeries(metadata: nil) { samples, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: samples ?? []) }
        }
    }
    if samples.isEmpty {
        RideLog.skip("\(call).addSamples", "finishSeries 没有返回 sample")
        return
    }
    try await builder.addSamples(samples)
    RideLog.ok("\(call).addSamples", "该序列已挂到本次运动", extra: clock.extra("\(samples.count) 条 sample"))
}

private func addEvents(_ activity: FITActivity, to builder: HKWorkoutBuilder,
                       clock: inout RideStageClock) async throws {
    var events: [HKWorkoutEvent] = []
    var paused = false
    var pauses = 0
    var resumes = 0
    for event in activity.timerEvents {
        guard event.paused != paused else { continue }
        paused = event.paused
        if event.paused { pauses += 1 } else { resumes += 1 }
        events.append(HKWorkoutEvent(type: event.paused ? .pause : .resume,
                                     dateInterval: DateInterval(start: event.date, duration: 0),
                                     metadata: nil))
    }
    if events.isEmpty {
        let rest = activity.elapsed - activity.duration
        if rest > 1 {
            let pauseAt = activity.end.addingTimeInterval(-rest)
            if pauseAt > activity.start {
                RideLog.step("HKWorkoutEvent.pause", "FIT 没有 timer 事件，把休息整段落在结束前，用来还原真实骑行时间",
                             extra: "休息 \(RideLog.hms(rest))")
                events.append(HKWorkoutEvent(type: .pause,
                                             dateInterval: DateInterval(start: pauseAt, duration: 0),
                                             metadata: nil))
                pauses = 1
            }
        } else {
            RideLog.skip("HKWorkoutEvent.pause/resume", "没有暂停可还原")
        }
    } else {
        RideLog.ok("HKWorkoutEvent.pause/resume", "用 FIT timer 事件还原暂停，健康运动时长不含休息",
                   extra: "pause \(pauses)，resume \(resumes)")
    }
    for lap in activity.splits {
        events.append(HKWorkoutEvent(type: .lap,
                                     dateInterval: DateInterval(start: lap.start, duration: max(lap.duration, 0)),
                                     metadata: nil))
    }
    if activity.laps.isEmpty, !activity.splits.isEmpty {
        RideLog.step("HKWorkoutEvent.lap", "FIT 没有圈段，按累计距离切 1 km；圈事件不能带 HKAverageSpeed，健康会崩溃")
    } else if !activity.laps.isEmpty {
        RideLog.step("HKWorkoutEvent.lap", "写入码表圈段。Apple 禁止在 lap 事件上放 HKAverageSpeed / HKMaximumSpeed，圈均速改挂在整场 metadata",
                     extra: "\(activity.laps.count) 圈")
    } else {
        RideLog.skip("HKWorkoutEvent.lap", "没有圈段可写")
    }
    events.sort { $0.dateInterval.start < $1.dateInterval.start }
    guard !events.isEmpty else { return }
    try await builder.addWorkoutEvents(events)
    RideLog.ok("addWorkoutEvents", "暂停/恢复/圈段已加入本次运动", extra: clock.extra("\(events.count) 个事件"))
}

private func routeLocations(_ activity: FITActivity) -> [CLLocation] {
    var last: Date?
    var result: [CLLocation] = []
    result.reserveCapacity(activity.locations.count)
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

private func metadata(_ activity: FITActivity, meterPerSecond: HKUnit) -> [String: Any] {
    var info: [String: Any] = [
        HKMetadataKeyIndoorWorkout: false,
        HKMetadataKeyWorkoutBrandName: "iGPSPORT"
    ]
    if let speed = activity.avgSpeed ?? (activity.duration > 0 ? activity.distance.map { $0 / activity.duration } : nil) {
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
    let lapSpeeds = activity.splits.compactMap(\.avgSpeed)
    if !lapSpeeds.isEmpty {
        info["iGPSPORTLapAvgSpeedsKmh"] = lapSpeeds.map { String(format: "%.2f", $0 * 3.6) }.joined(separator: ",")
    }
    return info
}

private func metadataSummary(_ info: [String: Any]) -> String {
    info.keys.sorted().map { key in
        switch key {
        case HKMetadataKeyIndoorWorkout: "室内=否"
        case HKMetadataKeyWorkoutBrandName: "品牌=iGPSPORT"
        case HKMetadataKeyAverageSpeed: "均速"
        case HKMetadataKeyMaximumSpeed: "极速"
        case HKMetadataKeyElevationAscended: "累计爬升"
        case HKMetadataKeyElevationDescended: "累计下降"
        case HKMetadataKeyWeatherTemperature: "环境温度"
        case "iGPSPORTLapAvgSpeedsKmh": "圈均速km/h"
        default: key
        }
    }.joined(separator: "、")
}

private func typeName(_ type: HKSampleType) -> String {
    switch type.identifier {
    case HKObjectType.workoutType().identifier: "运动记录 HKWorkout"
    case HKQuantityType(.distanceCycling).identifier: "骑行距离 distanceCycling"
    case HKQuantityType(.cyclingSpeed).identifier: "骑行速度 cyclingSpeed"
    case HKQuantityType(.cyclingCadence).identifier: "踏频 cyclingCadence"
    case HKQuantityType(.cyclingPower).identifier: "功率 cyclingPower"
    case HKQuantityType(.activeEnergyBurned).identifier: "活动能量 activeEnergyBurned"
    case HKQuantityType(.heartRate).identifier: "心率 heartRate"
    case HKSeriesType.workoutRoute().identifier: "GPS路线 HKWorkoutRoute"
    default: type.identifier
    }
}

private enum ImportError: LocalizedError {
    case unavailable, permission, saveFailed, timedOut(TimeInterval)
    var errorDescription: String? {
        switch self {
        case .unavailable: "当前设备无法使用 Apple 健康。"
        case .permission: "请允许写入本次骑行所需的健康数据，然后重新导入。可在系统设置的健康权限中修改。"
        case .saveFailed: "骑行未能保存，请重试。"
        case .timedOut(let seconds): RideWaitError.timedOut(seconds).errorDescription
        }
    }
}
