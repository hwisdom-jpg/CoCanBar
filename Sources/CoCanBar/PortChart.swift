import SwiftUI
import CoCanKit
import CoCanStyle

/// 端口的显示状态。
enum PortKind: Equatable {
    case unknown, off, idle, standby, charging

    init(_ port: PortMetrics?) {
        // 没有读数，或者云端读不到开关状态（没在供电的口）：画成空槽，不猜开没开
        guard let port, let on = port.isPoweredOn else {
            self = .unknown
            return
        }
        if !on {
            self = .off
        } else if port.isCharging {
            self = .charging
        } else {
            self = port.attached ? .standby : .idle
        }
    }
}

/// 端口功率图，照小程序「电控」页的充电图谱：每个口一根胶囊柱，柱子右边是协议和读数，
/// 下面一条橙色基线和端口名。柱高按当前功率占该口上限（A 60 W、C 140 W）取平方根，
/// 小功率也看得出高低；颜色用场景模式的端口配色。
/// 整块高度固定，读数变化只改柱高和数字，不会挤动别的内容。
struct PortChart: View {
    let ports: [PortMetrics]
    let limits: [Int]
    let colors: ModeColors
    let stale: Bool
    let selected: Int?
    /// false 时柱子缩到最低。面板每次打开时从低处依次长到实际高度。
    let grown: Bool
    let namespace: Namespace.ID
    let select: (Int) -> Void

    static let height: CGFloat = 53

    var body: some View {
        HStack(spacing: 0) {
            if ports.isEmpty {
                // 还没有读数时放占位柱子，读数到了只换内容
                ForEach(0..<5, id: \.self) { index in
                    column(index: index, order: index, port: nil)
                }
            } else {
                ForEach(Array(ports.enumerated()), id: \.element.id) { order, port in
                    column(index: port.id, order: order, port: port)
                }
            }
        }
        .frame(height: Self.height)
    }

    private func column(index: Int, order: Int, port: PortMetrics?) -> some View {
        PortColumn(name: PortNaming.name(index: index),
                   port: port,
                   limit: limits.indices.contains(index) ? limits[index] : 140,
                   color: colors.port(index),
                   stale: stale,
                   selected: port != nil && selected == port?.id,
                   grown: grown,
                   delay: Double(order) * 0.045,
                   namespace: namespace) {
            if let port { select(port.id) }
        }
    }
}

/// 一个口的一列：柱子和读数、基线、端口名、选中下划线。
private struct PortColumn: View {
    let name: String
    let port: PortMetrics?
    let limit: Int
    let color: Color
    let stale: Bool
    let selected: Bool
    let grown: Bool
    let delay: Double
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barWidth: CGFloat = 9
    private static let barHeight: CGFloat = 28
    private static let labelWidth: CGFloat = 31

    private var kind: PortKind { PortKind(port) }
    private var watts: Double { port?.watts ?? 0 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 4) {
                    PowerBar(kind: kind, ratio: grown ? ratio : 0, color: color,
                             width: Self.barWidth, height: Self.barHeight)
                        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.7).delay(delay),
                                   value: grown)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: ratio)
                    readout
                        .frame(width: Self.labelWidth, height: Self.barHeight, alignment: .bottomLeading)
                }
                .opacity(stale ? 0.45 : 1)
                .padding(.top, 5)
                Rectangle()
                    .fill(Palette.brand.opacity(stale ? 0.3 : 0.8))
                    .frame(height: 1)
                lane {
                    Text(name)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(selected ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(Palette.ink))
                        .opacity(stale ? 0.6 : 1)
                        .fixedSize()
                }
                .frame(height: 14)
                .padding(.top, 2)
                lane {
                    if selected {
                        Capsule()
                            .fill(Palette.brand)
                            .frame(width: 12, height: 2.5)
                            .matchedGeometryEffect(id: "underline", in: namespace)
                    }
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.columnSelected)
                        .matchedGeometryEffect(id: "column", in: namespace)
                } else if hovering && port != nil {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.columnHover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 占位柱子不响应点击；不用 disabled，免得系统把它整体调暗
        .allowsHitTesting(port != nil)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: kind)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(port == nil ? "\(name)：还没有读数" : "\(name)：点按查看详情和开关")
        .accessibilityLabel("\(name) 口")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 和柱子同一条竖线上的内容（端口名、下划线）：以柱子为中心，右边空出读数那一栏。
    private func lane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            content()
                .frame(width: Self.barWidth)
            Color.clear
                .frame(width: Self.labelWidth, height: 1)
        }
    }

    /// 柱高比例：平方根让 5–30 W 的手机充电也有明显高低。
    private var ratio: Double {
        guard kind == .charging, limit > 0 else { return 0 }
        return min(max((watts / Double(limit)).squareRoot(), 0), 1)
    }

    @ViewBuilder
    private var readout: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch kind {
            case .charging:
                Text(protocolText)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.unit)
                    .opacity(protocolText.isEmpty ? 0 : 1)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(PanelFormat.watts(watts))
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText(value: watts))
                    Text("W")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.unit)
                }
                .animation(.snappy(duration: 0.35), value: watts)
            case .standby:
                Text("待机")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            case .idle:
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("0")
                        .font(.system(size: 11, weight: .bold))
                    Text("W")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Palette.unit)
            case .off:
                Text("关闭")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.unit)
            case .unknown:
                Text("–")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.unit)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var protocolText: String {
        guard let port else { return "" }
        let short = port.shortProtocol
        let volts = PanelFormat.volts(port.volts)
        return short.isEmpty ? volts : "\(short) \(volts)"
    }

    private var accessibilityValue: String {
        switch kind {
        case .charging: return "\(PanelFormat.watts(watts)) 瓦，\(protocolText)"
        case .standby: return "已连接，未取电"
        case .idle: return "空闲"
        case .off: return "已关闭"
        case .unknown: return "读不到状态"
        }
    }
}

/// 一根功率柱：浅色底槽；在充时从下往上填该口的颜色；空闲是斜线底纹；
/// 已连接未取电是描边；关闭只画虚线框。
struct PowerBar: View {
    let kind: PortKind
    let ratio: Double
    let color: Color
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            switch kind {
            case .off:
                Capsule()
                    .strokeBorder(Palette.unit, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            case .idle:
                Capsule()
                    .fill(Palette.track)
                    .overlay {
                        Hatch()
                            .stroke(Palette.hatch, lineWidth: 1)
                            .clipShape(Capsule())
                    }
            case .standby:
                Capsule()
                    .fill(Palette.track)
                    .overlay { Capsule().strokeBorder(color.opacity(0.85), lineWidth: 1) }
            case .charging:
                Capsule()
                    .fill(Palette.track)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .top, endPoint: .bottom))
                    // 最低也是一个圆点，表示在充
                    .frame(height: max(width, height * ratio))
            case .unknown:
                Capsule()
                    .fill(Palette.track)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
    }
}

/// 接口图形：A 口是带舌片的矩形，C 口是胶囊。
struct PortGlyph: View {
    let typeA: Bool
    var scale: CGFloat = 1

    var body: some View {
        if typeA {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 0.8 * scale)
                    .strokeBorder(lineWidth: scale)
                Rectangle()
                    .frame(width: 8 * scale, height: 1.2 * scale)
                    .padding(.top, 1.4 * scale)
            }
            .frame(width: 14 * scale, height: 5 * scale)
        } else {
            ZStack {
                Capsule()
                    .strokeBorder(lineWidth: scale)
                Capsule()
                    .frame(width: 6 * scale, height: 1.2 * scale)
            }
            .frame(width: 13 * scale, height: 5 * scale)
        }
    }
}

/// 品牌色的开关（小程序「实时调度」里的橙色开关）。显示的是端口的实际状态，点按只发出请求，读数刷新后才变。
struct PortSwitch: View {
    let isOn: Bool
    let enabled: Bool
    let name: String
    var size: CGFloat = 1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SwitchCapsule(isOn: isOn, size: size)
                .animation(.snappy(duration: 0.22), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle("\(name) 口供电", isOn: Binding(get: { isOn }, set: { _ in action() }))
        }
    }
}

/// 云端读不到开关状态的口：不画开关（画了就是在猜开没开），给「打开」「关闭」两个按钮。
/// 这样的口都没在供电（在供电的口能确定开着），关掉不会让设备断电，所以不再确认。
struct PowerButtons: View {
    let enabled: Bool
    let name: String
    let action: (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button("打开") { action(true) }
                .help("打开 \(name)（云端读不到它现在开没开）")
            Button("关闭") { action(false) }
                .help("关闭 \(name)（云端读不到它现在开没开）")
        }
        .buttonStyle(PillButtonStyle())
        .disabled(!enabled)
    }
}

/// 小转圈。离屏截图时换成静态图标。
struct Spinner: View {
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.mini)
        }
    }
}
