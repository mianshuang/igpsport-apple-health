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

选择 FIT 文件后点「写入 Apple 健康」，允许本次涉及的写入类型。应用的 Documents 会显示在「文件 → 我的 iPhone → FIT 导入」。导入后到健康 App 的这条骑行记录里核对路线。请勿重复导入同一文件。

## 实测文件

`~/Downloads/ride-0-2026-09-20-20-19-33.fit`（iGPSPORT，FIT manufacturer `115`，product `302`，运动名 `Road Cycling`）：

| 项 | 值 |
| --- | --- |
| 运动 | 骑行 / 公路（sport 2，sub_sport 7） |
| 距离 | 35.57 km |
| 骑行时间 `total_timer_time` | 1:45:20（6320 s） |
| 总耗时 `total_elapsed_time` | 2:34:29（9269 s） |
| 移动时间 `total_moving_time` | 与骑行时间相同 |
| 平均 / 最大速度 | 20.3 / 36.7 km/h |
| 爬升 / 下降 | 142 / 137 m |
| 热量 | 846 kcal |
| 环境温度 | 平均 24℃，最高 26℃ |
| GPS record | 6299 / 6315 点（约 1 Hz） |
| 圈段 | 7 × 5 km + 0.57 km |
| 计时事件 | 73 条 pause / resume |
| 心率 / 踏频 / 功率 | 本文件未接传感器，FIT 中为无效值，不写入 |

## FIT 里有什么，健康里写什么

码表按 Garmin FIT 活动文件写。下面以这次公路骑行为准；接了心率带 / 踏频器 / 功率计时，对应采样会一并写入。

### 会写入健康的

| 码表 / FIT | 健康 | 说明 |
| --- | --- | --- |
| sport 2 + 非室内 sub_sport | `HKWorkout` 骑行，室外 | 其它运动或室内骑行直接拒绝 |
| `start_time` + `total_elapsed_time` | 运动起止 | 总耗时是墙钟时间 |
| `total_timer_time` + timer 事件 | 运动时长（不含暂停） | 健康用 pause/resume 还原真实骑行时间。没有 timer 事件时，把休息整段落在结束前 |
| record `position_lat` / `position_long` / `altitude` / `speed` | **`HKWorkoutRoute` GPS 地图** | 半圆坐标转经纬度；高度 `value/5 - 500` 米 |
| session `total_distance` | `distanceCycling` | 米，一条总量 |
| record `enhanced_speed`（优先）或 `speed` | `cyclingSpeed` 采样 | m/s，健康里可看速度曲线 |
| session `enhanced_avg_speed` / `enhanced_max_speed` | `HKMetadataKeyAverageSpeed` / `MaximumSpeed` | 也用于摘要 |
| lap（本机 5 km 自动圈） | `HKWorkoutEvent.lap` | 圈平均/最大速度放事件 metadata。没有圈时按累计距离切 1 km |
| session `total_calories` | `activeEnergyBurned` | 千卡 |
| record `heart_rate` | `heartRate` | 有心率带才有 |
| record `cadence` | `cyclingCadence` | 有踏频传感器才有 |
| record `power` | `cyclingPower` | 有功率计才有 |
| session `total_ascent` / `total_descent` | `HKMetadataKeyElevationAscended` / `ElevationDescended` | 米 |
| session `avg_temperature` | `HKMetadataKeyWeatherTemperature` | 码表环境温度，不是体温 |
| — | `HKMetadataKeyWorkoutBrandName` = iGPSPORT | 来源标记 |

### FIT 有、健康没有对应类型（不写）

- 坡度、垂直速度、平均/最低/最高海拔（海拔已随路线点写入）
- 环境温度曲线（只有整场平均温度能进天气 metadata）
- 左右平衡、踏频/功率分区时间、训练效果、NP/IF/TSS
- 骑行姿势等 event
- FIT 开发者自定义字段

没有心率带、踏频器、功率计时，对应采样是 FIT 无效值，应用不会编造数据。

### 配速

健康对骑行展示的是 **速度（km/h）**，没有单独的「配速」类型。时段速度来自整场平均/最大速度 metadata、逐秒 `cyclingSpeed`，以及圈段 lap 事件上的平均速度。本机自动圈是 5 km；没有 lap 时按 1 km 切。

## 文件

- `.cursor/rules/igpsport-cycling.mdc`：范围紧箍咒
- `FITHealth/ContentView.swift`：选文件、摘要、写入
- `FITHealth/Core/FITParser.swift`：FIT 二进制解析
- `FITHealth/HealthImporter.swift`：HealthKit 授权及保存
- `FITHealthTests/FITParserTests.swift`：解析测试，可在 Mac 上跑

## 验证

```sh
swift test
```

2026-09-21：解析测试通过，含真实 iGPSPORT 公路骑行文件，并拒绝非骑行 / 室内骑行。Xcode MCP 曾在 iPhone 18 Pro 模拟器（iOS 27）构建并启动；真机 iPhone 17 Pro Max 需连接后再导入验收路线。

## 接口

- [Garmin FIT Protocol](https://developer.garmin.com/fit/articles/fit-protocol/fit_protocol.html)
- [HKWorkoutBuilder](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder)
- [HKWorkoutRouteBuilder](https://developer.apple.com/documentation/healthkit/hkworkoutroutebuilder)
- [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
