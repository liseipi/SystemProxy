import SwiftUI
import NetworkExtension
import Combine
import Security

// MARK: - 代理配置模型
struct ProxyConfiguration: Codable {
    var proxyHost: String
    var httpPort: String
    var httpsPort: String
    var socks5Port: String
    var isEnabled: Bool
    var enabledTypes: Set<ProxyType>
    var networkInterface: String
    var bypassDomains: String
    
    enum ProxyType: String, Codable, CaseIterable, Hashable {
        case http = "HTTP"
        case https = "HTTPS"
        case socks5 = "SOCKS5"
    }
}

// MARK: - 代理管理器
class ProxyManager: ObservableObject {
    @Published var configuration: ProxyConfiguration
    @Published var statusMessage: String
    @Published var isLoading: Bool
    @Published var networkInterfaces: [String] = []
    @Published var isHelperInstalled: Bool = false
    
    private let defaults = UserDefaults.standard
    private let configKey = "ProxyConfiguration"
    private let helperPath = "/usr/local/bin/systemproxy-helper"
    
    init() {
        self.configuration = ProxyConfiguration(
            proxyHost: "127.0.0.1",
            httpPort: "7890",
            httpsPort: "7890",
            socks5Port: "7891",
            isEnabled: false,
            enabledTypes: [.http, .https, .socks5],
            networkInterface: "Wi-Fi",
            bypassDomains: "127.0.0.1, localhost, *.local, 192.168.0.0/16, 10.0.0.0/8"
        )
        self.statusMessage = "代理未启用"
        self.isLoading = false
        
        loadNetworkInterfaces()
        loadConfiguration()
        checkHelperInstallation()
    }
    
    // 检查辅助脚本是否已安装
    func checkHelperInstallation() {
        let fileManager = FileManager.default
        isHelperInstalled = fileManager.fileExists(atPath: helperPath) && fileManager.isExecutableFile(atPath: helperPath)
    }
    
    // 安装辅助脚本（只需一次密码）
    func installHelper() {
        isLoading = true
        statusMessage = "正在安装辅助工具..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 创建辅助脚本内容
            let helperScript = """
            #!/bin/bash
            # SystemProxy Helper Script
            # This script runs networksetup commands with elevated privileges
            
            if [ "$#" -lt 2 ]; then
                echo "Usage: $0 <command> <args...>"
                exit 1
            fi
            
            /usr/sbin/networksetup "$@"
            """
            
            // 使用 AppleScript 一次性安装脚本
            let script = """
            do shell script "echo '\(self.escapeForAppleScript(helperScript))' | sudo tee \(helperPath) > /dev/null && sudo chmod +x \(helperPath)" with administrator privileges
            """
            
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: script) {
                let result = scriptObject.executeAndReturnError(&error)
                
                DispatchQueue.main.async {
                    if let error = error {
                        let errorCode = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                        if errorCode == -128 {
                            self.statusMessage = "❌ 用户取消了安装"
                        } else {
                            self.statusMessage = "❌ 安装失败"
                        }
                        self.isLoading = false
                    } else {
                        self.isHelperInstalled = true
                        self.statusMessage = "✅ 辅助工具安装成功！现在可以无需密码切换代理"
                        self.isLoading = false
                    }
                }
            }
        }
    }
    
    // 卸载辅助脚本
    func uninstallHelper() {
        let script = """
        do shell script "sudo rm -f \(helperPath)" with administrator privileges
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if error == nil {
                isHelperInstalled = false
                statusMessage = "✅ 辅助工具已卸载"
            }
        }
    }
    
    // 加载网络接口列表
    func loadNetworkInterfaces() {
        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments = ["-listallnetworkservices"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let interfaces = output.components(separatedBy: "\n")
                    .filter { !$0.isEmpty && !$0.contains("*") && $0 != "An asterisk (*) denotes that a network service is disabled." }
                
                DispatchQueue.main.async {
                    self.networkInterfaces = interfaces
                    if !interfaces.contains(self.configuration.networkInterface), let first = interfaces.first {
                        self.configuration.networkInterface = first
                    }
                }
            }
        } catch {
            print("无法加载网络接口: \(error)")
        }
    }
    
    func saveConfiguration() {
        if let encoded = try? JSONEncoder().encode(configuration) {
            defaults.set(encoded, forKey: configKey)
        }
    }
    
    func loadConfiguration() {
        if let data = defaults.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode(ProxyConfiguration.self, from: data) {
            configuration = decoded
        }
    }
    
    func enableProxy() {
        isLoading = true
        statusMessage = "正在启用代理..."
        executeProxyCommands(enabled: true)
    }
    
    func disableProxy() {
        isLoading = true
        statusMessage = "正在禁用代理..."
        executeProxyCommands(enabled: false)
    }
    
    // 转义 AppleScript 字符串
    private func escapeForAppleScript(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
    
    // 使用辅助脚本执行命令（无需密码）
    private func executeWithHelper(_ args: [String]) -> Bool {
        let task = Process()
        task.launchPath = helperPath
        task.arguments = args
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            print("执行失败: \(error)")
            return false
        }
    }
    
    // 执行代理命令
    private func executeProxyCommands(enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var commands: [[String]] = []
            
            if enabled {
                // HTTP 代理
                if self.configuration.enabledTypes.contains(.http) {
                    commands.append(["-setwebproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.httpPort])
                    commands.append(["-setwebproxystate", self.configuration.networkInterface, "on"])
                    
                    let bypassList = self.configuration.bypassDomains.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    commands.append(["-setproxybypassdomains", self.configuration.networkInterface] + bypassList)
                }
                
                // HTTPS 代理
                if self.configuration.enabledTypes.contains(.https) {
                    commands.append(["-setsecurewebproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.httpsPort])
                    commands.append(["-setsecurewebproxystate", self.configuration.networkInterface, "on"])
                }
                
                // SOCKS5 代理
                if self.configuration.enabledTypes.contains(.socks5) {
                    commands.append(["-setsocksfirewallproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.socks5Port])
                    commands.append(["-setsocksfirewallproxystate", self.configuration.networkInterface, "on"])
                }
            } else {
                // 禁用所有代理类型
                commands = [
                    ["-setwebproxystate", self.configuration.networkInterface, "off"],
                    ["-setsecurewebproxystate", self.configuration.networkInterface, "off"],
                    ["-setsocksfirewallproxystate", self.configuration.networkInterface, "off"]
                ]
            }
            
            var allSuccess = true
            
            if self.isHelperInstalled {
                // 使用辅助脚本（无需密码）
                for args in commands {
                    if !self.executeWithHelper(args) {
                        allSuccess = false
                        break
                    }
                }
            } else {
                // 回退到 AppleScript（需要密码）
                let result = self.executeCommandsWithAppleScript(commands)
                allSuccess = result.success
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if allSuccess {
                    self.configuration.isEnabled = enabled
                    if enabled {
                        var parts: [String] = []
                        if self.configuration.enabledTypes.contains(.http) {
                            parts.append("HTTP:\(self.configuration.httpPort)")
                        }
                        if self.configuration.enabledTypes.contains(.https) {
                            parts.append("HTTPS:\(self.configuration.httpsPort)")
                        }
                        if self.configuration.enabledTypes.contains(.socks5) {
                            parts.append("SOCKS5:\(self.configuration.socks5Port)")
                        }
                        self.statusMessage = "✅ 代理已启用 - \(parts.joined(separator: ", "))"
                    } else {
                        self.statusMessage = "✅ 代理已禁用"
                    }
                    self.saveConfiguration()
                } else {
                    self.statusMessage = "❌ 操作失败"
                    self.configuration.isEnabled = false
                }
            }
        }
    }
    
    // 使用 AppleScript 执行命令（需要密码）
    private func executeCommandsWithAppleScript(_ commands: [[String]]) -> (success: Bool, error: String?) {
        var shellCommands: [String] = []
        
        for args in commands {
            let escapedArgs = args.map { arg in
                if arg.contains(" ") {
                    return "'\(arg)'"
                }
                return arg
            }
            shellCommands.append("/usr/sbin/networksetup \(escapedArgs.joined(separator: " "))")
        }
        
        let combinedScript = shellCommands.joined(separator: "; ")
        let script = """
        do shell script "\(escapeForAppleScript(combinedScript))" with administrator privileges
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            
            if let error = error {
                let errorCode = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
                return (false, "错误 (\(errorCode)): \(errorMessage)")
            }
            return (true, nil)
        }
        
        return (false, "无法创建 AppleScript")
    }
    
    func checkProxyStatus() {
        statusMessage = "正在检查代理状态..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var statusParts: [String] = []
            
            // 检查 HTTP 代理
            if let httpStatus = self.getProxyStatus(type: "webproxy") {
                statusParts.append(httpStatus)
            }
            
            // 检查 HTTPS 代理
            if let httpsStatus = self.getProxyStatus(type: "securewebproxy") {
                statusParts.append(httpsStatus)
            }
            
            // 检查 SOCKS5 代理
            if let socksStatus = self.getProxyStatus(type: "socksfirewallproxy") {
                statusParts.append(socksStatus)
            }
            
            DispatchQueue.main.async {
                if statusParts.isEmpty {
                    self.statusMessage = "⚪️ 所有代理均未启用"
                    self.configuration.isEnabled = false
                } else {
                    self.statusMessage = "✅ 已启用: \(statusParts.joined(separator: ", "))"
                    self.configuration.isEnabled = true
                }
            }
        }
    }
    
    private func getProxyStatus(type: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments = ["-get\(type)", self.configuration.networkInterface]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                if output.contains("Enabled: Yes") {
                    let lines = output.components(separatedBy: "\n")
                    var server = ""
                    var port = ""
                    
                    for line in lines {
                        if line.contains("Server:") {
                            server = line.replacingOccurrences(of: "Server:", with: "").trimmingCharacters(in: .whitespaces)
                        } else if line.contains("Port:") {
                            port = line.replacingOccurrences(of: "Port:", with: "").trimmingCharacters(in: .whitespaces)
                        }
                    }
                    
                    let typeName = type == "webproxy" ? "HTTP" : (type == "securewebproxy" ? "HTTPS" : "SOCKS5")
                    return "\(typeName) \(server):\(port)"
                }
            }
        } catch {
            print("检查 \(type) 状态失败: \(error)")
        }
        
        return nil
    }
    
    func testProxy() {
        statusMessage = "正在测试代理连接..."
        
        guard let url = URL(string: "https://www.google.com") else {
            statusMessage = "无效的测试URL"
            return
        }
        
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        
        var proxyDict: [String: Any] = [:]
        
        if configuration.enabledTypes.contains(.http) {
            proxyDict = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: configuration.proxyHost,
                kCFNetworkProxiesHTTPPort as String: Int(configuration.httpPort) ?? 7890
            ]
        } else if configuration.enabledTypes.contains(.socks5) {
            proxyDict = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: configuration.proxyHost,
                kCFNetworkProxiesSOCKSPort as String: Int(configuration.socks5Port) ?? 7891
            ]
        }
        
        config.connectionProxyDictionary = proxyDict
        let session = URLSession(configuration: config)
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.statusMessage = "❌ 代理测试失败: \(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse {
                    self?.statusMessage = "✅ 代理测试成功! HTTP \(httpResponse.statusCode)"
                }
            }
        }
        task.resume()
    }
}

// MARK: - 主视图
struct ContentView: View {
    @StateObject private var proxyManager = ProxyManager()
    @State private var showHelp = false
    
    var body: some View {
        VStack(spacing: 20) {
            // 标题栏
            HStack {
                Text("系统级代理工具")
                    .font(.system(size: 24, weight: .bold))
                
                Spacer()
                
                Button(action: {
                    showHelp.toggle()
                }) {
                    Image(systemName: "questionmark.circle")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .popover(isPresented: $showHelp) {
                    HelpView()
                }
            }
            .padding(.horizontal)
            .padding(.top)
            
            // 辅助工具状态
            if !proxyManager.isHelperInstalled {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("安装辅助工具后，切换代理将不再需要输入密码")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    
                    Button(action: {
                        proxyManager.installHelper()
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("安装辅助工具（仅需一次密码）")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
                .padding(.horizontal)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("辅助工具已安装 - 可无密码切换代理")
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Button("卸载") {
                        proxyManager.uninstallHelper()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .font(.caption)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(10)
                .padding(.horizontal)
            }
            
            // 网络接口选择
            VStack(alignment: .leading, spacing: 8) {
                Text("网络接口")
                    .font(.headline)
                
                Picker("", selection: $proxyManager.configuration.networkInterface) {
                    ForEach(proxyManager.networkInterfaces, id: \.self) { interface in
                        Text(interface).tag(interface)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .disabled(proxyManager.configuration.isEnabled)
                .onChange(of: proxyManager.configuration.networkInterface) { _, _ in
                    proxyManager.saveConfiguration()
                }
            }
            .padding(.horizontal)
            
            // 代理类型选择
            VStack(alignment: .leading, spacing: 8) {
                Text("代理类型")
                    .font(.headline)
                
                HStack(spacing: 15) {
                    ForEach(ProxyConfiguration.ProxyType.allCases, id: \.self) { type in
                        Toggle(isOn: Binding(
                            get: { proxyManager.configuration.enabledTypes.contains(type) },
                            set: { isEnabled in
                                if isEnabled {
                                    proxyManager.configuration.enabledTypes.insert(type)
                                } else {
                                    proxyManager.configuration.enabledTypes.remove(type)
                                }
                                proxyManager.saveConfiguration()
                            }
                        )) {
                            Text(type.rawValue)
                                .font(.subheadline)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(proxyManager.configuration.isEnabled)
                    }
                }
            }
            .padding(.horizontal)
            
            // 代理服务器配置
            VStack(alignment: .leading, spacing: 12) {
                Text("代理服务器")
                    .font(.headline)
                
                HStack {
                    Text("主机:")
                        .frame(width: 80, alignment: .leading)
                    TextField("IP 地址", text: $proxyManager.configuration.proxyHost)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(proxyManager.configuration.isEnabled)
                }
                
                if proxyManager.configuration.enabledTypes.contains(.http) {
                    HStack {
                        Text("HTTP 端口:")
                            .frame(width: 80, alignment: .leading)
                        TextField("端口", text: $proxyManager.configuration.httpPort)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 100)
                            .disabled(proxyManager.configuration.isEnabled)
                        Spacer()
                    }
                }
                
                if proxyManager.configuration.enabledTypes.contains(.https) {
                    HStack {
                        Text("HTTPS 端口:")
                            .frame(width: 80, alignment: .leading)
                        TextField("端口", text: $proxyManager.configuration.httpsPort)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 100)
                            .disabled(proxyManager.configuration.isEnabled)
                        Spacer()
                    }
                }
                
                if proxyManager.configuration.enabledTypes.contains(.socks5) {
                    HStack {
                        Text("SOCKS5 端口:")
                            .frame(width: 80, alignment: .leading)
                        TextField("端口", text: $proxyManager.configuration.socks5Port)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 100)
                            .disabled(proxyManager.configuration.isEnabled)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal)
            
            // 代理绕过列表
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("绕过代理的地址")
                        .font(.headline)
                    
                    Button(action: {}) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("这些地址将直接连接，不通过代理")
                }
                
                TextEditor(text: $proxyManager.configuration.bypassDomains)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .disabled(proxyManager.configuration.isEnabled)
                    .onChange(of: proxyManager.configuration.bypassDomains) { _, _ in
                        proxyManager.saveConfiguration()
                    }
                
                Text("多个地址用逗号分隔")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            
            // 状态显示
            VStack(spacing: 8) {
                HStack {
                    Circle()
                        .fill(proxyManager.configuration.isEnabled ? Color.green : Color.gray)
                        .frame(width: 12, height: 12)
                    
                    Text(proxyManager.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                
                if proxyManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .frame(minHeight: 50)
            .padding(.horizontal)
            
            // 控制按钮
            HStack(spacing: 12) {
                Button(action: {
                    if proxyManager.configuration.isEnabled {
                        proxyManager.disableProxy()
                    } else {
                        proxyManager.enableProxy()
                    }
                }) {
                    HStack {
                        Image(systemName: proxyManager.configuration.isEnabled ? "stop.circle.fill" : "play.circle.fill")
                        Text(proxyManager.configuration.isEnabled ? "停止代理" : "启动代理")
                    }
                    .frame(width: 110)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(proxyManager.configuration.isEnabled ? .red : .green)
                .disabled(proxyManager.isLoading || proxyManager.configuration.enabledTypes.isEmpty)
                
                Button(action: {
                    proxyManager.checkProxyStatus()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("检查状态")
                    }
                    .frame(width: 110)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(proxyManager.isLoading)
                
                Button(action: {
                    proxyManager.testProxy()
                }) {
                    HStack {
                        Image(systemName: "network")
                        Text("测试连接")
                    }
                    .frame(width: 110)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(!proxyManager.configuration.isEnabled || proxyManager.isLoading)
            }
            
            Spacer()
        }
        .frame(width: 480, height: 780)
        .padding()
    }
}

// MARK: - 帮助视图
struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("使用帮助")
                .font(.title2)
                .fontWeight(.bold)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                HelpItem(
                    icon: "1.circle.fill",
                    title: "安装辅助工具（推荐）",
                    description: "首次使用时点击安装辅助工具，输入一次密码后，以后切换代理将无需再输入密码"
                )
                
                HelpItem(
                    icon: "2.circle.fill",
                    title: "启动代理服务器",
                    description: "确保你的代理服务器(如 Clash、V2Ray 等)已经运行"
                )
                
                HelpItem(
                    icon: "3.circle.fill",
                    title: "配置代理信息",
                    description: "填写代理服务器的 IP 地址和端口号"
                )
                
                HelpItem(
                    icon: "4.circle.fill",
                    title: "启动/停止代理",
                    description: "如已安装辅助工具，切换将立即生效；否则需要输入密码"
                )
            }
            
            Divider()
            
            Text("安全说明")
                .font(.headline)
            
            Text("辅助工具安装在 /usr/local/bin/ 目录，仅用于执行 networksetup 命令。你可以随时点击 '卸载'按钮移除它。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 420)
    }
}

struct HelpItem: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - App 入口
@main
struct SystemProxyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
