import Foundation
import Network

/// 纯原生 Swift 实现的轻量本地 HTTP 服务器（基于 Network.framework，0 外部第三方依赖）
/// 专为解决 iOS WKWebView 运行 RPG Maker MV/MZ 时的 CORS 跨域与音频流式读取问题
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
        receiveRequest(connection)
    }
    
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, let requestString = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            
            // 解析简单的 HTTP GET 请求头
            let lines = requestString.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else {
                connection.cancel()
                return
            }
            
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2, parts[0].uppercased() == "GET" else {
                self.sendResponse(connection: connection, statusCode: 405, headers: [:], body: Data("Method Not Allowed".utf8))
                return
            }
            
            var requestPath = parts[1]
            // 去除 URL 参数与哈希
            if let queryIndex = requestPath.firstIndex(of: "?") {
                requestPath = String(requestPath[..<queryIndex])
            }
            if requestPath == "/" {
                requestPath = "/index.html"
            }
            
            // URL 路径解码 (避免中文资源名 404)
            let decodedPath = requestPath.removingPercentEncoding ?? requestPath
            self.serveFile(at: decodedPath, connection: connection)
        }
    }
    
    private func serveFile(at relativePath: String, connection: NWConnection) {
        guard let rootURL = rootDirectoryURL else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Server Not Configured".utf8))
            return
        }
        
        let sanitizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetFileURL = rootURL.appendingPathComponent(sanitizedPath)
        
        // 安全沙盒防御，避免越界访问
        guard targetFileURL.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path) else {
            sendResponse(connection: connection, statusCode: 403, headers: [:], body: Data("Forbidden".utf8))
            return
        }
        
        guard FileManager.default.fileExists(atPath: targetFileURL.path) else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: Data("Not Found".utf8))
            return
        }
        
        guard let fileData = try? Data(contentsOf: targetFileURL) else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: Data("Read Error".utf8))
            return
        }
        
        let mimeType = mimeType(for: targetFileURL.pathExtension)
        let headers: [String: String] = [
            "Content-Type": mimeType,
            "Content-Length": "\(fileData.count)",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, OPTIONS",
            "Cache-Control": "no-cache",
            "Accept-Ranges": "bytes"
        ]
        
        sendResponse(connection: connection, statusCode: 200, headers: headers, body: fileData)
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], body: Data) {
        let statusText = statusCode == 200 ? "OK" : (statusCode == 404 ? "Not Found" : "Error")
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
        default: return "application/octet-stream"
        }
    }
}
