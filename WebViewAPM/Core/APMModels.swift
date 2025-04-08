import Foundation

// 通用记录协议，所有监控记录都应遵循
public protocol APMRecordable: Codable {
    var recordType: APMRecordType { get }
    var id: UUID { get } // 添加唯一标识符
    var timestamp: TimeInterval { get } // Unix timestamp (e.g., Date().timeIntervalSince1970)
    // 可以添加通用字段，如 appVersion, osVersion, deviceModel, userID 等
}

// 记录类型枚举
public enum APMRecordType: String, Codable {
    case pageLoad
    case jsError
    case apiCall
    case resourceLoad
    // 可以根据需要扩展更多类型
}

// 页面加载性能记录 (添加详细 H5 阶段时间点)
public struct PageLoadRecord: APMRecordable {
    public let recordType: APMRecordType = .pageLoad
    public let id: UUID = UUID()
    public let timestamp: TimeInterval
    public let url: String?

    // --- 核心时间点 (已存在) ---
    /// Navigation Timing API L1/L2: navigationStart (相对时间 0)
    /// JS 获取: Level 2: 0, Level 1: 0 (处理后)
    public let navigationStart: Double? // 基准时间，通常处理为 0
    /// Navigation Timing API L1/L2: domContentLoadedEventEnd
    /// JS 获取: Level 2: navEntry.domContentLoadedEventEnd, Level 1: timing.domContentLoadedEventEnd - navigationStart
    public let domContentLoadedEventEnd: Double?
    /// Navigation Timing API L1/L2: loadEventEnd
    /// JS 获取: Level 2: navEntry.loadEventEnd, Level 1: timing.loadEventEnd - navigationStart
    public let loadEventEnd: Double?
    /// Paint Timing API: first-paint
    /// JS 获取: paintEntries['first-paint']
    public let firstPaint: Double?
    /// Paint Timing API: first-contentful-paint
    /// JS 获取: paintEntries['first-contentful-paint']
    public let firstContentfulPaint: Double?

    // --- 新增详细时间点 (Navigation Timing L1/L2) ---
    /// 开始卸载前一个文档的时间
    public let unloadEventStart: Double?
    /// 结束卸载前一个文档的时间
    public let unloadEventEnd: Double?
    /// 第一个 HTTP 重定向开始的时间
    public let redirectStart: Double?
    /// 最后一个 HTTP 重定向完成（最后一个字节到达）的时间
    public let redirectEnd: Double?
    /// 浏览器准备好使用 HTTP 请求抓取文档的时间 (发生在检查本地缓存之后)
    public let fetchStart: Double?
    /// DNS 域名查询开始的时间
    public let domainLookupStart: Double?
    /// DNS 域名查询完成的时间
    public let domainLookupEnd: Double?
    /// 建立服务器连接开始的时间（TCP 握手）
    public let connectStart: Double?
    /// 建立服务器连接完成的时间
    public let connectEnd: Double?
    /// HTTPS 安全连接握手开始的时间
    public let secureConnectionStart: Double?
    /// 浏览器发送 HTTP 请求（或第一个字节）的时间
    public let requestStart: Double?
    /// 浏览器从服务器或缓存接收到响应的第一个字节的时间
    public let responseStart: Double?
    /// 浏览器接收到响应的最后一个字节或连接关闭的时间
    public let responseEnd: Double?
    /// DOM 解析完成，文档对象模型准备就绪的时间 (`DOMContentLoaded` 之前)
    public let domInteractive: Double?
    /// `DOMContentLoaded` 事件处理程序开始执行的时间
    public let domContentLoadedEventStart: Double?
    /// 当前文档解析完成，"加载状态"设置为 `complete` 的时间 (`load` 事件之前)
    public let domComplete: Double?
    /// `load` 事件处理程序开始执行的时间
    public let loadEventStart: Double?

    // --- Level 2 Only 详细信息 ---
    /// Service Worker 线程准备处理 fetch 事件的时间
    public let workerStart: Double?
    /// 网络传输的总大小 (bytes)
    public let transferSize: Double? // 使用 Double 兼容 JS number
    /// 编码后的响应体大小 (bytes)
    public let encodedBodySize: Double?
    /// 解码后的响应体大小 (bytes)
    public let decodedBodySize: Double?

    // 明确 CodingKeys，包含所有新字段
    enum CodingKeys: String, CodingKey {
        // 原有核心字段 (不含 recordType, id)
        case timestamp, url, navigationStart, domContentLoadedEventEnd, loadEventEnd, firstPaint, firstContentfulPaint
        // 新增详细字段
        case unloadEventStart, unloadEventEnd, redirectStart, redirectEnd, fetchStart
        case domainLookupStart, domainLookupEnd, connectStart, connectEnd, secureConnectionStart
        case requestStart, responseStart, responseEnd, domInteractive
        case domContentLoadedEventStart, domComplete, loadEventStart
        // Level 2 Only
        case workerStart, transferSize, encodedBodySize, decodedBodySize
    }
}

// JS 错误记录
public struct JSErrorRecord: APMRecordable {
    public let recordType: APMRecordType = .jsError
    public let id: UUID = UUID()
    public let timestamp: TimeInterval
    public let message: String
    public let stack: String?
    public let url: String?
    public let line: Int?
    public let column: Int?
    public let errorType: String?

    // 明确 CodingKeys
    enum CodingKeys: String, CodingKey {
        case timestamp, message, stack, url, line, column, errorType
    }
}

// API 调用记录
public struct ApiCallRecord: APMRecordable {
    public let recordType: APMRecordType = .apiCall
    public let id: UUID = UUID()
    public let timestamp: TimeInterval
    public let url: String
    public let method: String
    public let startTime: Double
    public let duration: Double
    public let statusCode: Int?
    public let requestSize: Int?
    public let responseSize: Int?
    public let success: Bool
    public let errorMessage: String?

    // 明确 CodingKeys
    enum CodingKeys: String, CodingKey {
        case timestamp, url, method, startTime, duration, statusCode, requestSize, responseSize, success, errorMessage
    }
}

// 资源加载记录
public struct ResourceLoadRecord: APMRecordable {
    public let recordType: APMRecordType = .resourceLoad
    public let id: UUID = UUID()
    public let timestamp: TimeInterval
    public let url: String
    public let initiatorType: String
    public let startTime: Double
    public let duration: Double
    public let transferSize: Int?
    public let decodedBodySize: Int?

    // 明确 CodingKeys
    enum CodingKeys: String, CodingKey {
        case timestamp, url, initiatorType, startTime, duration, transferSize, decodedBodySize
    }
}

// 用于 JS 通信的包装结构体，这个保持 internal 即可
struct RawRecordWrapper: Decodable {
    let type: String // 对应 APMRecordType 的 rawValue
    let data: [String: AnyCodable] // 使用 AnyCodable 或类似方式处理异构数据
}

// 辅助类型，用于解码来自 JS 的异构 JSON 数据，这个保持 internal
struct AnyCodable: Codable {
    let value: Any

    init<T>(_ value: T?) {
        self.value = value ?? ()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self.value = () }
        else if let bool = try? container.decode(Bool.self) { self.value = bool }
        else if let int = try? container.decode(Int.self) { self.value = int }
        else if let double = try? container.decode(Double.self) { self.value = double }
        else if let string = try? container.decode(String.self) { self.value = string }
        else if let array = try? container.decode([AnyCodable].self) { self.value = array.map { $0.value } }
        else if let dictionary = try? container.decode([String: AnyCodable].self) { self.value = dictionary.mapValues { $0.value } }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is Void: try container.encodeNil()
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        // 处理 NSNull for JSON null
        case is NSNull: try container.encodeNil()
        // 明确处理数组和字典
        case let array as [Any]: try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]: try container.encode(dictionary.mapValues { AnyCodable($0) })
        // 尝试其他数字类型
        case let uint as UInt: try container.encode(uint)
        case let float as Float: try container.encode(float)
        // 添加对 URL 的处理 (如果需要)
        case let url as URL: try container.encode(url.absoluteString)
        default:
             // 添加日志记录无法编码的类型
             // print("AnyCodable: Attempting to encode value of unknown type: \(type(of: value))")
             // 尝试用 description 编码，但这可能不是有效的 JSON
             // try container.encode("\(value)")
             throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value of type \(type(of: value)) cannot be encoded"))
        }
    }

    // 辅助方法从字典获取特定类型的值
    static func getValue<T>(from dict: [String: AnyCodable], key: String) -> T? {
        return dict[key]?.value as? T
    }
     static func getValue<T>(from dict: [String: AnyCodable], key: String, defaultValue: T) -> T {
        return dict[key]?.value as? T ?? defaultValue
    }
} 