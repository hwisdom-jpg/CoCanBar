import Foundation

/// 一个口上接的设备和线材。
///
/// 数据来自官方 MCP（2026-10-15 对 CP02 Pro 实测过字段）：
/// - `get_port_pd_status`：PD 握手里拿到的厂商号 / 产品号、电池、线材 E-Marker、设备请求的档位。
///   只返回正在充电的口；不走 PD 的口（USB 普通充电、QC 等）也会有一条，但里面的 PD 字段没有意义。
/// - `get_port_details`：每个口的实时详情和会话号。工具说明里写了带“设备识别”，认出设备时应该带型号（`device_name_*`），
///   但手头的设备都没报厂商号，还没实测到；字段名参照线材的 `cable_brand_*` / `cable_name_*`（实测过）和其他开源客户端，
///   `device_brand_*` 是按同样的命名推断的。
///
/// 小程序也是这样识别的：拿厂商号和产品号去它自己的云端产品库查型号。
/// 设备在 PD 握手里不报身份（厂商号为 0）就认不出来，小程序里显示为“未获取到 PID VID 的设备”。
public struct PortIdentity: Sendable, Equatable {
    /// 和 `PortMetrics.id` 一致，从 0 开始（MCP 端口号减 1）。
    public var portID: Int
    /// `get_port_details` 的会话号，和局域网读数里的 `session_id` 是同一个计数，用来判断结果是不是这次插入的。
    public var sessionID: Int?
    /// 服务端认出的品牌和型号（中文优先）。
    public var brand: String?
    public var model: String?
    /// USB 厂商号 / 产品号（PD Discover Identity）。设备没报时为 nil。
    public var vendorID: Int?
    public var productID: Int?
    /// 这个口当前是不是 PD 协商的。不是时 PD 档位、线材都没有意义。
    public var usesPD: Bool
    public var pdRevision: String?
    /// 设备请求的档位。
    public var requestedVolts: Double?
    public var requestedAmps: Double?
    public var supportsPPS: Bool
    public var supportsEPR: Bool
    /// 设备声明的最大取电功率（W，PD 3.x 的 Sink Maximum PDP）。
    public var maxWatts: Int?
    public var battery: BatteryInfo?
    /// 线材的 E-Marker 信息。PD 口用的线没有 E-Marker 时为 nil（按 PD 规范最高 3 A）。
    public var cable: CableInfo?

    public init(portID: Int, sessionID: Int? = nil, brand: String? = nil, model: String? = nil,
                vendorID: Int? = nil, productID: Int? = nil, usesPD: Bool = true, pdRevision: String? = nil,
                requestedVolts: Double? = nil, requestedAmps: Double? = nil, supportsPPS: Bool = false,
                supportsEPR: Bool = false, maxWatts: Int? = nil, battery: BatteryInfo? = nil, cable: CableInfo? = nil) {
        self.portID = portID
        self.sessionID = sessionID
        self.brand = brand
        self.model = model
        self.vendorID = vendorID
        self.productID = productID
        self.usesPD = usesPD
        self.pdRevision = pdRevision
        self.requestedVolts = requestedVolts
        self.requestedAmps = requestedAmps
        self.supportsPPS = supportsPPS
        self.supportsEPR = supportsEPR
        self.maxWatts = maxWatts
        self.battery = battery
        self.cable = cable
    }

    /// 显示用的设备名：服务端给了型号就用型号（品牌不在型号里时加在前面）；
    /// 只认出厂商时是“Apple 设备”这样；都没有时为 nil。
    public var displayName: String? {
        if let model {
            if let brand, !model.localizedCaseInsensitiveContains(brand) { return "\(brand) \(model)" }
            return model
        }
        return vendorName.map { "\($0) 设备" }
    }

    /// 厂商名：服务端给的品牌优先，其次按厂商号查内置的厂商表。
    public var vendorName: String? {
        brand ?? vendorID.flatMap(USBVendor.name(for:))
    }

    /// 服务端认出了品牌或型号。认出来时服务端会把厂商号、产品号换成名字（线材实测如此），所以这时没有厂商号是正常的。
    public var recognizedByServer: Bool { brand != nil || model != nil }

    /// “厂商号 0x05AC · 产品号 0x12A8”。设备没报时为 nil。
    public var idText: String? {
        guard let vendorID else { return nil }
        var text = "厂商号 " + Self.hex(vendorID)
        if let productID { text += " · 产品号 " + Self.hex(productID) }
        return text
    }

    /// “PD 3.0 · 请求 9V 2.22A · 设备最高 27W · 支持 PPS”。不走 PD 时为 nil。
    public var pdSummary: String? {
        guard usesPD else { return nil }
        var parts: [String] = []
        if let pdRevision { parts.append(pdRevision) }
        if let volts = requestedVolts, let amps = requestedAmps {
            parts.append("请求 \(Self.number(volts))V \(Self.number(amps))A")
        }
        if let maxWatts { parts.append("设备最高 \(maxWatts)W") }
        if supportsEPR {
            parts.append("支持 EPR")
        } else if supportsPPS {
            parts.append("支持 PPS")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 把两个工具的结果合并成每个口的识别结果，键是 `PortMetrics.id`。`details` 读不到时传 nil。
    public static func parse(pdStatus: JSONValue?, details: JSONValue?) -> [Int: PortIdentity] {
        let pdByPort = byPort(pdStatus)
        let detailByPort = byPort(details)
        var result: [Int: PortIdentity] = [:]
        for port in Set(pdByPort.keys).union(detailByPort.keys) where port >= 1 {
            let detail = detailByPort[port]
            // 没接设备的口不用识别
            if detail?["connected"]?.boolValue == false, pdByPort[port] == nil { continue }
            result[port - 1] = PortIdentity(port: port, pd: pdByPort[port], detail: detail)
        }
        return result
    }

    /// 各口的插拔签名（是否连接、协议、会话号）。变了说明插拔过或重新握手过，识别结果要重读。
    public static func signature(of ports: [PortMetrics]) -> String {
        ports.sorted { $0.id < $1.id }
            .map { "\($0.id):\($0.attached ? 1 : 0):\($0.fcProtocol):\($0.sessionID ?? -1)" }
            .joined(separator: "|")
    }

    init(port: Int, pd: JSONValue?, detail: JSONValue?) {
        let brand = Self.firstText([detail, pd], keys: ["device_brand_zh", "device_brand_en"])
        let model = Self.firstText([detail, pd], keys: ["device_name_zh", "device_name_en"])
        var vendorID = Self.positive(pd?["manufacturer_vid"]) ?? Self.positive(detail?["manufacturer_vid"])
        var productID = Self.positive(pd?["manufacturer_pid"]) ?? Self.positive(detail?["manufacturer_pid"])
        // 照小程序：苹果、三星、任天堂的设备常常只在电池信息里报厂商号，这时用电池的厂商号和产品号来认
        if vendorID == nil, let batteryVendor = Self.positive(pd?["battery_vid"]),
           USBVendor.reportsIdentityInBattery.contains(batteryVendor) {
            vendorID = batteryVendor
            productID = Self.positive(pd?["battery_pid"])
        }
        // operating_voltage 的单位是 10 mV，operating_current 是 10 mA
        let volts = pd?["operating_voltage"]?.looseDouble.flatMap { $0 > 0 ? $0 / 100 : nil }
        let amps = pd?["operating_current"]?.looseDouble.flatMap { $0 > 0 ? $0 / 100 : nil }
        let usesPD = detail?["fc_protocol"]?.trimmedText.map { $0.uppercased().hasPrefix("PD") } ?? (volts != nil)
        let pdEntry = usesPD ? pd : nil
        self.init(portID: port - 1,
                  sessionID: detail?["session_id"]?.looseInt,
                  brand: brand, model: model, vendorID: vendorID, productID: productID,
                  usesPD: usesPD,
                  pdRevision: pdEntry?["pd_revision"]?.trimmedText,
                  requestedVolts: pdEntry == nil ? nil : volts,
                  requestedAmps: pdEntry == nil ? nil : amps,
                  supportsPPS: pdEntry?["pps_charging_supported"]?.boolValue ?? false,
                  supportsEPR: pdEntry?["request_epr_mode_capable"]?.boolValue ?? false,
                  maxWatts: Self.positive(pdEntry?["sink_maximum_pdp"]),
                  battery: pd.flatMap(BatteryInfo.init(pd:)),
                  cable: pdEntry.flatMap(CableInfo.init(pd:)))
    }

    private static func byPort(_ value: JSONValue?) -> [Int: JSONValue] {
        var result: [Int: JSONValue] = [:]
        for entry in value?["ports"]?.arrayValue ?? [] {
            if let port = entry["port"]?.looseInt { result[port] = entry }
        }
        return result
    }

    private static func firstText(_ sources: [JSONValue?], keys: [String]) -> String? {
        for key in keys {
            for source in sources {
                if let text = source?[key]?.trimmedText { return text }
            }
        }
        return nil
    }

    /// 大于 0 的整数；0 表示设备没报。
    private static func positive(_ value: JSONValue?) -> Int? {
        value?.looseInt.flatMap { $0 > 0 ? $0 : nil }
    }

    static func hex(_ value: Int) -> String { String(format: "0x%04X", value) }

    /// 9 → “9”，2.22 → “2.22”，3.25 → “3.25”。
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
    }
}

/// 设备通过 PD 报的电池信息。
public struct BatteryInfo: Sendable, Equatable {
    /// 剩余电量（%）：当前容量 / 最近一次充满的容量。
    public var percent: Int
    /// 健康度（%）：最近一次充满的容量 / 设计容量。
    public var health: Int
    /// 设计容量（Wh）。
    public var designWh: Double

    public init(percent: Int, health: Int, designWh: Double) {
        self.percent = percent
        self.health = health
        self.designWh = designWh
    }

    /// 规则照小程序（formatPortPdStatus）：容量的单位是 0.1 Wh；设计容量或满电容量不在 5–200 Wh 之间，
    /// 或者健康度低于 75%，都当作设备报得不准，整块不显示。
    init?(pd: JSONValue) {
        if pd["battery_invalid"]?.boolValue == true { return nil }
        if pd["battery_present"]?.boolValue == false { return nil }
        guard let design = Self.wattHours(pd["battery_design_capacity"]),
              let full = Self.wattHours(pd["battery_last_full_charge_capacity"]),
              let present = Self.wattHours(pd["battery_present_capacity"]) else { return nil }
        let plausible = 5.0...200.0
        guard plausible.contains(design), plausible.contains(full) else { return nil }
        let health = min(Int((full / design * 100).rounded()), 100)
        guard health >= 75 else { return nil }
        self.init(percent: min(Int((present / full * 100).rounded()), 100), health: health, designWh: design)
    }

    /// 0.1 Wh 单位的原始值换成 Wh。0 和 0xFFFF 表示设备不知道。
    private static func wattHours(_ value: JSONValue?) -> Double? {
        guard let raw = value?.looseDouble, raw > 0, raw != 0xFFFF else { return nil }
        return raw / 10
    }
}

/// 线材 E-Marker 里的信息。
public struct CableInfo: Sendable, Equatable {
    /// 服务端认出的线材品牌和型号。
    public var name: String?
    /// 线材能承受的最高电流、电压，例如 “5A”“20V”。
    public var maxCurrent: String?
    public var maxVoltage: String?
    /// 线材的最高数据速率，例如 “USB 2.0”“USB 3.2 Gen1”。
    public var usbSpeed: String?
    public var isActive: Bool
    public var supportsEPR: Bool

    public init(name: String? = nil, maxCurrent: String? = nil, maxVoltage: String? = nil, usbSpeed: String? = nil,
                isActive: Bool = false, supportsEPR: Bool = false) {
        self.name = name
        self.maxCurrent = maxCurrent
        self.maxVoltage = maxVoltage
        self.usbSpeed = usbSpeed
        self.isActive = isActive
        self.supportsEPR = supportsEPR
    }

    /// MCP 返回的是字符串（“5A”）；按开源固件，原始值是编号时也能换成同样的写法。
    init?(pd: JSONValue) {
        guard pd["has_emarker"]?.boolValue == true else { return nil }
        let brand = pd["cable_brand_zh"]?.trimmedText ?? pd["cable_brand_en"]?.trimmedText
        let model = pd["cable_name_zh"]?.trimmedText ?? pd["cable_name_en"]?.trimmedText
        let name: String?
        if let brand, let model, !model.localizedCaseInsensitiveContains(brand) {
            name = "\(brand) \(model)"
        } else {
            name = model ?? brand
        }
        self.init(name: name,
                  maxCurrent: Self.label(pd["cable_max_vbus_current"], codes: [1: "3A", 2: "5A"]),
                  maxVoltage: Self.label(pd["cable_max_vbus_voltage"], codes: [0: "20V", 1: "30V", 2: "40V", 3: "50V"]),
                  usbSpeed: Self.label(pd["cable_usb_highest_speed"],
                                       codes: [0: "USB 2.0", 1: "USB 3.2 Gen1", 2: "USB 3.2/4 Gen2", 3: "USB4 Gen3", 4: "USB4 Gen4"]),
                  isActive: pd["cable_is_active"]?.boolValue ?? false,
                  supportsEPR: pd["cable_epr_mode_capable"]?.boolValue ?? false)
    }

    /// “E-Marker · 最高 5A / 20V · USB 3.2 Gen1”。认出了线材型号时，型号放在最前面。
    public var summary: String {
        var parts = [name ?? "E-Marker"]
        let limits = [maxCurrent, maxVoltage].compactMap { $0 }
        if !limits.isEmpty { parts.append("最高 " + limits.joined(separator: " / ")) }
        if let usbSpeed { parts.append(usbSpeed) }
        if isActive { parts.append("有源线") }
        if supportsEPR { parts.append("支持 EPR") }
        return parts.joined(separator: " · ")
    }

    /// 服务端不认识的编号会写成 “unknown(2)”（2026-10-15 实测苹果 240W 线：电流 unknown(2)、电压 unknown(3)），
    /// 这时按 PD 规范 Cable VDO 的编号换算（和开源固件的对照表一致）。
    private static func label(_ value: JSONValue?, codes: [Int: String]) -> String? {
        if let text = value?.trimmedText {
            guard text.lowercased().hasPrefix("unknown") else { return text }
            return Int(text.filter(\.isNumber)).flatMap { codes[$0] }
        }
        return value?.intValue.flatMap { codes[$0] }
    }
}

/// 常见的 USB 厂商号（USB-IF 分配），只收手机、电脑、游戏机这类终端品牌。
/// PD 控制芯片厂（TI、Cypress、瑞昱等）也有自己的厂商号，设备没改成自己的号时报的是芯片厂的，这类不当品牌显示。
public enum USBVendor {
    public static func name(for vendorID: Int) -> String? { names[vendorID] }

    /// 照小程序：这几家的设备常常只在电池信息里报厂商号。
    static let reportsIdentityInBattery: Set<Int> = [0x05AC, 0x04E8, 0x057E]

    static let names: [Int: String] = [
        0x05AC: "Apple",
        0x04E8: "三星",
        0x18D1: "Google",
        0x12D1: "华为",
        0x2717: "小米",
        0x22D9: "OPPO",
        0x2D95: "vivo",
        0x2A70: "一加",
        0x2A45: "魅族",
        0x19D2: "中兴",
        0x22B8: "摩托罗拉",
        0x1004: "LG",
        0x0BB4: "HTC",
        0x054C: "索尼",
        0x0FCE: "索尼",
        0x17EF: "联想",
        0x413C: "戴尔",
        0x03F0: "惠普",
        0x0B05: "华硕",
        0x0502: "宏碁",
        0x045E: "微软",
        0x32AC: "Framework",
        0x057E: "任天堂",
        0x28DE: "Valve",
        0x046D: "罗技",
        0x1532: "雷蛇",
        0x2CA3: "大疆",
        0x2672: "GoPro",
        0x091E: "佳明",
        0x1949: "亚马逊",
        0x291A: "安克",
        0x050D: "贝尔金",
    ]
}

// 读取见 `MCPClient.portInfo()`（PortActivity.swift）。

extension JSONValue {
    /// 整数；字符串形式的数字和 “0x05AC” 这类十六进制也认。
    var looseInt: Int? {
        if let value = intValue { return value }
        guard let text = trimmedText else { return nil }
        if text.lowercased().hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
        return Int(text)
    }

    var looseDouble: Double? {
        doubleValue ?? trimmedText.flatMap(Double.init)
    }

    /// 去掉首尾空白后的非空字符串。
    var trimmedText: String? {
        guard let text = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
