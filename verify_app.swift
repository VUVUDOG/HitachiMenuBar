// AppModel regression checks, compiled with the actual application source.
let testRuntime = URL(fileURLWithPath: CommandLine.arguments[1])
let fakeWorker = URL(fileURLWithPath: "/usr/bin/true")
func saveFixture(_ name: String, _ value: Any, runtime: URL = testRuntime) throws {
    try JSONSerialization.data(withJSONObject: value).write(to: runtime.appendingPathComponent(name))
}
func seedAuthenticated(runtime: URL = testRuntime) throws {
    try saveFixture("auth.json", ["generation": "old-session", "state": "authenticated", "account": "session"], runtime: runtime)
    try saveFixture("status.json", ["generation": "old-session", "phase": "complete", "message": "设备状态已更新"], runtime: runtime)
    try saveFixture("report.json", ["devices": [["device": ["did": "test-room", "name": "测试空调"], "state": []]]], runtime: runtime)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
try seedAuthenticated()
let original = AppModel(worker: fakeWorker, runtime: testRuntime)
expect(original.rooms.count == 1, "Existing authenticated login must load cached rooms")
original.login()
expect(original.rooms.isEmpty && original.selectedID.isEmpty && original.readAt == nil, "Relogin must immediately clear native state")
let revoked = try JSONSerialization.jsonObject(with: Data(contentsOf: testRuntime.appendingPathComponent("auth.json"))) as! [String: Any]
expect(revoked["state"] as? String == "logged_out", "Revocation must persist before the QR worker starts")
expect(revoked["generation"] as? String != "old-session", "Relogin must invalidate the previous generation")
expect(!FileManager.default.fileExists(atPath: testRuntime.appendingPathComponent("report.json").path), "Cached rooms must be deleted")
original.process?.waitUntilExit()
let restarted = AppModel(worker: fakeWorker, runtime: testRuntime)
expect(restarted.rooms.isEmpty && !restarted.busy && restarted.qr == nil, "Restart after cancelled relogin must stay signed out")

try seedAuthenticated()
let logout = AppModel(worker: fakeWorker, runtime: testRuntime)
logout.logout()
expect(logout.rooms.isEmpty && logout.authState == "logged_out", "Logout must clear native state synchronously")
logout.process?.waitUntilExit()
let afterLogout = AppModel(worker: fakeWorker, runtime: testRuntime)
expect(afterLogout.rooms.isEmpty && !afterLogout.canLogout, "Logout must survive restart")

try seedAuthenticated()
try saveFixture("auth.json", ["generation": "pending", "state": "pending", "account": "session.pending"])
try saveFixture("status.json", ["generation": "pending", "phase": "awaiting_scan", "message": "等待扫码"])
let interrupted = AppModel(worker: fakeWorker, runtime: testRuntime)
expect(interrupted.rooms.isEmpty && interrupted.qr == nil && !interrupted.busy, "Interrupted QR login must not revive stale rooms or remain busy")
print("Native login lifecycle: 3 regression scenarios passed")

// Exercise the actual SwiftUI intrinsic height for all three panel states.
let _ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
interrupted.rooms = [RoomReading(id: "layout-room", name: "测试空调", power: false, target: 26, mode: 1, fan: 0,
    modes: [ControlOption(id: 0, label: "自动"), ControlOption(id: 1, label: "制冷"), ControlOption(id: 2, label: "除湿"), ControlOption(id: 3, label: "送风"), ControlOption(id: 4, label: "制热")],
    fans: [ControlOption(id: 0, label: "自动"), ControlOption(id: 1, label: "低风"), ControlOption(id: 2, label: "中风"), ControlOption(id: 3, label: "高风")],
    writable: [], minimum: 16, maximum: 32, step: 1, message: nil)]
let hosting = NSHostingView(rootView: ControlView(model: interrupted, onHeightChange: { _ in }))
hosting.sizingOptions = [.intrinsicContentSize]
hosting.frame = NSRect(x: 0, y: 0, width: 376, height: 100)
let controlHeight = hosting.fittingSize.height
let layoutRooms = interrupted.rooms
interrupted.rooms = []; interrupted.authState = "logged_out"
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
let signedOutHeight = hosting.fittingSize.height
interrupted.active = true; interrupted.phase = "awaiting_scan"; interrupted.qr = NSImage(size: NSSize(width: 232, height: 232))
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
let qrHeight = hosting.fittingSize.height
expect(controlHeight > signedOutHeight + 100, "Control panel must measure its natural height")
expect(qrHeight > signedOutHeight + 100, "QR panel must grow to fit its content")
expect(signedOutHeight > 200 && signedOutHeight < 450, "Signed-out panel must shrink without fixed-height padding")
print("Native layout: control \(Int(controlHeight)) / signed out \(Int(signedOutHeight)) / QR \(Int(qrHeight)) pt")

// Reproduce login/QR/room transitions inside the actual material container.
// Exercise the legacy branch even on macOS 26 to catch wrapper sizing regressions.
for useGlass in [true, false] {
    let host = TransparentHostingView(rootView: ControlView(model: interrupted, onHeightChange: { _ in }))
    host.sizingOptions = [.intrinsicContentSize]
    host.frame = NSRect(x: 0, y: 0, width: 376, height: 100)
    let container = PanelContentView(content: host, useLiquidGlass: useGlass)
    let window = MenuPanel(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    for state in ["control", "signed-out", "qr", "control"] {
        interrupted.rooms = state == "control" ? layoutRooms : []
        interrupted.active = state == "qr"
        interrupted.phase = state == "qr" ? "awaiting_scan" : "logged_out"
        interrupted.qr = state == "qr" ? NSImage(size: NSSize(width: 232, height: 232)) : nil
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let height = ceil(host.fittingSize.height)
        window.setContentSize(NSSize(width: 376, height: height))
        container.layoutSubtreeIfNeeded()
        expect(abs(container.bounds.height - height) <= 1, "Material must fill the measured window")
        expect(host.frame == container.bounds && container.backdrop.frame == container.bounds,
               "Login transitions must not leave extra space above or below the material")
    }
    if #available(macOS 26.0, *), useGlass {
        expect(container.usesLiquidGlass && container.backdrop is NSGlassEffectView, "New Macs must use native Liquid Glass")
    } else {
        expect(!container.usesLiquidGlass && container.backdrop is NSVisualEffectView, "Older Macs must use the menu material")
    }
    window.close()
}
print("Native backdrop: Liquid Glass and legacy menu material follow all panel sizes")

let cacheRuntime = testRuntime.appendingPathComponent("cache-test")
try FileManager.default.createDirectory(at: cacheRuntime, withIntermediateDirectories: true)
try seedAuthenticated(runtime: cacheRuntime)
let testSession = ["user_id": "test", "ssecurity": "test-security", "service_token": "test-token"]
let testSessionData = try JSONSerialization.data(withJSONObject: testSession)
let cached = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: cacheRuntime,
    credentialReader: { _ in (errSecSuccess, testSessionData) })
func finish(_ model: AppModel) {
    let deadline = Date(timeIntervalSinceNow: 5)
    while model.active && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
    expect(!model.active, "Worker must complete and its private session pipe must close")
}
func requests() throws -> [[String: Bool]] {
    let lines = try String(contentsOf: cacheRuntime.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
    return try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Bool] }
}
cached.refresh(); finish(cached)
expect(cached.sessionData != nil, "First authorized read must cache the session in memory")
cached.refresh(); finish(cached)
let initialRequests = try requests()
expect(initialRequests.count == 2 && initialRequests.allSatisfy { $0["memory"] == true }, "Every GUI refresh, including the first, must use the private pipe instead of worker Keychain reads")
expect(cached.keychainReads == 1 && cached.memoryRequests == 2, "Main app must authorize once and reuse its session")
expect(!cached.diagnosticSummary.contains("test-token") && !cached.diagnosticSummary.contains("test-security"), "Diagnostics must not include credentials")
cached.logout()
expect(cached.sessionData == nil && cached.sessionGeneration == nil, "Logout must immediately erase the in-memory login")
finish(cached)
let restartCache = AppModel(worker: fakeWorker, runtime: cacheRuntime)
expect(restartCache.sessionData == nil, "Memory cache must not persist across app restarts")

try seedAuthenticated(runtime: cacheRuntime)
try Data().write(to: cacheRuntime.appendingPathComponent("deny-keychain"))
let denied = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: cacheRuntime,
    credentialReader: { _ in
        FileManager.default.fileExists(atPath: cacheRuntime.appendingPathComponent("deny-keychain").path)
            ? (errSecAuthFailed, nil) : (errSecSuccess, testSessionData)
    })
denied.refresh(); finish(denied)
expect(denied.automaticRefreshSuspended && !denied.busy, "Denied Keychain access must stop automatic attempts and leave controls responsive")
let countBefore = try requests().count
let readsBefore = denied.keychainReads
denied.refresh(automatic: true)
let countAutomatic = try requests().count
expect(!denied.active && countAutomatic == countBefore && denied.keychainReads == readsBefore, "Automatic refresh must not prompt again after denial")
denied.refresh(); finish(denied)
let countAfter = try requests().count
expect(countAfter == countBefore && denied.keychainReads == readsBefore + 1, "Manual refresh may retry main-app authorization, but must not launch another Keychain-reading worker")
expect(denied.automaticRefreshSuspended, "Repeated identical denials must still suspend automatic refresh")
denied.refresh(automatic: true)
let countRepeated = try requests().count
expect(!denied.active && countRepeated == countAfter, "Identical denial responses must not restart the automatic prompt loop")
let restartDenied = AppModel(worker: fakeWorker, runtime: cacheRuntime)
restartDenied.refresh(automatic: true)
expect(restartDenied.automaticRefreshSuspended && !restartDenied.active, "Restart must not automatically repeat a previously denied authorization")
try FileManager.default.removeItem(at: cacheRuntime.appendingPathComponent("deny-keychain"))
denied.refresh(); finish(denied)
expect(denied.sessionData != nil && !denied.automaticRefreshSuspended, "Successful manual authorization must restore normal automatic refresh")
expect(denied.memoryRequests == 1, "Successful retry must pass the main app's session to the worker")

try seedAuthenticated(runtime: cacheRuntime)
let malformed = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: cacheRuntime,
    credentialReader: { _ in (errSecSuccess, Data("not-json".utf8)) })
malformed.refresh(); finish(malformed)
malformed.refresh(automatic: true)
expect(malformed.keychainReads == 1 && malformed.workerRequests == 0 && malformed.automaticRefreshSuspended,
    "Invalid credential data must stop without another implicit Keychain attempt")

// Revoking a login while the OS authorization is pending must remain immediate.
try seedAuthenticated(runtime: cacheRuntime)
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let late = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: cacheRuntime,
    credentialReader: { _ in
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        return (errSecSuccess, testSessionData)
    })
late.refresh()
expect(entered.wait(timeout: .now() + 1) == .success, "Native Keychain read must run off the UI thread")
late.logout()
release.signal()
finish(late)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
expect(late.sessionData == nil && late.authState == "logged_out", "Late system authorization must not restore a revoked session")
expect(late.workerRequests == 1, "Cancelled authorization must not start its old refresh worker")

// Legacy sessions are migrated only when no auth marker exists, not after logout.
let legacyRuntime = testRuntime.appendingPathComponent("legacy-test")
try FileManager.default.createDirectory(at: legacyRuntime, withIntermediateDirectories: true)
let legacy = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: legacyRuntime,
    credentialReader: { account in
        expect(account == "session", "Pre-0.3 login must use the existing Keychain account")
        return (errSecSuccess, testSessionData)
    })
legacy.refresh(); finish(legacy)
expect(legacy.authState == "authenticated" && legacy.sessionData != nil && legacy.keychainReads == 1,
    "Native reader must preserve an existing legacy session")

// Controls update the panel immediately, merge repeated taps, and revert on failure.
let controlRuntime = testRuntime.appendingPathComponent("control-test")
try FileManager.default.createDirectory(at: controlRuntime, withIntermediateDirectories: true)
try seedAuthenticated(runtime: controlRuntime)
let controlSpec: [String: Any] = ["services": [["iid": 2, "type": "urn:miot-spec-v2:service:air-conditioner:1", "properties": [
    ["iid": 1, "type": "urn:miot-spec-v2:property:on:1", "format": "bool", "access": ["read", "write"]],
    ["iid": 2, "type": "urn:miot-spec-v2:property:mode:1", "access": ["read", "write"],
     "value-list": [["value": 1, "description": "Cool"], ["value": 2, "description": "Heat"]]],
    ["iid": 4, "type": "urn:miot-spec-v2:property:target-temperature:1", "access": ["read", "write"], "value-range": [16, 32, 1]]]]]]
let controlState: [[String: Any]] = [["siid": 2, "piid": 1, "code": 0, "value": true],
    ["siid": 2, "piid": 2, "code": 0, "value": 1], ["siid": 2, "piid": 4, "code": 0, "value": 26.0]]
try saveFixture("report.json", ["devices": [["device": ["did": "test-room", "name": "测试空调"], "spec": controlSpec, "state": controlState]]], runtime: controlRuntime)
let control = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: controlRuntime,
    credentialReader: { _ in (errSecSuccess, testSessionData) })
func controls() -> [[String]] {
    guard let text = try? String(contentsOf: controlRuntime.appendingPathComponent("controls.jsonl"), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
}
func settle(_ model: AppModel) {
    let deadline = Date(timeIntervalSinceNow: 6)
    while (model.active || model.inFlight != nil || !model.pending.isEmpty) && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    expect(!model.active && model.inFlight == nil && model.pending.isEmpty, "Queued controls must drain")
}
expect(control.selected?.target == 26, "Control fixture must load the reported temperature")
for value in [27.0, 28.0, 29.0] { control.set("target-temperature", value: value, delay: 0.6) }
expect(control.selected?.target == 29 && !control.active, "Taps must show immediately and wait for the debounce")
settle(control)
expect(controls().count == 1 && Array(controls()[0][2..<6]) == ["--field", "target-temperature", "--value", "29"],
    "Repeated temperature taps must send only the final value")
control.set("target-temperature", value: 27.0)
control.flush()
expect(control.inFlight != nil, "First control must start")
control.set("mode", value: 2)
expect(control.selected?.mode == 2, "Taps during a running command must not be dropped")
settle(control)
expect(controls().count == 3 && controls()[2].contains("mode"), "A tap made during a running command must be sent afterwards")
control.set("target-temperature", value: 26.0)
control.set("target-temperature", value: 28.0); settle(control)
try Data().write(to: controlRuntime.appendingPathComponent("fail-control"))
control.set("target-temperature", value: 31.0)
expect(control.selected?.target == 31, "Failure case must first show the optimistic value")
settle(control)
expect(control.selected?.target == 26 && control.message.contains("未调整成功"), "A failed control must revert to the reported state")

let leaseRuntime = testRuntime.appendingPathComponent("lease-test")
try FileManager.default.createDirectory(at: leaseRuntime, withIntermediateDirectories: true)
var lease = ApplicationLease(runtime: leaseRuntime)
expect(lease != nil, "First app instance must acquire its lease")
expect(ApplicationLease(runtime: leaseRuntime) == nil, "A duplicate app instance must not start another authorization loop")
lease = nil
expect(ApplicationLease(runtime: leaseRuntime) != nil, "Exiting the app must release its lease")
print("Native authentication: single main-app read, worker private pipes, retry suspension, revocation race, legacy migration, optimistic controls, and duplicate-instance lease passed")
