import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var showPicker = false
    @State private var activity: FITActivity?
    @State private var routeLine: RouteLine?
    @State private var filename = ""
    @State private var readingData = false
    @State private var drawingRoute = false
    @State private var importing = false
    @State private var imported = false
    @State private var errorMessage: String?
    @State private var routeToken = UUID()
    private let importer = HealthImporter()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("选择骑行 FIT", systemImage: "doc.badge.plus") { showPicker = true }
                        .disabled(readingData || importing)
                }
                if readingData {
                    Section("摘要") {
                        loadingText("正在读取骑行数据…")
                    }
                } else if let activity {
                    Section("摘要") {
                        summary(activity)
                    }
                }
                if drawingRoute {
                    Section("路线") {
                        loadingText("正在生成路线预览…")
                    }
                } else if let routeLine {
                    Section("路线") {
                        RoutePreview(line: routeLine)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                }
                if let activity {
                    Section {
                        Button {
                            Task { await save(activity) }
                        } label: {
                            HStack {
                                if importing { ProgressView() }
                                Text(imported ? "已写入健康" : "写入 Apple 健康")
                                Spacer()
                                if imported { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            }
                        }
                        .disabled(importing || imported || readingData)
                    } footer: {
                        Text("写入 iGPSPORT 户外骑行的 GPS 路线、距离、速度、圈段及文件中存在的心率/踏频/功率。请勿重复导入。")
                    }
                }
            }
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
            .task { await autoImportIfRequested() }
        }
    }

    @ViewBuilder
    private func summary(_ activity: FITActivity) -> some View {
        LabeledContent("文件", value: filename)
        LabeledContent("运动", value: activity.sportName)
        LabeledContent("开始", value: activity.start.formatted(date: .abbreviated, time: .shortened))
        LabeledContent("骑行时间", value: hms(activity.duration))
        LabeledContent("总耗时", value: hms(activity.elapsed))
        if let distance = activity.distance {
            LabeledContent("距离", value: String(format: "%.2f km", distance / 1000))
        }
        if let speed = activity.avgSpeed {
            LabeledContent("平均速度", value: kmh(speed))
        }
        if let speed = activity.maxSpeed {
            LabeledContent("最大速度", value: kmh(speed))
        }
        if !activity.locations.isEmpty {
            LabeledContent("GPS", value: "\(activity.locations.count) 点")
        }
        if !activity.splits.isEmpty {
            LabeledContent("圈段", value: "\(activity.splits.count) 圈")
        }
        if let ascent = activity.ascent {
            LabeledContent("爬升", value: "\(Int(ascent)) m")
        }
        if let calories = activity.calories {
            LabeledContent("热量", value: "\(Int(calories)) kcal")
        }
        if !activity.heartRates.isEmpty {
            LabeledContent("心率", value: "\(activity.heartRates.count) 点")
        }
    }

    private func loadingText(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func autoImportIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-autoImportDocuments") else { return }
        RideLog.step("-autoImportDocuments", "端到端：从 App Documents 自动读取 FIT 并写入健康")
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fits = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "fit" } ?? []
        guard let url = fits.first else {
            RideLog.fail("-autoImportDocuments", "Documents 里没有 .fit")
            errorMessage = "Documents 里没有 FIT 文件。"
            return
        }
        await load(url)
        guard let activity else { return }
        await save(activity)
    }

    @MainActor
    private func load(_ url: URL) async {
        let token = UUID()
        routeToken = token
        readingData = true
        drawingRoute = false
        activity = nil
        routeLine = nil
        imported = false
        RideLog.phase("选择文件")
        RideLog.step("fileImporter", "用户挑中了一个 FIT", extra: url.lastPathComponent)
        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
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
                var parser = FITParser(data: data)
                return try parser.parse()
            }.value
            guard routeToken == token else {
                RideLog.skip("FITActivity", "用户又选了新文件，丢弃这次解析结果")
                return
            }
            filename = url.lastPathComponent
            activity = parsed
            readingData = false
            RideLog.ok("摘要", "骑行数据已显示在界面上")
            let locations = parsed.locations
            guard locations.count >= 2 else {
                RideLog.skip("RouteLine", "GPS 不足 2 点，不做路线预览", extra: "\(locations.count) 点")
                return
            }
            RideLog.phase("路线预览")
            RideLog.step("RouteLine", "无底图，把经纬度投影成折线", extra: "\(locations.count) 个 GPS 点")
            drawingRoute = true
            let line = await Task.detached(priority: .utility) {
                RouteLine(locations: locations)
            }.value
            guard routeToken == token else {
                RideLog.skip("RoutePreview", "用户又选了新文件，丢弃这次路线预览")
                return
            }
            routeLine = line
            drawingRoute = false
            if let line {
                RideLog.ok("RoutePreview", "路线描线已画到界面", extra: String(format: "%d 点，宽高比 %.2f", line.points.count, line.aspect))
            } else {
                RideLog.fail("RouteLine", "经纬度投影失败，无法描线")
            }
        } catch {
            guard routeToken == token else { return }
            readingData = false
            drawingRoute = false
            RideLog.fail("load", "读取或解析失败", extra: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save(_ activity: FITActivity) async {
        importing = true
        defer { importing = false }
        RideLog.step("写入 Apple 健康", "用户确认把当前骑行写入本机健康")
        do {
            try await importer.save(activity)
            imported = true
            RideLog.ok("写入 Apple 健康", "界面标记为已写入。请勿对同一文件重复导入")
        } catch {
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

private struct RouteLine: Sendable {
    struct Point: Sendable {
        var x: Double
        var y: Double
    }

    let points: [Point]
    let aspect: Double

    init?(locations: [FITActivity.Location]) {
        guard locations.count >= 2 else { return nil }
        let meanLat = locations.reduce(0.0) { $0 + $1.latitude } / Double(locations.count)
        let xScale = max(cos(meanLat * .pi / 180), 0.2)
        let xs = locations.map { $0.longitude * xScale }
        let ys = locations.map(\.latitude)
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
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(minHeight: 160, maxHeight: 240)
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
                                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .accessibilityLabel("骑行路线")
    }
}

extension UTType {
    static let fitActivity = UTType(importedAs: "com.garmin.fit", conformingTo: .data)
}
