import Foundation

/// 充电策略（MCP `set_charging_strategy` 的取值；魔拟充按官方说明走 `set_usba_charging_mode`）。
/// 名称照小程序「模式」页：智能模式里的自由流、睡眠充对应 FLEXAI_FAST / FLEXAI_SLOW
/// （睡眠充 = 1 是按页面分组推断的），情景模式里的魔拟充、极速单充·C1 对应 6 和 8。
/// 小程序的「苹果全家桶」「自定义」走静态分配表，MCP 不能设置。
public enum ChargingStrategy: Int, CaseIterable, Sendable, Identifiable, Codable {
    case fast = 0
    case slow = 1
    case usbA = 6
    case highPerformance = 7
    case ultraFastSinglePort = 8

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .fast: return "自由流"
        case .slow: return "睡眠充"
        case .usbA: return "魔拟充"
        case .highPerformance: return "性能模式"
        case .ultraFastSinglePort: return "极速单充"
        }
    }

    public var detail: String {
        switch self {
        case .fast: return "FluxAI 多设备按需分配"
        case .slow: return "夜间慢充，避免电池久满电"
        case .usbA: return "小家电用 C 口模拟 A 口"
        case .highPerformance: return "C1 无线损，最大化效率"
        case .ultraFastSinglePort: return "关闭其他口，C1 独享"
        }
    }

    /// 切换前确认时说明会发生什么。
    public var warning: String {
        switch self {
        case .ultraFastSinglePort: return "会关闭其他端口，只给 C1 供电。"
        case .usbA: return "C 口改成模拟 A 口给小家电供电，充电可能短暂中断。"
        default: return "会重新分配功率，充电可能短暂中断。"
        }
    }

    /// 面板详情条里放得下的简短说明。
    public var briefWarning: String {
        switch self {
        case .ultraFastSinglePort: return "会关闭其他口，只留 C1"
        case .usbA: return "C 口改成模拟 A 口"
        default: return "充电可能短暂中断"
        }
    }
}

public enum TemperatureMode: Int, CaseIterable, Sendable, Identifiable {
    case powerFirst = 0
    case temperatureFirst = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .powerFirst: return "功率优先"
        case .temperatureFirst: return "温度优先"
        }
    }
}

public enum DisplayLevel: String, CaseIterable, Sendable, Identifiable {
    case off = "关"
    case low = "低"
    case medium = "中"
    case high = "高"

    public var id: String { rawValue }
}

/// 屏显模式（`set_status_display_mode`，官方说明仅 CP02S 支持）。
public enum StatusDisplayMode: String, CaseIterable, Sendable, Identifiable {
    case idleAnimation = "待机动画优先"
    case power = "功率显示优先"

    public var id: String { rawValue }
}

/// 待机显示（`set_idle_display`，官方说明仅 CP02S 支持）。
public enum IdleDisplay: String, CaseIterable, Sendable, Identifiable {
    case meteor = "流星"
    case petals = "落花"
    case lifeGame = "康威的生命游戏"
    case clock = "时间"

    public var id: String { rawValue }
}

/// `get_display_config` 的结果。CP02 只返回亮度；CP02S 还返回屏显模式、待机显示和整点报时。
/// CP02S 的字段名没有文档，按取值认：字符串对得上枚举值就算，布尔值看键名里有没有 chime。
public struct DisplayConfig: Sendable, Equatable {
    public var level: DisplayLevel?
    public var statusMode: StatusDisplayMode?
    public var idleDisplay: IdleDisplay?
    public var hourlyChime: Bool?

    /// 设备报了 CP02S 才有的显示设置，界面上才显示这几项。
    public var supportsExtendedOptions: Bool {
        statusMode != nil || idleDisplay != nil || hourlyChime != nil
    }

    public init(level: DisplayLevel? = nil, statusMode: StatusDisplayMode? = nil,
                idleDisplay: IdleDisplay? = nil, hourlyChime: Bool? = nil) {
        self.level = level
        self.statusMode = statusMode
        self.idleDisplay = idleDisplay
        self.hourlyChime = hourlyChime
    }

    public init(json: JSONValue) {
        level = json["level"]?.stringValue.flatMap(DisplayLevel.init(rawValue:))
        for (key, value) in json.objectValue ?? [:] where key != "level" {
            if let text = value.stringValue {
                if let mode = StatusDisplayMode(rawValue: text) { statusMode = mode }
                if let idle = IdleDisplay(rawValue: text) { idleDisplay = idle }
            } else if let flag = value.boolValue, key.lowercased().contains("chime") || key.contains("报时") {
                hourlyChime = flag
            }
        }
    }
}

/// `get_machine_facts` 的整机上限，用来检查端口功率分配。
public struct MachineFacts: Sendable, Equatable {
    /// 整机功率上限（W）。
    public var maxPowerBudget: Int
    /// 每口功率上限（W），按端口顺序 A、C1…C4。
    public var portMaxPower: [Int]

    /// 开源固件的单口下限（SW3566_MIN_POWER，默认 15 W）。分配 0 表示这个口按策略默认。
    public static let portMinPower = 15
    /// 2026-10-15 两台 CP02 Pro 实测的 `get_machine_facts`；读不到时用它。
    public static let cp02Pro = MachineFacts(maxPowerBudget: 160, portMaxPower: [60, 140, 140, 140, 140])

    public init(maxPowerBudget: Int, portMaxPower: [Int]) {
        self.maxPowerBudget = maxPowerBudget
        self.portMaxPower = portMaxPower
    }

    public init?(json: JSONValue) {
        guard let budget = json["max_power_budget"]?.intValue,
              let ports = json["ports"]?.arrayValue, !ports.isEmpty else { return nil }
        let sorted = ports.sorted { ($0["index"]?.intValue ?? 0) < ($1["index"]?.intValue ?? 0) }
        let limits = sorted.compactMap { $0["power"]?.intValue }
        guard limits.count == ports.count else { return nil }
        self.init(maxPowerBudget: budget, portMaxPower: limits)
    }

    /// 检查一组分配（按端口顺序，单位 W）：每口 0 或在下限到上限之间，合计不超过整机上限。
    /// 不合格时返回原因，合格返回 nil。
    public func problem(with allocation: [Int]) -> String? {
        guard allocation.count == portMaxPower.count else {
            return "需要 \(portMaxPower.count) 个口的分配值，收到 \(allocation.count) 个"
        }
        for (index, watts) in allocation.enumerated() {
            let name = PortNaming.name(index: index)
            let limit = portMaxPower[index]
            if watts < 0 || (watts != 0 && watts < Self.portMinPower) || watts > limit {
                return "\(name) 要在 \(Self.portMinPower)–\(limit) W 之间，或设为 0（按策略默认）"
            }
        }
        let total = allocation.reduce(0, +)
        if total > maxPowerBudget { return "合计 \(total) W，超过整机上限 \(maxPowerBudget) W" }
        return nil
    }
}

public extension MCPClient {
    /// 开关端口。`ports` 从 1 开始（A=1，C1=2 … C4=5）。
    func setPorts(_ ports: [Int], on: Bool) async throws -> String {
        try await callTool(on ? "turn_on_port" : "turn_off_port",
                           arguments: ["ports": .array(ports.map { .number(Double($0)) })])
    }

    func setStrategy(_ strategy: ChargingStrategy) async throws -> String {
        if strategy == .usbA {
            return try await callTool("set_usba_charging_mode")
        }
        return try await callTool("set_charging_strategy", arguments: ["strategy": .number(Double(strategy.rawValue))])
    }

    func setTemperatureMode(_ mode: TemperatureMode) async throws -> String {
        try await callTool("set_temperature_mode", arguments: ["mode": .number(Double(mode.rawValue))])
    }

    func setDisplayLevel(_ level: DisplayLevel) async throws -> String {
        try await callTool("set_display_intensity", arguments: ["level": .string(level.rawValue)])
    }

    func temperatureMode() async throws -> TemperatureMode? {
        let value = try await callToolJSON("get_temperature_mode")
        return value["mode"]?.intValue.flatMap(TemperatureMode.init(rawValue:))
    }

    func displayConfig() async throws -> DisplayConfig {
        DisplayConfig(json: try await callToolJSON("get_display_config"))
    }

    func machineFacts() async throws -> MachineFacts? {
        MachineFacts(json: try await callToolJSON("get_machine_facts"))
    }

    /// 临时的端口功率分配（`set_port_power_allocation`），按端口顺序 A、C1…C4，单位 W，0 表示按策略默认。
    /// 按开源固件的实现，应用时所有口会重新握手；之后插拔设备或开关端口，设备会回到策略分配。
    func setPowerAllocation(_ watts: [Int]) async throws -> String {
        try await callTool("set_port_power_allocation",
                           arguments: ["power_allocation": .array(watts.map { .number(Double($0)) })])
    }

    func setStatusDisplayMode(_ mode: StatusDisplayMode) async throws -> String {
        try await callTool("set_status_display_mode", arguments: ["mode": .string(mode.rawValue)])
    }

    func setIdleDisplay(_ display: IdleDisplay) async throws -> String {
        try await callTool("set_idle_display", arguments: ["idle_display": .string(display.rawValue)])
    }

    func setHourlyChime(_ enabled: Bool) async throws -> String {
        try await callTool("set_hourly_chime", arguments: ["enabled": .bool(enabled)])
    }
}
