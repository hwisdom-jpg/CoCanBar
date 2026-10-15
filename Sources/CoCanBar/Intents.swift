import AppIntents
import CoCanKit
import CoCanStyle

// 「快捷指令」里的动作。都在菜单栏 app 里执行（app 没开时系统会先把它打开），
// 和面板用同一个模型：读数走局域网，控制用钥匙串里的 MCP 地址，令牌不会交给快捷指令。

// MARK: - 设备和选项

/// 菜单栏 app 里添加过的一台小电拼。
struct ChargerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "小电拼"
    static let defaultQuery = ChargerQuery()

    /// PSN。
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ device: DeviceConfig) {
        id = device.psn
        name = device.name
    }
}

struct ChargerQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ChargerEntity] {
        let model = try await AppModel.ready()
        return identifiers.compactMap { model.device($0).map(ChargerEntity.init) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ChargerEntity] {
        try await AppModel.ready().devices.map(ChargerEntity.init)
    }
}

enum ChargerPort: String, AppEnum, CaseIterable {
    case a, c1, c2, c3, c4

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "端口"
    static let caseDisplayRepresentations: [ChargerPort: DisplayRepresentation] = [
        .a: "A 口", .c1: "C1", .c2: "C2", .c3: "C3", .c4: "C4",
    ]

    /// `PortMetrics.id`。
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var name: String { PortNaming.name(index: index) }
}

enum PortAction: String, AppEnum, CaseIterable {
    case on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "开关"
    static let caseDisplayRepresentations: [PortAction: DisplayRepresentation] = [.on: "打开", .off: "关闭"]
}

enum StrategyOption: String, AppEnum, CaseIterable {
    case fast, slow, usbA, highPerformance, ultraFastSinglePort

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "充电策略"
    static let caseDisplayRepresentations: [StrategyOption: DisplayRepresentation] = [
        .fast: DisplayRepresentation(title: "自由流", subtitle: "多设备按需分配"),
        .slow: DisplayRepresentation(title: "睡眠充", subtitle: "夜间慢充，避免电池久满电"),
        .usbA: DisplayRepresentation(title: "魔拟充", subtitle: "C 口模拟 A 口给小家电供电"),
        .highPerformance: DisplayRepresentation(title: "性能模式", subtitle: "C1 无线损，最大化效率"),
        .ultraFastSinglePort: DisplayRepresentation(title: "极速单充", subtitle: "关闭其他口，C1 独享"),
    ]

    var strategy: ChargingStrategy {
        switch self {
        case .fast: return .fast
        case .slow: return .slow
        case .usbA: return .usbA
        case .highPerformance: return .highPerformance
        case .ultraFastSinglePort: return .ultraFastSinglePort
        }
    }
}

enum TemperatureOption: String, AppEnum, CaseIterable {
    case powerFirst, temperatureFirst

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "温控"
    static let caseDisplayRepresentations: [TemperatureOption: DisplayRepresentation] = [
        .powerFirst: DisplayRepresentation(title: "性能温控", subtitle: "更高效能"),
        .temperatureFirst: DisplayRepresentation(title: "安心温控", subtitle: "更少发热"),
    ]

    var mode: TemperatureMode { self == .powerFirst ? .powerFirst : .temperatureFirst }
}

enum BrightnessOption: String, AppEnum, CaseIterable {
    case off, low, medium, high

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "屏幕亮度"
    static let caseDisplayRepresentations: [BrightnessOption: DisplayRepresentation] = [
        .off: "关", .low: "低", .medium: "中", .high: "高",
    ]

    var level: DisplayLevel {
        switch self {
        case .off: return .off
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

enum ChargerIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case noDevice
    case unknownDevice
    case offline(String)
    case noMCP(String)
    case noPort(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "菜单栏 app 还没准备好，请稍后再试"
        case .noDevice: return "还没有添加小电拼，先在菜单栏 app 的设置里添加"
        case .unknownDevice: return "菜单栏 app 里没有这台设备"
        case .offline(let name): return "「\(name)」现在读不到，确认它和这台 Mac 在同一个局域网"
        case .noMCP(let name): return "「\(name)」还没配好 MCP，先在菜单栏 app 的设置里添加 MCP 地址"
        case .noPort(let name): return "「\(name)」没有这个口"
        case .failed(let text): return "\(text)"
        }
    }
}

extension AppModel {
    /// 快捷指令可能比 app 的界面先跑起来（系统刚把 app 打开），最多等 3 秒。
    static func ready() async throws -> AppModel {
        for _ in 0..<30 {
            if let running { return running }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChargerIntentError.appNotReady
    }

    /// 快捷指令里选的设备；没选时用第一台。
    func intentDevice(_ entity: ChargerEntity?) throws -> DeviceConfig {
        guard let entity else {
            guard let first = devices.first else { throw ChargerIntentError.noDevice }
            return first
        }
        guard let device = device(entity.id) else { throw ChargerIntentError.unknownDevice }
        return device
    }

    /// 要发控制命令的设备：必须配好 MCP。控制走云端，Mac 不在同一个局域网也能发。
    func controllableDevice(_ entity: ChargerEntity?) throws -> DeviceConfig {
        let device = try intentDevice(entity)
        guard mcpConfigured.contains(device.psn) else { throw ChargerIntentError.noMCP(device.name) }
        return device
    }

    /// 先读一次最新数据（局域网读不到时马上读云端）；读不到就报不在线。
    func freshMetrics(_ device: DeviceConfig) async throws -> DeviceMetrics {
        await refresh(device.psn, cloudNow: true)
        guard isOnline(device.psn), let metrics = runtime[device.psn]?.metrics else {
            throw ChargerIntentError.offline(device.name)
        }
        return metrics
    }
}

extension AppIntent {
    /// 执行前问一句；用户点取消时抛错，动作不再继续。macOS 14 上只有旧接口。
    func confirm(_ dialog: IntentDialog, action: ConfirmationActionName) async throws {
        if #available(macOS 15.0, *) {
            try await requestConfirmation(actionName: action, dialog: dialog)
        } else {
            try await (LegacyConfirmation(intent: self) as any LegacyConfirming).confirm(dialog, action: action)
        }
    }
}

// macOS 14 只有旧的确认接口，而它整个标了弃用。经协议调用一层，免得每次编译都报这条警告。
private protocol LegacyConfirming {
    func confirm(_ dialog: IntentDialog, action: ConfirmationActionName) async throws
}

private struct LegacyConfirmation<Intent: AppIntent>: LegacyConfirming {
    let intent: Intent

    @available(*, deprecated)
    func confirm(_ dialog: IntentDialog, action: ConfirmationActionName) async throws {
        try await intent.requestConfirmation(result: .result(dialog: dialog), confirmationActionName: action)
    }
}

// MARK: - 读数

struct ReadChargerPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "读取小电拼功率"
    static let description: IntentDescription? = IntentDescription(
        "读取小电拼现在的输出功率（瓦），不选端口时是各口合计。读数来自局域网，Mac 要和小电拼在同一个网络。")

    @Parameter(title: "设备", description: "不选时读第一台")
    var charger: ChargerEntity?

    @Parameter(title: "端口", description: "不选时读各口合计")
    var port: ChargerPort?

    static var parameterSummary: some ParameterSummary {
        Summary("读取 \(\.$charger) \(\.$port) 的功率")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let model = try await AppModel.ready()
        let device = try model.intentDevice(charger)
        let metrics = try await model.freshMetrics(device)
        let watts: Double
        let label: String
        if let port {
            guard let reading = metrics.ports.first(where: { $0.id == port.index }) else {
                throw ChargerIntentError.noPort(device.name)
            }
            watts = reading.watts
            label = "\(device.name) \(port.name)"
        } else {
            watts = metrics.totalWatts
            label = device.name
        }
        let value = (watts * 10).rounded() / 10
        return .result(value: value, dialog: "\(label)：\(PanelFormat.watts(watts)) W")
    }
}

struct ReadChargerStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "读取小电拼状态"
    static let description: IntentDescription? = IntentDescription(
        "读取小电拼各口的状态：开关、功率、电压、协议、认出的设备和本次充电的电量，返回一段文字。")

    @Parameter(title: "设备", description: "不选时读第一台")
    var charger: ChargerEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("读取 \(\.$charger) 的状态")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = try await AppModel.ready()
        let device = try model.intentDevice(charger)
        let metrics = try await model.freshMetrics(device)
        let source = model.isCloud(device.psn) ? "（云端读数）" : ""
        var lines = ["\(device.name)：合计 \(PanelFormat.watts(metrics.totalWatts)) W\(source)"]
        for port in metrics.ports {
            let name = PortNaming.name(index: port.id)
            guard let on = port.isPoweredOn else {
                // 云端读不到开关状态，只说看得到的
                lines.append("\(name)：\(port.attached ? "已连接，没有供电" : "没接设备")（开关状态未知）")
                continue
            }
            guard on else {
                lines.append("\(name)：已关闭")
                continue
            }
            guard port.attached else {
                lines.append("\(name)：空闲")
                continue
            }
            var parts = ["\(PanelFormat.watts(port.watts)) W"]
            if port.watts > 0 {
                parts.append(PanelFormat.volts(port.volts))
                let protocolName = port.shortProtocol
                if !protocolName.isEmpty { parts.append(protocolName) }
            }
            if let identity = model.identity(device.psn, port: port) {
                if let deviceName = identity.displayName { parts.append(deviceName) }
                if let battery = identity.battery { parts.append("电量 \(battery.percent)%") }
            }
            if let energy = model.sessionEnergy(device.psn, port: port) {
                parts.append("本次 \(SessionEnergy.format(mWh: energy))")
            }
            if let temperature = model.temperature(device.psn, port: port) { parts.append(temperature.label) }
            lines.append("\(name)：" + parts.joined(separator: " · "))
        }
        let text = lines.joined(separator: "\n")
        return .result(value: text, dialog: "\(text)")
    }
}

// MARK: - 控制

struct SetChargerPortIntent: AppIntent {
    static let title: LocalizedStringResource = "开关小电拼端口"
    static let description: IntentDescription? = IntentDescription(
        "打开或关闭小电拼的一个口。通过官方 MCP 发送，要先在菜单栏 app 里配好 MCP 地址。")

    @Parameter(title: "设备", description: "不选时用第一台")
    var charger: ChargerEntity?

    @Parameter(title: "端口")
    var port: ChargerPort

    @Parameter(title: "操作", default: .off)
    var action: PortAction

    @Parameter(title: "关闭正在用的口前确认", description: "口上插着设备时先问一句，免得误关正在充电的设备", default: true)
    var confirmInUse: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) \(\.$charger) 的 \(\.$port)") {
            \.$confirmInUse
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await AppModel.ready()
        let device = try model.controllableDevice(charger)
        let turnOn = action == .on
        if !turnOn, confirmInUse {
            await model.refresh(device.psn)
            let reading = model.isOnline(device.psn)
                ? model.runtime[device.psn]?.metrics?.ports.first { $0.id == port.index } : nil
            if let reading, reading.isInUse {
                let who = model.identity(device.psn, port: reading)?.displayName ?? "设备"
                try await confirm("\(device.name) 的 \(port.name) 正在给\(who)供电，确定关闭吗？", action: .turnOff)
            } else if reading == nil {
                try await confirm("读不到 \(device.name) 现在的状态，确定关闭 \(port.name) 吗？", action: .turnOff)
            }
        }
        if let error = await model.setPort(psn: device.psn, index: port.index, on: turnOn) {
            throw ChargerIntentError.failed(error)
        }
        return .result(dialog: "\(turnOn ? "已打开" : "已关闭") \(device.name) 的 \(port.name)")
    }
}

struct SetChargingStrategyIntent: AppIntent {
    static let title: LocalizedStringResource = "切换小电拼充电策略"
    static let description: IntentDescription? = IntentDescription(
        "切换小电拼的充电策略（场景模式）。切换会重新分配功率，充电可能短暂中断；极速单充会关闭 C1 以外的口。")

    @Parameter(title: "设备", description: "不选时用第一台")
    var charger: ChargerEntity?

    @Parameter(title: "策略")
    var strategy: StrategyOption

    @Parameter(title: "切换前确认", description: "和面板一样先问一句；自动化里可以关掉", default: true)
    var confirm: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$charger) 切换到 \(\.$strategy)") {
            \.$confirm
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await AppModel.ready()
        let device = try model.controllableDevice(charger)
        let target = strategy.strategy
        if confirm {
            try await confirm("把 \(device.name) 切换到「\(target.title)」？\(target.warning)", action: .set)
        }
        if let error = await model.setStrategy(psn: device.psn, target) { throw ChargerIntentError.failed(error) }
        return .result(dialog: "\(device.name) 已切换到「\(target.title)」")
    }
}

struct SetTemperatureModeIntent: AppIntent {
    static let title: LocalizedStringResource = "设置小电拼温控"
    static let description: IntentDescription? = IntentDescription(
        "性能温控（功率优先）或安心温控（温度优先，更少发热）。")

    @Parameter(title: "设备", description: "不选时用第一台")
    var charger: ChargerEntity?

    @Parameter(title: "温控")
    var mode: TemperatureOption

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$charger) 的温控设为 \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await AppModel.ready()
        let device = try model.controllableDevice(charger)
        if let error = await model.setTemperature(psn: device.psn, mode.mode) { throw ChargerIntentError.failed(error) }
        return .result(dialog: "\(device.name) 的温控已设为\(mode.mode.displayName)")
    }
}

struct SetDisplayBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "设置小电拼屏幕亮度"
    static let description: IntentDescription? = IntentDescription("设置小电拼屏幕的亮度，可以关掉屏幕。")

    @Parameter(title: "设备", description: "不选时用第一台")
    var charger: ChargerEntity?

    @Parameter(title: "亮度")
    var level: BrightnessOption

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$charger) 的屏幕亮度设为 \(\.$level)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await AppModel.ready()
        let device = try model.controllableDevice(charger)
        if let error = await model.setDisplay(psn: device.psn, level.level) { throw ChargerIntentError.failed(error) }
        return .result(dialog: "\(device.name) 的屏幕亮度已设为「\(level.level.rawValue)」")
    }
}

// MARK: - 快捷指令 app 和聚焦搜索里直接出现的动作

struct CoCanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReadChargerPowerIntent(),
                    phrases: ["用\(.applicationName)读取功率", "\(.applicationName)现在多少瓦"],
                    shortTitle: "读取功率", systemImageName: "bolt")
        AppShortcut(intent: ReadChargerStatusIntent(),
                    phrases: ["用\(.applicationName)读取状态"],
                    shortTitle: "读取状态", systemImageName: "list.bullet.rectangle")
        AppShortcut(intent: SetChargerPortIntent(),
                    phrases: ["用\(.applicationName)开关端口"],
                    shortTitle: "开关端口", systemImageName: "power")
        AppShortcut(intent: SetChargingStrategyIntent(),
                    phrases: ["用\(.applicationName)切换充电策略"],
                    shortTitle: "充电策略", systemImageName: "fanblades")
    }
}
