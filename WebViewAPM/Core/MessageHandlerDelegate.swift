import Foundation
import WebKit

// 定义一个协议，让 MessageHandlerDelegate 可以将解析后的数据传递出去
protocol MessageHandlerDelegateOutput: AnyObject {
    func didReceiveRecord(_ record: APMRecordable)
}

// 负责接收和解析来自 WKWebView JS 环境的消息
class MessageHandlerDelegate: NSObject, WKScriptMessageHandler {

    // 使用弱引用避免循环引用
    weak var output: MessageHandlerDelegateOutput?

    init(output: MessageHandlerDelegateOutput?) {
        self.output = output
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // 1. 尝试将消息体转换为 JSON 数据
        // WKScriptMessage.body 是 Any 类型, JS 发送的是对象，通常会是 NSDictionary
        guard let bodyDict = message.body as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: bodyDict, options: []) else {
            InternalLogger.log(.error, "无法将消息体序列化为 JSON 数据: \(message.body)")
            return
        }

        // 2. 尝试将 JSON 数据解码为 RawRecordWrapper
        let decoder = JSONDecoder()
        guard let rawWrapper = try? decoder.decode(RawRecordWrapper.self, from: jsonData) else {
            // 如果解码失败，打印原始 JSON 方便调试
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "无法解码的 JSON"
            InternalLogger.log(.error, "无法将 JSON 解码为 RawRecordWrapper: \(jsonString)")
            return
        }

        // 3. 验证记录类型
        guard let recordType = APMRecordType(rawValue: rawWrapper.type) else {
            InternalLogger.log(.error, "收到未知的记录类型: \(rawWrapper.type)")
            return
        }

        // 4. 将内部的 'data' 部分重新编码，以便解码为具体的 APMRecordable 类型
        let encoder = JSONEncoder()
        guard let innerJsonData = try? encoder.encode(rawWrapper.data) else {
             InternalLogger.log(.error, "无法重新编码类型 \(recordType) 的内部数据")
             return
        }

        // 5. 根据记录类型解码为具体的结构体
        do {
            let record: APMRecordable
            switch recordType {
            case .pageLoad:
                record = try decoder.decode(PageLoadRecord.self, from: innerJsonData)
            case .jsError:
                record = try decoder.decode(JSErrorRecord.self, from: innerJsonData)
            case .apiCall:
                record = try decoder.decode(ApiCallRecord.self, from: innerJsonData)
            case .resourceLoad:
                record = try decoder.decode(ResourceLoadRecord.self, from: innerJsonData)
            // 在这里添加对未来新类型的 case
            }

            // 6. 将解码后的记录传递给输出代理
            output?.didReceiveRecord(record)

        } catch {
            // 如果解码具体类型失败，打印错误和内部 JSON 方便调试
            let innerJsonString = String(data: innerJsonData, encoding: .utf8) ?? "无法解码的内部 JSON"
            InternalLogger.log(.error, "解码类型 \(recordType) 的记录失败: \(error). JSON: \(innerJsonString)")
        }
    }

    // MARK: - Helper
    private func logError(_ message: String) {
        // TODO: 集成更完善的内部日志系统
        print("[WebViewAPM MessageHandler Error] \(message)")
    }
} 