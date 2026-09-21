# iGPSPORT 骑行导入

把 iGPSPORT 码表的 **户外骑行** `.fit` 写入本机 Apple 健康。数据只在手机上处理，无账号、无服务器。

当前按开发者自己的环境使用：**iPhone 17 Pro Max / iOS 27**。

## 紧箍咒

后继开发必须遵守 `.cursor/rules/igpsport-cycling.mdc`：

- 只服务 iGPSPORT 户外骑行（FIT `sport == 2`，且不是室内 `sub_sport == 6`）
- 不要兼容跑步、步行、徒步、游泳、室内骑行或其它品牌/机型
- 不是户外骑行的文件直接拒绝，不要部分导入
- UI 保持单页，不为其它运动加分支

## 运行

用 Xcode 打开 `FITHealth.xcodeproj`，scheme 选 `FITHealth`，目标选已连接的 iPhone，Run。

Cursor 侧已配置官方 Xcode MCP（`xcrun mcpbridge`）。Xcode → Settings → Intelligence 中打开 “Allow external agents to use Xcode tools”。

选择 FIT 文件后点「写入 Apple 健康」，允许本次涉及的写入类型，并允许读取体能消耗（MET）。读取、路线预览和写入都会显示预估耗时；授权约 75 秒、写入按 GPS 点数放宽到最多 90 秒，超时即停止等待。应用的 Documents 会显示在「文件 → 我的 iPhone → FIT 导入」。导入后到健康 App 的这条骑行记录里核对路线、天气和平均强度。请勿重复导入同一文件。

Apple Developer 的 App ID `com.mianshuang.FITHealth` 需要打开 **WeatherKit** 和 HealthKit。天气查不到时不影响骑行本身入库。

## 实测文件

两份都是 iGPSPORT 户外公路骑行（sport 2，sub_sport 7）。放在 `~/Downloads/`，导入前拷进应用 Documents。

### 1 号 `ride-0-2026-09-20-20-19-33.fit`

manufacturer `115`，product `302`。未接心率带 / 踏频器 / 功率计。期望摘要：

| 项 | 期望 |
| --- | --- |
| 距离 | 35.57 km |
| 骑行时间 | 1:45:20（6320 s） |
| 平均速度 | 20.2 km/h（码表一位小数；FIT `enhanced_avg_speed` 为 20.3 km/h / 5.628 m/s） |
| 最大速度 | 36.7 km/h |
| 累计爬升 | 142 m |
| 热量 | 846 kcal |
| 总耗时 | 2:34:29（9269 s） |
| GPS | 6299 点 |
| 圈段 | 7 × 5 km + 0.57 km |
| 心率 / 踏频 / 功率 | 无，不写入 |

### 2 号 `ride-0-2026-05-01-19-09-30.fit`

manufacturer `115`，product `301`。数值不对齐 1 号，只用来补传感器字段。本文件 `enhanced_speed` 全为 0，速度回退到普通 `speed`。

| 项 | 值 |
| --- | --- |
| 开始 | 2026-05-01 19:09:30 |
| 距离 | 42.37 km（不对齐 1 号） |
| 骑行时间 / 总耗时 | 1:42:11 / 3:03:35 |
| 心率 record | 508 点有效（约 106–174） |
| 踏频 record | 712 点有效（约 21–92 rpm） |
| 功率 record | 909 点（含滑行 0 W；峰值 516 W） |
| GPS | 913 点 |

## FIT 里有什么，健康里写什么

码表按 Garmin FIT 活动文件写。1 号没有传感器；2 号有心率 / 踏频 / 功率时，对应采样会一并写入。

### 会写入健康的

| 码表 / FIT | 健康 | 说明 |
| --- | --- | --- |
| sport 2 + 非室内 sub_sport | `HKWorkout` 骑行，室外 | 其它运动或室内骑行直接拒绝 |
| `start_time` + `total_elapsed_time` | 运动起止 | 总耗时是墙钟时间 |
| `total_timer_time` + timer 事件 | 运动时长（不含暂停） | 健康用 pause/resume 还原真实骑行时间。没有 timer 事件时，把休息整段落在结束前 |
| record `position_lat` / `position_long` / `altitude` / `speed` | **`HKWorkoutRoute` GPS 地图** | 半圆坐标转经纬度；高度 `value/5 - 500` 米 |
| session `total_distance` | `distanceCycling` | 按码表 record 累计里程的**增量**写入。不要写成一条覆盖休息的总量，健康会按未暂停时间把距离按比例切掉。GPS 折线只画路线，不参与距离 |
| record `enhanced_speed`（优先，且必须 > 0）或 `speed` | `cyclingSpeed` 采样 | 按 `speedInterval = 5` 每 5 个点取平均后再写入。enhanced 为 0 时回退普通 speed（见 2 号文件） |
| session `enhanced_avg_speed` / `enhanced_max_speed` | `HKMetadataKeyAverageSpeed` / `MaximumSpeed` | 也用于摘要 |
| lap（本机 5 km 自动圈） | `HKWorkoutEvent.lap` | 圈事件不带速度 metadata（健康会崩溃）。圈均速在整场 `iGPSPORTLapAvgSpeedsKmh`。没有圈时按累计距离切 1 km |
| session `total_calories` | `activeEnergyBurned` | 千卡 |
| record `heart_rate` | `heartRate` | 有心率带才有 |
| record `cadence` | `cyclingCadence` | 有踏频传感器才有 |
| record `power` | `cyclingPower` | 有功率计才有 |
| session `total_ascent` / `total_descent` | `HKMetadataKeyElevationAscended` / `ElevationDescended` | 米 |
| session `avg_temperature` | `HKMetadataKeyWeatherTemperature` | 仅当 WeatherKit 没补到温度时，才用码表环境温度 |
| 骑行中点时间 + GPS | `HKMetadataKeyWeatherTemperature` / `Humidity` / `Condition` / `BarometricPressure` | WeatherKit 查中点那一小时，作为整场环境。不查天气曲线 |
| FIT 时间范围 + timer-running | `HKMetadataKeyAverageMETs` | 优先时间加权 Apple Watch `physicalEffort`；没有 Watch 样本时用码表速度按 Compendium 回退。暂停不计入 |
| — | `HKMetadataKeyWorkoutBrandName` = iGPSPORT | 来源标记 |

### FIT 有、健康没有对应类型（不写）

- 坡度、垂直速度、平均/最低/最高海拔（海拔已随路线点写入）
- 环境温度曲线（整场天气用骑行中点查 WeatherKit；码表平均温度只在天气查询失败时回退）
- 左右平衡、踏频/功率分区时间、训练效果、NP/IF/TSS
- 骑行姿势等 event
- FIT 开发者自定义字段

没有心率带、踏频器、功率计时，对应采样是 FIT 无效值，应用不会编造数据。

### 配速

健康对骑行展示的是 **速度（km/h）**，没有单独的「配速」类型。时段速度来自整场平均/最大速度 metadata、稀释后的 `cyclingSpeed`，以及圈段 lap 事件。圈均速写在整场 metadata `iGPSPORTLapAvgSpeedsKmh`。本机自动圈是 5 km；没有 lap 时按 1 km 切。

GPS 路线由 `HKWorkoutBuilder.seriesBuilder(for: .workoutRoute())` 收集点，随 `finishWorkout()` 一并保存并关联。不要再对这个 builder 调用 `finishRoute(with:)`，iOS 会抛错。独立 `HKWorkoutRouteBuilder(healthStore:)` 才需要先保存 Workout 再 `finishRoute`。应用内路线预览只描线，没有底图。

## 文件

- `.cursor/rules/igpsport-cycling.mdc`：范围紧箍咒
- `FITHealth/ContentView.swift`：选文件、摘要、无底图路线描线预览、等待/超时、写入
- `FITHealth/Core/FITParser.swift`：FIT 二进制解析，以及天气中点 / 时间加权 MET 计算
- `FITHealth/HealthImporter.swift`：HealthKit 授权及保存
- `FITHealth/WorkoutEnrichment.swift`：WeatherKit 中点天气、读取 Watch MET
- `FITHealthTests/FITParserTests.swift`：解析测试，可在 Mac 上跑

## 验证

```sh
swift test
```

2026-09-21：解析测试覆盖 1 号公路骑行（35.57 km / 1:45:20 / 爬升 142 m / 846 kcal）和 2 号带心率、踏频、功率的骑行。Xcode MCP 用 iPhone 18 Pro Max 模拟器（iOS 27）验收；真机目标仍是 iPhone 17 Pro Max。

## 接口

- [Garmin FIT Protocol](https://developer.garmin.com/fit/articles/fit-protocol/fit_protocol.html)
- [HKWorkoutBuilder](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder)
- [HKMetadataKeyWeatherTemperature](https://developer.apple.com/documentation/healthkit/hkmetadatakeyweathertemperature)
- [HKMetadataKeyAverageMETs](https://developer.apple.com/documentation/healthkit/hkmetadatakeyaverageMets)
- [WeatherQuery.hourly(startDate:endDate:)](https://developer.apple.com/documentation/weatherkit/weatherquery/hourly(startdate:enddate:))
- [HKWorkoutRouteBuilder](https://developer.apple.com/documentation/healthkit/hkworkoutroutebuilder)
- [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
