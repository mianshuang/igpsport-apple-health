import SwiftUI

@main
struct FITHealthApp: App {
    init() {
        RideLog.phase("启动")
        RideLog.ok("FITHealthApp", "进入单页导入界面，等待选择 iGPSPORT 户外骑行 FIT")
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
