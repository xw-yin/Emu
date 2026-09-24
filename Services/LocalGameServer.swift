import Foundation
import Network

/// 纯原生 Swift 实现的高性能本地 HTTP 服务器（基于 Network.framework，0 外部第三方依赖）
/// 专为解决 iOS WKWebView 运行 RPG Maker MV/MZ 时的 CORS 跨域、音频流式读取 (HTTP 206 Partial Content)
/// 以及存档直接写入与读取 (HTTP PUT/GET/DELETE)
final class LocalGameServer: ObservableObject {
    static let shared = LocalGameServer()
    
    private var listener: NWListener?
    private var rootDirectoryURL: URL?
    private let queue = DispatchQueue(label: "com.emu.localserver", qos: .userInteractive)
    
    @Published private(set) var isRunning: Bool = false
    let port: UInt16 = 8080
    
    private init() {}
    
    /// 启动本地服务器并指定根目录
    func start(serving directoryURL: URL) throws {
        stop()
        self.rootDirectoryURL = directoryURL
        
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
                    print("[LocalServer] 启动成功，监听地址: http://127.0.0.1:\(self?.port ?? 8080)/")
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
    }
    
    // MARK: - 请求分发与静态文件响应
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
                    // 数据尚未读取完整，继续接收
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
        
        // 虚拟内置资源：OGG 软解脚本
        if req.path == "/_emu/stbvorbis.js" {
            let scriptData = Data(EmuScriptAssets.stbvorbisScript.utf8)
            let headers = [
                "Content-Type": "application/javascript; charset=utf-8",
                "Content-Length": "\(scriptData.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "max-age=86400"
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
    
    // MARK: - 存档写入支持 (PUT/POST)
    private func handleSaveWrite(path: String, body: Data, connection: NWConnection) {
        guard let rootURL = rootDirectoryURL else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Server Not Configured".utf8))
            return
        }
        
        let sanitizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var targetFileURL = rootURL.appendingPathComponent(sanitizedPath)
        
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
        
        // 2. 文件若直接不存在，进行不区分大小写匹配（解决 Windows 移植游戏文件名大小写差异）
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
        
        // 若仍然找不到
        guard fileManager.fileExists(atPath: targetFileURL.path) else {
            sendResponse(connection: connection, statusCode: 404, headers: ["Access-Control-Allow-Origin": "*"], body: Data("Not Found".utf8))
            return
        }
        
        guard let fileData = try? Data(contentsOf: targetFileURL) else {
            sendResponse(connection: connection, statusCode: 500, headers: ["Access-Control-Allow-Origin": "*"], body: Data("Read Error".utf8))
            return
        }
        
        let totalCount = fileData.count
        let mime = mimeType(for: targetFileURL.pathExtension)
        
        // 4. 解析 HTTP Range 请求 (iOS WebKit 流媒体核心要求)
        if let rangeHeader = requestHeaders["range"], rangeHeader.hasPrefix("bytes=") {
            let rangeSpec = String(rangeHeader.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            let parts = rangeSpec.components(separatedBy: "-")
            
            var start = 0
            var end = totalCount - 1
            
            if parts.count >= 1, let s = Int(parts[0]) {
                start = max(0, min(s, totalCount - 1))
            }
            if parts.count >= 2, !parts[1].isEmpty, let e = Int(parts[1]) {
                end = max(start, min(e, totalCount - 1))
            }
            
            let chunkLength = max(0, end - start + 1)
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
            "Cache-Control": "no-cache"
        ]
        
        sendResponse(connection: connection, statusCode: 200, headers: headers, body: method == "HEAD" ? Data() : fileData)
    }
    
    /// 大小写不敏感递归查找文件（解决 Windows 到 iOS APFS 的路径大小写不一致）
    private func resolveCaseInsensitiveFile(root: URL, relativePath: String) -> URL? {
        let components = relativePath.components(separatedBy: "/").filter { !$0.isEmpty }
        var currentURL = root
        let fm = FileManager.default
        
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
        return fm.fileExists(atPath: currentURL.path) ? currentURL : nil
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
        
        var headerString = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (key, val) in headers {
            headerString += "\(key): \(val)\r\n"
        }
        headerString += "\r\n"
        
        var packet = Data(headerString.utf8)
        packet.append(body)
        
        connection.send(content: packet, completion: .contentProcessed({ _ in
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
