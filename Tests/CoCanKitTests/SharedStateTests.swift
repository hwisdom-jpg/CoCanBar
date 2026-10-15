import XCTest
@testable import CoCanKit

final class SharedStateTests: XCTestCase {
    private var directory: URL!
    private var store: SharedStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoCanShared-\(UUID().uuidString)")
        store = SharedStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func port(_ id: Int, on: Bool = true, attached: Bool = false, watts: Double = 0) -> WidgetSnapshot.Port {
        WidgetSnapshot.Port(id: id, poweredOn: on, attached: attached, watts: watts, volts: watts > 0 ? 9 : 0,
                            amps: watts > 0 ? watts / 9 : 0, fcProtocol: watts > 0 ? 15 : 255)
    }

    private func snapshot(watts: Double = 20, attached: Bool = true, message: String? = nil) -> WidgetSnapshot {
        let device = WidgetSnapshot.Device(psn: "TEST0001", name: "书桌", online: true,
                                           readAt: Date(timeIntervalSince1970: 1_000), controllable: true, strategy: 0,
                                           ports: [port(0), port(1, attached: attached, watts: watts)],
                                           recentWatts: [nil, 18.5, 20], message: message)
        return WidgetSnapshot(updatedAt: Date(timeIntervalSince1970: 1_000), devices: [device])
    }

    func testSnapshotRoundTrip() throws {
        XCTAssertNil(store.readSnapshot())
        let original = snapshot()
        try store.writeSnapshot(original)
        XCTAssertEqual(store.readSnapshot(), original)
        XCTAssertEqual(store.readSnapshot()?.device(nil)?.totalWatts, 20)
        XCTAssertEqual(store.readSnapshot()?.device("TEST0001")?.ports[1].name, "C1")
        XCTAssertNil(store.readSnapshot()?.device("OTHER"))
    }

    func testCloudFieldsRoundTrip() throws {
        var original = snapshot()
        original.devices[0].viaCloud = true
        original.devices[0].ports[0].poweredOn = nil
        original.devices[0].ports[1].protocolText = "Apple 2.4A"
        try store.writeSnapshot(original)
        let read = try XCTUnwrap(store.readSnapshot()?.devices.first)
        XCTAssertEqual(read.viaCloud, true)
        XCTAssertNil(read.ports[0].poweredOn)
        XCTAssertFalse(read.ports[0].inUse)
        XCTAssertEqual(read.ports[1].protocolText, "Apple 2.4A")
    }

    func testOlderSnapshotWithoutCloudFieldsDecodes() throws {
        // 局域网读数的快照不写 viaCloud、protocolText，和旧版本写出的一样；开关状态照常写出、照常读回
        try store.writeSnapshot(snapshot())
        let text = try String(contentsOf: directory.appendingPathComponent("snapshot.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("viaCloud"))
        XCTAssertFalse(text.contains("protocolText"))
        XCTAssertTrue(text.contains("poweredOn"))
        let read = try XCTUnwrap(store.readSnapshot()?.devices.first)
        XCTAssertNil(read.viaCloud)
        XCTAssertEqual(read.ports.map(\.poweredOn), [true, true])
    }

    func testPortInUseNeedsPowerAndDevice() {
        XCTAssertTrue(port(1, attached: true, watts: 5).inUse)
        XCTAssertTrue(port(1, attached: true).inUse)
        XCTAssertFalse(port(1, on: false, attached: true).inUse)
        XCTAssertFalse(port(1).inUse)
        XCTAssertTrue(port(1, attached: true, watts: 5).isCharging)
        XCTAssertFalse(port(1, attached: true).isCharging)
    }

    func testTemperatureRawValueRoundTrip() {
        for raw in ["cool", "moderate", "warm", "hot", "scorching"] {
            XCTAssertEqual(PortTemperature(raw)?.rawValue, raw)
        }
    }

    func testCommandsAreTakenOnceInOrder() throws {
        let later = WidgetCommand(psn: "TEST0001", port: 2, turnOn: true, issuedAt: Date(timeIntervalSince1970: 20))
        let earlier = WidgetCommand(psn: "TEST0001", port: 1, turnOn: false, issuedAt: Date(timeIntervalSince1970: 10))
        try store.send(later)
        try store.send(earlier)
        XCTAssertEqual(store.takeCommands(), [earlier, later])
        XCTAssertEqual(store.takeCommands(), [])
    }

    func testWithdrawnCommandIsNotTaken() throws {
        let command = WidgetCommand(psn: "TEST0001", port: 1, turnOn: false)
        try store.send(command)
        XCTAssertTrue(store.withdraw(command.id))
        XCTAssertEqual(store.takeCommands(), [])
        // app 已经取走的命令撤不回
        let taken = WidgetCommand(psn: "TEST0001", port: 1, turnOn: true)
        try store.send(taken)
        XCTAssertEqual(store.takeCommands(), [taken])
        XCTAssertFalse(store.withdraw(taken.id))
    }

    func testCommandExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(WidgetCommand(psn: "P", port: 0, turnOn: true, issuedAt: now.addingTimeInterval(-14)).isExpired(now: now))
        XCTAssertTrue(WidgetCommand(psn: "P", port: 0, turnOn: true, issuedAt: now.addingTimeInterval(-16)).isExpired(now: now))
        XCTAssertTrue(WidgetCommand(psn: "P", port: 0, turnOn: true, issuedAt: now.addingTimeInterval(30)).isExpired(now: now))
    }

    func testRepliesAreTakenAndOldOnesPruned() throws {
        let now = Date()
        let stale = WidgetReply(id: UUID(), accepted: true, message: "旧的", repliedAt: now.addingTimeInterval(-120))
        try store.reply(stale)
        let fresh = WidgetReply(id: UUID(), accepted: false, message: "设备不在线", repliedAt: now)
        try store.reply(fresh)
        XCTAssertNil(store.takeReply(stale.id))
        XCTAssertEqual(store.takeReply(fresh.id), fresh)
        XCTAssertNil(store.takeReply(fresh.id))
    }

    func testPendingAndNotice() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pending = PendingConfirmation(psn: "TEST0001", port: 3, expiresAt: now.addingTimeInterval(10))
        store.writePending(pending)
        XCTAssertEqual(store.readPending(), pending)
        XCTAssertTrue(pending.matches(psn: "TEST0001", port: 3, now: now))
        XCTAssertFalse(pending.matches(psn: "TEST0001", port: 2, now: now))
        XCTAssertFalse(pending.matches(psn: "TEST0001", port: 3, now: now.addingTimeInterval(11)))
        store.writePending(nil)
        XCTAssertNil(store.readPending())

        let notice = WidgetNotice(psn: nil, text: "菜单栏 app 没有运行", isError: true, expiresAt: now.addingTimeInterval(10))
        store.writeNotice(notice)
        XCTAssertEqual(store.readNotice(), notice)
        XCTAssertTrue(notice.applies(to: "ANY", now: now))
        XCTAssertFalse(notice.applies(to: "ANY", now: now.addingTimeInterval(10)))
        XCTAssertFalse(WidgetNotice(psn: "A", text: "x", isError: false, expiresAt: now.addingTimeInterval(5)).applies(to: "B", now: now))
        store.writeNotice(nil)
        XCTAssertNil(store.readNotice())
    }

    func testMinuteSeriesAveragesEachMinute() {
        let now = Date(timeIntervalSince1970: 6_000 + 25) // 第 100 分钟过了 25 秒
        let samples = [
            PowerSample(time: Date(timeIntervalSince1970: 6_000 - 30 * 60), watts: 99, volts: 0, amps: 0), // 窗口外
            PowerSample(time: Date(timeIntervalSince1970: 6_000 - 60), watts: 10, volts: 0, amps: 0),
            PowerSample(time: Date(timeIntervalSince1970: 6_000 - 50), watts: 20, volts: 0, amps: 0),
            PowerSample(time: Date(timeIntervalSince1970: 6_000 + 20), watts: 7, volts: 0, amps: 0),
        ]
        let series = WidgetSnapshot.minuteSeries(samples, now: now, minutes: 30)
        XCTAssertEqual(series.count, 30)
        XCTAssertEqual(series[29], 7)
        XCTAssertEqual(series[28], 15)
        XCTAssertNil(series[0])
        XCTAssertEqual(series.compactMap { $0 }.count, 2)
    }

    func testChangeDetection() {
        let base = snapshot()
        XCTAssertEqual(base.change(since: nil), .state)
        XCTAssertEqual(snapshot(watts: 21).change(since: base), .none)
        XCTAssertEqual(snapshot(watts: 26).change(since: base), .readings)
        XCTAssertEqual(snapshot(attached: false).change(since: base), .state)
        XCTAssertEqual(snapshot(message: "已关闭 C1").change(since: base), .state)
        var offline = base
        offline.devices[0].online = false
        XCTAssertEqual(offline.change(since: base), .state)
        var switchedOff = base
        switchedOff.devices[0].ports[0].poweredOn = false
        XCTAssertEqual(switchedOff.change(since: base), .state)
        // 改读云端（开关变灰）、开关状态变成未知，也要马上刷新
        var viaCloud = base
        viaCloud.devices[0].viaCloud = true
        XCTAssertEqual(viaCloud.change(since: base), .state)
        var unknown = base
        unknown.devices[0].ports[0].poweredOn = nil
        XCTAssertEqual(unknown.change(since: base), .state)
        XCTAssertTrue(WidgetSnapshot.Change.none < .readings && WidgetSnapshot.Change.readings < .state)
    }

    func testDarwinNotificationRoundTrip() {
        let name = "com.local.CoCanBar.tests.\(UUID().uuidString)"
        let received = expectation(description: "通知")
        let observer = DarwinNotificationObserver(name: name, queue: .global()) { received.fulfill() }
        XCTAssertNotNil(observer)
        XCTAssertTrue(DarwinNotification.post(name))
        wait(for: [received], timeout: 2)
        withExtendedLifetime(observer) {}
    }

    func testNoAppGroupInTestRunner() {
        // 测试进程没有 App Group 权限：共享功能整个关掉，而不是写到别的地方
        XCTAssertNil(AppGroup.identifier)
        XCTAssertNil(SharedStore.appGroup)
        XCTAssertEqual(AppGroup.commandNotification(group: "TEAMID.com.local.CoCanBar"), "TEAMID.com.local.CoCanBar.command")
    }
}
