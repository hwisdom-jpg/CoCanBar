import Foundation
import CoCanKit

// 演示数据：小组件库里的预览、占位图和离屏截图用。PSN 是假的。

extension WidgetSnapshot {
    static func demo(now: Date) -> WidgetSnapshot {
        let desk = Device(
            psn: "DEMO0001", name: "书桌", online: true, readAt: now.addingTimeInterval(-2), controllable: true,
            strategy: ChargingStrategy.fast.rawValue,
            ports: [
                Port(id: 0, poweredOn: true, attached: false, watts: 0, volts: 0, amps: 0, fcProtocol: 255),
                Port(id: 1, poweredOn: true, attached: true, watts: 27.4, volts: 9.0, amps: 3.04, fcProtocol: 18,
                     deviceName: "iPhone 17 Pro", batteryPercent: 64, temperature: "moderate",
                     sessionEnergyMWh: 3_460, chargingSeconds: 1_500, sessionID: 101,
                     sessionCharge: 3_460 * demoUnitsPerMWh),
                Port(id: 2, poweredOn: true, attached: true, watts: 45.1, volts: 20, amps: 2.25, fcProtocol: 15,
                     deviceName: "MacBook Air", batteryPercent: 81, temperature: "warm",
                     sessionEnergyMWh: 12_800, chargingSeconds: 3_100, sessionID: 102,
                     sessionCharge: 12_800 * demoUnitsPerMWh),
                Port(id: 3, poweredOn: false, attached: false, watts: 0, volts: 0, amps: 0, fcProtocol: 255),
                Port(id: 4, poweredOn: true, attached: true, watts: 2.1, volts: 5.1, amps: 0.41, fcProtocol: 0,
                     deviceName: "AirPods Pro", temperature: "cool", sessionEnergyMWh: 412, chargingSeconds: 900,
                     sessionID: 103, sessionCharge: 412 * demoUnitsPerMWh),
            ],
            recentWatts: demoSeries(), recentWattsAt: now, host: "demo.invalid",
            lanUnitsPerMWh: Double(demoUnitsPerMWh))
        let sofa = Device(
            psn: "DEMO0002", name: "沙发", online: true, readAt: now.addingTimeInterval(-3), controllable: true,
            strategy: ChargingStrategy.slow.rawValue,
            ports: [
                Port(id: 0, poweredOn: true, attached: false, watts: 0, volts: 0, amps: 0, fcProtocol: 255),
                Port(id: 1, poweredOn: true, attached: true, watts: 9.8, volts: 9.0, amps: 1.09, fcProtocol: 15,
                     deviceName: "iPad mini", batteryPercent: 92, temperature: "cool",
                     sessionEnergyMWh: 5_120, chargingSeconds: 4_200),
                Port(id: 2, poweredOn: true, attached: false, watts: 0, volts: 0, amps: 0, fcProtocol: 255),
                Port(id: 3, poweredOn: true, attached: false, watts: 0, volts: 0, amps: 0, fcProtocol: 255),
                Port(id: 4, poweredOn: true, attached: false, watts: 0, volts: 0, amps: 0, fcProtocol: 255),
            ],
            recentWatts: Array(repeating: 9.9, count: 30))
        return WidgetSnapshot(updatedAt: now.addingTimeInterval(-1), devices: [desk, sofa])
    }

    /// 局域网电量计数每 mWh 的值（和实测量级一样）。
    static let demoUnitsPerMWh = 146_600

    /// 前几分钟没有记录，之后 MacBook 插上、功率慢慢爬升又回落一点。
    private static func demoSeries() -> [Double?] {
        (0..<30).map { minute -> Double? in
            guard minute >= 4 else { return nil }
            let rise = min(Double(minute - 4) / 10, 1)
            let wobble = sin(Double(minute) * 1.7) * 2.2
            return 29 + rise * 48 - Double(max(minute - 22, 0)) * 0.6 + wobble
        }
    }
}

extension ChargerEntry {
    static func preview(date: Date) -> ChargerEntry {
        ChargerEntry(date: date, snapshot: .demo(now: date), psn: nil)
    }

    /// 菜单栏 app 40 分钟前退出，小组件刚自己读了一次局域网：C1、C2 还是同一次充电，C4 换了一台设备。
    static func directPreview(date: Date) -> ChargerEntry {
        let snapshot = WidgetSnapshot.demo(now: date.addingTimeInterval(-40 * 60))
        var entry = ChargerEntry(date: date, snapshot: snapshot, psn: nil)
        entry.appRunning = false
        let units = WidgetSnapshot.demoUnitsPerMWh
        func port(_ id: Int, on: Bool = true, attached: Bool = false, milliamps: Int = 0, millivolts: Int = 0,
                  protocolCode: Int = 255, session: Int? = nil, charge: Int? = nil) -> PortMetrics {
            PortMetrics(id: id, active: on, state: on ? "ACTIVE" : "INACTIVE", portType: id == 0 ? "A" : "C",
                        attached: attached, chargingDurationSeconds: 0, fcProtocol: protocolCode,
                        currentMilliamps: milliamps, voltageMillivolts: millivolts, inputMillivolts: 0,
                        powerBudgetWatts: 0, sessionID: session, sessionCharge: charge)
        }
        let metrics = DeviceMetrics(ports: [
            port(0),
            port(1, attached: true, milliamps: 1_420, millivolts: 9_000, protocolCode: 18, session: 101,
                 charge: (3_460 + 11_200) * units),
            port(2, attached: true, milliamps: 1_510, millivolts: 20_000, protocolCode: 15, session: 102,
                 charge: (12_800 + 24_500) * units),
            port(3, on: false),
            port(4, attached: true, milliamps: 980, millivolts: 5_000, protocolCode: 0, session: 205, charge: 300 * units),
        ], system: nil)
        entry.direct = snapshot.devices[0].updated(with: metrics, at: date.addingTimeInterval(-4))
        return entry
    }
}
