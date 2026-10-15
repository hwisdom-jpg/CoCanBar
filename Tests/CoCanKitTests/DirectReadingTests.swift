import XCTest
@testable import CoCanKit

/// 菜单栏 app 没在运行时小组件自己读局域网，以及充电曲线存盘。
final class DirectReadingTests: XCTestCase {
    private let units = 146_600
    private let start = Date(timeIntervalSince1970: 1_000_020)

    private func metricsPort(_ id: Int, attached: Bool = true, milliamps: Int = 2_000, session: Int?,
                             charge: Int?) -> PortMetrics {
        PortMetrics(id: id, active: true, state: "ACTIVE", portType: "C", attached: attached,
                    chargingDurationSeconds: 60, fcProtocol: 15, currentMilliamps: milliamps, voltageMillivolts: 9_000,
                    inputMillivolts: 0, powerBudgetWatts: 0, sessionID: session, sessionCharge: charge)
    }

    private func appDevice() -> WidgetSnapshot.Device {
        WidgetSnapshot.Device(
            psn: "TEST0001", name: "书桌", online: true, readAt: start, controllable: true, strategy: 1,
            ports: [
                WidgetSnapshot.Port(id: 1, poweredOn: true, attached: true, watts: 27, volts: 9, amps: 3, fcProtocol: 18,
                                    deviceName: "iPhone", batteryPercent: 60, temperature: "warm",
                                    sessionEnergyMWh: 1_000, sessionID: 7, sessionCharge: 1_000 * units),
                WidgetSnapshot.Port(id: 2, poweredOn: true, attached: true, watts: 5, volts: 5, amps: 1, fcProtocol: 0,
                                    deviceName: "AirPods", sessionEnergyMWh: 200, sessionID: 8, sessionCharge: 200 * units),
            ],
            recentWatts: Array(repeating: 30, count: 30), recentWattsAt: start, busy: "正在关闭 C2…", message: "已打开 C1",
            host: "cp02-TEST0001.local", lanIP: "192.0.2.22", lanUnitsPerMWh: Double(units))
    }

    func testDirectReadingContinuesTheSameChargingSession() {
        let now = start.addingTimeInterval(5 * 60)
        let metrics = DeviceMetrics(ports: [
            metricsPort(1, session: 7, charge: 1_500 * units),
            metricsPort(2, session: 9, charge: 10 * units),
        ], system: nil)
        let device = appDevice().updated(with: metrics, at: now)

        XCTAssertEqual(device.readAt, now)
        XCTAssertTrue(device.online)
        XCTAssertNil(device.busy, "app 的进行中提示不带过来")
        XCTAssertNil(device.message)
        XCTAssertEqual(device.name, "书桌")
        XCTAssertEqual(device.host, "cp02-TEST0001.local")

        // 同一次充电：设备名留着，电量接着算；电池和温度只有 MCP 有，不显示旧值
        XCTAssertEqual(device.ports[0].deviceName, "iPhone")
        XCTAssertEqual(device.ports[0].sessionEnergyMWh ?? 0, 1_500, accuracy: 0.001)
        XCTAssertNil(device.ports[0].batteryPercent)
        XCTAssertNil(device.ports[0].temperature)
        XCTAssertEqual(device.ports[0].watts, 18, accuracy: 0.001)

        // 会话号变了：换了设备，名字和电量都不沿用
        XCTAssertNil(device.ports[1].deviceName)
        XCTAssertNil(device.ports[1].sessionEnergyMWh)
        XCTAssertEqual(device.ports[1].sessionID, 9)

        // 接着再读一次，用上一次直读的结果继续算
        let later = device.updated(with: DeviceMetrics(ports: [metricsPort(1, session: 7, charge: 1_600 * units)], system: nil),
                                   at: now.addingTimeInterval(60))
        XCTAssertEqual(later.ports[0].deviceName, "iPhone")
        XCTAssertEqual(later.ports[0].sessionEnergyMWh ?? 0, 1_600, accuracy: 0.001)
    }

    func testDirectReadingDropsNameWhenUnpluggedOrNoSession() {
        var device = appDevice()
        device.lanUnitsPerMWh = nil
        let metrics = DeviceMetrics(ports: [
            metricsPort(1, attached: false, milliamps: 0, session: 7, charge: 1_500 * units),
            metricsPort(2, session: nil, charge: nil),
        ], system: nil)
        let updated = device.updated(with: metrics, at: start.addingTimeInterval(30))
        XCTAssertNil(updated.ports[0].deviceName, "拔掉了")
        XCTAssertNil(updated.ports[1].deviceName, "读不到会话号时不猜")
        XCTAssertNil(updated.ports[1].sessionEnergyMWh)
    }

    func testShiftedSeries() {
        let base = Date(timeIntervalSince1970: 60 * 1_000 + 15)
        let values: [Double?] = (0..<30).map { Double($0) }
        // 同一分钟：只换最后一个
        let same = WidgetSnapshot.shiftedSeries(values, from: base, to: base.addingTimeInterval(20), latest: 99)
        XCTAssertEqual(same.count, 30)
        XCTAssertEqual(same[28], 28)
        XCTAssertEqual(same[29], 99)
        // 隔 3 分钟：往前挪 3 格，中间两分钟没有记录
        let shifted = WidgetSnapshot.shiftedSeries(values, from: base, to: base.addingTimeInterval(180), latest: 50)
        XCTAssertEqual(shifted[0], 3)
        XCTAssertEqual(shifted[26], 29)
        XCTAssertNil(shifted[27])
        XCTAssertNil(shifted[28])
        XCTAssertEqual(shifted[29], 50)
        // 隔太久：只剩这一次
        let far = WidgetSnapshot.shiftedSeries(values, from: base, to: base.addingTimeInterval(3_600), latest: 7)
        XCTAssertEqual(far.compactMap { $0 }, [7])
        // 旧数据不满 30 个时前面补空
        let short = WidgetSnapshot.shiftedSeries([1, 2], from: base, to: base, latest: 3)
        XCTAssertEqual(short.count, 30)
        XCTAssertEqual(short.suffix(2), [1, 3])
        XCTAssertNil(short[0])
    }

    func testAppIsRunning() {
        var snapshot = WidgetSnapshot(updatedAt: start, devices: [appDevice()])
        XCTAssertTrue(snapshot.appIsRunning(at: start.addingTimeInterval(30)))
        XCTAssertFalse(snapshot.appIsRunning(at: start.addingTimeInterval(WidgetSnapshot.appAliveWindow + 1)),
                       "1 分钟没写快照")
        snapshot.appStoppedAt = start
        XCTAssertFalse(snapshot.appIsRunning(at: start.addingTimeInterval(1)), "正常退出时马上算没在运行")
    }

    func testDirectReadingFilesPerDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoCanDirect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(directory: directory)
        XCTAssertNil(store.readDirectReading("TEST0001"))
        let device = appDevice()
        try store.writeDirectReading(device)
        var other = appDevice()
        other.psn = "TEST0002"
        try store.writeDirectReading(other)
        XCTAssertEqual(store.readDirectReading("TEST0001"), device)
        XCTAssertEqual(store.readDirectReading("TEST0002")?.psn, "TEST0002")

        var odd = appDevice()
        odd.psn = "../x"
        try store.writeDirectReading(odd)
        XCTAssertNil(store.readDirectReading("../x"), "PSN 里有别的字符时不拼路径")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("x.json").path))
    }

    // 旧版本写的快照没有新加的字段，也要能读
    func testSnapshotWithoutNewFieldsStillDecodes() throws {
        let json = """
        {"updatedAt": 0, "devices": [{"psn": "TEST0001", "name": "书桌", "online": true, "controllable": false,
          "ports": [{"id": 1, "poweredOn": true, "attached": false, "watts": 0, "volts": 0, "amps": 0,
                     "fcProtocol": 255, "chargingSeconds": 0}],
          "recentWatts": [], "messageIsError": false}]}
        """
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.appStoppedAt)
        XCTAssertNil(snapshot.devices[0].host)
        XCTAssertNil(snapshot.devices[0].ports[0].sessionID)
    }

    // MARK: - 充电曲线存盘

    private func sample(_ offset: TimeInterval, _ watts: Double) -> PowerSample {
        PowerSample(time: start.addingTimeInterval(offset), watts: watts, volts: 9, amps: (watts / 9 * 1000).rounded() / 1000)
    }

    func testPowerSampleIsStoredCompactly() throws {
        let original = PowerSample(time: Date(timeIntervalSince1970: 1_000_010), watts: 27.4136, volts: 9.0123, amps: 3.0417)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[1000010,27.41,9.012,3.042]")
        let decoded = try JSONDecoder().decode(PowerSample.self, from: data)
        XCTAssertEqual(decoded.time, original.time)
        XCTAssertEqual(decoded.watts, 27.41)
    }

    func testNewDeviceSamplesKeepTheOlderDeviceWindow() {
        var history = PortHistory()
        history.setDeviceSamples([sample(0, 1), sample(10, 1)], loadedAt: start.addingTimeInterval(15))
        for offset in stride(from: 20.0, through: 40, by: 10) { history.record(sample(offset, 2)) }
        // 半小时后再读设备内存：只覆盖 30 秒以后，0–10 秒那段并进记录，不丢
        history.setDeviceSamples([sample(30, 5), sample(40, 5)], loadedAt: start.addingTimeInterval(45))
        XCTAssertEqual(history.samples(since: start).map(\.watts), [1, 1, 2, 5, 5])
        XCTAssertEqual(history.recorded.map(\.watts), [1, 1, 2, 2, 2])
        XCTAssertEqual(history.deviceLoadedAt, start.addingTimeInterval(45))
    }

    func testHistoryArchiveRoundTripAndPrune() throws {
        var kept = PortHistory()
        kept.record(sample(-3 * 3_600, 1))
        kept.record(sample(0, 2))
        kept.setDeviceSamples([sample(-2.5 * 3_600, 3)], loadedAt: start)
        var expired = PortHistory()
        expired.record(sample(-3 * 3_600, 4))
        let archive = HistoryArchive(savedAt: start, devices: [
            "TEST0001": [1: kept, 2: expired],
            "REMOVED1": [1: kept],
        ])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CoCanHistory-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try archive.save(to: url)
        let loaded = try XCTUnwrap(HistoryArchive.load(from: url))
        XCTAssertEqual(loaded, archive)

        let pruned = loaded.pruned(now: start.addingTimeInterval(60), keeping: ["TEST0001"])
        XCTAssertEqual(Array(pruned.keys), ["TEST0001"], "删掉的设备不读回")
        XCTAssertEqual(pruned["TEST0001"]?.keys.sorted(), [1], "全过期的口去掉")
        let port = try XCTUnwrap(pruned["TEST0001"]?[1])
        XCTAssertEqual(port.recorded.map(\.watts), [2])
        XCTAssertTrue(port.fromDevice.isEmpty)
        XCTAssertNil(port.deviceLoadedAt, "设备数据全过期时下次显示曲线重读")

        XCTAssertNil(HistoryArchive.load(from: url.deletingLastPathComponent().appendingPathComponent("missing.json")))
    }
}
