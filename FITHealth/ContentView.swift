import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var showPicker = false
    @State private var activity: FITActivity?
    @State private var filename = ""
    @State private var busy = false
    @State private var imported = false
    @State private var errorMessage: String?
    private let importer = HealthImporter()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("选择骑行 FIT", systemImage: "doc.badge.plus") { showPicker = true }
                        .disabled(busy)
                }
                if let activity {
                    Section("摘要") {
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
                    Section {
                        Button {
                            Task { await save(activity) }
                        } label: {
                            HStack {
                                if busy { ProgressView() }
                                Text(imported ? "已写入健康" : "写入 Apple 健康")
                                Spacer()
                                if imported { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            }
                        }
                        .disabled(busy || imported)
                    } footer: {
                        Text("写入 iGPSPORT 户外骑行的 GPS 路线、距离、速度、圈段及文件中存在的心率/踏频/功率。请勿重复导入。")
                    }
                } else if busy {
                    ProgressView("正在读取…")
                }
            }
            .navigationTitle("骑行导入")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.fitActivity], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await load(url) } }
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert("无法完成导入", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    @MainActor
    private func load(_ url: URL) async {
        busy = true
        activity = nil
        imported = false
        defer { busy = false }
        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                var parser = FITParser(data: try Data(contentsOf: url))
                return try parser.parse()
            }.value
            filename = url.lastPathComponent
            activity = parsed
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func save(_ activity: FITActivity) async {
        busy = true
        defer { busy = false }
        do {
            try await importer.save(activity)
            imported = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func hms(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private func kmh(_ metersPerSecond: Double) -> String {
        String(format: "%.1f km/h", metersPerSecond * 3.6)
    }
}

extension UTType {
    static let fitActivity = UTType(importedAs: "com.garmin.fit", conformingTo: .data)
}
