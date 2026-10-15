import SwiftUI
import WidgetKit

#if SWIFT_PACKAGE
// SwiftPM 构建这个目标只用来离屏截图：`swift run CoCanBarWidget <输出目录>`。
// 正式的小组件扩展由 Xcode 工程打包（scripts/build-app.sh），那里走下面的 WidgetBundle。
@main
struct WidgetSnapshotTool {
    @MainActor
    static func main() {
        WidgetSnapshots.render(arguments: CommandLine.arguments)
    }
}
#else
@main
struct CoCanBarWidgets: WidgetBundle {
    var body: some Widget {
        ChargerWidget()
    }
}
#endif
