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
    
    private let defaults = UserDefaults.standard
    private let configKey = "ProxyConfiguration"
    
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
    }
    
    // 执行多个命令（只需要一次授权）
    private func executeCommands(_ commands: [(cmd: String, args: [String], description: String)]) -> (success: Bool, error: String?, failedStep: String?) {
        // 构建所有命令的 shell 脚本
        var shellCommands: [String] = []
        
        for (cmd, args, description) in commands {
            let escapedArgs = args.map { arg in
                // 对参数进行适当的引号处理
                if arg.contains(" ") {
                    return "'\(arg)'"
                }
                return arg
            }
            let fullCommand = "\(cmd) \(escapedArgs.joined(separator: " "))"
            shellCommands.append(fullCommand)
            print("准备执行: \(description) - \(fullCommand)")
        }
        
        // 用分号连接所有命令
        let combinedScript = shellCommands.joined(separator: "; ")
        
        let script = """
        do shell script "\(escapeForAppleScript(combinedScript))" with administrator privileges
        """
        
        print("\n完整脚本:\n\(combinedScript)\n")
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            
            if let error = error {
                let errorCode = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
                print("命令执行失败")
                print("错误码: \(errorCode), 错误信息: \(errorMessage)")
                
                if errorCode == -128 {
                    return (false, "用户取消了操作", nil)
                } else if errorCode == -2825 {
                    return (false, "需要管理员权限", nil)
                } else {
                    return (false, "错误 (\(errorCode)): \(errorMessage)", nil)
                }
            } else {
                print("所有命令执行成功")
                if let resultString = result.stringValue, !resultString.isEmpty {
                    print("结果: \(resultString)")
                }
                return (true, nil, nil)
            }
        }
        
        return (false, "无法创建 AppleScript", nil)
    }
    
    private func executeProxyCommands(enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var commands: [(cmd: String, args: [String], description: String)] = []
            
            if enabled {
                // HTTP 代理
                if self.configuration.enabledTypes.contains(.http) {
                    commands.append((cmd: "/usr/sbin/networksetup",
                                   args: ["-setwebproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.httpPort],
                                   description: "设置 HTTP 代理"))
                    commands.append((cmd: "/usr/sbin/networksetup",
                                   args: ["-setwebproxystate", self.configuration.networkInterface, "on"],
                                   description: "启用 HTTP 代理"))
                    // 设置绕过列表
                    commands.append((cmd: "/usr/sbin/networksetup",
                                   args: ["-setproxybypassdomains", self.configuration.networkInterface] + self.configuration.bypassDomains.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                                   description: "设置代理绕过列表"))
                }
                
                // HTTPS 代理
                if self.configuration.enabledTypes.contains(.https) {
                    commands.append((cmd: "/usr/sbin/networksetup",
                                   args: ["-setsecurewebproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.httpsPort],
                                   description: "设置 HTTPS 代理"))
                    commands.append((cmd: "/usr/sbin/networksetup",
                                   args: ["-setsecurewebproxystate", self.configuration.networkInterface, "on"],
                                   description: "启用 HTTPS 代理"))
                }
                
                // SOCKS5 代理
                if self.configuration.enabledTypes.contains(.socks5) {
                    commands.append((cmd: "/usr/sbin/networksetup",
                                   args: ["-setsocksfirewallproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.socks5Port],
                                   description: "设置 SOCKS5 代理"))
                    commands.append((cmd: "/usr/sbin/networksetup",
                                   args: ["-setsocksfirewallproxystate", self.configuration.networkInterface, "on"],
                                   description: "启用 SOCKS5 代理"))
                }
            } else {
                // 禁用所有代理类型
                commands = [
                    (cmd: "/usr/sbin/networksetup",
                     args: ["-setwebproxystate", self.configuration.networkInterface, "off"],
                     description: "禁用 HTTP 代理"),
                    (cmd: "/usr/sbin/networksetup",
                     args: ["-setsecurewebproxystate", self.configuration.networkInterface, "off"],
                     description: "禁用 HTTPS 代理"),
                    (cmd: "/usr/sbin/networksetup",
                     args: ["-setsocksfirewallproxystate", self.configuration.networkInterface, "off"],
                     description: "禁用 SOCKS5 代理")
                ]
            }
            
            var allSuccess = true
            var failedStep = ""
            
            // 一次性执行所有命令
            let result = self.executeCommands(commands)
            
            if !result.success {
                allSuccess = false
                failedStep = result.failedStep ?? "未知步骤"
                
                DispatchQueue.main.async {
                    self.statusMessage = "❌ 执行失败: \(result.error ?? "未知错误")"
                    self.isLoading = false
                    self.configuration.isEnabled = false
                }
                return
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
                }
            }
        }
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
        
        // 如果启用了 HTTP，使用 HTTP 代理测试
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
                
                // 主机地址
                HStack {
                    Text("主机:")
                        .frame(width: 80, alignment: .leading)
                    TextField("IP 地址", text: $proxyManager.configuration.proxyHost)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(proxyManager.configuration.isEnabled)
                }
                
                // HTTP 端口
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
                
                // HTTPS 端口
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
                
                // SOCKS5 端口
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
                    .help("这些地址将直接连接，不通过代理。防止代理软件自身进入死循环。")
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
                
                Text("多个地址用逗号分隔，支持通配符 (如 *.local) 和 CIDR (如 192.168.0.0/16)")
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
                        .multilineTextAlignment(.leading)
                }
                
                if proxyManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .frame(minHeight: 60)
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
            
            Divider()
                .padding(.horizontal)
            
            // 说明文本
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("首次启动需要输入管理员密码")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(8)
                
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                    Text("本地地址已自动绕过，避免代理软件死循环")
                        .font(.caption)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .frame(width: 480, height: 720)
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
                    title: "启动代理服务器",
                    description: "在启动此工具前,确保你的代理服务器(如 Clash、V2Ray 等)已经运行"
                )
                
                HelpItem(
                    icon: "2.circle.fill",
                    title: "选择代理类型",
                    description: "可以同时勾选 HTTP、HTTPS 和 SOCKS5，它们可以使用不同的端口"
                )
                
                HelpItem(
                    icon: "3.circle.fill",
                    title: "配置代理信息",
                    description: "填写代理服务器的 IP 地址和各类型的端口号。例如：Clash 通常 HTTP/HTTPS 用 7890，SOCKS5 用 7891"
                )
                
                HelpItem(
                    icon: "4.circle.fill",
                    title: "选择网络接口",
                    description: "Wi-Fi 用于无线连接,以太网用于有线连接"
                )
                
                HelpItem(
                    icon: "5.circle.fill",
                    title: "输入管理员密码",
                    description: "点击启动代理时会弹出密码对话框,输入你的 Mac 登录密码"
                )
                
                HelpItem(
                    icon: "checkmark.circle.fill",
                    title: "测试连接",
                    description: "启动代理后,可以点击测试连接按钮验证代理是否正常工作"
                )
            }
            
            Divider()
            
            Text("常见配置")
                .font(.headline)
            
            Text("• Clash: HTTP/HTTPS 端口 7890，SOCKS5 端口 7891")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("• V2Ray: 通常使用 SOCKS5，端口 1080")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("• Shadowrocket: 根据配置，通常 HTTP 1087，SOCKS5 1086")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            Text("绕过列表说明")
                .font(.headline)
            
            Text("• 默认已包含本地地址，防止代理软件死循环")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("• 如需添加其他地址，用逗号分隔")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("• 例如：127.0.0.1, localhost, *.apple.com, 192.168.0.0/16")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            Text("常见问题")
                .font(.headline)
            
            Text("• 如果没有弹出密码框,请检查系统设置中的辅助功能权限")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("• 如果代理无法使用,请确认代理服务器地址和端口正确")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("• 停止使用时记得关闭代理,否则可能无法正常上网")
                .font(.caption)
                .foregroundColor(.secondary)
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
