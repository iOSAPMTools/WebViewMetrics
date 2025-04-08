import Foundation

// 负责缓冲、处理和触发上报 APM 记录
class DataProcessor: MessageHandlerDelegateOutput {

    private let configuration: APMConfiguration
    private var buffer: [APMRecordable] = []
    private let queue = DispatchQueue(label: "com.webviewapm.dataprocessor.queue", qos: .utility) // 后台队列处理
    private var timer: Timer?
    private var isUploading: Bool = false // 简单的锁，防止并发上传
    private let cacheDirectory: URL // 缓存目录

    // 用于管理缓存文件的 Encoder 和 Decoder
    private let cacheEncoder = JSONEncoder()
    private let cacheDecoder = JSONDecoder()
    private let cacheFileExtension = "apmcache"

    init(configuration: APMConfiguration) {
        self.configuration = configuration

        // 初始化缓存目录 (例如：Caches/WebViewAPMCache)
        if let cacheBaseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDirectory = cacheBaseURL.appendingPathComponent("WebViewAPMCache")
        } else {
            cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WebViewAPMCache")
            InternalLogger.log(.warning, "无法获取 Caches 目录，使用临时目录作为缓存：\(cacheDirectory.path)")
        }
        createCacheDirectoryIfNeeded()

        // 如果 SDK 启用，则启动定时器
        if configuration.isEnabled {
            setupTimer()
            InternalLogger.log(.debug, "DataProcessor 初始化完成，缓存目录: \(cacheDirectory.path)")
        } else {
             InternalLogger.log(.info, "DataProcessor 初始化，但 SDK 已禁用。")
        }
    }

    // MARK: - Cache Directory Management
    private func createCacheDirectoryIfNeeded() {
        queue.async { // 在后台队列操作文件 IO
            if !FileManager.default.fileExists(atPath: self.cacheDirectory.path) {
                do {
                    try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true, attributes: nil)
                    InternalLogger.log(.info, "已创建缓存目录: \(self.cacheDirectory.path)")
                } catch {
                    InternalLogger.log(.error, "创建缓存目录失败: \(error)")
                }
            }
        }
    }

     // MARK: - Offline Cache Handling (改进 3)
    func loadAndUploadCachedData() {
         guard configuration.isEnabled else { return }
         InternalLogger.log(.debug, "开始检查并加载缓存数据...")
         queue.async { [weak self] in
             guard let self = self else { return }
             do {
                 let fileManager = FileManager.default
                 let cacheFiles = try fileManager.contentsOfDirectory(at: self.cacheDirectory,
                                                                    includingPropertiesForKeys: nil)
                                                .filter { $0.pathExtension == self.cacheFileExtension }

                 InternalLogger.log(.debug, "发现 \(cacheFiles.count) 个缓存文件。")

                 for fileURL in cacheFiles {
                     if let data = try? Data(contentsOf: fileURL),
                        let records = self.decodeRecords(from: data) {
                         InternalLogger.log(.info, "从文件 \(fileURL.lastPathComponent) 加载了 \(records.count) 条缓存记录。")
                         // 将加载的记录添加到缓冲区头部（优先处理旧数据）
                         self.buffer.insert(contentsOf: records, at: 0)
                         // 删除已成功加载的缓存文件
                         try? fileManager.removeItem(at: fileURL)
                         InternalLogger.log(.debug, "已删除缓存文件: \(fileURL.lastPathComponent)")
                     } else {
                         InternalLogger.log(.warning, "无法解码缓存文件: \(fileURL.lastPathComponent)，将尝试删除。")
                         try? fileManager.removeItem(at: fileURL) // 删除无法解析的文件
                     }
                 }

                 // 如果加载后缓冲区有数据，触发一次上传检查
                 if !self.buffer.isEmpty {
                      InternalLogger.log(.debug, "缓存加载后，缓冲区大小: \(self.buffer.count)，触发上传检查。")
                      self.triggerUpload()
                 }

             } catch {
                 InternalLogger.log(.error, "加载缓存文件时出错: \(error)")
             }
         }
     }

    private func saveRecordsToCache(_ records: [APMRecordable]) -> URL? {
        guard !records.isEmpty else { return nil }
        let fileName = "\(UUID().uuidString).\(cacheFileExtension)"
        let fileURL = cacheDirectory.appendingPathComponent(fileName)

        do {
            // 将 [APMRecordable] 转换为 [AnyRecordWrapper] 进行编码
            let wrappedRecords = records.map { AnyRecordWrapper($0) }
            let data = try cacheEncoder.encode(wrappedRecords) // 编码包装后的数组
            try data.write(to: fileURL, options: Data.WritingOptions.atomic) // 明确指定类型
            InternalLogger.log(.debug, "成功将 \(records.count) 条记录写入缓存文件: \(fileName)")
            return fileURL
        } catch {
            InternalLogger.log(.error, "写入缓存文件 \(fileName) 失败: \(error)")
            return nil
        }
    }

    // 辅助解码函数，需要处理 APMRecordable 数组的解码
    private func decodeRecords(from data: Data) -> [APMRecordable]? {
        do {
            // 解码为 [AnyRecordWrapper]，然后提取 .record
            let wrappers = try cacheDecoder.decode([AnyRecordWrapper].self, from: data)
            let records = wrappers.compactMap { $0.record } // 解开包装
            return records
        } catch {
             InternalLogger.log(.error, "从缓存数据解码记录失败: \(error)")
             return nil
        }
    }

    // MARK: - MessageHandlerDelegateOutput

    func didReceiveRecord(_ record: APMRecordable) {
        guard configuration.isEnabled else { return } // 如果 SDK 禁用，则忽略

        queue.async { [weak self] in
            guard let self = self else { return }
            self.buffer.append(record)
            InternalLogger.log(.debug, "记录已添加到缓冲区 (ID: \(record.id)), 当前大小: \(self.buffer.count)")

            // 检查是否达到批次大小
            if self.buffer.count >= self.configuration.batchSize {
                InternalLogger.log(.debug, "缓冲区达到批次大小 \(self.configuration.batchSize)，触发上传。")
                self.triggerUpload()
            }
        }
    }

    // MARK: - Timer and Upload Logic

    private func setupTimer() {
        // 确保在主线程配置 Timer，但其触发的操作在后台队列执行
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
             // 先取消旧的 Timer (如果存在)
             self.timer?.invalidate()
             self.timer = Timer.scheduledTimer(withTimeInterval: self.configuration.uploadInterval, repeats: true) { [weak self] _ in
                 self?.queue.async { // 确保在后台队列执行检查和上传
                     self?.checkAndUploadBasedOnTimer()
                 }
             }
             // 允许 Timer 在后台模式下继续运行 (如果需要)
             // RunLoop.current.add(self.timer!, forMode: .common)
             InternalLogger.log(.debug, "定时器已设置，间隔: \(self.configuration.uploadInterval) 秒")
        }
    }

    @objc private func checkAndUploadBasedOnTimer() {
         guard configuration.isEnabled else { return }

         // 只有当缓冲区有数据时才基于定时器触发
         if !buffer.isEmpty {
             InternalLogger.log(.debug, "定时器触发，检查上传。缓冲区大小: \(buffer.count)")
             triggerUpload()
         } else {
             InternalLogger.log(.debug, "定时器触发，但缓冲区为空，跳过上传。")
         }
    }

    private func triggerUpload() {
        // 在后台队列执行
        guard !isUploading else {
            InternalLogger.log(.debug, "正在上传中，跳过此次触发。")
            return
        }
        guard !buffer.isEmpty else {
            InternalLogger.log(.debug, "缓冲区为空，无需上传。")
            return
        }

        isUploading = true
        InternalLogger.log(.debug, "开始上传...")

        // 取出当前缓冲区的所有数据进行上传
        let dataToUpload = buffer
        // **改进 3: 先写入缓存**
        let cacheFileURL = saveRecordsToCache(dataToUpload)
        InternalLogger.log(.debug, "准备上传 \(dataToUpload.count) 条记录。缓存文件: \(cacheFileURL?.lastPathComponent ?? "无")")

        // 调用用户提供的上传器
        configuration.dataUploader.upload(data: dataToUpload) { [weak self] success in
            self?.queue.async { // 确保在后台队列处理回调
                guard let self = self else { return }
                if success {
                    InternalLogger.log(.info, "数据上传成功。")
                    // **改进 3: 删除对应的缓存文件**
                    if let url = cacheFileURL {
                        do {
                            try FileManager.default.removeItem(at: url)
                            InternalLogger.log(.debug, "已删除缓存文件: \(url.lastPathComponent)")
                        } catch {
                             InternalLogger.log(.error, "删除缓存文件 \(url.lastPathComponent) 失败: \(error)")
                        }
                    }

                    // **改进 2: 使用 ID 从内存缓冲区移除已上传的数据**
                    let uploadedIDs = Set(dataToUpload.map { $0.id })
                    self.buffer.removeAll { uploadedIDs.contains($0.id) }
                    InternalLogger.log(.debug, "成功上传后，内存缓冲区剩余: \(self.buffer.count)")

                } else {
                    InternalLogger.log(.error, "数据上传失败。")
                    // **改进 3: 上传失败，保留缓存文件，数据仍在内存缓冲区**
                    // (如果实现了更复杂的重试，可能需要从内存移除，只依赖缓存)
                    InternalLogger.log(.debug, "上传失败，数据保留在内存缓冲区和缓存文件 (\(cacheFileURL?.lastPathComponent ?? "无"))。内存缓冲区大小: \(self.buffer.count)")
                }
                self.isUploading = false // 解锁
            }
        }
    }

    // MARK: - Teardown

    func stop() {
        // 停止定时器并尝试上传剩余数据
        DispatchQueue.main.async { // Timer 需要在主线程 invalidate
           self.timer?.invalidate()
           self.timer = nil
           InternalLogger.log(.debug, "定时器已停止。")
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.buffer.isEmpty {
                 InternalLogger.log(.info, "停止时，尝试上传剩余 \(self.buffer.count) 条内存记录。")
                 self.triggerUpload() // 触发最后一次上传（会写入缓存）
            }
        }
    }

    deinit {
        timer?.invalidate() // 确保定时器在对象销毁时停止
        InternalLogger.log(.debug, "DataProcessor 已销毁。")
    }
}


// MARK: - Codable Wrapper for Heterogeneous Array (APMRecordable)
// 保持 internal，因为它只是内部实现细节
struct AnyRecordWrapper: Codable { // 移除 public
    let record: APMRecordable?

    // 自定义编码逻辑
    init(_ record: APMRecordable) {
        self.record = record
    }

    enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(APMRecordType.self, forKey: .type) // APMRecordType 是 public
        // 根据 type 解码 payload
        switch type {
        case .pageLoad:
            self.record = try container.decode(PageLoadRecord.self, forKey: .payload) // PageLoadRecord 是 public
        case .jsError:
             self.record = try container.decode(JSErrorRecord.self, forKey: .payload) // JSErrorRecord 是 public
        case .apiCall:
             self.record = try container.decode(ApiCallRecord.self, forKey: .payload) // ApiCallRecord 是 public
        case .resourceLoad:
             self.record = try container.decode(ResourceLoadRecord.self, forKey: .payload) // ResourceLoadRecord 是 public
        // 添加其他 case
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard let record = record else { return } // 不应该发生

        try container.encode(record.recordType, forKey: .type) // APMRecordType 是 public
        // 根据具体类型编码到 payload
        switch record.recordType {
        case .pageLoad:
            try container.encode(record as? PageLoadRecord, forKey: .payload) // PageLoadRecord 是 public
        case .jsError:
             try container.encode(record as? JSErrorRecord, forKey: .payload) // JSErrorRecord 是 public
        case .apiCall:
             try container.encode(record as? ApiCallRecord, forKey: .payload) // ApiCallRecord 是 public
        case .resourceLoad:
             try container.encode(record as? ResourceLoadRecord, forKey: .payload) // ResourceLoadRecord 是 public
         // 添加其他 case
        }
    }
}

// 移除冲突的 Array 扩展
// extension Array: Encodable where Element == APMRecordable { ... }

// MARK: - Helper
private func logDebug(_ message: String) {
    // TODO: 集成更完善的内部日志系统 (考虑日志级别)
    print("[WebViewAPM DataProcessor Debug] \(message)")
}
private func logError(_ message: String) {
    print("[WebViewAPM DataProcessor Error] \(message)")
} 