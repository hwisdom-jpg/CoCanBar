import SwiftUI
import CoCanKit
import CoCanStyle

// 配色、格式、温度标签等和桌面小组件共用的部分在 CoCanStyle 里。

extension EnvironmentValues {
    /// 面板窗口当前是否在屏幕上。不可见时不去读控制状态，下次打开时功率柱重新长出来。
    @Entry var panelVisible = false
    /// 离屏截图模式：菜单、转圈等 AppKit 控件离屏画不出来，换成静态替身。
    @Entry var snapshotMode = false
}

/// 胶囊形按钮（取消 / 确认）。纯 SwiftUI 绘制，离屏截图也能画出来。
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Palette.brand

    func makeBody(configuration: Configuration) -> some View {
        PillButton(configuration: configuration, prominent: prominent, tint: tint)
    }

    private struct PillButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.ink))
                .padding(.horizontal, 10)
                .frame(height: 21)
                .background(Capsule().fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Palette.card)))
                .overlay {
                    if !prominent {
                        Capsule().strokeBorder(Palette.pillStroke, lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }
    }
}

/// 卡片背景：小程序的白色大圆角卡片，阴影很淡。
struct CardBackground: View {
    var radius: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.card)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.cardStroke, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

/// 小程序「电控」页的数据标签：前面一个橙色圆点。
struct DotLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Palette.brand)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Palette.heading)
        }
        .lineLimit(1)
    }
}
