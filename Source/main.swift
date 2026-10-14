import AppKit
import ApplicationServices
import Security
import Darwin
import ServiceManagement

let service = "com.fortibar.app.vpn"
let fortiID = "com.fortinet.FortiClient"
let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FortiBar")
struct Settings: Codable {
    var profile = ""
    var username = ""
    var ready: Bool { !profile.isEmpty && !username.isEmpty }
    var account: String { "\(profile):\(username)" }
}
var settings: Settings = {
    guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("config.json")),
          let value = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
    return value
}()
func persistSettings() {
    try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    let url = supportDirectory.appendingPathComponent("config.json")
    if let data = try? JSONEncoder().encode(settings) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

func secretQuery(_ account: String = settings.account) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: account]
}
func saveSecret(_ value: String) -> OSStatus {
    let data = Data(value.utf8)
    let status = SecItemUpdate(secretQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status != errSecItemNotFound { return status }
    var q = secretQuery()
    q[kSecValueData as String] = data
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(q as CFDictionary, nil)
}
func loadSecret(_ account: String = settings.account) -> String? {
    var q = secretQuery(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}
if CommandLine.arguments.contains("--store-secret") {
    guard settings.ready else { print("Configure the VPN profile and username first."); exit(2) }
    guard let value = readLine(), !value.isEmpty else { exit(2) }
    let status = saveSecret(value)
    print(status == errSecSuccess ? "Password saved to Keychain." : "Keychain save failed: \(status)")
    exit(status == errSecSuccess ? 0 : 1)
}
if CommandLine.arguments.contains("--check-secret") {
    print(loadSecret() == nil ? "Keychain item unavailable" : "Keychain item available")
    exit(0)
}

func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &v) == .success ? v : nil
}
func string(_ e: AXUIElement, _ key: String) -> String { attr(e, key) as? String ?? "" }
func tree(_ root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        guard depth < 25, result.count < 2000, !result.contains(where: { CFEqual($0, e) }) else { return }
        result.append(e)
        for child in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
        // Hidden applications can omit windows from AXChildren. AXWindows still
        // identifies the actual login/status window; never infer a VPN from an IP.
        if string(e, kAXRoleAttribute) == kAXApplicationRole {
            for window in attr(e, kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window, depth + 1) }
        }
    }
    walk(root, 0)
    return result
}
func fortiRoot() -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: fortiID).first else { return nil }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 2)
    return root
}
func label(_ e: AXUIElement) -> String {
    if string(e, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
        return [kAXTitleAttribute, kAXDescriptionAttribute].map { string(e, $0) }.joined(separator: " ")
    }
    return [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { string(e, $0) }.joined(separator: " ")
}
func identified(_ nodes: [AXUIElement], _ id: String) -> AXUIElement? {
    nodes.first { string($0, kAXIdentifierAttribute) == id || string($0, "AXDOMIdentifier") == id }
}
func button(_ nodes: [AXUIElement], _ names: [String]) -> AXUIElement? {
    nodes.first { element in
        string(element, kAXRoleAttribute) == kAXButtonRole &&
        [kAXTitleAttribute, kAXDescriptionAttribute].contains { names.contains(string(element, $0)) }
    }
}
func enabled(_ e: AXUIElement) -> Bool { (attr(e, kAXEnabledAttribute) as? Bool) != false }
func connectionInfo(_ nodes: [AXUIElement]) -> ConnectionInfo? {
    for node in nodes {
        if let info = parseConnectionInfo(label(node)) { return info }
    }
    return parseConnectionInfo(nodes.map(label).joined(separator: "\n"))
}
func connectedProfile(_ nodes: [AXUIElement]) -> String? { connectionInfo(nodes)?.profile }

enum State: String { case connected, disconnected, unknown, permission, connecting }
final class Controller: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let worker = DispatchQueue(label: "com.fortibar.app.accessibility")
    var timer: Timer?
    var busy = false
    var checking = false
    var state = State.unknown
    var detail = "Checking VPN status"
    var connectStarted: Date?
    var window: NSWindow?
    var setupText: NSTextField?
    var permissionButton: NSButton?
    var awaitingPermission = false
    var lastReport: Data?
    var profileInput: NSTextField?
    var usernameInput: NSTextField?
    var connectButton: NSButton?
    var connectionStatus: NSTextField?
    var startupInfo = ""
    func configureStartup() {
        let legacy = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.fortibar.app.plist")
        if legacy { startupInfo = "Starts at login. One connection attempt per click."; return }
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/") || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed else { startupInfo = "Move FortiBar to Applications to enable startup at login."; return }
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            } catch {
                startupInfo = "Enable FortiBar in System Settings → General → Login Items."
                return
            }
        }
        startupInfo = SMAppService.mainApp.status == .enabled ? "Starts at login. One connection attempt per click." : "Enable FortiBar in System Settings → General → Login Items."
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStartup()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        if !AXIsProcessTrusted() || !settings.ready { showSetup() }
    }
    func render() {
        item.isVisible = state != .connected
        updateSetup()
        let titles: [State: String] = [.connected: "VPN Connected", .disconnected: "Connect VPN", .unknown: "Check VPN",
                                     .permission: "VPN Permission", .connecting: "Connecting…"]
        item.button?.title = titles[state] ?? "VPN"
        item.button?.image = NSImage(systemSymbolName: state == .connected ? "lock.shield.fill" : "network", accessibilityDescription: "FortiBar")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "\(settings.profile) • \(detail)\nRight-click for settings"
        let report: [String: Any] = ["state": state.rawValue, "accessibility": AXIsProcessTrusted(),
                                   "detail": detail,
                                   "buttonVisible": item.isVisible, "fortiClientHidden": NSRunningApplication.runningApplications(withBundleIdentifier: fortiID).first?.isHidden ?? false,
                                   "permissionWindowVisible": awaitingPermission && (window?.isVisible ?? false)]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), data != lastReport {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FortiBar")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
            lastReport = data
        }
    }
    func updateSetup() {
        let trusted = AXIsProcessTrusted()
        let permissionText = trusted ? "Accessibility permission: granted." : "Accessibility permission: required. Allow FortiBar in System Settings → Privacy & Security → Accessibility."
        setupText?.stringValue = "Click Connect VPN in the menu bar when disconnected. Your password is retrieved from Keychain. Complete MFA in FortiClient if required. Once connected, the FortiClient window is hidden.\n\n\(permissionText)"
        permissionButton?.isHidden = trusted
        let reason: String
        if !trusted {
            reason = "Connect unavailable: Accessibility permission required."
        } else if !settings.ready {
            reason = "Connect unavailable: save a VPN profile and username."
        } else if busy {
            reason = "Connection attempt in progress. If macOS asks for Keychain access, approve it in the system dialog."
        } else if state == .connecting {
            reason = "Connecting… waiting for FortiClient. Complete MFA if requested."
        } else if state == .connected {
            reason = "VPN is already connected. Connect becomes available when disconnected."
        } else if state == .unknown {
            reason = "VPN status could not be confirmed. Connect will check FortiClient first."
        } else {
            reason = "VPN is disconnected. Ready to connect. macOS may request Keychain access."
        }
        connectionStatus?.stringValue = reason
        connectButton?.toolTip = reason
        connectButton?.isEnabled = trusted && settings.ready && state != .connected && state != .connecting && !busy
        window?.title = trusted ? "FortiBar — Settings" : "FortiBar — Accessibility Required"
        if trusted && awaitingPermission {
            window?.close()
            awaitingPermission = false
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }
    func observe(_ config: Settings = settings) -> (State, String) {
        guard config.ready else { return (.unknown, "Enter a VPN profile name and username in Settings") }
        guard AXIsProcessTrusted() else {
            return (.permission, "Accessibility access required")
        }
        guard let root = fortiRoot() else { return (.disconnected, "FortiClient will open") }
        let nodes = tree(root)
        let text = nodes.map(label).joined(separator: "\n")
        // FortiClient can retain old status text in its accessibility tree.
        // The actionable login control takes precedence over that text.
        if let action = identified(nodes, "vpn-connect-button") ?? button(nodes, ["Connect", "Bağlan"]), enabled(action) {
            return (.disconnected, "Click to connect")
        }
        if text.contains("VPN Connected") {
            guard let disconnect = button(nodes, ["Disconnect", "Bağlantıyı Kes"]), enabled(disconnect) else {
                return (.unknown, "Connected text has no active Disconnect control; open FortiClient to check")
            }
            guard let info = connectionInfo(nodes), info.profile == config.profile else { return (.unknown, "A different VPN is connected; check FortiClient") }
            guard activeTunnelMatches(info.ip) else {
                return (.disconnected, "No active routed tunnel matches the FortiClient status")
            }
            return (.connected, "VPN connected; FortiClient IP matches the active routed tunnel")
        }
        if text.contains("Connecting") { return (.connecting, "FortiClient is connecting") }
        if identified(nodes, "vpn-connect-button") != nil || button(nodes, ["Connect", "Bağlan"]) != nil {
            return (.disconnected, "Click to connect")
        }
        return (.unknown, "Cannot read FortiClient status; open it to check")
    }
    func refresh() {
        guard !checking, !busy else { return }
        checking = true
        let config = settings
        worker.async {
            let observed = self.observe(config)
            DispatchQueue.main.async {
                self.checking = false
                guard settings.profile == config.profile, settings.username == config.username else { self.refresh(); return }
                if observed.0 == .connected && self.state != .connected {
                    NSRunningApplication.runningApplications(withBundleIdentifier: fortiID).first?.hide()
                }
                if let started = self.connectStarted, observed.0 != .connected {
                    if Date().timeIntervalSince(started) < 45 {
                        self.state = .connecting
                        self.detail = "Waiting for VPN; complete MFA in FortiClient if required"
                    } else {
                        self.connectStarted = nil
                        self.state = observed.0
                        self.detail = "Connection not confirmed. Check FortiClient for an error or MFA prompt."
                    }
                } else {
                    self.connectStarted = nil
                    self.state = observed.0
                    self.detail = observed.1
                }
                self.render()
            }
        }
    }
    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || state == .connected || state == .connecting { showMenu(); return }
        if !AXIsProcessTrusted() { showSetup(); return }
        connect()
    }
    func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "\(settings.profile) — \(detail)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        if state != .connected && state != .connecting {
            let m = menu.addItem(withTitle: "Connect VPN", action: #selector(connect), keyEquivalent: "")
            m.target = self
        }
        for (title, action) in [("Open FortiClient", #selector(openForti)), ("Settings & Password", #selector(showSetup)), ("Quit FortiBar", #selector(quit))] {
            let m = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); m.target = self
        }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
    @objc func openForti() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/FortiClient.app"), configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func connect() {
        guard !busy, connectStarted == nil else { return }
        if state == .connected { NSRunningApplication.runningApplications(withBundleIdentifier: fortiID).first?.hide(); return }
        guard settings.ready else { showSetup(); return }
        guard AXIsProcessTrusted() else { showSetup(); return }
        busy = true; state = .connecting; detail = "Preparing FortiClient"; render()
        openForti()
        let config = settings
        worker.async {
            var result = "FortiClient connection screen not found."
            var submitted = false
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.5)
                guard let root = fortiRoot() else { continue }
                let nodes = tree(root)
                let observed = self.observe(config)
                if observed.0 == .connected { result = "VPN is already connected"; break }
                guard let connect = identified(nodes, "vpn-connect-button") ?? button(nodes, ["Connect", "Bağlan"]), enabled(connect) else { continue }
                // Never enter credentials into a different profile, token, or password-reset prompt.
                guard let profile = identified(nodes, "vpn-connection") ?? nodes.first(where: { string($0, kAXRoleAttribute) == kAXPopUpButtonRole }),
                      string(profile, kAXValueAttribute) == config.profile else {
                    result = "Select the configured VPN profile in FortiClient. No credentials were sent to another profile."; break
                }
                guard let password = identified(nodes, "vpn-password") ?? nodes.first(where: {
                    string($0, kAXRoleAttribute) == kAXTextFieldRole && label($0).lowercased().contains("password") && !label($0).lowercased().contains("confirm")
                }), string(password, kAXSubroleAttribute) == kAXSecureTextFieldSubrole,
                   let secret = loadSecret(config.account) else {
                    result = "Password field or Keychain credential not found."; break
                }
                guard let username = identified(nodes, "vpn-username") ?? nodes.first(where: { string($0, kAXRoleAttribute) == kAXTextFieldRole && label($0).lowercased().contains("username") }),
                      AXUIElementSetAttributeValue(username, kAXValueAttribute as CFString, config.username as CFString) == .success else {
                    result = "Could not fill the username field."; break
                }
                guard AXUIElementSetAttributeValue(password, kAXValueAttribute as CFString, secret as CFString) == .success else {
                    result = "Could not fill the password field. Check FortiClient."; break
                }
                // Fresh tree after mutation prevents clicking a replaced or stale control.
                let fresh = tree(root)
                guard let selected = identified(fresh, "vpn-connection") ?? fresh.first(where: { string($0, kAXRoleAttribute) == kAXPopUpButtonRole }), string(selected, kAXValueAttribute) == config.profile,
                      let action = identified(fresh, "vpn-connect-button") ?? button(fresh, ["Connect", "Bağlan"]), enabled(action),
                      AXUIElementPerformAction(action, kAXPressAction as CFString) == .success else {
                    result = "Could not activate the Connect button."; break
                }
                submitted = true; result = "Connection request submitted"; break
            }
            DispatchQueue.main.async {
                self.busy = false
                self.detail = result
                self.connectStarted = submitted ? Date() : nil
                self.state = submitted ? .connecting : .unknown
                self.render()
                if !submitted { self.alert(result) }
            }
        }
    }
    func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "FortiBar"; a.informativeText = message; a.runModal()
    }
    @objc func showSetup() {
        awaitingPermission = !AXIsProcessTrusted()
        if let existing = window { updateSetup(); existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "FortiBar — Setup"; w.isReleasedWhenClosed = false; w.center()
        let content = w.contentView!
        let text = NSTextField(wrappingLabelWithString: "")
        text.frame = NSRect(x: 22, y: 255, width: 436, height: 148); content.addSubview(text)
        setupText = text
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .boldSystemFont(ofSize: 13)
        status.frame = NSRect(x: 22, y: 205, width: 436, height: 46)
        content.addSubview(status); connectionStatus = status
        for (title, y) in [("VPN profile", 165), ("Username", 125)] {
            let label = NSTextField(labelWithString: title); label.frame = NSRect(x: 22, y: y, width: 100, height: 25); content.addSubview(label)
        }
        let profile = NSTextField(frame: NSRect(x: 125, y: 165, width: 330, height: 26))
        profile.stringValue = settings.profile; profile.placeholderString = "Exact profile name in FortiClient"; content.addSubview(profile); profileInput = profile
        let username = NSTextField(frame: NSRect(x: 125, y: 125, width: 330, height: 26))
        username.stringValue = settings.username; content.addSubview(username); usernameInput = username
        let save = NSButton(title: "Save connection settings", target: self, action: #selector(saveConfiguration))
        save.frame = NSRect(x: 230, y: 85, width: 225, height: 30); content.addSubview(save)
        let connect = NSButton(title: "Connect VPN", target: self, action: #selector(connect))
        connect.frame = NSRect(x: 20, y: 85, width: 190, height: 30); content.addSubview(connect); connectButton = connect
        let permission = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openPermissions))
        permission.frame = NSRect(x: 20, y: 45, width: 260, height: 32); content.addSubview(permission)
        permissionButton = permission
        let password = NSButton(title: "Update Password", target: self, action: #selector(editSecret))
        password.frame = NSRect(x: 290, y: 45, width: 170, height: 32); content.addSubview(password)
        let note = NSTextField(labelWithString: startupInfo)
        note.font = .systemFont(ofSize: 11); note.frame = NSRect(x: 22, y: 17, width: 440, height: 20); content.addSubview(note)
        window = w; updateSetup(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func saveConfiguration() {
        guard !busy, connectStarted == nil else { alert("Wait for the connection attempt to finish before changing settings."); return }
        let profile = profileInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = usernameInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !profile.isEmpty, !username.isEmpty else { alert("VPN profile name and username are required."); return }
        if settings.profile != profile || settings.username != username {
            settings = Settings(profile: profile, username: username)
            persistSettings()
        }
        refresh(); updateSetup()
    }
    @objc func openPermissions() {
        guard !AXIsProcessTrusted() else { updateSetup(); return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func editSecret() {
        guard settings.ready else { alert("Save your VPN profile and username first."); return }
        let a = NSAlert(); a.messageText = "VPN Password"; a.informativeText = "Your password is stored only in this Mac’s Keychain."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        a.accessoryView = input; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn && !input.stringValue.isEmpty {
            let status = saveSecret(input.stringValue); input.stringValue = ""
            if status != errSecSuccess { alert("Could not save to Keychain: \(status)") }
        }
    }
    @objc func quit() {
        // Disable the launch job first so KeepAlive does not immediately restart a user-requested quit.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/com.fortibar.app"]
        try? p.run()
        NSApp.terminate(nil)
    }
}
if CommandLine.arguments.contains("--diagnose") {
    let observation = Controller().observe()
    let report: [String: Any] = ["state": observation.0.rawValue, "detail": observation.1,
                              "accessibility": AXIsProcessTrusted(), "buttonVisible": observation.0 != .connected]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}
let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
