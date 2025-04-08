# WebViewAPM SDK

一个用于监控 `WKWebView` 性能指标的轻量级 iOS/macOS SDK。它通过在 Web 内容中注入 JavaScript Agent 来收集性能数据，并通过原生代码进行处理和上报。

## 特性

*   自动注入 JavaScript Agent 监控 Web 内容。
*   通过 `WKScriptMessageHandler` 实现 JS 与 Native 高效通信。
*   收集页面加载、JS 错误、API 调用、资源加载等性能指标 (*具体指标取决于 JS Agent 实现*)。
*   可配置的数据上报接口 (`DataUploader`)。
*   支持运行时启用/禁用 SDK。
*   提供内部日志系统，支持 Debug 模式。
*   支持使用自定义 JavaScript Agent 脚本。
*   支持数据**批处理 (Batching)** 上传，减少网络请求次数。
*   支持**定时上传 (Timed Uploads)**，确保数据定期发送。
*   内置**离线缓存 (Offline Caching)** 机制，在上传失败或应用离线时保存数据，提高数据可靠性。

## 环境要求

*   iOS 13+

## 安装

### Swift Package Manager

1.  在 Xcode 中，选择 `File` > `Swift Packages` > `Add Package Dependency...`
2.  输入仓库 URL: `https://github.com/iOSAPMTools/WebViewMetrics.git` (*请替换为实际的仓库 URL*)
3.  选择合适的版本规则，然后点击 `Add Package`。

## 使用方法

### 1. 配置与初始化

在使用 SDK 之前，需要先进行初始化配置。你需要提供一个实现了 `DataUploader` 协议的对象，并可以调整批处理大小和上传间隔等参数。

```swift
import WebViewAPM
import WebKit // 如果在同一个文件使用 WKWebView

// 1. 实现 DataUploader 协议
// SDK 需要一个遵循 DataUploader 协议的对象来处理最终的数据上传。
// 你需要自行实现这个协议。
public protocol DataUploader {
    /// 上传收集到的 APM 数据
    /// - Parameters:
    ///   - data: 需要上传的序列化后的数据 (通常是 JSON 格式)
    ///   - completion: 上传完成后的回调，告知 SDK 是否上传成功
    func upload(data: Data, completion: @escaping (Bool) -> Void)
}

// 示例实现：
class MyDataUploader: DataUploader {
    func upload(data: Data, completion: @escaping (Bool) -> Void) {
        // 在这里实现你的数据上传逻辑，例如发送到你的数据分析服务器
        guard let url = URL(string: "https://your-server.com/apm-data") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        print("[MyDataUploader] Uploading APM data: \(String(data: data, encoding: .utf8) ?? "Invalid data")")

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("[MyDataUploader] Upload failed: \(error)")
                completion(false)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                print("[MyDataUploader] Upload failed with status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                completion(false)
                return
            }
            print("[MyDataUploader] Upload successful.")
            completion(true)
        }
        task.resume()
    }
}

// 2. 创建配置对象
let uploader = MyDataUploader() // 使用你实现的 Uploader
var config = APMConfiguration(dataUploader: uploader)

// 可选配置：
config.isEnabled = true // 控制是否启用 SDK (默认为 true)
config.messageHandlerName = "webviewAPMHandler" // JS 调用 Native 的 Handler 名称 (默认为 "webviewAPM")
config.batchSize = 50 // 缓冲区达到多少条记录时触发上传 (例如，默认为 100)
config.uploadInterval = 60.0 // 定时检查上传的时间间隔（秒）(例如，默认为 300.0)
// config.jsAgentScript = "window.myCustomAgent = true; console.log('My custom JS agent loaded!'); window.webkit.messageHandlers.\(config.messageHandlerName).postMessage({type: 'custom', data: 'hello'});" // 可选：提供完整的自定义 JS 脚本字符串

// 3. 初始化 SDK (通常在应用启动时调用，例如 AppDelegate 或 SceneDelegate)
WebViewAPM.initialize(configuration: config)
```

### 2. 附加到 WKWebView

在创建 `WKWebView` 实例后，你需要将 APM 监控附加到它上面。

```swift
let webViewConfiguration = WKWebViewConfiguration()
// 确保 userContentController 存在 (通常默认存在)
// let userContentController = webViewConfiguration.userContentController

let webView = WKWebView(frame: view.bounds, configuration: webViewConfiguration)
view.addSubview(webView) // 将 webView 添加到你的视图层级

// 附加 APM 监控
// 建议在 WebView 加载任何内容之前附加
do {
    try WebViewAPM.attach(to: webView)
    print("WebViewAPM attached successfully to WebView.")
} catch {
    // 处理错误，例如记录日志或禁用依赖 APM 的功能
    print("Failed to attach WebViewAPM: \(error.localizedDescription)")
    // 可以检查 error 的类型，例如 APMError.sdkNotInitialized
}

// 现在可以加载 URL 了
// if let url = URL(string: "https://example.com") {
//     webView.load(URLRequest(url: url))
// }
```

### 3. 从 WKWebView 分离 (可选)

如果你需要停止监控某个特定的 `WKWebView` 实例（例如，在它被销毁之前或用户禁用了某些功能），可以调用 `detach`。

```swift
// 当不再需要监控这个 webView 时
WebViewAPM.detach(from: webView)
print("WebViewAPM detached from WebView.")
```
*注意：`detach` 主要移除 Native 端的 Message Handler。已注入的 JS 脚本通常会随着页面的下一次导航或 WebView 的销毁而失效。*

### 4. 使用自定义 JavaScript Agent

如果你不想使用 SDK 内置的 JS Agent，可以通过 `APMConfiguration` 的 `jsAgentScript` 属性提供你自己的脚本字符串。

```swift
var config = APMConfiguration(dataUploader: uploader)
config.messageHandlerName = "myMessageHandler" // 确保你的脚本使用这个 Handler Name
config.jsAgentScript = """
    console.log('Loading My Custom APM Agent...');
    // ... 你的自定义监控逻辑 ...

    // 示例：发送数据到 Native
    function sendDataToNative(payload) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.myMessageHandler) {
            window.webkit.messageHandlers.myMessageHandler.postMessage(payload);
            console.log('Sent data to native:', payload);
        } else {
            console.error('Native message handler "myMessageHandler" not found.');
        }
    }

    // 示例：监听错误并上报
    window.addEventListener('error', function(event) {
        sendDataToNative({ type: 'jsError', message: event.message, filename: event.filename, lineno: event.lineno });
    });

    console.log('My Custom APM Agent Loaded.');
"""

WebViewAPM.initialize(configuration: config)

// ... 后续 attach 操作同上 ...
```
*重要提示：使用自定义脚本时，你需要确保脚本逻辑正确，并使用配置中指定的 `messageHandlerName` 通过 `window.webkit.messageHandlers[messageHandlerName].postMessage()` 与 Native 端通信。SDK 不会验证自定义脚本的内容。*

## 数据处理

SDK 内部的数据处理流程设计旨在平衡实时性、效率和可靠性：

1.  **收集与接收**: JS Agent 在 WebView 中收集性能指标和事件，并通过配置的 `messageHandlerName` 发送给 Native 端的 `MessageHandlerDelegate`。
2.  **缓冲**: `MessageHandlerDelegate` 将接收到的原始记录 (`APMRecordable`) 传递给内部的 `DataProcessor`。`DataProcessor` 将记录暂时存放在内存**缓冲区 (Buffer)** 中。
3.  **批处理触发**: 当缓冲区中的记录数量达到配置的 `batchSize` 时，`DataProcessor` 会触发一次上传尝试。
4.  **定时触发**: 同时，`DataProcessor` 会根据配置的 `uploadInterval`（单位：秒）**定时检查**缓冲区。如果缓冲区中有数据，也会触发一次上传尝试。
5.  **离线缓存**: 在**尝试上传之前**，`DataProcessor` 会将当前批次的数据**写入本地文件缓存**（位于应用的 Caches 目录下）。这确保了即使上传失败或应用退出，数据也不会丢失。
6.  **上传调用**: `DataProcessor` 调用你提供的 `DataUploader` 实例的 `upload(data:completion:)` 方法，将序列化后的数据（通常是 JSON 格式的记录数组）传递给它。
7.  **结果处理**:
    *   如果你的 `DataUploader` 通过 `completion(true)` 回调表示**上传成功**，`DataProcessor` 会**删除对应的本地缓存文件**。
    *   如果上传**失败** (`completion(false)`)，`DataProcessor` 会**保留该缓存文件**，数据将在后续的批处理或定时触发，或者下次应用启动时尝试重新上传。
8.  **启动时加载缓存**: SDK 初始化时，`DataProcessor` 会自动检查缓存目录，加载之前未成功上传的数据文件到内存缓冲区，并尝试再次上传。

因此，你的 `DataUploader` 实现只需要专注于执行单次上传的网络请求逻辑即可，SDK 会处理好缓冲、触发时机、缓存和重试加载的机制。

## 日志记录

SDK 内部使用 `InternalLogger` 进行日志记录。

*   日志级别包括: Debug, Info, Warning, Error。
*   日志格式: `[WebViewAPM Level] [FileName:LineNumber FunctionName] Message`
*   **Debug 日志**: 只有在 `DEBUG` 编译标志（通常在 Xcode 的 Debug 构建配置中设置）下才会被打印到控制台。Info, Warning, Error 级别的日志在所有构建配置中都会打印。

这有助于在开发阶段诊断问题，同时避免在 Release 版本中输出过多的调试信息。

## 错误处理

`WebViewAPM.attach(to:)` 方法在特定情况下会抛出 `APMError` 类型的错误：

*   `APMError.sdkNotInitialized`: 尝试 `attach` 时 SDK 尚未初始化或已被禁用 (`isEnabled = false`)。
*   `APMError.scriptInjectionFailed(reason)`: 注入 JS Agent 脚本失败（例如，无法加载内置脚本，或者提供的自定义脚本为空）。

建议在使用 `attach` 时使用 `do-catch` 块来处理这些潜在错误。

## 许可证

[MIT License](LICENSE)
