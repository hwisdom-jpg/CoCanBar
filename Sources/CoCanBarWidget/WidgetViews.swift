import SwiftUI
import WidgetKit
import CoCanKit
import CoCanStyle

// 小组件的三种尺寸。配色和面板一样照小程序：白卡片、品牌橙红、每个口一种颜色（随充电策略变）。
// 视图只依赖传进来的 entry 和 family，离屏截图时也能直接画。

struct ChargerWidgetContent: View {
    let entry: ChargerEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            if let device = entry.device {
                switch family {
                case .systemSmall: SmallChargerView(entry: entry, device: device)
                case .systemMedium: MediumChargerView(entry: entry, device: device)
                default: LargeChargerView(entry: entry, device: device)
                }
            } else {
                EmptyChargerView(hasSnapshot: entry.snapshot != nil)
            }
        }
        .foregroundStyle(Palette.ink)
    }
}

// MARK: - 三种尺寸

struct SmallChargerView: View {
    let entry: ChargerEntry
    let device: WidgetSnapshot.Device

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                DeviceName(name: device.name, size: 12.5)
                Spacer(minLength: 2)
                ReadingTime(entry: entry, device: device, size: 10)
                RefreshButton(size: 9)
            }
            Spacer(minLength: 6)
            TotalWatts(watts: device.totalWatts, size: 36)
                .opacity(entry.isStale || !device.online ? 0.45 : 1)
            ChargingSummary(entry: entry, device: device, size: 11)
            Spacer(minLength: 8)
            PortStrip(device: device)
        }
        .padding(14)
    }
}

struct MediumChargerView: View {
    let entry: ChargerEntry
    let device: WidgetSnapshot.Device

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    DeviceName(name: device.name, size: 13)
                    Spacer(minLength: 2)
                    RefreshButton(size: 9.5)
                }
                ReadingTime(entry: entry, device: device, size: 10, showsSource: true)
                Spacer(minLength: 4)
                TotalWatts(watts: device.totalWatts, size: 32)
                    .opacity(entry.isStale || !device.online ? 0.45 : 1)
                ChargingSummary(entry: entry, device: device, size: 10.5)
                Spacer(minLength: 6)
                RecentPowerChart(values: device.recentWatts, color: ModeColors.of(device.chargingStrategy).theme)
                    .frame(height: 26)
            }
            .frame(width: 124)

            VStack(spacing: 2) {
                ForEach(device.ports) { port in
                    CompactPortRow(port: port, color: device.portColor(port.id), pending: entry.pendingPort == port.id)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(14)
    }
}

struct LargeChargerView: View {
    let entry: ChargerEntry
    let device: WidgetSnapshot.Device

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                DeviceName(name: device.name, size: 14)
                StatusBadge(status: entry.isStale ? .connecting : (device.online ? .online : .offline),
                            text: entry.isStale ? "未更新" : nil)
                Spacer(minLength: 4)
                ReadingTime(entry: entry, device: device, size: 10.5, showsOffline: false, showsSource: true)
                RefreshButton(size: 10)
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    TotalWatts(watts: device.totalWatts, size: 34)
                        .opacity(entry.isStale || !device.online ? 0.45 : 1)
                    ChargingSummary(entry: entry, device: device, size: 11)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    RecentPowerChart(values: device.recentWatts, color: ModeColors.of(device.chargingStrategy).theme)
                        .frame(width: 150, height: 40)
                    Text("最近 30 分钟")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.unit)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(device.ports.enumerated()), id: \.element.id) { index, port in
                    if index > 0 {
                        Rectangle().fill(Palette.cardStroke).frame(height: 1).padding(.leading, 36)
                    }
                    LargePortRow(port: port, device: device, entry: entry)
                }
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.inset))

            LargeFooter(entry: entry, device: device)
        }
        .padding(14)
    }
}

/// 还没有数据，或者还没添加设备。
struct EmptyChargerView: View {
    let hasSnapshot: Bool

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.brand)
            Text("小电拼")
                .font(.system(size: 13, weight: .semibold))
            Text(hasSnapshot ? "先在菜单栏「小电拼」的设置里添加设备" : "打开菜单栏里的「小电拼」后显示读数")
                .font(.system(size: 11))
                .foregroundStyle(Palette.heading)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 部件

struct DeviceName: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Text(name)
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
    }
}

/// 读数时间（24 小时制，和中文界面一致）。读数过时了换成「停在 14:05」，离线时写离线；
/// 中、大尺寸在小组件自己读局域网时加上「直读」。
struct ReadingTime: View {
    let entry: ChargerEntry
    let device: WidgetSnapshot.Device
    let size: CGFloat
    var showsOffline = true
    var showsSource = false

    static let format = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current, calendar: .current)

    var body: some View {
        Group {
            if let readAt = device.readAt {
                let time = readAt.formatted(Self.format)
                if entry.isStale {
                    Text("停在 \(time)").foregroundStyle(Palette.brand)
                } else if !device.online, showsOffline {
                    Text("离线 · \(time)").foregroundStyle(Palette.heading)
                } else if entry.isDirect, showsSource {
                    Text("\(time) · 直读").foregroundStyle(Palette.unit)
                } else {
                    Text(time).foregroundStyle(Palette.unit)
                }
            } else {
                Text("还没读到").foregroundStyle(Palette.heading)
            }
        }
        .font(.system(size: size, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// 刷新按钮：菜单栏 app 在运行时请它马上读一次，没在运行时小组件自己读局域网。
struct RefreshButton: View {
    let size: CGFloat

    var body: some View {
        Button(intent: WidgetRefreshIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Palette.unit)
                .frame(width: size + 7, height: size + 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("刷新读数")
    }
}

struct TotalWatts: View {
    let watts: Double
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(PanelFormat.watts(watts))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
            Text("W")
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.unit)
        }
        .lineLimit(1)
        // 竖直方向不许被挤小；横向放不下（三位数加宽字体）时才缩
        .fixedSize(horizontal: false, vertical: true)
        .widgetAccentable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("总功率 \(PanelFormat.watts(watts)) 瓦")
    }
}

struct ChargingSummary: View {
    let entry: ChargerEntry
    let device: WidgetSnapshot.Device
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(Palette.heading)
            .lineLimit(1)
    }

    private var text: String {
        if !device.online { return "这台 Mac 现在读不到它" }
        switch device.chargingCount {
        case 0: return device.ports.contains(where: \.attached) ? "插着设备，没有在充" : "没有设备在充电"
        case let count: return "\(count) 个口在充电"
        }
    }
}

/// 小尺寸底部的五个口：在充的口是彩色的柱子，空闲是浅槽，关掉的口是斜线。
struct PortStrip: View {
    let device: WidgetSnapshot.Device

    var body: some View {
        HStack(spacing: 5) {
            ForEach(device.ports) { port in
                VStack(spacing: 3) {
                    PortBar(port: port, color: device.portColor(port.id))
                        .frame(height: 5)
                    Text(port.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(port.isCharging ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Palette.unit))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.ports.map { "\($0.name) \(PortState(port: $0).spoken)" }.joined(separator: "，"))
    }
}

struct PortBar: View {
    let port: WidgetSnapshot.Port
    let color: Color

    var body: some View {
        switch PortState(port: port) {
        case .off:
            Capsule().fill(Palette.track).overlay(Hatch(spacing: 3).stroke(Palette.hatch, lineWidth: 1).clipShape(Capsule()))
        case .idle, .attached:
            Capsule().fill(Palette.track)
        case .charging:
            Capsule().fill(color)
        }
    }
}

/// 端口名的小方块：在充时是端口色，空闲时浅底，关闭时斜线。
struct PortBadge: View {
    let port: WidgetSnapshot.Port
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        let state = PortState(port: port)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(state == .charging ? AnyShapeStyle(color) : AnyShapeStyle(Palette.track))
            .overlay {
                if state == .off {
                    Hatch(spacing: 3).stroke(Palette.hatch, lineWidth: 1)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                }
            }
            .overlay {
                Text(port.name)
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(state == .charging ? AnyShapeStyle(.white)
                                     : state == .off ? AnyShapeStyle(Palette.unit) : AnyShapeStyle(Palette.ink))
            }
            .frame(width: size, height: size)
    }
}

enum PortState: Equatable {
    case off, idle, attached, charging

    init(port: WidgetSnapshot.Port) {
        if !port.poweredOn {
            self = .off
        } else if port.isCharging {
            self = .charging
        } else if port.attached {
            self = .attached
        } else {
            self = .idle
        }
    }

    var spoken: String {
        switch self {
        case .off: return "已关闭"
        case .idle: return "空闲"
        case .attached: return "插着设备"
        case .charging: return "在充电"
        }
    }
}

/// 中尺寸右边的一行：口名、设备（或状态）、功率。
struct CompactPortRow: View {
    let port: WidgetSnapshot.Port
    let color: Color
    let pending: Bool

    var body: some View {
        HStack(spacing: 7) {
            PortBadge(port: port, color: color, size: 20)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(pending ? AnyShapeStyle(Palette.danger)
                                 : port.attached ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Palette.heading))
                .lineLimit(1)
            Spacer(minLength: 2)
            if port.isCharging {
                PortWatts(watts: port.watts, size: 12.5)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var title: String {
        if pending { return "再点一次关闭" }
        switch PortState(port: port) {
        case .off: return "已关闭"
        case .idle: return "空闲"
        case .attached, .charging: return port.deviceName ?? (port.isCharging ? "正在充电" : "插着设备")
        }
    }
}

/// 设备电池电量：图标随电量变。
struct BatteryText: View {
    let percent: Int
    let size: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: size + 1))
            Text("\(percent)%")
                .font(.system(size: size))
                .monospacedDigit()
        }
        .foregroundStyle(Palette.heading)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电量 \(percent)%")
    }

    private var symbol: String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct PortWatts: View {
    let watts: Double
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(PanelFormat.watts(watts))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("W")
                .font(.system(size: size * 0.7, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.unit)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// 大尺寸的一行：口名、设备和详情、功率、开关。
struct LargePortRow: View {
    let port: WidgetSnapshot.Port
    let device: WidgetSnapshot.Device
    let entry: ChargerEntry

    var body: some View {
        HStack(spacing: 9) {
            PortBadge(port: port, color: device.portColor(port.id), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: port.attached ? .semibold : .regular))
                        .foregroundStyle(port.attached ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Palette.heading))
                        .lineLimit(1)
                    if port.attached, let battery = port.batteryPercent {
                        BatteryText(percent: battery, size: 10)
                    }
                }
                if !details.isEmpty || temperature != nil {
                    HStack(spacing: 5) {
                        if !details.isEmpty {
                            Text(details).lineLimit(1)
                        }
                        if let temperature {
                            TemperatureLabel(temperature: temperature, size: 10)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.heading)
                }
            }
            Spacer(minLength: 4)
            if port.isCharging {
                PortWatts(watts: port.watts, size: 14)
            }
            if device.controllable {
                PortSwitchButton(port: port, device: device, entry: entry)
            }
        }
        .frame(height: 43)
    }

    private var title: String {
        switch PortState(port: port) {
        case .off: return "已关闭"
        case .idle: return "空闲"
        case .attached: return port.deviceName ?? "插着设备，没有在充"
        case .charging: return port.deviceName ?? "正在充电"
        }
    }

    private var temperature: PortTemperature? { port.attached ? port.temperatureLevel : nil }

    private var details: String {
        guard port.attached else { return "" }
        var parts: [String] = []
        if port.isCharging {
            parts.append(PanelFormat.volts(port.volts))
            let name = PanelFormat.shortProtocol(port.fcProtocol)
            if !name.isEmpty { parts.append(name) }
        }
        if let energy = port.sessionEnergyMWh { parts.append("本次 \(SessionEnergy.format(mWh: energy))") }
        return parts.joined(separator: " · ")
    }
}

/// 开关按钮。显示的是端口的实际状态，点了以后等菜单栏 app 执行完、快照更新才变。
struct PortSwitchButton: View {
    let port: WidgetSnapshot.Port
    let device: WidgetSnapshot.Device
    let entry: ChargerEntry

    var body: some View {
        let pending = entry.pendingPort == port.id
        Button(intent: WidgetPortSwitchIntent(psn: device.psn, port: port.id, turnOn: !port.poweredOn, inUse: port.inUse)) {
            if pending {
                Text("关闭？")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 17)
                    .background(Capsule().fill(Palette.danger))
            } else {
                SwitchCapsule(isOn: port.poweredOn, size: 0.95)
            }
        }
        .buttonStyle(.plain)
        .disabled(!entry.canSwitch)
        .opacity(entry.canSwitch ? 1 : 0.4)
        .accessibilityLabel(port.poweredOn ? "关闭 \(port.name)" : "打开 \(port.name)")
    }
}

struct LargeFooter: View {
    let entry: ChargerEntry
    let device: WidgetSnapshot.Device

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Kind { case pending, message(isError: Bool), warning, hint }

    private var kind: (Kind, String) {
        if let port = entry.pendingPort {
            return (.pending, "\(PortNaming.name(index: port)) 正在用，10 秒内再点一次才会关闭")
        }
        if let message = entry.message { return (.message(isError: message.isError), message.text) }
        if !entry.appRunning {
            if entry.directFailed { return (.warning, "菜单栏 app 没开，小组件也读不到局域网") }
            if entry.isDirect {
                return (.hint, device.controllable ? "菜单栏 app 没开：小组件直接读局域网，开关要先打开 app"
                                                   : "菜单栏 app 没开：读数由小组件直接读局域网")
            }
            return (.hint, device.controllable ? "菜单栏 app 没在运行，开关要先打开它" : "菜单栏 app 没在运行")
        }
        if !device.controllable { return (.hint, "在「小电拼」里配好 MCP 后，这里可以开关端口") }
        if entry.isStale { return (.hint, "读数超过 15 分钟没更新，点右上角刷新") }
        if !device.online { return (.hint, "Mac 和小电拼不在同一个网络时读不到实时数据") }
        let energy = device.ports.compactMap(\.sessionEnergyMWh).reduce(0, +)
        return (.hint, energy > 0 ? "各口本次共充 \(SessionEnergy.format(mWh: energy))" : "")
    }

    private var text: String { kind.1 }

    private var symbol: String? {
        switch kind.0 {
        case .pending: return "hand.tap"
        case .message(let isError): return isError ? "exclamationmark.triangle.fill" : "checkmark.circle"
        case .warning: return "wifi.exclamationmark"
        case .hint: return nil
        }
    }

    private var color: AnyShapeStyle {
        switch kind.0 {
        case .pending, .warning: return AnyShapeStyle(Palette.brand)
        case .message(let isError): return isError ? AnyShapeStyle(Palette.danger) : AnyShapeStyle(Palette.heading)
        case .hint: return AnyShapeStyle(Palette.unit)
        }
    }
}

/// 最近 30 分钟的合计功率，每分钟一个点；没有记录的分钟断开。
struct RecentPowerChart: View {
    let values: [Double?]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let peak = max((values.compactMap { $0 }.max() ?? 0) * 1.15, 5)
            let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
            let point = { (index: Int, value: Double) in
                CGPoint(x: CGFloat(index) * step, y: size.height - CGFloat(value / peak) * (size.height - 2) - 1)
            }
            let segments = Self.segments(values)
            ZStack {
                Rectangle()
                    .fill(Palette.track)
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    if segment.count == 2, segment[0].0 == segment[1].0 {
                        // 前后都没有记录的单独一个点（比如 app 没开时小组件刚读了一次），画成圆点
                        Circle()
                            .fill(color)
                            .frame(width: 4, height: 4)
                            .position(point(segment[0].0, segment[0].1))
                    }
                    Path { path in
                        guard let first = segment.first else { return }
                        path.move(to: CGPoint(x: point(first.0, first.1).x, y: size.height))
                        for item in segment { path.addLine(to: point(item.0, item.1)) }
                        path.addLine(to: CGPoint(x: point(segment[segment.count - 1].0, 0).x, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        guard let first = segment.first else { return }
                        path.move(to: point(first.0, first.1))
                        for item in segment.dropFirst() { path.addLine(to: point(item.0, item.1)) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 连续有值的几段；单独一个点也算一段（重复一次，画成圆点）。
    static func segments(_ values: [Double?]) -> [[(Int, Double)]] {
        var result: [[(Int, Double)]] = []
        var current: [(Int, Double)] = []
        for (index, value) in values.enumerated() {
            if let value {
                current.append((index, value))
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.count == 1 ? [$0[0], ($0[0].0, $0[0].1)] : $0 }
    }
}

extension WidgetSnapshot.Device {
    var chargingStrategy: ChargingStrategy? { strategy.flatMap(ChargingStrategy.init(rawValue:)) }

    func portColor(_ index: Int) -> Color { ModeColors.of(chargingStrategy).port(index) }
}
