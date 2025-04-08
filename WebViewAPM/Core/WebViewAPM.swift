import Foundation
import WebKit

// MARK: - Internal Logger
struct InternalLogger {
    enum Level: String {
        case debug = "[WebViewAPM Debug]"
        case info = "[WebViewAPM Info]"
        case warning = "[WebViewAPM Warning]"
        case error = "[WebViewAPM Error]"
    }

    static var isDebugEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    static func log(_ level: Level, _ message: String, file: String = #file, function: String = #function, line: UInt = #line) {
        guard level != .debug || isDebugEnabled else { return } // 只在 DEBUG 模式下打印 debug 日志

        let fileName = (file as NSString).lastPathComponent
        let logMessage = "\(level.rawValue) [\(fileName):\(line) \(function)] \(message)"
        print(logMessage)
        // TODO: 可以扩展为写入文件或发送到远程日志服务
    }
}

public class WebViewAPM {

    // MARK: - Singleton Access (可选，但常见)
    // 如果采用单例模式，确保线程安全初始化
    // public static let shared = WebViewAPM()
    // private init() {} // 私有化初始化

    // MARK: - Static Properties (用于全局配置和状态)
    private static var currentConfiguration: APMConfiguration?
    private static var dataProcessor: DataProcessor?
    // 使用字典来存储每个 WKWebView 对应的 MessageHandlerDelegate，避免内存泄漏
    private static var messageHandlers = NSMapTable<WKWebView, MessageHandlerDelegate>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static let setupQueue = DispatchQueue(label: "com.webviewapm.setup.queue") // 用于同步配置访问
    private static var defaultJSAgentContent: String? // 缓存 JS 脚本内容

    // MARK: - Public API

    /// 初始化 WebViewAPM SDK
    /// - Parameter configuration: SDK 的配置对象。必须提供 dataUploader。
    public static func initialize(configuration: APMConfiguration) {
        // 使用队列确保线程安全地更新配置
        setupQueue.async {
            guard configuration.isEnabled else {
                InternalLogger.log(.info, "WebViewAPM SDK 已禁用，跳过初始化。")
                // 如果之前已初始化，需要停止现有处理器
                self.dataProcessor?.stop()
                self.currentConfiguration = configuration // 仍然保存配置，以便知道是禁用状态
                self.dataProcessor = nil
                // 清理可能存在的 Handlers
                // 注意：这里直接清空可能影响已 attach 的 WebView，更好的方式是标记为禁用
                // self.messageHandlers.removeAllObjects()
                return
            }

            guard self.currentConfiguration == nil else {
                InternalLogger.log(.warning, "WebViewAPM SDK 已经初始化，忽略此次调用。如需更改配置，请先考虑停止或提供更新配置的接口。")
                return
            }

            InternalLogger.log(.info, "正在初始化 WebViewAPM SDK...")
            self.currentConfiguration = configuration

            // 创建并启动 DataProcessor
            // 传递 logger 实例或让 DataProcessor 直接调用 InternalLogger
            self.dataProcessor = DataProcessor(configuration: configuration)

            // 启动时尝试加载并上传缓存数据
            self.dataProcessor?.loadAndUploadCachedData()

            // 预加载 JS Agent 脚本内容
            self.loadJavaScriptAgentContent(config: configuration)

            InternalLogger.log(.info, "WebViewAPM SDK 初始化完成。")
        }
    }

    /// 将 APM 监控附加到指定的 WKWebView 实例
    /// - Parameter webView: 需要监控的 WKWebView 对象
    /// - Throws: 如果 SDK 未初始化或配置失败，则抛出错误
    public static func attach(to webView: WKWebView) throws {
        // 在主队列或 setupQueue 访问配置和处理器（取决于哪个更合适，这里用 setupQueue 保持一致性）
        try setupQueue.sync { // 使用 sync 确保 attach 前配置完成且能立即抛错
            guard let config = currentConfiguration, let processor = dataProcessor, config.isEnabled else {
                InternalLogger.log(.error, "无法附加到 WebView：WebViewAPM SDK 未初始化或已禁用。")
                throw APMError.sdkNotInitialized
            }

            guard let scriptContent = getFinalJavaScriptAgentContent(config: config) else {
                 InternalLogger.log(.error, "无法附加到 WebView：未能加载或准备 JS Agent 脚本。")
                 throw APMError.scriptInjectionFailed("JS Agent 脚本无效")
            }

            let userContentController = webView.configuration.userContentController

            // 1. 创建并添加 Message Handler
            if messageHandlers.object(forKey: webView) == nil {
                 let messageHandler = MessageHandlerDelegate(output: processor)
                 userContentController.add(messageHandler, name: config.messageHandlerName)
                 messageHandlers.setObject(messageHandler, forKey: webView)
                 InternalLogger.log(.info, "已为 WebView 添加 Message Handler: \(config.messageHandlerName)")
            } else {
                 InternalLogger.log(.info, "Message Handler (\(config.messageHandlerName)) 已存在于此 WebView。")
            }


            // 2. 创建并添加 User Script
            let userScript = WKUserScript(
                source: scriptContent,
                injectionTime: .atDocumentStart, // 必须在 document start 注入
                forMainFrameOnly: true // 通常只监控主框架
            )
            userContentController.addUserScript(userScript)
            InternalLogger.log(.info, "已为 WebView 添加 User Script。")


             InternalLogger.log(.info, "成功附加 APM 监控到 WebView。")
        }
    }

    /// （可选）从 WKWebView 实例移除 APM 监控
    /// - Parameter webView: 要停止监控的 WKWebView 对象
public static func detach(from webView: WKWebView) {
    setupQueue.async {
        guard let config = currentConfiguration else {
            InternalLogger.log(.warning, "尝试分离，但 SDK 配置不存在。")
            return
        }
        InternalLogger.log(.info, "正在从 WebView 分离 APM 监控...")

        // 在主线程上访问 WKWebView 的 configuration
        DispatchQueue.main.async {
            let userContentController = webView.configuration.userContentController

            // 移除 Message Handler
            if messageHandlers.object(forKey: webView) != nil {
                userContentController.removeScriptMessageHandler(forName: config.messageHandlerName)
                messageHandlers.removeObject(forKey: webView) // 从我们的记录中移除
                InternalLogger.log(.info, "已移除 Message Handler: \(config.messageHandlerName)")
            }

            // 移除 User Script (比较困难，WKWebView 没有直接移除单个脚本的 API)
            // 通常的做法是移除所有脚本，然后重新添加不需要移除的脚本
            // 或者，如果注入脚本时可以添加唯一标识符（例如注释），则可以在获取所有脚本后过滤掉目标脚本
            // 这里简化处理，不主动移除脚本，依赖 WebView 销毁或页面导航
            InternalLogger.log(.warning, "User Script 无法直接移除，将随着 WebView 导航或销毁而失效。")

            InternalLogger.log(.info, "完成从 WebView 分离 APM 监控。")
        }
    }
}

    // MARK: - Private Helpers

    // Checklist Item 10: 实现 JS 注入逻辑 - 加载和准备脚本
    private static func loadJavaScriptAgentContent(config: APMConfiguration) {
        // 如果用户提供了自定义脚本，则优先使用
        if let customScript = config.jsAgentScript {
            InternalLogger.log(.info, "使用用户提供的 JS Agent 脚本。")
            defaultJSAgentContent = customScript // 直接使用，假设用户已处理好占位符
            return
        }

        // 否则，加载内置脚本
        guard let scriptPath = Bundle(for: WebViewAPM.self).path(forResource: "JavaScriptAgent", ofType: "js") else {
            InternalLogger.log(.error, "无法找到内置的 JavaScriptAgent.js 文件。请确保它已添加到 Framework Target 的 Bundle Resources 中。")
            defaultJSAgentContent = nil
            return
        }

        do {
            let scriptContent = try String(contentsOfFile: scriptPath, encoding: .utf8)
            defaultJSAgentContent = scriptContent
            InternalLogger.log(.info, "成功加载内置 JS Agent 脚本。")
        } catch {
            InternalLogger.log(.error, "读取内置 JS Agent 脚本失败: \(error)")
            defaultJSAgentContent = nil
        }
    }

    private static func getFinalJavaScriptAgentContent(config: APMConfiguration) -> String? {
         // 如果使用自定义脚本，直接返回（假设用户已处理占位符或不需要）
         if config.jsAgentScript != nil {
             return defaultJSAgentContent // 返回缓存的自定义脚本或 nil
         }

         // 否则，处理内置脚本的占位符
         guard var scriptContent = defaultJSAgentContent else {
             InternalLogger.log(.error, "内置 JS Agent 脚本内容为空。")
             return nil
         }

         // 替换占位符
         let placeholder = "{{MESSAGE_HANDLER_NAME_PLACEHOLDER}}"
         scriptContent = scriptContent.replacingOccurrences(of: placeholder, with: config.messageHandlerName)
         InternalLogger.log(.debug, "JS Agent 脚本占位符已替换为: \(config.messageHandlerName)")

         return scriptContent
    }

    // MARK: - Logging (已由 InternalLogger 替代)
    // private static func logInfo(_ message: String) { print("[WebViewAPM Info] \(message)") }
    // private static func logWarning(_ message: String) { print("[WebViewAPM Warning] \(message)") }
    // private static func logError(_ message: String) { print("[WebViewAPM Error] \(message)") }
    // private static func logDebug(_ message: String) {
    //     #if DEBUG
    //     print("[WebViewAPM Debug] \(message)")
    //     #endif
    // }
}

// MARK: - Custom Error Type
enum APMError: Error, LocalizedError {
    case sdkNotInitialized
    case scriptInjectionFailed(String)
    // 可以添加更多错误类型

    var errorDescription: String? {
        switch self {
        case .sdkNotInitialized:
            return "WebViewAPM SDK 未初始化或已禁用。"
        case .scriptInjectionFailed(let reason):
            return "JS 脚本注入失败: \(reason)"
        }
    }
} 