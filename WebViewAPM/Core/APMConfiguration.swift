import Foundation
import WebKit

// 数据上传器协议
public protocol APMDataUploader {
    /// 上传收集到的 APM 记录
    /// - Parameters:
    ///   - data: 一个包含 APMRecordable 对象的数组
    ///   - completion: 上报完成后的回调，参数表示是否成功
    func upload(data: [APMRecordable], completion: @escaping (Bool) -> Void)
}

// SDK 配置结构体
public struct APMConfiguration {
    /// 必需：实现数据上报逻辑的对象
    let dataUploader: APMDataUploader

    /// 批量上报的数据条数阈值，达到此数量会触发上报 (默认 50)
    let batchSize: Int

    /// 批量上报的时间间隔阈值（秒），达到此时间会触发上报 (默认 60.0)
    let uploadInterval: TimeInterval

    /// SDK 是否启用 (默认 true)
    let isEnabled: Bool

    /// (可选) 自定义的 JS 代理脚本内容。如果为 nil，则使用内置脚本。
    let jsAgentScript: String?

    /// JS 与 Native 通信的 WKScriptMessageHandler 名称 (默认 "apmHandler")
    let messageHandlerName: String

    /// 初始化配置
    /// - Parameters:
    ///   - dataUploader: 实现 APMDataUploader 协议的对象
    ///   - batchSize: 批量上报条数阈值 (默认 50)
    ///   - uploadInterval: 批量上报时间间隔 (默认 60.0 秒)
    ///   - isEnabled: SDK 是否启用 (默认 true)
    ///   - jsAgentScript: 自定义 JS 脚本 (默认 nil)
    ///   - messageHandlerName: JS 通信 Handler 名称 (默认 "apmHandler")
    public init(
        dataUploader: APMDataUploader,
        batchSize: Int = 50,
        uploadInterval: TimeInterval = 60.0,
        isEnabled: Bool = true,
        jsAgentScript: String? = nil,
        messageHandlerName: String = "apmHandler"
    ) {
        self.dataUploader = dataUploader
        self.batchSize = max(1, batchSize) // 保证至少为 1
        self.uploadInterval = max(5.0, uploadInterval) // 保证至少 5 秒
        self.isEnabled = isEnabled
        self.jsAgentScript = jsAgentScript
        // 确保 handler 名称不为空
        self.messageHandlerName = messageHandlerName.isEmpty ? "apmHandler" : messageHandlerName
    }
} 