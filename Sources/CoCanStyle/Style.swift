import SwiftUI
import CoCanKit

// 面板和桌面小组件共用的配色、格式和小部件。

/// 面板配色，照小程序的 wxss 和场景模式配色表（scene-mode.js）：
/// 奶油底 #F8F5EC、白卡片、正文 #121212、单位灰 #B8B8B8、品牌橙红 #FF4719、在线绿 #00C539。
/// 深色外观换成同一色调的暖深灰。
public enum Palette {
    public static let brand = Color(hex: 0xFF4719)
    public static let brandLight = Color(hex: 0xFF7A4D)
    public static let online = Color(hex: 0x00C539)
    public static let danger = Color(hex: 0xFF3B30)

    /// 面板和「调节」页的底色。
    public static let canvas = Adaptive(light: Color(hex: 0xF8F5EC), dark: Color(hex: 0x1C1B19))
    public static let card = Adaptive(light: .white, dark: Color(hex: 0x292724))
    public static let cardStroke = Adaptive(light: .black.opacity(0.03), dark: .white.opacity(0.06))
    /// 卡片里的浅底（详情条、表头），和面板底色一个色调。
    public static let inset = Adaptive(light: Color(hex: 0xF8F5EC), dark: Color(hex: 0x211F1C))
    /// 大数字和端口名。
    public static let ink = Adaptive(light: Color(hex: 0x121212), dark: Color(hex: 0xF3F0EA))
    /// 卡片外的分组标题（小程序「实时调度」那种灰）。
    public static let heading = Adaptive(light: Color(hex: 0x6E6A62), dark: Color(hex: 0xA9A49A))
    /// 数字后面的单位。
    public static let unit = Adaptive(light: Color(hex: 0xB8B8B8), dark: Color(hex: 0x7A766E))
    /// 功率柱的底槽、关闭的开关。
    public static let track = Adaptive(light: Color(hex: 0xEFEBE1), dark: Color(hex: 0x3A3733))
    public static let hatch = Adaptive(light: .black.opacity(0.08), dark: .white.opacity(0.08))
    public static let pillStroke = Adaptive(light: Color(hex: 0xDCD7CB), dark: .white.opacity(0.16))
    public static let pill = Adaptive(light: Color(hex: 0xF1EDE4), dark: .white.opacity(0.1))
    public static let columnSelected = Adaptive(light: Color(hex: 0xFFF2EC), dark: Color(hex: 0x3B2B24))
    public static let columnHover = Adaptive(light: Color(hex: 0xFAF8F3), dark: Color(hex: 0x302E2A))

    /// 只在离屏截图时垫在面板下面。
    public static let snapshotBackdrop = canvas
}

/// 小程序每个场景模式的主题色和五个口的配色（A、C1…C4）。
/// 魔拟充和临时分配在小程序里用的是默认（自由流）的配色。
public struct ModeColors: Sendable {
    public let theme: Color
    public let ports: [Color]

    public init(theme: Color, ports: [Color]) {
        self.theme = theme
        self.ports = ports
    }

    public static let standard = ModeColors(theme: Color(hex: 0xFFA51E),
                                            ports: [0x2C89FB, 0xFFC444, 0xFFA51E, 0xFF921E, 0xFF7315].map(Color.init(hex:)))
    public static let sleep = ModeColors(theme: Color(hex: 0x9965C7),
                                         ports: [0x4460DD, 0xB787E0, 0x9965C7, 0x7B3FB0, 0x56297E].map(Color.init(hex:)))
    public static let performance = ModeColors(theme: Color(hex: 0xFF7F17), ports: standard.ports)
    public static let singlePort = ModeColors(theme: Color(hex: 0x1DC6FA),
                                              ports: [0x46BC2C, 0x71CBE7, 0x22ADEE, 0x0381E1, 0x0058C4].map(Color.init(hex:)))

    public static func of(_ strategy: ChargingStrategy?) -> ModeColors {
        switch strategy {
        case .slow: return .sleep
        case .highPerformance: return .performance
        case .ultraFastSinglePort: return .singlePort
        case .fast, .usbA, nil: return .standard
        }
    }

    public func port(_ index: Int) -> Color {
        ports.isEmpty ? theme : ports[min(max(index, 0), ports.count - 1)]
    }
}

public extension ChargingStrategy {
    /// 小程序「模式」页的图标，换成意思相近的 SF Symbols。
    var symbol: String {
        switch self {
        case .fast: return "fanblades"
        case .slow: return "moon.zzz"
        case .usbA: return "arrow.triangle.2.circlepath"
        case .highPerformance: return "gauge.with.dots.needle.67percent"
        case .ultraFastSinglePort: return "arrow.right.circle"
        }
    }

    /// 「调节」页模式格子里的两行说明，按词断行。
    var tileDetail: String {
        switch self {
        case .fast: return "FluxAI\n多设备按需分配"
        case .slow: return "夜间慢充\n避免电池久满电"
        case .usbA: return "小家电模式\nC 口模拟 A 口"
        case .highPerformance: return "C1 无线损\n最大化效率"
        case .ultraFastSinglePort: return "关闭其他口\nC1 独享"
        }
    }
}

public extension TemperatureMode {
    /// 小程序里的叫法：功率优先 = 性能温控（更高效能），温度优先 = 安心温控（更少发热）。
    var displayName: String {
        switch self {
        case .powerFirst: return "性能温控"
        case .temperatureFirst: return "安心温控"
        }
    }

    var detail: String {
        switch self {
        case .powerFirst: return "更高效能"
        case .temperatureFirst: return "更少发热"
        }
    }

    var symbol: String {
        switch self {
        case .powerFirst: return "thermometer.high"
        case .temperatureFirst: return "thermometer.low"
        }
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 按浅色 / 深色外观取颜色。用 SwiftUI 环境判断，离屏渲染时指定 colorScheme 也能生效。
public struct Adaptive: ShapeStyle {
    public let light: Color
    public let dark: Color

    public init(light: Color, dark: Color) {
        self.light = light
        self.dark = dark
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? dark : light
    }
}

/// 面板里数字和文字的格式。
public enum PanelFormat {
    /// 功率数字（单位另外显示）：100 W 以下保留一位小数。
    public static func watts(_ value: Double) -> String {
        value >= 99.95 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// 电压：接近整数时不带小数（20V、5V），PPS 这类可调电压保留一位（9.1V）。
    public static func volts(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.15 ? String(format: "%.0fV", value) : String(format: "%.1fV", value)
    }

    public static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(minutes, 1)) 分钟" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(rest) 分"
    }

    /// 端口柱旁边放得下的快充协议简称（全称见 `FastChargeProtocol.name`）。
    public static func shortProtocol(_ code: Int) -> String {
        switch code {
        case 0: return "USB"
        case 1: return "QC2"
        case 2: return "QC3"
        case 3: return "QC3+"
        case 4: return "SFCP"
        case 5: return "AFC"
        case 6: return "FCP"
        case 7: return "SCP"
        case 8, 9: return "VOOC"
        case 10: return "SVOOC"
        case 11: return "TFCP"
        case 12: return "UFCS"
        case 13, 14: return "PE"
        case 15, 16: return "PD"
        case 17, 20: return "AVS"
        case 18, 21: return "PPS"
        case 19: return "EPR"
        default: return ""
        }
    }
}

/// 在线状态的小胶囊：在线是绿底白字（小程序首页的「在线」），连接中和离线是灰的。
public struct StatusBadge: View {
    public enum Status: Sendable {
        case online, connecting, offline
    }

    public let status: Status
    public var text: String?

    public init(status: Status, text: String? = nil) {
        self.status = status
        self.text = text
    }

    public var body: some View {
        Text(text ?? defaultText)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(status == .online ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Capsule().fill(status == .online ? AnyShapeStyle(Palette.online) : AnyShapeStyle(Palette.track)))
            .lineLimit(1)
            .fixedSize()
            .animation(.easeInOut(duration: 0.25), value: status)
    }

    private var defaultText: String {
        switch status {
        case .online: return "在线"
        case .connecting: return "连接中"
        case .offline: return "离线"
        }
    }
}

/// 芯片温度：前面一个按档位着色的圆点（凉爽绿、温和黄、偏热橙红、过热红，不认识的档位灰色）。
public struct TemperatureLabel: View {
    public let temperature: PortTemperature
    public var size: CGFloat = 12

    public init(temperature: PortTemperature, size: CGFloat = 12) {
        self.temperature = temperature
        self.size = size
    }

    public static func color(_ temperature: PortTemperature) -> Color {
        switch temperature.level {
        case 0: return Palette.online
        case 1: return ModeColors.standard.theme
        case 2: return Palette.brand
        case 3: return Palette.danger
        default: return .secondary
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.color(temperature))
                .frame(width: size * 0.45, height: size * 0.45)
            Text(temperature.label)
                .font(.system(size: size))
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("芯片温度\(temperature.label)")
    }
}

/// 品牌色的开关外形（小程序「实时调度」里的橙色开关）。面板的开关和小组件的开关按钮共用。
public struct SwitchCapsule: View {
    public let isOn: Bool
    public var size: CGFloat = 1

    public init(isOn: Bool, size: CGFloat = 1) {
        self.isOn = isOn
        self.size = size
    }

    public var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(Palette.track))
            .frame(width: 30 * size, height: 17 * size)
            .overlay(alignment: isOn ? .trailing : .leading) {
                // 圆点定死尺寸，左右对齐才有位移
                Circle()
                    .fill(.white)
                    .frame(width: 13 * size, height: 13 * size)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(2 * size)
            }
    }
}

/// 斜线底纹（小程序里空闲端口的柱子）。
public struct Hatch: Shape {
    public var spacing: CGFloat = 3

    public init(spacing: CGFloat = 3) {
        self.spacing = spacing
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
