import Foundation

/// `GET /metrics.json` 里单个端口的读数。
///
/// 单位（2026-10-15 用两路数据核对过）：current 是 mA，voltage / vin_value 是 mV，power_budget 是 W。
/// `session_charge` 不是 mWh，只用它的增量推算电量，见 `SessionEnergy`。
public struct PortMetrics: Sendable, Equatable, Identifiable {
    /// 从 0 开始；MCP 的端口号是 id + 1。
    public let id: Int
    public let active: Bool
    public let state: String
    /// 设备上报的当前类型，会随模式变化（例如 C4 走 USB 普通充电时报 "A"），不能用来命名端口。
    public let portType: String
    public let attached: Bool
    public let chargingDurationSeconds: Int
    public let fcProtocol: Int
    public let currentMilliamps: Int
    public let voltageMillivolts: Int
    public let inputMillivolts: Int
    public let powerBudgetWatts: Int
    /// 充电会话号，每次插入换一个；和 MCP `get_port_details` 的 `session_id` 是同一个计数。
    public let sessionID: Int?
    /// 本次会话的电量计数，一直在涨；单位不是 mWh，见 `SessionEnergy`。
    public let sessionCharge: Int?

    public init(id: Int, active: Bool, state: String, portType: String, attached: Bool,
                chargingDurationSeconds: Int, fcProtocol: Int, currentMilliamps: Int,
                voltageMillivolts: Int, inputMillivolts: Int, powerBudgetWatts: Int, sessionID: Int? = nil,
                sessionCharge: Int? = nil) {
        self.id = id
        self.active = active
        self.state = state
        self.portType = portType
        self.attached = attached
        self.chargingDurationSeconds = chargingDurationSeconds
        self.fcProtocol = fcProtocol
        self.currentMilliamps = currentMilliamps
        self.voltageMillivolts = voltageMillivolts
        self.inputMillivolts = inputMillivolts
        self.powerBudgetWatts = powerBudgetWatts
        self.sessionID = sessionID
        self.sessionCharge = sessionCharge
    }

    public var watts: Double { Double(currentMilliamps) * Double(voltageMillivolts) / 1_000_000 }
    public var volts: Double { Double(voltageMillivolts) / 1000 }
    public var amps: Double { Double(currentMilliamps) / 1000 }
    public var isCharging: Bool { attached && currentMilliamps > 0 }
    /// 端口是否开着。固件的端口状态有 ACTIVE / INACTIVE / ATTACHED / OPENING 等，INACTIVE 视为关闭。
    public var isPoweredOn: Bool { active && state.uppercased() != "INACTIVE" }
    /// 开着并且插着设备：关掉会让设备断电，界面上先确认。
    public var isInUse: Bool { isPoweredOn && attached }
}

extension PortMetrics: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, active, state, attached, current, voltage
        case portType = "port_type"
        case chargingDurationSeconds = "charging_duration_seconds"
        case fcProtocol = "fc_protocol"
        case vinValue = "vin_value"
        case powerBudget = "power_budget"
        case sessionID = "session_id"
        case sessionCharge = "session_charge"
    }

    // 字段缺失时用默认值，固件升级加减字段不至于整份解析失败
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        portType = try c.decodeIfPresent(String.self, forKey: .portType) ?? ""
        attached = try c.decodeIfPresent(Bool.self, forKey: .attached) ?? false
        chargingDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .chargingDurationSeconds) ?? 0
        fcProtocol = try c.decodeIfPresent(Int.self, forKey: .fcProtocol) ?? 255
        currentMilliamps = try c.decodeIfPresent(Int.self, forKey: .current) ?? 0
        voltageMillivolts = try c.decodeIfPresent(Int.self, forKey: .voltage) ?? 0
        inputMillivolts = try c.decodeIfPresent(Int.self, forKey: .vinValue) ?? 0
        powerBudgetWatts = try c.decodeIfPresent(Int.self, forKey: .powerBudget) ?? 0
        sessionID = try c.decodeIfPresent(Int.self, forKey: .sessionID)
        sessionCharge = try c.decodeIfPresent(Int.self, forKey: .sessionCharge)
    }
}

public struct SystemMetrics: Sendable, Equatable, Decodable {
    public let appVersion: String?
    public let bootTimeSeconds: Int?
    public let resetReason: Int?
    public let freeHeap: Int?

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case bootTimeSeconds = "boot_time_seconds"
        case resetReason = "reset_reason"
        case freeHeap = "free_heap"
    }
}

/// `GET /metrics.json` 的整体结构（只取需要的字段，Wi‑Fi 信息不读）。
public struct DeviceMetrics: Sendable, Equatable, Decodable {
    public let ports: [PortMetrics]
    public let system: SystemMetrics?

    public init(ports: [PortMetrics], system: SystemMetrics?) {
        self.ports = ports
        self.system = system
    }

    public var totalWatts: Double { ports.reduce(0) { $0 + $1.watts } }
    public var chargingCount: Int { ports.filter(\.isCharging).count }
}

/// `GET /` 首页里 `window.__INFOZ` 的设备信息。
public struct DeviceInfo: Sendable, Equatable, Decodable {
    public let psn: String?
    public let deviceName: String?
    public let deviceModel: String?
    public let productFamily: String?
    public let esp32Version: String?
    public let mcuVersion: String?
    public let fpgaVersion: String?
    public let mdnsHostname: String?

    enum CodingKeys: String, CodingKey {
        case psn
        case deviceName = "device_name"
        case deviceModel = "device_model"
        case productFamily = "product_family"
        case esp32Version = "esp32_version"
        case mcuVersion = "mcu_version"
        case fpgaVersion = "fpga_version"
        case mdnsHostname = "mdns_hostname"
    }

    public static func parse(html: String) -> DeviceInfo? {
        guard let json = extractObject(in: html, after: "window.__INFOZ"),
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    /// 在 marker 之后找第一个完整的 `{...}`，跳过字符串里的括号。
    static func extractObject(in text: String, after marker: String) -> String? {
        guard let markerRange = text.range(of: marker),
              let start = text[markerRange.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

public enum PortNaming {
    /// 端口名按 id 固定映射（与小程序 product-family-config 和 MCP get_machine_facts 一致）。
    public static func name(index: Int, family: String? = nil) -> String {
        let names: [String]
        switch family?.uppercased() {
        case "PA768S": names = ["C1", "C2", "C3"]
        default: names = ["A", "C1", "C2", "C3", "C4"]
        }
        return index >= 0 && index < names.count ? names[index] : "P\(index + 1)"
    }
}

public enum FastChargeProtocol {
    /// fc_protocol 编号（来自小程序 FAST_CHARGE_PROTOCOL 枚举）。
    public static func name(_ code: Int) -> String {
        switch code {
        case 0: return "USB 普通"
        case 1: return "QC 2.0"
        case 2: return "QC 3.0"
        case 3: return "QC 3+"
        case 4: return "SFCP"
        case 5: return "AFC"
        case 6: return "FCP"
        case 7: return "SCP"
        case 8: return "VOOC 1.0"
        case 9: return "VOOC 4.0"
        case 10: return "SuperVOOC 2.0"
        case 11: return "TFCP"
        case 12: return "UFCS"
        case 13: return "PE 1.0"
        case 14: return "PE 2.0"
        case 15: return "PD 5V"
        case 16: return "PD 固定高压"
        case 17: return "PD SPR AVS"
        case 18: return "PD PPS"
        case 19: return "PD EPR"
        case 20: return "PD AVS"
        case 21: return "PD 小米 PPS"
        case 255: return "未充电"
        default: return "协议 \(code)"
        }
    }
}
