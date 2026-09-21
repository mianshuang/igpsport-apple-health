import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

private enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String {
        switch self { case .light: "浅色"; case .dark: "深色"; case .system: "跟随系统" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .light: .light; case .dark: .dark; case .system: nil }
    }
}

struct ContentView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("appAppearance") private var appearance: AppAppearance = .light

    @State private var showPicker = false
    @State private var activity: FITActivity?
    @State private var mapLocations: [FITActivity.Location] = []
    @State private var snapshot = EnrichmentSnapshot()
    @State private var weatherBusy = false
    @State private var metsBusy = false
    @State private var queryPassFinished = false
    @State private var filename = ""
    @State private var workoutName = "户外骑行"
    @State private var wait: WaitState?
    @State private var importing = false
    @State private var imported = false
    @State private var errorMessage: String?
    @State private var routeToken = UUID()
    @State private var importEpoch = 0
    @State private var importer = HealthImporter()
    @State private var writeOutcomeUncertain = false

    private var busy: Bool { wait != nil || importing || weatherBusy || metsBusy }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Button {
                        showPicker = true
                    } label: {
                        Label("选择骑行 FIT", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(busy)

                    Text("仅支持 igpsport 户外骑行fit 格式数据导入apple health")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let wait {
                        WaitBanner(state: wait)
                    }

                    if let activity, wait?.kind != .reading {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("运动名称").font(.caption).foregroundStyle(.secondary)
                            TextField("户外骑行", text: $workoutName)
                                .textFieldStyle(.roundedBorder)
                                .font(.body)
                                .submitLabel(.done)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(importing || imported)
                                .onSubmit { workoutName = WorkoutDisplay.name(workoutName) }
                                .accessibilityLabel("运动名称")
                            Text("写入后作为 Fitness 里这条骑行的标题。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .card()
                        summaryCard(activity)
                    }

                    if mapLocations.count >= 2, wait?.kind != .reading {
                        RouteMap(locations: mapLocations)
                            .id(activity?.start)
                    }

                    if let activity, wait?.kind != .reading, !imported {
                        QueryChecklist(
                            activity: activity,
                            snapshot: snapshot,
                            weatherBusy: weatherBusy,
                            metsBusy: metsBusy,
                            retryEnabled: queryPassFinished && !busy,
                            onRetryWeather: { Task { await retryWeather(activity) } }
                        )
                    }

                    if let activity, wait?.kind != .reading {
                        if writeOutcomeUncertain {
                            Text("写入结果尚未确认。请先到健康 App 核对记录，核对后重新启动本应用。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        importButton(activity)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("iGPS to Health")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("外观", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .accessibilityLabel("皮肤")
                    .accessibilityValue(appearance.title)
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.fitActivity], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await load(url) } }
                    else {
                        RideLog.fail("fileImporter", "选择器没有返回文件")
                        errorMessage = "没有选中文件。"
                    }
                case .failure(let error):
                    RideLog.fail("fileImporter", "系统文件选择失败", extra: error.localizedDescription)
                    errorMessage = error.localizedDescription
                }
            }
            .onOpenURL { url in
                guard !busy else {
                    errorMessage = "当前操作尚未完成，请完成后重新分享 FIT 文件。"
                    return
                }
                guard url.isFileURL, url.pathExtension.lowercased() == "fit" else {
                    errorMessage = "请选择或分享 iGPSPORT 导出的 .fit 文件。"
                    return
                }
                Task { await load(url) }
            }
            .alert("无法完成导入", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task {
                #if DEBUG && targetEnvironment(simulator)
                await autoImportIfRequested()
                #endif
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .tint((appearance == .dark || (appearance == .system && systemColorScheme == .dark))
              ? Color(red: 0.40, green: 0.87, blue: 0.70)
              : Color(red: 0.02, green: 0.42, blue: 0.33))
    }

    @ViewBuilder
    private func summaryCard(_ activity: FITActivity) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(filename)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                Metric("骑行时间", hms(activity.duration))
                Metric("总耗时", hms(activity.elapsed))
                if let distance = activity.distance {
                    Metric("距离", String(format: "%.2f km", distance / 1000))
                }
                if let speed = activity.avgSpeed {
                    Metric("均速", kmh(speed))
                }
                if let speed = activity.maxSpeed {
                    Metric("极速", kmh(speed))
                }
                if let ascent = activity.ascent {
                    Metric("爬升", "\(Int(ascent)) m")
                }
                if !activity.locations.isEmpty {
                    Metric("GPS", "\(activity.locations.count) 点")
                }
                if !activity.splits.isEmpty {
                    Metric("圈段", "\(activity.splits.count) 圈")
                }
                if !activity.heartRates.isEmpty {
                    Metric("心率", "\(activity.heartRates.count) 点")
                }
                if let calories = activity.calories {
                    Metric("热量", "\(Int(calories)) kcal")
                }
                let cadenceCount = activity.samples.filter { ($0.cadence ?? 0) > 0 }.count
                if cadenceCount > 0 {
                    Metric("踏频", "\(cadenceCount) 点")
                }
                let powerCount = activity.samples.filter { $0.power != nil }.count
                if powerCount > 0 {
                    Metric("功率", "\(powerCount) 点")
                }
            }
        }
        .card()
    }

    private func importButton(_ activity: FITActivity) -> some View {
        let estimate = RideTiming.persistEstimate(activity: activity)
        return Button {
            Task { await save(activity) }
        } label: {
            HStack {
                if imported {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(imported ? "已写入健康" : "写入 Apple 健康")
                Spacer()
                if !imported {
                    Text(RideTiming.secondsLabel(estimate))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color("OnAccent").opacity(0.75))
                }
            }
            .foregroundStyle(Color("OnAccent"))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(busy || imported || writeOutcomeUncertain || !queryPassFinished || weatherBusy || metsBusy)
    }

    #if DEBUG && targetEnvironment(simulator)
    @MainActor
    private func autoImportIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-autoImportDocuments") else { return }
        RideLog.step("-autoImportDocuments", "端到端：从 App Documents 自动读取 FIT 并写入健康")
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fits = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "fit" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard !fits.isEmpty else {
            RideLog.fail("-autoImportDocuments", "Documents 里没有 .fit")
            errorMessage = "Documents 里没有 FIT 文件。"
            return
        }
        for url in fits {
            RideLog.step("-autoImportDocuments", "自动导入", extra: url.lastPathComponent)
            await load(url)
            guard let activity else { continue }
            for _ in 0..<150 where !queryPassFinished {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            imported = false
            await save(activity)
        }
    }
    #endif

    @MainActor
    private func load(_ url: URL) async {
        let token = UUID()
        routeToken = token
        activity = nil
        workoutName = "户外骑行"
        mapLocations = []
        snapshot = EnrichmentSnapshot()
        queryPassFinished = false
        weatherBusy = false
        metsBusy = false
        imported = false
        wait = WaitState(kind: .reading, estimate: 2, timeout: 20, started: .now)
        RideLog.phase("选择文件")
        RideLog.step("fileImporter", "用户挑中了一个 FIT", extra: url.lastPathComponent)
        do {
            let data = try await withTimeout(20) {
                let access = url.startAccessingSecurityScopedResource()
                RideLog.step("startAccessingSecurityScopedResource()", "拿到安全作用域读取权限", extra: access ? "已授权" : "无需授权")
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                        RideLog.ok("stopAccessingSecurityScopedResource()", "释放文件访问权限")
                    }
                }
                RideLog.step("Data(contentsOf:)", "把 FIT 读进内存")
                let data = try FITFileReader.read(url)
                RideLog.ok("Data(contentsOf:)", "文件字节已读取", extra: "\(data.count) 字节")
                return data
            }
            guard routeToken == token else { return }
            let parseEstimate = RideTiming.parseEstimate(bytes: data.count)
            let parseTimeout = RideTiming.parseTimeout(estimate: parseEstimate)
            wait = WaitState(kind: .reading, estimate: parseEstimate, timeout: parseTimeout, started: .now)
            RideLog.step("FITParser.parse()", "预计解析耗时", extra: "\(RideTiming.secondsLabel(parseEstimate))，超时 \(Int(parseTimeout)) 秒")
            let parsed = try await withTimeout(parseTimeout) {
                var parser = FITParser(data: data)
                return try parser.parse()
            }
            guard routeToken == token else {
                RideLog.skip("FITActivity", "用户又选了新文件，丢弃这次解析结果")
                return
            }
            filename = url.lastPathComponent
            activity = parsed
            mapLocations = parsed.locations
            wait = nil
            RideLog.ok("摘要", "骑行数据已显示在界面上")
            if parsed.locations.count < 2 {
                RideLog.skip("RouteMap", "GPS 不足 2 点，不做地图预览", extra: "\(parsed.locations.count) 点")
            }
            await runQueries(parsed, token: token)
        } catch {
            guard routeToken == token else { return }
            wait = nil
            RideLog.fail("load", "读取或解析失败", extra: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runQueries(_ activity: FITActivity, token: UUID) async {
        weatherBusy = true
        metsBusy = true
        queryPassFinished = false
        async let weather = importer.fetchWeather(for: activity)
        async let mets = importer.fetchMETs(for: activity)
        let weatherResult = await weather
        let metsResult = await mets
        guard routeToken == token else { return }
        snapshot.weather = weatherResult
        snapshot.mets = metsResult
        weatherBusy = false
        metsBusy = false
        queryPassFinished = true
    }

    @MainActor
    private func retryWeather(_ activity: FITActivity) async {
        guard !weatherBusy else { return }
        let token = routeToken
        weatherBusy = true
        let weather = await importer.fetchWeather(for: activity)
        guard routeToken == token else { return }
        snapshot.weather = weather
        weatherBusy = false
    }

    @MainActor
    private func save(_ activity: FITActivity) async {
        guard !importing, !imported, !writeOutcomeUncertain else { return }
        importing = true
        importEpoch += 1
        let epoch = importEpoch
        let persistEstimate = RideTiming.persistEstimate(activity: activity)
        wait = WaitState(kind: .authorizing, estimate: RideTiming.authorizeEstimate, timeout: RideTiming.authorizeTimeout, started: .now)
        defer {
            importing = false
            if importEpoch == epoch, wait?.kind == .authorizing || wait?.kind == .writing {
                wait = nil
            }
        }
        RideLog.step("写入 Apple 健康", "用户确认把当前骑行写入本机健康")
        do {
            try await importer.save(activity, enrichment: snapshot, workoutName: WorkoutDisplay.name(workoutName)) { phase in
                Task { @MainActor in
                    guard importEpoch == epoch else { return }
                    switch phase {
                    case .authorizing:
                        wait = WaitState(kind: .authorizing, estimate: RideTiming.authorizeEstimate,
                                         timeout: RideTiming.authorizeTimeout, started: .now)
                    case .writing:
                        wait = WaitState(kind: .writing, estimate: persistEstimate,
                                         timeout: RideTiming.persistTimeout(estimate: persistEstimate), started: .now)
                    }
                }
            }
            guard importEpoch == epoch else { return }
            importEpoch += 1
            wait = nil
            imported = true
            RideLog.ok("写入 Apple 健康", "界面标记为已写入。请勿对同一文件重复导入")
        } catch {
            guard importEpoch == epoch else { return }
            importEpoch += 1
            wait = nil
            RideLog.fail("写入 Apple 健康", "保存失败，界面弹出错误", extra: error.localizedDescription)
            if case ImportError.writeOutcomeUnknown = error { writeOutcomeUncertain = true }
            errorMessage = error.localizedDescription
        }
    }

    private func hms(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private func kmh(_ metersPerSecond: Double) -> String {
        String(format: "%.1f km/h", metersPerSecond * 3.6)
    }
}

private struct WaitState {
    enum Kind { case reading, authorizing, writing }
    let kind: Kind
    let estimate: TimeInterval
    let timeout: TimeInterval
    let started: Date

    var title: String {
        switch kind {
        case .reading: "正在读取骑行数据"
        case .authorizing: "等待健康授权"
        case .writing: "正在写入 Apple 健康"
        }
    }

    var hint: String {
        switch kind {
        case .reading: "解析 FIT，文件越大越久"
        case .authorizing: "系统弹窗请点「全选」再「允许」"
        case .writing: "写入路线、天气、平均强度和圈段"
        }
    }
}

private struct WaitBanner: View {
    let state: WaitState

    var body: some View {
        TimelineView(.periodic(from: state.started, by: 0.25)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(state.started))
            let remaining = max(0, state.estimate - elapsed)
            let overtime = elapsed > state.estimate
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(state.title)
                        .font(.headline)
                    Spacer()
                    Text(overtime ? "已超过预估" : "还剩 \(max(1, Int(remaining.rounded()))) 秒")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(elapsed / max(state.estimate, 0.1), 1))
                    .tint(overtime ? Color.orange : Color.primary)
                Text(overtime
                     ? "超过 \(Int(state.timeout.rounded())) 秒将停止等待。"
                     : state.hint)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QueryChecklist: View {
    let activity: FITActivity
    let snapshot: EnrichmentSnapshot
    let weatherBusy: Bool
    let metsBusy: Bool
    let retryEnabled: Bool
    let onRetryWeather: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("查询补全")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Link("Weather data by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                    Text("·").foregroundStyle(.tertiary)
                    Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }
                .font(.system(size: 10))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      alignment: .leading, spacing: 16) {
                row(title: "平均强度", value: metsText, ok: snapshot.mets.value != nil, busy: metsBusy)
                row(title: "天气温度", value: temperatureText, ok: willWriteTemperature, busy: weatherBusy)
                ForEach(otherWeatherRows, id: \.title) { item in
                    row(title: item.title, value: item.value, ok: item.ok, busy: weatherBusy)
                }
            }
            if let error = snapshot.weather.error, !weatherBusy {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: onRetryWeather) {
                Text(weatherBusy ? "正在查询天气…" : "重试")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!retryEnabled || weatherBusy)
            .accessibilityLabel("重新查询 Open-Meteo 天气")
        }
        .card()
    }

    private var otherWeatherRows: [(title: String, value: String?, ok: Bool)] {
        let rows: [(title: String, value: String?, ok: Bool)] = [
            ("天气湿度", humidityText, snapshot.weather.humidity != nil),
            ("天气状况", conditionText, snapshot.weather.condition != nil),
            ("气压", pressureText, snapshot.weather.pressureHPa != nil)
        ]
        return rows.filter { $0.ok } + rows.filter { !$0.ok }
    }

    private var willWriteTemperature: Bool {
        snapshot.weather.temperatureCelsius != nil || activity.avgTemperature != nil
    }

    private var temperatureText: String? {
        if let value = snapshot.weather.temperatureCelsius {
            return String(format: "%.1f°C", value)
        }
        if let value = activity.avgTemperature {
            return String(format: "码表 %.1f°C", value)
        }
        return "暂无数据"
    }

    private var humidityText: String? {
        if let value = snapshot.weather.humidity {
            return String(format: "%.0f%%", value * 100)
        }
        return "暂无数据"
    }

    private var conditionText: String? {
        snapshot.weather.conditionName ?? "暂无数据"
    }

    private var pressureText: String? {
        if let value = snapshot.weather.pressureHPa {
            return String(format: "%.0f hPa", value)
        }
        return "暂无数据"
    }

    private var metsText: String? {
        if let value = snapshot.mets.value {
            return String(format: "%.1f MET · %@", value, snapshot.mets.fromWatch ? "Watch" : "速度回退")
        }
        return snapshot.mets.error
    }

    @ViewBuilder
    private func row(title: String, value: String?, ok: Bool, busy: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                    .font(.subheadline)
                    .foregroundStyle(ok ? Color("BrandAccent") : Color.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let value, !busy {
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if busy {
                    Text("查询中…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)

        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(busy ? "查询中" : (value ?? "未获取到"))")
    }

}

private struct RouteMap: View {
    let locations: [FITActivity.Location]
    @State private var position: MapCameraPosition = .automatic

    private var coordinates: [CLLocationCoordinate2D] {
        RideSampling.previewPoints(locations).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    var body: some View {
        let coords = coordinates
        VStack(alignment: .leading, spacing: 10) {
            Text("路线")
                .font(.caption)
                .foregroundStyle(.secondary)
            Map(position: $position, interactionModes: [.pan, .zoom]) {
                if coords.count >= 2 {
                    MapPolyline(coordinates: coords)
                        .stroke(.orange, lineWidth: 3.5)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("骑行路线")
            .onAppear {
                position = .region(Self.region(for: coords))
            }
        }
        .card()
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion()
        }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.35, 0.004),
                longitudeDelta: max((maxLon - minLon) * 1.35, 0.004)
            )
        )
    }
}

private extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension UTType {
    static let fitActivity = UTType(importedAs: "com.garmin.fit", conformingTo: .data)
}
