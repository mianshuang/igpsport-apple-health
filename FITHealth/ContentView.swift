import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var showPicker = false
    @State private var activity: FITActivity?
    @State private var routeLine: RouteLine?
    @State private var filename = ""
    @State private var wait: WaitState?
    @State private var importing = false
    @State private var imported = false
    @State private var errorMessage: String?
    @State private var routeToken = UUID()
    @State private var importEpoch = 0
    private let importer = HealthImporter()

    private var busy: Bool { wait != nil || importing }

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

                    if let wait {
                        WaitBanner(state: wait)
                    }

                    if let activity, wait?.kind != .reading {
                        summaryCard(activity)
                    }

                    if let routeLine, wait?.kind != .preview {
                        RoutePreview(line: routeLine)
                    }

                    if let activity, wait?.kind != .reading {
                        importButton(activity)
                        Text("只写入 iGPSPORT 户外骑行。请勿重复导入同一文件。")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("骑行导入")
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
            .alert("无法完成导入", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task {
                #if DEBUG
                await autoImportIfRequested()
                #endif
            }
        }
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
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(busy || imported)
    }

    #if DEBUG
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
        routeLine = nil
        imported = false
        wait = WaitState(kind: .reading, estimate: 2, timeout: 20, started: .now)
        RideLog.phase("选择文件")
        RideLog.step("fileImporter", "用户挑中了一个 FIT", extra: url.lastPathComponent)
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                RideLog.step("startAccessingSecurityScopedResource()", "拿到安全作用域读取权限", extra: access ? "已授权" : "无需授权")
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                        RideLog.ok("stopAccessingSecurityScopedResource()", "释放文件访问权限")
                    }
                }
                RideLog.step("Data(contentsOf:)", "把 FIT 读进内存")
                let data = try Data(contentsOf: url)
                RideLog.ok("Data(contentsOf:)", "文件字节已读取", extra: "\(data.count) 字节")
                return data
            }.value
            guard routeToken == token else { return }
            let parseEstimate = RideTiming.parseEstimate(bytes: data.count)
            let parseTimeout = RideTiming.parseTimeout(estimate: parseEstimate)
            wait = WaitState(kind: .reading, estimate: parseEstimate, timeout: parseTimeout, started: .now)
            RideLog.step("FITParser.parse()", "预计解析耗时", extra: "\(RideTiming.secondsLabel(parseEstimate))，超时 \(Int(parseTimeout)) 秒")
            let parsed = try await withTimeout(parseTimeout) {
                try await Task.detached(priority: .userInitiated) {
                    var parser = FITParser(data: data)
                    return try parser.parse()
                }.value
            }
            guard routeToken == token else {
                RideLog.skip("FITActivity", "用户又选了新文件，丢弃这次解析结果")
                return
            }
            filename = url.lastPathComponent
            activity = parsed
            wait = nil
            RideLog.ok("摘要", "骑行数据已显示在界面上")
            let locations = parsed.locations
            guard locations.count >= 2 else {
                RideLog.skip("RouteLine", "GPS 不足 2 点，不做路线预览", extra: "\(locations.count) 点")
                return
            }
            let previewEstimate = RideTiming.previewEstimate(points: locations.count)
            let previewTimeout = RideTiming.previewTimeout(estimate: previewEstimate)
            RideLog.phase("路线预览")
            RideLog.step("RouteLine", "无底图，把经纬度投影成折线", extra: "\(locations.count) 个 GPS 点，\(RideTiming.secondsLabel(previewEstimate))")
            wait = WaitState(kind: .preview, estimate: previewEstimate, timeout: previewTimeout, started: .now)
            let line = try await withTimeout(previewTimeout) {
                await Task.detached(priority: .utility) {
                    RouteLine(locations: locations)
                }.value
            }
            guard routeToken == token else {
                RideLog.skip("RoutePreview", "用户又选了新文件，丢弃这次路线预览")
                return
            }
            routeLine = line
            wait = nil
            if let line {
                RideLog.ok("RoutePreview", "路线描线已画到界面", extra: String(format: "%d 点，宽高比 %.2f", line.points.count, line.aspect))
            } else {
                RideLog.fail("RouteLine", "经纬度投影失败，无法描线")
            }
        } catch {
            guard routeToken == token else { return }
            wait = nil
            RideLog.fail("load", "读取或解析失败", extra: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save(_ activity: FITActivity) async {
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
            try await importer.save(activity) { phase in
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
    enum Kind { case reading, preview, authorizing, writing }
    let kind: Kind
    let estimate: TimeInterval
    let timeout: TimeInterval
    let started: Date

    var title: String {
        switch kind {
        case .reading: "正在读取骑行数据"
        case .preview: "正在生成路线预览"
        case .authorizing: "等待健康授权"
        case .writing: "正在写入 Apple 健康"
        }
    }

    var hint: String {
        switch kind {
        case .reading: "解析 FIT，文件越大越久"
        case .preview: "把 GPS 点描成折线，没有底图"
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

private struct RouteLine: Sendable {
    struct Point: Sendable {
        var x: Double
        var y: Double
    }

    let points: [Point]
    let aspect: Double

    init?(locations: [FITActivity.Location]) {
        let source = RideSampling.previewPoints(locations)
        guard source.count >= 2 else { return nil }
        let meanLat = source.reduce(0.0) { $0 + $1.latitude } / Double(source.count)
        let xScale = max(cos(meanLat * .pi / 180), 0.2)
        let xs = source.map { $0.longitude * xScale }
        let ys = source.map(\.latitude)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let spanX = max(maxX - minX, 1e-8)
        let spanY = max(maxY - minY, 1e-8)
        let padX = spanX * 0.06
        let padY = spanY * 0.06
        let width = spanX + padX * 2
        let height = spanY + padY * 2
        points = zip(xs, ys).map { x, y in
            Point(x: (x - (minX - padX)) / width, y: ((maxY + padY) - y) / height)
        }
        aspect = width / height
    }
}

private struct RoutePreview: View {
    let line: RouteLine

    var body: some View {
        let aspect = min(max(line.aspect, 0.55), 2.4)
        VStack(alignment: .leading, spacing: 10) {
            Text("路线")
                .font(.caption)
                .foregroundStyle(.secondary)
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(minHeight: 148, maxHeight: 220)
                .overlay {
                    Canvas { context, size in
                        guard line.points.count >= 2, size.width > 1, size.height > 1 else { return }
                        var path = Path()
                        let first = line.points[0]
                        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                        for point in line.points.dropFirst() {
                            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                        }
                        context.stroke(path, with: .color(.primary),
                                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    }
                }
                .accessibilityLabel("骑行路线")
        }
        .card()
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
