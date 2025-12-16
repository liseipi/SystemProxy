import SwiftUI
import NetworkExtension
import Combine
import Security

// MARK: - 代理配置模型
struct ProxyConfiguration: Codable {
    var proxyHost: String
    var proxyPort: String
    var isEnabled: Bool
    var proxyType: ProxyType
    var networkInterface: String
    
    enum ProxyType: String, Codable, CaseIterable {
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
            proxyPort: "1080",
            isEnabled: false,
            proxyType: .http,
            networkInterface: "Wi-Fi"
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
    
    // 使用 Process 和 AuthorizationExecuteWithPrivileges 的替代方案
    private func executeProxyCommands(enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let commands: [(cmd: String, args: [String])]
            
            if enabled {
                switch self.configuration.proxyType {
                case .http:
                    commands = [
                        ("/usr/sbin/networksetup", ["-setwebproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.proxyPort]),
                        ("/usr/sbin/networksetup", ["-setwebproxystate", self.configuration.networkInterface, "on"])
                    ]
                case .https:
                    commands = [
                        ("/usr/sbin/networksetup", ["-setsecurewebproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.proxyPort]),
                        ("/usr/sbin/networksetup", ["-setsecurewebproxystate", self.configuration.networkInterface, "on"])
                    ]
                case .socks5:
                    commands = [
                        ("/usr/sbin/networksetup", ["-setsocksfirewallproxy", self.configuration.networkInterface, self.configuration.proxyHost, self.configuration.proxyPort]),
                        ("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", self.configuration.networkInterface, "on"])
                    ]
                }
            } else {
                commands = [
                    ("/usr/sbin/networksetup", ["-setwebproxystate", self.configuration.networkInterface, "off"]),
                    ("/usr/sbin/networksetup", ["-setsecurewebproxystate", self.configuration.networkInterface, "off"]),
                    ("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", self.configuration.networkInterface, "off"])
                ]
            }
            
            // 使用 AppleScript 执行命令
            var allSuccess = true
            for (cmd, args) in commands {
                let argString = args.map { "\"\($0)\"" }.joined(separator: " ")
                let fullCommand = "\(cmd) \(argString)"
                
                let script = """
                do shell script "\(fullCommand)" with administrator privileges
                """
                
                var error: NSDictionary?
                if let scriptObject = NSAppleScript(source: script) {
                    let result = scriptObject.executeAndReturnError(&error)
                    
                    if let error = error {
                        print("命令执行失败: \(fullCommand)")
                        print("错误: \(error)")
                        allSuccess = false
                        
                        DispatchQueue.main.async {
                            let errorCode = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                            let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "未知错误"
                            
                            if errorCode == -128 {
                                self.statusMessage = "⚠️ 操作已取消"
                            } else if errorCode == -2825 {
                                self.statusMessage = "⚠️ 需要管理员权限,请在弹出的对话框中输入密码"
                            } else {
                                self.statusMessage = "❌ 错误 (\(errorCode)): \(errorMessage)"
                            }
                        }
                        break
                    } else {
                        print("命令执行成功: \(fullCommand)")
                        if let resultString = result.stringValue {
                            print("结果: \(resultString)")
                        }
                    }
                } else {
                    allSuccess = false
                    break
                }
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if allSuccess {
                    self.configuration.isEnabled = enabled
                    self.statusMessage = enabled ?
                        "✅ 代理已启用 - \(self.configuration.proxyType.rawValue) \(self.configuration.proxyHost):\(self.configuration.proxyPort)" :
                        "✅ 代理已禁用"
                    self.saveConfiguration()
                } else {
                    self.configuration.isEnabled = false
                }
            }
        }
    }
    
    func checkProxyStatus() {
        statusMessage = "正在检查代理状态..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let task = Process()
            task.launchPath = "/usr/sbin/networksetup"
            task.arguments = ["-getwebproxy", self.configuration.networkInterface]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let isEnabled = output.contains("Enabled: Yes")
                    
                    DispatchQueue.main.async {
                        if isEnabled {
                            // 提取服务器和端口信息
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
                            
                            self.statusMessage = "✅ 代理已启用 - \(server):\(port)"
                        } else {
                            self.statusMessage = "⚪️ 代理当前未启用"
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "❌ 无法检查代理状态"
                }
            }
        }
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
        
        switch configuration.proxyType {
        case .http:
            proxyDict = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: configuration.proxyHost,
                kCFNetworkProxiesHTTPPort as String: Int(configuration.proxyPort) ?? 1080
            ]
        case .https:
            proxyDict = [
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: configuration.proxyHost,
                kCFNetworkProxiesHTTPSPort as String: Int(configuration.proxyPort) ?? 1080
            ]
        case .socks5:
            proxyDict = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: configuration.proxyHost,
                kCFNetworkProxiesSOCKSPort as String: Int(configuration.proxyPort) ?? 1080
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
                
                Picker("", selection: $proxyManager.configuration.proxyType) {
                    ForEach(ProxyConfiguration.ProxyType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .disabled(proxyManager.configuration.isEnabled)
            }
            .padding(.horizontal)
            
            // 代理服务器配置
            VStack(alignment: .leading, spacing: 8) {
                Text("代理服务器")
                    .font(.headline)
                
                HStack {
                    TextField("IP 地址", text: $proxyManager.configuration.proxyHost)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(proxyManager.configuration.isEnabled)
                    
                    Text(":")
                        .font(.title3)
                    
                    TextField("端口", text: $proxyManager.configuration.proxyPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)
                        .disabled(proxyManager.configuration.isEnabled)
                }
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
                .disabled(proxyManager.isLoading)
                
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
                
                Label("代理将应用于整个系统的所有网络连接", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .frame(width: 480, height: 580)
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
                    title: "配置代理信息",
                    description: "填写代理服务器的 IP 地址和端口,通常本地代理使用 127.0.0.1"
                )
                
                HelpItem(
                    icon: "3.circle.fill",
                    title: "选择网络接口",
                    description: "Wi-Fi 用于无线连接,以太网用于有线连接"
                )
                
                HelpItem(
                    icon: "4.circle.fill",
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
        .frame(width: 400)
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
