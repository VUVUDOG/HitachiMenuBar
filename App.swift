import AppKit
import SwiftUI
import Darwin
import Security

// Hold this lease for the application's lifetime. Opening a second copy must
// not create another independent Keychain authorization or refresh loop.
final class ApplicationLease {
    let descriptor: Int32
    init?(runtime: URL) {
        let fd = Darwin.open(runtime.appendingPathComponent("application.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return nil }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

struct ControlOption: Identifiable { let id: Int; let label: String }
// Changes for one room that have been sent, or are waiting to be sent, to the cloud.
struct ControlCommand { let room: String; var changes: [String: AnyHashable] }
struct RoomReading: Identifiable {
    let id: String
    let name: String
    var power: Bool?
    var target: Double?
    var mode: Int?
    var fan: Int?
    let modes: [ControlOption]
    let fans: [ControlOption]
    let writable: Set<String>
    let minimum: Double
    let maximum: Double
    let step: Double
    let message: String?
    var indoor: Double? = nil
    var humidity: Double? = nil
}

final class AppModel: ObservableObject {
    @Published var phase = "idle"
    @Published var message = "请先扫码登录米家"
    @Published var qr: NSImage?
    @Published var rooms: [RoomReading] = []
    @Published var selectedID = UserDefaults.standard.string(forKey: "selectedRoom") ?? ""
    @Published var readAt: Date?
    @Published var active = false {
        didSet { if oldValue && !active { DispatchQueue.main.async { [weak self] in self?.workerFinished() } } }
    }
    // Optimistic control state: the UI shows these values immediately. `pending`
    // collects the latest intent per room and field; `inFlight` is being sent.
    @Published var pending: [String: [String: AnyHashable]] = [:]
    @Published var inFlight: ControlCommand?
    var flushWork: DispatchWorkItem?
    @Published var authState = "legacy"
    let runtime: URL
    let worker: URL
    var process: Process?
    var timer: Timer?
    var lastStatus = Data()
    var lastReport = Data()
    var titleChanged: ((String) -> Void)?
    var generation: String?
    var startedAt: Date?
    var sessionData: Data?
    var sessionGeneration: String?
    var automaticRefreshSuspended = false
    var authorizationID: UUID?
    let credentialReader: (String) -> (OSStatus, Data?)
    var keychainReads = 0
    var workerRequests = 0
    var memoryRequests = 0
    var diagnosticEvents: [[String: Any]] = []

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" }
    static var defaultRuntime: URL {
        ProcessInfo.processInfo.environment["HITACHI_RUNTIME_PATH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HitachiMenuBar")
    }

    static func readKeychain(account: String) -> (OSStatus, Data?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "HitachiMenuBar.CloudWorker", kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true]
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        return (code, result as? Data)
    }

    init(worker: URL, runtime overrideRuntime: URL? = nil,
         credentialReader: @escaping (String) -> (OSStatus, Data?) = AppModel.readKeychain) {
        self.worker = worker
        self.credentialReader = credentialReader
        runtime = overrideRuntime ?? Self.defaultRuntime
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        poll()
        recordDiagnostic("launch")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    var displayRooms: [RoomReading] { rooms.map(overlaid) }
    var selected: RoomReading? { (rooms.first { $0.id == selectedID } ?? rooms.first).map(overlaid) }

    func overlaid(_ reading: RoomReading) -> RoomReading {
        var room = reading
        var changes = inFlight?.room == room.id ? inFlight?.changes ?? [:] : [:]
        changes.merge(pending[room.id] ?? [:]) { $1 }
        if let value = changes["on"]?.base as? Bool { room.power = value }
        if let value = changes["target-temperature"]?.base as? Double { room.target = value }
        if let value = changes["mode"]?.base as? Int { room.mode = value }
        if let value = changes["fan-level"]?.base as? Int { room.fan = value }
        return room
    }
    var busy: Bool { active || ["starting", "authenticating", "awaiting_scan", "reading", "controlling"].contains(phase) }
    var controlling: Bool { active && process?.arguments?.contains("--field") == true }
    var canLogout: Bool { authState == "authenticated" || authState == "pending" || !rooms.isEmpty }

    static func degrees(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }

    static func translated(_ text: String) -> String {
        let map = ["cool": "制冷", "heat": "制热", "dry": "除湿", "fan": "送风", "auto": "自动",
                   "low": "低风", "medium": "中风", "high": "高风"]
        return map[text.lowercased()] ?? text
    }

    func poll(forceStatus: Bool = false) {
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("auth.json")),
           let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            authState = auth["state"] as? String ?? "logged_out"
            generation = auth["generation"] as? String
        }
        let authenticated = authState == "legacy" || authState == "authenticated"
        if !authenticated || sessionGeneration != generation { forgetSession() }
        if !authenticated {
            rooms = []; readAt = nil; selectedID = ""
            if !active && phase != "error" { qr = nil; phase = "logged_out"; message = authState == "pending" ? "上次扫码未完成，请重新登录" : "请扫码登录米家" }
        }
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("status.json")), forceStatus || data != lastStatus,
           let status = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           generation == nil || status["generation"] == generation {
            lastStatus = data
            phase = status["phase"] ?? "error"
            message = status["message"] ?? "未收到连接状态"
            automaticRefreshSuspended = status["reason"] == "keychain_access"
            qr = active && phase == "awaiting_scan" ? NSImage(contentsOf: runtime.appendingPathComponent("login.png")) : nil
            if !active && ["starting", "authenticating", "reading", "awaiting_scan", "controlling"].contains(phase) {
                phase = authenticated ? "complete" : "logged_out"
                message = authenticated ? "点击刷新，获取最新状态" : "上次扫码未完成，请重新登录"
            }
        }
        if authenticated, let data = try? Data(contentsOf: runtime.appendingPathComponent("report.json")), data != lastReport,
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = report["devices"] as? [[String: Any]] {
            lastReport = data
            readAt = (report["read_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            rooms = devices.compactMap { item in
                guard let device = item["device"] as? [String: Any], let did = device["did"] as? String else { return nil }
                let spec = item["spec"] as? [String: Any] ?? [:]
                let states = item["state"] as? [[String: Any]] ?? []
                var properties: [String: [String: Any]] = [:]
                var values: [String: Any] = [:]
                var writable = Set<String>()
                for service in spec["services"] as? [[String: Any]] ?? [] {
                    let siid = service["iid"] as? Int
                    for prop in service["properties"] as? [[String: Any]] ?? [] {
                        guard let type = prop["type"] as? String,
                              let field = ["on", "mode", "target-temperature", "fan-level"].first(where: { type.contains(":\($0):") }),
                              let piid = prop["iid"] as? Int else { continue }
                        properties[field] = prop
                        if let state = states.first(where: { ($0["siid"] as? Int) == siid && ($0["piid"] as? Int) == piid }),
                           (state["code"] as? Int) == 0, let value = state["value"] {
                            values[field] = value
                            if (prop["access"] as? [String] ?? []).contains("write") { writable.insert(field) }
                        }
                    }
                }
                func options(_ field: String) -> [ControlOption] {
                    (properties[field]?["value-list"] as? [[String: Any]] ?? []).compactMap { option in
                        guard let id = option["value"] as? Int else { return nil }
                        return ControlOption(id: id, label: Self.translated(option["description"] as? String ?? "\(id)"))
                    }
                }
                let limits = properties["target-temperature"]?["value-range"] as? [Double] ?? [16, 32, 1]
                return RoomReading(id: did, name: device["name"] as? String ?? "空调",
                    power: values["on"] as? Bool, target: values["target-temperature"] as? Double,
                    mode: values["mode"] as? Int, fan: values["fan-level"] as? Int,
                    modes: options("mode"), fans: options("fan-level"), writable: writable,
                    // Half degrees are offered until the unit has rejected one (see probe.py).
                    minimum: limits[0], maximum: limits[1],
                    step: item["half_step"] as? Bool == false ? limits[2] : min(limits[2], 0.5), message: item["message"] as? String,
                    indoor: (item["climate"] as? [String: Any])?["temperature"] as? Double,
                    humidity: (item["climate"] as? [String: Any])?["humidity"] as? Double)
            }
            if !rooms.contains(where: { $0.id == selectedID }) { selectedID = rooms.first?.id ?? "" }
        }
        UserDefaults.standard.set(selectedID, forKey: "selectedRoom")
        if active && phase == "authenticating", let startedAt = startedAt, Date().timeIntervalSince(startedAt) > 12 {
            message = "请允许系统钥匙串访问，或从设置重新扫码登录"
        }
        updateTitle()
    }

    func updateTitle() {
        if let room = selected, let temp = room.target {
            titleChanged?(room.power == true ? " \(Self.degrees(temp))°" : " 空调")
        } else { titleChanged?(" 空调") }
    }

    func run(arguments: [String], label: String) {
        guard !busy else { return }
        poll()
        guard !busy else { return }
        if arguments.contains("--login") || arguments.contains("--logout") || sessionData != nil ||
            (authState != "authenticated" && authState != "legacy") {
            launchWorker(arguments: arguments, label: label)
            return
        }
        guard let auth = authenticationSnapshot(createLegacy: authState == "legacy"),
              auth["state"] as? String == "authenticated",
              let id = auth["generation"] as? String, let account = auth["account"] as? String else {
            pauseAuthorization(code: errSecDecode)
            return
        }
        generation = id; authState = "authenticated"
        active = true; phase = "authenticating"; startedAt = Date()
        message = "正在读取钥匙串中的登录会话…"
        let request = UUID()
        authorizationID = request
        keychainReads += 1
        recordDiagnostic("keychain_read")
        let reader = credentialReader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (code, data) = reader(account)
            DispatchQueue.main.async {
                guard let self = self, self.authorizationID == request else { return }
                self.authorizationID = nil
                self.recordDiagnostic("keychain_result", code: code)
                self.poll()
                guard self.generation == id, self.authState == "authenticated" else {
                    self.active = false
                    self.phase = self.authState == "authenticated" ? "complete" : "logged_out"
                    self.message = "登录状态已变化，请手动刷新或重新登录"
                    return
                }
                if code == errSecItemNotFound {
                    _ = self.invalidateSession()
                    self.message = "登录会话不存在，请重新扫码登录"
                    return
                }
                guard code == errSecSuccess, let data = data,
                      let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let envelope = try? JSONSerialization.data(withJSONObject: ["generation": id, "session": session]) else {
                    self.pauseAuthorization(code: code == errSecSuccess ? errSecDecode : code)
                    return
                }
                self.rememberSession(envelope)
                guard self.sessionData != nil, self.sessionGeneration == id else {
                    self.pauseAuthorization(code: errSecDecode)
                    return
                }
                self.launchWorker(arguments: arguments, label: label)
            }
        }
    }

    // File locks protect login generations, but are released before a system
    // authorization dialog can block. Never resurrect a revoked login here.
    func authenticationSnapshot(createLegacy: Bool = false) -> [String: Any]? {
        let fd = Darwin.open(runtime.appendingPathComponent("auth.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        let url = runtime.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard createLegacy else { return nil }
        let auth: [String: Any] = ["generation": UUID().uuidString, "state": "authenticated", "account": "session"]
        guard let data = try? JSONSerialization.data(withJSONObject: auth),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return auth
    }

    func pauseAuthorization(code: OSStatus) {
        active = false; automaticRefreshSuspended = true; phase = "error"
        message = "钥匙串访问未完成，自动刷新已暂停；请手动刷新或重新登录"
        recordDiagnostic("authorization_paused", code: code)
        let fd = Darwin.open(runtime.appendingPathComponent("auth.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0,
              let data = try? Data(contentsOf: runtime.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = generation, auth["generation"] as? String == id else { return }
        let status = ["generation": id, "phase": "error", "message": message, "reason": "keychain_access"]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: runtime.appendingPathComponent("status.json"), options: .atomic)
            lastStatus = data
        }
    }

    func launchWorker(arguments: [String], label: String) {
        active = true
        startedAt = Date()
        phase = "starting"
        message = label
        automaticRefreshSuspended = false
        let task = Process()
        task.executableURL = worker
        let session = sessionGeneration == generation ? sessionData : nil
        task.arguments = arguments + ["--session-output", "--require-session"] + (session == nil ? [] : ["--session-stdin"])
        workerRequests += 1
        if session != nil { memoryRequests += 1 }
        recordDiagnostic(session == nil ? "worker_without_session" : "worker_memory_session")
        var environment = ProcessInfo.processInfo.environment
        environment["HITACHI_RUNTIME_PATH"] = runtime.path
        if let generation = generation { environment["HITACHI_AUTH_GENERATION"] = generation }
        task.environment = environment
        let output = Pipe()
        let input = session == nil ? nil : Pipe()
        task.standardOutput = output
        if let input = input { task.standardInput = input }
        else { task.standardInput = FileHandle.nullDevice }
        task.standardError = FileHandle.nullDevice
        let previous = lastStatus
        task.terminationHandler = { [weak self] process in
            let payload = output.fileHandleForReading.readDataToEndOfFile()
            try? output.fileHandleForReading.close()
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.process === process else { return }
                self.rememberSession(payload)
                self.active = false
                self.poll(forceStatus: true)
                if (process.terminationStatus != 0 && self.lastStatus == previous && self.phase != "error") || self.busy {
                    self.phase = "error"
                    self.message = "云端连接未完成，请刷新或重新扫码登录。"
                }
            }
        }
        process = task
        do {
            try task.run()
            try? output.fileHandleForWriting.close()
            if let input = input, let session = session {
                try? input.fileHandleForReading.close()
                try input.fileHandleForWriting.write(contentsOf: session)
                try input.fileHandleForWriting.close()
            }
        } catch {
            try? output.fileHandleForWriting.close()
            try? input?.fileHandleForWriting.close()
            if task.isRunning { task.terminate() }
            process = nil; active = false; phase = "error"; message = "无法启动连接工具，请重新打开应用。"
        }
    }

    func forgetSession() { sessionData = nil; sessionGeneration = nil }

    var diagnosticSummary: String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let value: [String: Any] = ["version": Self.version, "architecture": architecture,
            "process_id": ProcessInfo.processInfo.processIdentifier,
            "keychain_reads": keychainReads, "worker_requests": workerRequests,
            "memory_requests": memoryRequests, "phase": phase, "auth_state": authState,
            "events": diagnosticEvents]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func recordDiagnostic(_ event: String, code: OSStatus? = nil) {
        var entry: [String: Any] = ["time": Date().timeIntervalSince1970, "event": event]
        if let code = code { entry["code"] = code }
        diagnosticEvents.append(entry)
        diagnosticEvents = Array(diagnosticEvents.suffix(24))
        // Only fixed event names and numeric OSStatus values are recorded.
        // No account, generation, arguments, URLs, or credentials are included.
        try? Data(diagnosticSummary.utf8).write(to: runtime.appendingPathComponent("diagnostics.json"), options: .atomic)
    }

    func rememberSession(_ payload: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = envelope["generation"] as? String,
              let session = envelope["session"] as? [String: String],
              ["user_id", "ssecurity", "service_token"].allSatisfy({ session[$0]?.isEmpty == false }),
              let marker = try? Data(contentsOf: runtime.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: marker) as? [String: Any],
              auth["state"] as? String == "authenticated", auth["generation"] as? String == id,
              let encoded = try? JSONSerialization.data(withJSONObject: session) else { return }
        sessionGeneration = id
        sessionData = encoded
    }

    // Persist revocation before launching any asynchronous worker. This also
    // invalidates a cancelled QR login if the app exits immediately afterwards.
    func invalidateSession() -> Bool {
        guard !controlling else { return false }
        let previousProcess = process
        flushWork?.cancel(); flushWork = nil
        pending = [:]; inFlight = nil
        authorizationID = nil
        process = nil
        active = false
        if previousProcess?.isRunning == true { previousProcess?.terminate() }
        forgetSession()
        recordDiagnostic("session_revoked")
        let fd = Darwin.open(runtime.appendingPathComponent("auth.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { phase = "error"; message = "无法清理登录状态，请重试"; return false }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        let url = runtime.appendingPathComponent("auth.json")
        let previous = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var retired = Set(previous["retired_accounts"] as? [String] ?? [])
        retired.insert(previous["account"] as? String ?? "session")
        let next = UUID().uuidString
        let auth: [String: Any] = ["generation": next, "state": "logged_out", "retired_accounts": Array(retired).sorted()]
        do {
            let data = try JSONSerialization.data(withJSONObject: auth)
            try data.write(to: url, options: .atomic)
            for name in ["report.json", "devices.json", "status.json", "login.png"] {
                let file = runtime.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        } catch { phase = "error"; message = "无法清理登录状态，请重试"; return false }
        generation = next; authState = "logged_out"
        active = false; phase = "logged_out"; qr = nil
        rooms = []; readAt = nil; selectedID = ""
        lastReport = Data(); lastStatus = Data()
        UserDefaults.standard.removeObject(forKey: "selectedRoom")
        titleChanged?(" 空调")
        return true
    }

    func login() {
        guard invalidateSession() else { return }
        run(arguments: ["--login"], label: "正在生成登录二维码…")
    }
    func logout() {
        guard invalidateSession() else { return }
        run(arguments: ["--logout"], label: "正在退出登录…")
    }
    func refresh(automatic: Bool = false) {
        guard !automatic || (!automaticRefreshSuspended && pending.isEmpty && inFlight == nil) else { return }
        run(arguments: rooms.isEmpty ? [] : ["--refresh"], label: "正在刷新状态…")
    }
    func resync() { run(arguments: [], label: "正在同步房间列表…") }
    // Record the intent immediately; repeated taps replace the queued value
    // instead of being dropped while an earlier command is still running.
    func set(_ field: String, value: AnyHashable, delay: TimeInterval = 0.05) {
        guard let room = selected, room.writable.contains(field) else { return }
        var changes = pending[room.id] ?? [:]
        let reported = rooms.first { $0.id == room.id }.map(reportedValue(field)) ?? nil
        if inFlight?.room != room.id || inFlight?.changes[field] == nil, reported == value {
            changes[field] = nil
        } else {
            changes[field] = value
        }
        pending[room.id] = changes.isEmpty ? nil : changes
        updateTitle()
        scheduleFlush(after: delay)
    }

    func reportedValue(_ field: String) -> (RoomReading) -> AnyHashable? {
        { room in
            switch field {
            case "on": return room.power.map(AnyHashable.init)
            case "target-temperature": return room.target.map(AnyHashable.init)
            case "mode": return room.mode.map(AnyHashable.init)
            default: return room.fan.map(AnyHashable.init)
            }
        }
    }

    func scheduleFlush(after delay: TimeInterval) {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func flush() {
        flushWork = nil
        guard inFlight == nil, !busy, !pending.isEmpty else { return }
        let id = pending[selectedID] != nil ? selectedID : pending.keys.sorted()[0]
        guard let room = rooms.first(where: { $0.id == id }), let changes = pending[id] else { pending[id] = nil; return }
        var arguments = ["--room", id]
        for field in ["on", "mode", "target-temperature", "fan-level"] {
            guard let value = changes[field], let data = try? JSONSerialization.data(withJSONObject: value.base, options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) else { continue }
            arguments += ["--field", field, "--value", json]
        }
        inFlight = ControlCommand(room: id, changes: changes)
        pending[id] = nil
        run(arguments: arguments, label: "正在同步到\(room.name)…")
        if !active { workerFinished() }
    }

    // Success keeps the cloud reading; failure drops the optimistic values so
    // the panel returns to the last confirmed state. Newer intents still go out.
    func workerFinished() {
        guard !active else { return }
        if let command = inFlight {
            inFlight = nil
            if phase != "complete" {
                pending[command.room] = pending[command.room]?.filter { command.changes[$0.key] == nil || $0.value != command.changes[$0.key] }
                if pending[command.room]?.isEmpty == true { pending[command.room] = nil }
                if let name = rooms.first(where: { $0.id == command.room })?.name, !message.contains(name) {
                    message = "\(name)未调整成功，已恢复原状态：\(message)"
                }
            }
            updateTitle()
        }
        if !pending.isEmpty { scheduleFlush(after: 0.05) }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct Surface: ViewModifier {
    var selected = false
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content.background(selected ? ControlView.accent.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(selected ? ControlView.accent.opacity(0.32) : Color.white.opacity(0.065), lineWidth: 1))
    }
}

struct QuietIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white.opacity(0.8))
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.045), in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ControlView: View {
    @ObservedObject var model: AppModel
    var onHeightChange: (CGFloat) -> Void
    @State private var draft = 26.0
    static let accent = Color(red: 0.45, green: 0.84, blue: 0.77)

    func roomIcon(_ name: String) -> String {
        if name.contains("卧") { return "bed.double" }
        if name.contains("书") { return "desktopcomputer" }
        return "sofa"
    }
    func modeIcon(_ label: String) -> String {
        ["自动": "arrow.triangle.2.circlepath", "制冷": "snowflake", "除湿": "drop", "送风": "wind", "制热": "sun.max"][label] ?? "air.conditioner.horizontal"
    }

    var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "air.conditioner.horizontal.fill").font(.system(size: 18))
                .foregroundStyle(Self.accent).frame(width: 38, height: 38)
                .background(Self.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("日立空调").font(.system(size: 16, weight: .semibold))
                Text(model.rooms.isEmpty ? "让舒适触手可及" : "\(model.rooms.count) 个房间 · \(model.displayRooms.filter { $0.power == true }.count) 台运行")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("同步房间") { model.resync() }.disabled(model.busy || (model.rooms.isEmpty && model.authState != "authenticated"))
                Button(model.rooms.isEmpty ? "扫码登录米家" : "重新登录米家") { model.login() }.disabled(model.controlling)
                Divider()
                Button("退出登录") { model.logout() }.disabled(model.controlling || !model.canLogout)
                Divider()
                Text("版本 \(AppModel.version)")
                Button("复制诊断信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticSummary, forType: .string)
                }
                Divider()
                Button("退出应用") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65)).frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.045), in: Circle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("设置")
        }
    }

    var roomTabs: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(model.displayRooms) { room in
                let selected = model.selectedID == room.id
                Button { model.selectedID = room.id; model.poll() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: roomIcon(room.name)).font(.system(size: 13)).frame(width: 18)
                        Text(room.name.replacingOccurrences(of: "空调", with: "")).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let indoor = room.indoor {
                            Text(String(format: "%.1f°", indoor)).font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.white.opacity(selected ? 0.75 : 0.45))
                        }
                        Circle().fill(room.power == true ? Self.accent : Color.white.opacity(0.2)).frame(width: 5, height: 5)
                    }.foregroundStyle(selected ? Self.accent : .white.opacity(0.65))
                        .padding(.horizontal, 12).padding(.vertical, 10).modifier(Surface(selected: selected))
                }.buttonStyle(.plain)
            }
        }
    }

    func temperatureCard(_ room: RoomReading) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(room.name).font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(room.power == true ? Self.accent : .secondary).frame(width: 4, height: 4)
                        Text(room.power.map { $0 ? "正在运行" : "已关机" } ?? "状态暂不可用")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let indoor = room.indoor {
                        HStack(spacing: 4) {
                            Image(systemName: "thermometer.medium").font(.system(size: 10))
                            Text("室温 " + String(format: "%.1f°", indoor) + (room.humidity.map { " · 湿度 \(Int($0.rounded()))%" } ?? ""))
                                .font(.system(size: 11)).monospacedDigit()
                        }.foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                Button { model.set("on", value: !(room.power ?? false)) } label: {
                    Image(systemName: "power").font(.system(size: 18, weight: .medium)).frame(width: 42, height: 42)
                        .foregroundStyle(room.power == true ? Self.accent : .white.opacity(0.6))
                        .background(room.power == true ? Self.accent.opacity(0.16) : Color.white.opacity(0.055), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.06)))
                }.buttonStyle(.plain).disabled(!room.writable.contains("on"))
                    .help(room.power == true ? "关闭空调" : "开启空调")
                    .accessibilityLabel(room.power == true ? "关闭空调" : "开启空调")
            }
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(room.target == nil ? "—" : AppModel.degrees(draft))
                        .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                    Text("°C").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.55))
                }
                Text("设定温度").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                Button { model.set("target-temperature", value: max(room.minimum, (room.target ?? draft) - room.step), delay: 0.6) } label: {
                    Image(systemName: "minus").font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32)
                }.buttonStyle(QuietIconStyle()).help("降低温度").accessibilityLabel("降低温度")
                    .disabled(!room.writable.contains("target-temperature") || (room.target ?? room.minimum) <= room.minimum)
                Slider(value: $draft, in: room.minimum...room.maximum, step: room.step) { editing in
                    if !editing { model.set("target-temperature", value: draft, delay: 0.3) }
                }.tint(Self.accent).disabled(!room.writable.contains("target-temperature"))
                    .accessibilityLabel("设定温度")
                Button { model.set("target-temperature", value: min(room.maximum, (room.target ?? draft) + room.step), delay: 0.6) } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32)
                }.buttonStyle(QuietIconStyle()).help("提高温度").accessibilityLabel("提高温度")
                    .disabled(!room.writable.contains("target-temperature") || (room.target ?? room.maximum) >= room.maximum)
            }
        }.padding(16)
            .background(LinearGradient(colors: [Self.accent.opacity(0.055), Color.white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.075)))
    }

    func options(_ room: RoomReading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运行模式").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(room.modes) { option in
                    let selected = room.mode == option.id
                    Button { model.set("mode", value: option.id) } label: {
                        VStack(spacing: 7) {
                            Image(systemName: modeIcon(option.label)).font(.system(size: 15)).frame(height: 18)
                            Text(option.label).font(.system(size: 11, weight: .medium))
                        }.foregroundStyle(selected ? Self.accent : .white.opacity(0.6))
                            .frame(maxWidth: .infinity).padding(.vertical, 9).modifier(Surface(selected: selected, radius: 10))
                    }.buttonStyle(.plain).disabled(!room.writable.contains("mode"))
                }
            }
            Text("风量").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 5)
            HStack(spacing: 6) {
                ForEach(room.fans) { option in
                    let selected = room.fan == option.id
                    Button { model.set("fan-level", value: option.id) } label: {
                        Text(option.label).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selected ? Self.accent : .white.opacity(0.6))
                            .frame(maxWidth: .infinity).padding(.vertical, 9).modifier(Surface(selected: selected, radius: 9))
                    }.buttonStyle(.plain).disabled(!room.writable.contains("fan-level"))
                }
            }
        }
    }

    var loginContent: some View {
        VStack(spacing: 16) {
            if let qr = model.qr {
                VStack(spacing: 6) {
                    Text("用米家 App 扫码登录").font(.system(size: 16, weight: .semibold))
                    Text("扫码后，在手机上确认登录").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Image(nsImage: qr).resizable().interpolation(.none).frame(width: 232, height: 232)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
                Text("请使用已关联日立设备的米家账号").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("取消登录") { model.logout() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
            } else if model.busy {
                ProgressView().controlSize(.small)
                Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 32, weight: .light)).foregroundStyle(Self.accent).padding(.top, 8)
                VStack(spacing: 7) {
                    Text(model.authState == "authenticated" ? "已连接米家" : "连接家中的舒适").font(.system(size: 17, weight: .semibold))
                    Text(model.authState == "authenticated" ? "同步房间，获取空调设备和状态" : "登录米家，在菜单栏控制各房间空调").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button { if model.authState == "authenticated" { model.resync() } else { model.login() } } label: {
                    Text(model.authState == "authenticated" ? "同步房间" : "扫码登录米家").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.07, green: 0.16, blue: 0.14))
                        .padding(.horizontal, 24).padding(.vertical, 11).background(Self.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 22).modifier(Surface(radius: 18))
    }

    var footer: some View {
        HStack(spacing: 9) {
            if model.busy || !model.pending.isEmpty { ProgressView().controlSize(.mini).frame(width: 12) }
            else { Circle().fill(model.phase == "error" ? Color.orange : Self.accent.opacity(0.75)).frame(width: 5, height: 5) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.message).font(.system(size: 11)).foregroundStyle(model.phase == "error" ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = model.readAt { Text("更新于 \(date.formatted(date: .omitted, time: .standard))").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 4)
            if !model.rooms.isEmpty {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13)).frame(width: 30, height: 30) }
                    .buttonStyle(QuietIconStyle()).disabled(model.busy).help("刷新空调状态").accessibilityLabel("刷新空调状态")
            }
        }.padding(.top, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let room = model.selected {
                roomTabs
                temperatureCard(room)
                options(room)
                if let message = room.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } else { loginContent }
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            footer
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .frame(width: 376, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(.dark)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .background(GeometryReader { geometry in Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height) })
            .onPreferenceChange(PanelHeightKey.self, perform: onHeightChange)
            .onAppear { draft = model.selected?.target ?? 26 }
            .onChange(of: model.selectedID) { _ in draft = model.selected?.target ?? 26 }
            .onChange(of: model.selected?.target) { value in draft = value ?? 26 }
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

// The backdrop and SwiftUI content share the exact same bounds. Measure the
// hosting view, never the material container, to avoid empty bands on resize.
final class PanelContentView: NSView {
    let content: NSView
    let backdrop: NSView
    let usesLiquidGlass: Bool

    init(content: NSView, useLiquidGlass: Bool = true) {
        self.content = content
        if #available(macOS 26.0, *), useLiquidGlass {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = content
            backdrop = glass
            usesLiquidGlass = true
        } else {
            let material = NSVisualEffectView(frame: content.frame)
            material.material = .menu
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 20
            material.layer?.masksToBounds = true
            material.layer?.borderWidth = 1
            material.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            material.addSubview(content)
            backdrop = material
            usesLiquidGlass = false
        }
        super.init(frame: content.frame)
        appearance = NSAppearance(named: .darkAqua)
        autoresizingMask = [.width, .height]
        backdrop.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        content.frame = bounds
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var applicationLease: ApplicationLease?
    var showObserver: NSObjectProtocol?
    var item: NSStatusItem!
    var panel: MenuPanel!
    var model: AppModel!
    var refreshTimer: Timer?
    var clickMonitor: Any?
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let resources = Bundle.main.resourceURL else { NSApp.terminate(nil); return }
        let runtime = AppModel.defaultRuntime
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let lease = ApplicationLease(runtime: runtime) else {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.hitachi.menubar.show"), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        applicationLease = lease
        model = AppModel(worker: resources.appendingPathComponent("CloudWorker/CloudWorker"))
        showObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.hitachi.menubar.show"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.panel != nil, !self.panel.isVisible else { return }
            self.toggle()
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "air.conditioner.horizontal", accessibilityDescription: "日立空调")
        item.button?.title = " 空调"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.titleChanged = { [weak self] title in self?.item.button?.title = title }
        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 376, height: 100),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "日立空调"
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = TransparentHostingView(rootView: ControlView(model: model, onHeightChange: { [weak self] height in
            DispatchQueue.main.async { self?.resizePanel(height: height) }
        }))
        host.sizingOptions = [.intrinsicContentSize]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = PanelContentView(content: host)
        resizePanel(height: host.fittingSize.height)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.panel.orderOut(nil) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.panel.orderOut(nil); return nil }
            return event
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.toggle() }
        }
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--preview=") }) {
            let path = String(argument.dropFirst("--preview=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.resizePanel(height: host.fittingSize.height)
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    if let panel = self?.panel {
                        let dimensions: [String: Double] = ["window_height": panel.contentRect(forFrameRect: panel.frame).height,
                            "content_height": host.bounds.height, "natural_height": host.fittingSize.height]
                        if let data = try? JSONSerialization.data(withJSONObject: dimensions) {
                            try? data.write(to: URL(fileURLWithPath: path + ".layout.json"))
                        }
                    }
                }
            }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.panel.isVisible, !self.model.busy, !self.model.rooms.isEmpty else { return }
            self.model.refresh(automatic: true)
        }
    }

    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil) }
        else {
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            if !model.rooms.isEmpty && !model.busy { model.refresh(automatic: true) }
        }
    }

    func resizePanel(height: CGFloat) {
        guard height > 0 else { return }
        let size = NSSize(width: 376, height: ceil(height))
        if abs(panel.frame.height - size.height) > 0.5 {
            panel.setContentSize(size)
            positionPanel()
        }
        // The glass material fills the measured content, including after login
        // or room-count changes. There is no independent minimum panel height.
        let frame = NSRect(origin: .zero, size: size)
        if panel.contentView?.frame != frame { panel.contentView?.frame = frame }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    func positionPanel() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let width = panel.frame.width
        let x = min(max(anchor.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - panel.frame.height - 8))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finish any already-sent HVAC command and save the readback before worker exit.
        if model?.process?.isRunning == true && model?.process?.arguments?.contains("--field") != true { model.process?.terminate() }
        if let observer = showObserver { DistributedNotificationCenter.default().removeObserver(observer) }
        applicationLease = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
