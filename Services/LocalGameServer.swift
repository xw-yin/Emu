import Foundation
import Network

/// 纯原生 Swift 实现的高性能本地 HTTP 服务器（基于 Network.framework，0 外部第三方依赖）
/// 专为解决 iOS WKWebView 运行 RPG Maker MV/MZ 时的 CORS 跨域、静态资源极速秒开、
/// 音频流式读取 (HTTP 206 Partial Content) 以及批量存档极速打通 (GET /_emu/saves, PUT/DELETE)
final class LocalGameServer: ObservableObject {
    static let shared = LocalGameServer()
    
    private var listener: NWListener?
    private var rootDirectoryURL: URL?
    // 使用高速串行队列（遵循 Apple Network.framework 对单连接串行化的严格要求，杜绝死锁与丢包）
    private let queue = DispatchQueue(label: "com.emu.localserver", qos: .userInteractive)
    
    // 路径大小写匹配内存高速缓存（大幅减少 APFS 磁盘目录遍历开销）
    private var resolvedPathCache = [String: URL]()
    private let cacheLock = NSLock()
    
    @Published private(set) var isRunning: Bool = false
    let port: UInt16 = 8080
    
    private init() {}
    
    /// 启动本地服务器并指定根目录
    func start(serving directoryURL: URL) throws {
        stop()
        self.rootDirectoryURL = directoryURL
        
        cacheLock.lock()
        resolvedPathCache.removeAll()
        cacheLock.unlock()
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isRunning = true
                    print("[LocalServer] 极速本地服务启动成功，监听地址: http://127.0.0.1:\(self?.port ?? 8080)/")
                case .failed(let error):
                    print("[LocalServer] 启动失败: \(error)")
                    self?.isRunning = false
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }
        
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener.start(queue: queue)
        self.listener = listener
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        cacheLock.lock()
        resolvedPathCache.removeAll()
        cacheLock.unlock()
    }
    
    // MARK: - 连接接入与 HTTP 请求解析
    private func handleConnection(_ connection: NWConnection) {
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
                let expectedContentLength = Int(headers["content-length"] ?? "0") ?? 0
                if bodyData.count < expectedContentLength && !isComplete {
                    self.readHTTPRequest(connection: connection, accumulatedData: currentData)
                    return
                }
                
                let request = ParsedRequest(method: method, path: decodedPath, headers: headers, body: bodyData)
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
                "Cache-Control": "public, max-age=86400"
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
    
    // MARK: - 批量读取存档 (GET /_emu/saves)
    private func handleListSaves(connection: NWConnection) {
        guard let rootURL = rootDirectoryURL else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data())
            return
        }
        let saveDir = rootURL.appendingPathComponent("save")
        var resultDict = [String: String]()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: saveDir.path) {
            for file in files {
                let lower = file.lowercased()
                if lower.hasSuffix(".rpgsave") || lower.hasSuffix(".rmmzsave") {
                    let fileURL = saveDir.appendingPathComponent(file)
                    if let str = try? String(contentsOf: fileURL, encoding: .utf8) {
                        resultDict[file] = str
                    }
                }
            }
        }
        if let jsonData = try? JSONSerialization.data(withJSONObject: resultDict) {
            let headers = [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": "\(jsonData.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache"
            ]
            sendResponse(connection: connection, statusCode: 200, headers: headers, body: jsonData)
        } else {
            let emptyData = Data("{}".utf8)
            sendResponse(connection: connection, statusCode: 200, headers: ["Content-Type": "application/json", "Content-Length": "\(emptyData.count)", "Access-Control-Allow-Origin": "*"], body: emptyData)
        }
    }
    
    // MARK: - 存档写入支持 (PUT/POST)
    private func handleSaveWrite(path: String, body: Data, connection: NWConnection) {
        guard let rootURL = rootDirectoryURL else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Server Not Configured".utf8))
            return
        }
        
        let sanitizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetFileURL = rootURL.appendingPathComponent(sanitizedPath)
        
        // 安全沙盒防御
        guard targetFileURL.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path) else {
            sendResponse(connection: connection, statusCode: 403, headers: [:], body: Data("Forbidden".utf8))
            return
        }
        
        let parentDir = targetFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        do {
            try body.write(to: targetFileURL, options: .atomic)
            let responseHeaders = [
                "Access-Control-Allow-Origin": "*",
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": "15"
            ]
            sendResponse(connection: connection, statusCode: 200, headers: responseHeaders, body: Data("{\"status\":\"ok\"}".utf8))
        } catch {
            let errData = Data("Write Error: \(error.localizedDescription)".utf8)
            sendResponse(connection: connection, statusCode: 500, headers: ["Access-Control-Allow-Origin": "*"], body: errData)
        }
    }
    
    // MARK: - 存档删除支持 (DELETE)
    private func handleSaveDelete(path: String, connection: NWConnection) {
        guard let rootURL = rootDirectoryURL else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Server Not Configured".utf8))
            return
        }
        
        let sanitizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetFileURL = rootURL.appendingPathComponent(sanitizedPath)
        
        guard targetFileURL.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path) else {
            sendResponse(connection: connection, statusCode: 403, headers: [:], body: Data("Forbidden".utf8))
            return
        }
        
        if FileManager.default.fileExists(atPath: targetFileURL.path) {
            try? FileManager.default.removeItem(at: targetFileURL)
        }
        
        let responseHeaders = [
            "Access-Control-Allow-Origin": "*",
            "Content-Type": "application/json; charset=utf-8",
            "Content-Length": "15"
        ]
        sendResponse(connection: connection, statusCode: 200, headers: responseHeaders, body: Data("{\"status\":\"ok\"}".utf8))
    }
    
    // MARK: - 文件检索与分段响应 (HTTP 206 Partial Content)
    private func serveFile(at relativePath: String, method: String, requestHeaders: [String: String], connection: NWConnection) {
        guard let rootURL = rootDirectoryURL else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Server Not Configured".utf8))
            return
        }
        
        let sanitizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var targetFileURL = rootURL.appendingPathComponent(sanitizedPath)
        
        // 1. 安全沙盒检查
        guard targetFileURL.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path) else {
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
        
        // 若仍然找不到，应用容错兜底
        guard fileManager.fileExists(atPath: targetFileURL.path) else {
            let lowerPath = sanitizedPath.lowercased()
            let lowerExt = targetFileURL.pathExtension.lowercased()
            
            // 容错 1：对于缺失的第三方插件或 JS 脚本，返回 200 OK 空桩
            if lowerPath.hasSuffix(".js") {
                let dummyJS = Data("// Emu auto-generated stub for missing script: \(sanitizedPath)\n".utf8)
                let headers = [
                    "Content-Type": "application/javascript; charset=utf-8",
                    "Content-Length": "\(dummyJS.count)",
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "public, max-age=86400"
                ]
                sendResponse(connection: connection, statusCode: 200, headers: headers, body: dummyJS)
                return
            }
            
            // 容错 2：对于缺失的图片，返回 1x1 透明 PNG
            if ["png", "jpg", "jpeg", "gif"].contains(lowerExt) {
                let transparentPNG = Data([
                    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
                    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
                    0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
                    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
                    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
                ])
                let headers = [
                    "Content-Type": "image/png",
                    "Content-Length": "\(transparentPNG.count)",
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "public, max-age=86400"
                ]
                sendResponse(connection: connection, statusCode: 200, headers: headers, body: transparentPNG)
                return
            }
            
            // 容错 3：对于缺失的音频，返回空音频
            if ["ogg", "m4a", "mp3", "wav"].contains(lowerExt) {
                let headers = [
                    "Content-Type": mimeType(for: lowerExt),
                    "Content-Length": "0",
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "public, max-age=86400"
                ]
                sendResponse(connection: connection, statusCode: 200, headers: headers, body: Data())
                return
            }
            
            // 容错 4：对于缺失的地图 JSON，返回基础空地图结构
            if lowerPath.hasPrefix("data/map") && lowerPath.hasSuffix(".json") {
                let dummyMap = Data("{\"width\":20,\"height\":15,\"data\":[],\"events\":[null],\"scrollType\":0,\"tilesetId\":1,\"bgm\":{\"name\":\"\",\"volume\":90,\"pitch\":100,\"pan\":0},\"bgs\":{\"name\":\"\",\"volume\":90,\"pitch\":100,\"pan\":0},\"autoplayBgm\":false,\"autoplayBgs\":false,\"encounterList\":[]}".utf8)
                let headers = [
                    "Content-Type": "application/json; charset=utf-8",
                    "Content-Length": "\(dummyMap.count)",
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-cache"
                ]
                sendResponse(connection: connection, statusCode: 200, headers: headers, body: dummyMap)
                return
            }
            
            sendResponse(connection: connection, statusCode: 404, headers: ["Access-Control-Allow-Origin": "*"], body: Data("Not Found".utf8))
            return
        }
        
        // 使用 .mappedIfSafe 实现零拷贝虚拟内存读取，极大加速大文件和频繁访问
        guard let fileData = try? Data(contentsOf: targetFileURL, options: .mappedIfSafe) else {
            sendResponse(connection: connection, statusCode: 500, headers: ["Access-Control-Allow-Origin": "*"], body: Data("Read Error".utf8))
            return
        }
        
        let totalCount = fileData.count
        let mime = mimeType(for: targetFileURL.pathExtension)
        let isStaticAsset = ["png", "jpg", "jpeg", "gif", "svg", "ogg", "m4a", "mp3", "wav", "woff", "woff2", "ttf", "js", "css"].contains(targetFileURL.pathExtension.lowercased())
        let cacheControl = isStaticAsset ? "public, max-age=86400" : "no-cache"
        
        // 4. 解析 HTTP Range 请求 (iOS WebKit 流媒体核心要求)
        if let rangeHeader = requestHeaders["range"], rangeHeader.hasPrefix("bytes=") {
            let rangeSpec = String(rangeHeader.dropFirst(6))
            let parts = rangeSpec.components(separatedBy: "-")
            
            let start = Int(parts[0]) ?? 0
            var end = totalCount - 1
            if parts.count > 1, let explicitEnd = Int(parts[1]) {
                end = min(explicitEnd, totalCount - 1)
            }
            
            guard start <= end, start < totalCount else {
                let headers = [
                    "Content-Range": "bytes */\(totalCount)",
                    "Access-Control-Allow-Origin": "*"
                ]
                sendResponse(connection: connection, statusCode: 416, headers: headers, body: Data())
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
                "Cache-Control": cacheControl
            ]
            
            sendResponse(connection: connection, statusCode: 206, headers: headers, body: method == "HEAD" ? Data() : chunk)
            return
        }
        
        // 5. 普通全量请求 200 OK
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(totalCount)",
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
            "Cache-Control": cacheControl
        ]
        
        sendResponse(connection: connection, statusCode: 200, headers: headers, body: method == "HEAD" ? Data() : fileData)
    }
    
    /// 带缓存的大小写不敏感递归查找文件（解决 Windows 到 iOS APFS 的路径大小写不一致并加速二次查找）
    private func resolveCaseInsensitiveFile(root: URL, relativePath: String) -> URL? {
        let fm = FileManager.default
        
        // 极速快路径：直接尝试原生路径 (匹配直接存在的情况)
        let directURL = root.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: directURL.path) {
            return directURL
        }
        
        // 内存缓存查找
        cacheLock.lock()
        if let cached = resolvedPathCache[relativePath] {
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
            resolvedPathCache[relativePath] = found
            cacheLock.unlock()
        }
        return result
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], body: Data) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 206: statusText = "Partial Content"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Error"
        }
        
        var effectiveHeaders = headers
        effectiveHeaders["Connection"] = "close"
        
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
