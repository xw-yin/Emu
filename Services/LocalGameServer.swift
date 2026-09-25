import Foundation
import Network
import CryptoKit
import Combine

/// 纯原生 Swift 实现的高性能本地 HTTP 服务器（基于 Network.framework，0 外部第三方依赖）
/// 专为解决 iOS WKWebView 运行 RPG Maker MV/MZ 时的 CORS 跨域、静态资源极速秒开、
/// 音频流式读取 (HTTP 206 Partial Content) 以及批量存档极速打通 (GET /_emu/saves, PUT/DELETE)
final class LocalGameServer: ObservableObject {
    static let shared = LocalGameServer()
    
    private var listener: NWListener?
    private var rootDirectoryURL: URL?
    private var persistentSaveDirectory: URL?
    private var sessionID = UUID()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    // 使用高速串行队列（遵循 Apple Network.framework 对单连接串行化的严格要求，杜绝死锁与丢包）
    private let queue = DispatchQueue(label: "com.emu.localserver", qos: .userInteractive)
    
    // 路径大小写匹配内存高速缓存（大幅减少 APFS 磁盘目录遍历开销）
    private var resolvedPathCache = [String: URL]()
    private let cacheLock = NSLock()
    
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16 = 8080
    @Published private(set) var lastError: String?
    
    private init() {}
    
    /// 启动本地服务器并指定根目录
    func start(serving directoryURL: URL, saveDirectory: URL? = nil) throws {
        stop()
        lastError = nil
        try queue.sync {
            self.rootDirectoryURL = directoryURL
            if let destination = saveDirectory {
                let fm = FileManager.default
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                let marker = destination.appendingPathComponent(".imported")
                if !fm.fileExists(atPath: marker.path) {
                    let existing = try self.readSaves()
                    for (name, text) in existing {
                        let target = destination.appendingPathComponent(name)
                        if !fm.fileExists(atPath: target.path) {
                            try Data(text.utf8).write(to: target, options: .atomic)
                        }
                    }
                    try Data("1".utf8).write(to: marker, options: .atomic)
                }
                self.persistentSaveDirectory = destination
            }
        }
        
        GameLogManager.shared.reset()
        GameLogManager.shared.log("正在准备本地环境与资源索引...")
        if saveDirectory != nil {
            GameLogManager.shared.log("外部游戏存档已使用 App 内独立目录，原游戏文件保持不变")
        }
        
        cacheLock.lock()
        resolvedPathCache.removeAll()
        cacheLock.unlock()
        
        try startListener(preferredPort: 8080)
    }
    
    private func startListener(preferredPort: UInt16?) throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        
        let portToUse: NWEndpoint.Port? = preferredPort.flatMap { NWEndpoint.Port(rawValue: $0) }
        let listener: NWListener
        if let p = portToUse {
            listener = try NWListener(using: params, on: p)
        } else {
            listener = try NWListener(using: params, on: .any)
        }
        
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            DispatchQueue.main.async {
                guard let self = self, let listener = listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let realPort = listener.port?.rawValue {
                        self.port = realPort
                    }
                    self.isRunning = true
                    GameLogManager.shared.log("本地流媒体服务已就绪: 端口 \(self.port)", level: .success)
                case .failed(let error):
                    if preferredPort != nil {
                        GameLogManager.shared.log("端口 8080 暂不可用 (\(error.localizedDescription))，正在自适应空闲端口...", level: .warning)
                        self.listener?.cancel()
                        self.listener = nil
                        do {
                            try self.startListener(preferredPort: nil)
                        } catch {
                            GameLogManager.shared.log("切换备用端口失败: \(error.localizedDescription)", level: .error)
                            self.lastError = error.localizedDescription
                            self.isRunning = false
                        }
                    } else {
                        GameLogManager.shared.log("本地服务启动失败: \(error.localizedDescription)", level: .error)
                        self.lastError = error.localizedDescription
                        self.isRunning = false
                    }
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
        }
        
        let session = queue.sync { sessionID }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.sessionID == session else {
                connection.cancel()
                return
            }
            self.handleConnection(connection)
        }
        
        self.listener = listener
        listener.start(queue: queue)
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        queue.sync {
            sessionID = UUID()
            rootDirectoryURL = nil
            persistentSaveDirectory = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
        cacheLock.lock()
        resolvedPathCache.removeAll()
        cacheLock.unlock()
    }
    
    // MARK: - 连接接入与 HTTP 请求解析
    private func handleConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: key) }
            if case .failed = state {
                self?.connections.removeValue(forKey: key)
                connection?.cancel()
            }
        }
        connection.start(queue: queue)
        readHTTPRequest(connection: connection, accumulatedData: Data())
    }
    
    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    
    private func readHTTPRequest(connection: NWConnection, accumulatedData: Data) {
        var currentData = accumulatedData
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if let chunk = chunk, !chunk.isEmpty {
                currentData.append(chunk)
            }
            
            // 查找 HTTP 头部结束符 "\r\n\r\n"
            let delimiter = Data("\r\n\r\n".utf8)
            if let delimiterRange = currentData.range(of: delimiter) {
                let headerData = currentData.subdata(in: 0..<delimiterRange.lowerBound)
                let bodyData = currentData.subdata(in: delimiterRange.upperBound..<currentData.count)
                
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                
                let lines = headerString.components(separatedBy: "\r\n")
                guard let firstLine = lines.first else {
                    connection.cancel()
                    return
                }
                
                let parts = firstLine.components(separatedBy: " ")
                guard parts.count >= 2 else {
                    connection.cancel()
                    return
                }
                
                let method = parts[0].uppercased()
                var requestPath = parts[1]
                if let queryIndex = requestPath.firstIndex(of: "?") {
                    requestPath = String(requestPath[..<queryIndex])
                }
                if requestPath == "/" {
                    requestPath = "/index.html"
                }
                let decodedPath = requestPath.removingPercentEncoding ?? requestPath
                
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colonIndex = line.firstIndex(of: ":") {
                        let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                        let val = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                        headers[key] = val
                    }
                }
                
                // 校验 Content-Length 是否已完整接收 Body
                guard headers["transfer-encoding"] == nil,
                      let expectedContentLength = Int(headers["content-length"] ?? "0"),
                      expectedContentLength >= 0 else {
                    self.sendResponse(connection: connection, statusCode: 400, headers: [:], body: Data("Unsupported request framing".utf8))
                    return
                }
                if bodyData.count < expectedContentLength {
                    if isComplete || error != nil {
                        self.sendResponse(connection: connection, statusCode: 400, headers: [:], body: Data("Incomplete request body".utf8))
                    } else {
                        self.readHTTPRequest(connection: connection, accumulatedData: currentData)
                    }
                    return
                }
                
                let request = ParsedRequest(method: method, path: decodedPath, headers: headers, body: Data(bodyData.prefix(expectedContentLength)))
                self.dispatchRequest(request, connection: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.readHTTPRequest(connection: connection, accumulatedData: currentData)
            }
        }
    }
    
    // MARK: - 请求分发
    private func dispatchRequest(_ req: ParsedRequest, connection: NWConnection) {
        if ["PUT", "POST", "DELETE"].contains(req.method),
           req.headers["x-emu-session"] != sessionID.uuidString {
            sendResponse(connection: connection, statusCode: 409, headers: [:], body: Data("Game session changed".utf8))
            return
        }
        // 跨域预检请求 OPTIONS
        if req.method == "OPTIONS" {
            let corsHeaders = [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "*",
                "Access-Control-Max-Age": "86400",
                "Content-Length": "0"
            ]
            sendResponse(connection: connection, statusCode: 200, headers: corsHeaders, body: Data())
            return
        }
        
        // 批量存档秒开接口：一次性返回 save 目录下所有存档内容供 JS 缓存预热，彻底杜绝读档同步 XHR 挂死
        if req.path == "/_emu/saves" {
            GameLogManager.shared.log("💾 预读存档索引 (GET /_emu/saves)", level: .server)
            handleListSaves(connection: connection)
            return
        }
        
        // 虚拟内置资源：OGG 软解脚本
        if req.path == "/_emu/stbvorbis.js" {
            let scriptData = Data(EmuScriptAssets.stbvorbisScript.utf8)
            let headers = [
                "Content-Type": "application/javascript; charset=utf-8",
                "Content-Length": "\(scriptData.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache"
            ]
            sendResponse(connection: connection, statusCode: 200, headers: headers, body: scriptData)
            return
        }
        
        // 存档写入请求 PUT / POST
        if req.method == "PUT" || req.method == "POST" {
            handleSaveWrite(path: req.path, body: req.body, connection: connection)
            return
        }
        
        // 存档删除请求 DELETE
        if req.method == "DELETE" {
            handleSaveDelete(path: req.path, connection: connection)
            return
        }
        
        // 文件读取请求 GET / HEAD
        if req.method == "GET" || req.method == "HEAD" {
            serveFile(at: req.path, method: req.method, requestHeaders: req.headers, connection: connection)
            return
        }
        
        sendResponse(connection: connection, statusCode: 405, headers: [:], body: Data("Method Not Allowed".utf8))
    }
    
    // Save bootstrap is read on the same queue as HTTP mutations, before navigation.
    func loadBootstrap(completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            let result = Result<Data, Error> {
                guard let root = self.rootDirectoryURL else { throw CocoaError(.fileNoSuchFile) }
                let namespace = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                var gameTitle = ""
                if let systemURL = self.resolveCaseInsensitiveFile(root: root, relativePath: "data/System.json"),
                   self.contained(systemURL, in: root), let systemData = try? Data(contentsOf: systemURL),
                   let system = (try? JSONSerialization.jsonObject(with: systemData)) as? [String: Any] {
                    gameTitle = system["gameTitle"] as? String ?? ""
                }
                return try JSONSerialization.data(withJSONObject: [
                    "namespace": namespace,
                    "session": self.sessionID.uuidString,
                    "gameTitle": gameTitle,
                    "saves": try self.readSaves()
                ])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func isSaveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !name.contains("/") && !name.contains("\\") &&
            [".rpgsave", ".rpgsave.bak", ".rmmzsave", ".rmmzsave_"].contains { lower.hasSuffix($0) }
    }

    private func fullyResolvedURL(_ url: URL, root: URL) -> URL {
        var current = url.standardizedFileURL
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        let basePath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var hops = 0

        while hops < 16 {
            if let dest = try? fm.destinationOfSymbolicLink(atPath: current.path) {
                hops += 1
                let parent = current.deletingLastPathComponent()
                current = dest.hasPrefix("/")
                    ? URL(fileURLWithPath: dest).standardizedFileURL
                    : URL(fileURLWithPath: dest, relativeTo: parent).standardizedFileURL
                continue
            }

            var ancestor = current.deletingLastPathComponent()
            var suffixComponents: [String] = [current.lastPathComponent]
            var foundSymlink = false

            while ancestor.path != "/" && !ancestor.path.isEmpty && ancestor.path != rootPath && ancestor.path != basePath {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: ancestor.path) {
                    hops += 1
                    let parent = ancestor.deletingLastPathComponent()
                    let target = dest.hasPrefix("/")
                        ? URL(fileURLWithPath: dest).standardizedFileURL
                        : URL(fileURLWithPath: dest, relativeTo: parent).standardizedFileURL
                    var rebuilt = target
                    for comp in suffixComponents {
                        rebuilt = rebuilt.appendingPathComponent(comp)
                    }
                    current = rebuilt.standardizedFileURL
                    foundSymlink = true
                    break
                }
                suffixComponents.insert(ancestor.lastPathComponent, at: 0)
                ancestor = ancestor.deletingLastPathComponent()
            }

            if !foundSymlink {
                break
            }
        }

        var existing = current
        var nonExistentSuffix: [String] = []
        while !fm.fileExists(atPath: existing.path) && existing.path != "/" {
            nonExistentSuffix.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }

        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for comp in nonExistentSuffix {
            resolved = resolved.appendingPathComponent(comp).standardizedFileURL
        }
        return resolved
    }

    private func contained(_ url: URL, in root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = fullyResolvedURL(url, root: root).path
        if base == "/" { return true }
        return resolvedPath == base || resolvedPath.hasPrefix(base + "/")
    }

    // File providers can materialize/download a document during coordinated access.
    // Always read the coordinator's URL, which may differ from the requested URL.
    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result { try Data(contentsOf: readableURL) }
        }
        if let error = coordinationError { throw error }
        guard let result = result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func readSaves() throws -> [String: String] {
        guard let root = rootDirectoryURL else { throw CocoaError(.fileNoSuchFile) }
        let directory = persistentSaveDirectory ?? resolveCaseInsensitiveFile(root: root, relativePath: "save") ?? root.appendingPathComponent("save")
        let saveRoot = persistentSaveDirectory ?? root
        guard contained(directory, in: saveRoot) else { throw CocoaError(.fileReadNoPermission) }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        var saves: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where isSaveName(file) {
            let url = directory.appendingPathComponent(file)
            guard contained(url, in: saveRoot) else { throw CocoaError(.fileReadNoPermission) }
            // Do not turn unreadable saves into a successful empty snapshot.
            let key = file.lowercased()
            guard saves[key] == nil else {
                throw NSError(domain: "Emu.Save", code: 1, userInfo: [NSLocalizedDescriptionKey: "存档文件名大小写冲突: \(file)"])
            }
            let data = try coordinatedRead(url)
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            saves[key] = text
        }
        return saves
    }

    private func handleListSaves(connection: NWConnection) {
        do {
            let data = try JSONSerialization.data(withJSONObject: readSaves())
            sendResponse(connection: connection, statusCode: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
        } catch {
            GameLogManager.shared.log("读取存档失败: \(error.localizedDescription)", level: .error)
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Save read failed".utf8))
        }
    }

    private func saveURL(path: String) -> URL? {
        guard let root = rootDirectoryURL else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "save", isSaveName(String(parts[2])) else { return nil }
        let directory = persistentSaveDirectory ?? resolveCaseInsensitiveFile(root: root, relativePath: "save") ?? root.appendingPathComponent("save")
        let url = resolveCaseInsensitiveFile(root: directory, relativePath: String(parts[2])) ?? directory.appendingPathComponent(String(parts[2]))
        return contained(url, in: persistentSaveDirectory ?? root) ? url : nil
    }

    private func handleSaveWrite(path: String, body: Data, connection: NWConnection) {
        guard let url = saveURL(path: path) else {
            sendResponse(connection: connection, statusCode: 403, headers: [:], body: Data("Invalid save path".utf8))
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, options: .atomic)
            sendResponse(connection: connection, statusCode: 200, headers: [:], body: Data("OK".utf8))
        } catch {
            GameLogManager.shared.log("存档写入失败 \(path): \(error.localizedDescription)", level: .error)
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Save write failed".utf8))
        }
    }

    private func handleSaveDelete(path: String, connection: NWConnection) {
        guard let url = saveURL(path: path) else {
            sendResponse(connection: connection, statusCode: 403, headers: [:], body: Data("Invalid save path".utf8))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            sendResponse(connection: connection, statusCode: 200, headers: [:], body: Data("OK".utf8))
        } catch {
            GameLogManager.shared.log("存档删除失败 \(path): \(error.localizedDescription)", level: .error)
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Save delete failed".utf8))
        }
    }

    // MARK: - 文件检索与分段响应 (HTTP 206 Partial Content)
    private func serveFile(at relativePath: String, method: String, requestHeaders: [String: String], connection: NWConnection) {
        guard var rootURL = rootDirectoryURL else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Server Not Configured".utf8))
            return
        }
        
        var sanitizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let directory = persistentSaveDirectory, sanitizedPath.hasPrefix("save/") {
            let name = String(sanitizedPath.dropFirst(5))
            guard isSaveName(name), !name.contains("/") else {
                sendResponse(connection: connection, statusCode: 403, headers: [:], body: Data())
                return
            }
            rootURL = directory
            sanitizedPath = name
        }
        var targetFileURL = rootURL.appendingPathComponent(sanitizedPath)
        
        // 1. 安全沙盒检查
        guard contained(targetFileURL, in: rootURL) else {
            sendResponse(connection: connection, statusCode: 403, headers: [:], body: Data("Forbidden".utf8))
            return
        }
        
        let fileManager = FileManager.default
        
        // 2. 文件若直接不存在，进行不区分大小写匹配（结合内存缓存加速）
        if !fileManager.fileExists(atPath: targetFileURL.path) {
            if let matched = resolveCaseInsensitiveFile(root: rootURL, relativePath: sanitizedPath) {
                targetFileURL = matched
            }
        }
        
        // 3. 音频智能回退：若请求 .m4a 找不到，尝试寻找同名 .ogg；反之亦然
        if !fileManager.fileExists(atPath: targetFileURL.path) {
            let ext = targetFileURL.pathExtension.lowercased()
            if ext == "m4a" {
                let oggPath = (sanitizedPath as NSString).deletingPathExtension + ".ogg"
                if let matched = resolveCaseInsensitiveFile(root: rootURL, relativePath: oggPath) {
                    targetFileURL = matched
                }
            } else if ext == "ogg" {
                let m4aPath = (sanitizedPath as NSString).deletingPathExtension + ".m4a"
                if let matched = resolveCaseInsensitiveFile(root: rootURL, relativePath: m4aPath) {
                    targetFileURL = matched
                }
            }
        }
        
        guard contained(targetFileURL, in: rootURL) else {
            sendResponse(connection: connection, statusCode: 403, headers: [:], body: Data("Forbidden".utf8))
            return
        }
        // Missing core/plugin/data assets must remain visible failures.
        guard fileManager.fileExists(atPath: targetFileURL.path) else {
            GameLogManager.shared.log("未找到文件 (404): \(sanitizedPath)", level: .error)
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: method == "HEAD" ? Data() : Data("Not Found".utf8))
            return
        }

        var fileData: Data
        do {
            fileData = try coordinatedRead(targetFileURL)
        } catch {
            let detail = error as NSError
            GameLogManager.shared.log("文件读取失败 (500): \(sanitizedPath): \(detail.domain)(\(detail.code)) \(detail.localizedDescription)", level: .error)
            sendResponse(connection: connection, statusCode: 500, headers: ["Access-Control-Allow-Origin": "*"], body: Data("Read Error".utf8))
            return
        }
        
        // Install synchronously after the managers are defined, before plugins/main.
        if ["rpg_managers.js", "rmmz_managers.js", "drill_coreofglobalsave.js"].contains(targetFileURL.lastPathComponent.lowercased()) {
            fileData.append(Data("\n;window.__emuInstallRuntime && window.__emuInstallRuntime();\n".utf8))
        }

        if targetFileURL.lastPathComponent.lowercased() == "drill_dialogcharouterglow.js",
           var source = String(data: fileData, encoding: .utf8) {
            // This plugin version stores a one-based default as a zero-based index.
            // Match the known implementation exactly; leave other versions alone.
            let brokenDefault = "DrillUp.g_DCOG_shadowColorIndex = Number(DrillUp.parameters[\"默认外发光颜色ID(全局)\"] || 1);"
            if source.contains(brokenDefault) {
                source = source.replacingOccurrences(of: brokenDefault, with:
                    "DrillUp.g_DCOG_shadowColorIndex = Number(DrillUp.parameters[\"默认外发光颜色ID(全局)\"] || 1) - 1;")
                source = source.replacingOccurrences(of: "if( color_index == 0 ){ color_index = 11; }", with:
                    "if( !DrillUp.g_DCOG_color_list[color_index] || !DrillUp.g_DCOG_color_list[color_index].color ){ color_index = DrillUp.g_DCOG_shadowColorIndex; }")
                fileData = Data(source.utf8)
            }
        }

        let totalCount = fileData.count
        let mime = mimeType(for: targetFileURL.pathExtension)
        
        // 4. 解析 HTTP Range 请求 (iOS WebKit 流媒体核心要求)
        if let rangeHeader = requestHeaders["range"], rangeHeader.hasPrefix("bytes=") {
            let rangeSpec = String(rangeHeader.dropFirst(6))
            let parts = rangeSpec.split(separator: "-", omittingEmptySubsequences: false)
            var start = -1
            var end = -1
            if parts.count == 2, !rangeSpec.contains(","), totalCount > 0 {
                if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
                    start = max(0, totalCount - suffix)
                    end = totalCount - 1
                } else if let first = Int(parts[0]), first >= 0 {
                    start = first
                    if parts[1].isEmpty { end = totalCount - 1 }
                    else if let last = Int(parts[1]), last >= 0 { end = min(last, totalCount - 1) }
                }
            }
            guard start >= 0, start <= end, start < totalCount else {
                sendResponse(connection: connection, statusCode: 416,
                             headers: ["Content-Range": "bytes */\(totalCount)"], body: Data())
                return
            }

            let chunkLength = end - start + 1
            let chunk = fileData.subdata(in: start..<(start + chunkLength))
            
            let headers: [String: String] = [
                "Content-Type": mime,
                "Content-Range": "bytes \(start)-\(end)/\(totalCount)",
                "Content-Length": "\(chunkLength)",
                "Accept-Ranges": "bytes",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
                "Cache-Control": "no-cache"
            ]
            
            let chunkKb = max(1, chunkLength / 1024)
            GameLogManager.shared.log("🎵 音频流: \(sanitizedPath) (\(chunkKb) KB)", level: .server)
            sendResponse(connection: connection, statusCode: 206, headers: headers, body: method == "HEAD" ? Data() : chunk)
            return
        }
        
        // 5. 普通全量请求 200 OK
        let kb = max(1, totalCount / 1024)
        let ext = targetFileURL.pathExtension.lowercased()
        let icon: String
        if ["js"].contains(ext) {
            icon = "📜 脚本"
        } else if ["json"].contains(ext) {
            icon = "📋 数据"
        } else if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
            icon = "🎨 贴图"
        } else if ["ogg", "m4a", "mp3", "wav"].contains(ext) {
            icon = "🎵 音频"
        } else if sanitizedPath == "index.html" {
            icon = "🌐 入口"
        } else {
            icon = "📦 资源"
        }
        GameLogManager.shared.log("\(icon): \(sanitizedPath) (\(kb) KB)", level: .success)
        
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(totalCount)",
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
            "Cache-Control": "no-cache"
        ]
        
        sendResponse(connection: connection, statusCode: 200, headers: headers, body: method == "HEAD" ? Data() : fileData)
    }
    
    /// 带缓存的大小写不敏感递归查找文件（解决 Windows 到 iOS APFS 的路径大小写不一致并加速二次查找）
    private func resolveCaseInsensitiveFile(root: URL, relativePath: String) -> URL? {
        let fm = FileManager.default
        let cacheKey = root.standardizedFileURL.path + "/" + relativePath
        
        // 极速快路径：直接尝试原生路径 (匹配直接存在的情况)
        let directURL = root.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: directURL.path) {
            return directURL
        }
        
        // 内存缓存查找
        cacheLock.lock()
        if let cached = resolvedPathCache[cacheKey], fm.fileExists(atPath: cached.path) {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        let components = relativePath.components(separatedBy: "/").filter { !$0.isEmpty }
        var currentURL = root
        
        for component in components {
            guard let contents = try? fm.contentsOfDirectory(atPath: currentURL.path) else {
                return nil
            }
            if let matched = contents.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) {
                currentURL = currentURL.appendingPathComponent(matched)
            } else {
                return nil
            }
        }
        let result = fm.fileExists(atPath: currentURL.path) ? currentURL : nil
        if let found = result {
            cacheLock.lock()
            resolvedPathCache[cacheKey] = found
            cacheLock.unlock()
        }
        return result
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], body: Data) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 206: statusText = "Partial Content"
        case 400: statusText = "Bad Request"
        case 409: statusText = "Conflict"
        case 416: statusText = "Range Not Satisfiable"
        case 500: statusText = "Internal Server Error"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Error"
        }
        
        var effectiveHeaders = headers
        effectiveHeaders["Connection"] = "close"
        if effectiveHeaders["Content-Length"] == nil { effectiveHeaders["Content-Length"] = "\(body.count)" }
        effectiveHeaders["Access-Control-Allow-Origin"] = "*"
        effectiveHeaders["Cache-Control"] = "no-store"
        
        var headerString = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (key, val) in effectiveHeaders {
            headerString += "\(key): \(val)\r\n"
        }
        headerString += "\r\n"
        
        var packet = Data(headerString.utf8)
        packet.append(body)
        
        connection.send(content: packet, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "ogg": return "audio/ogg"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "woff", "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "rpgsave", "rmmzsave": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}
