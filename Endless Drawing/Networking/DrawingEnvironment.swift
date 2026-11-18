import Foundation

nonisolated enum DrawingDataError: Error, Equatable, Sendable {
    case invalidEnvironment, invalidMessage, unsupportedProtocol, limitExceeded
    case corruptJournal, identityMismatch, invalidTransition
}

/// Identity and durable operations are bound to the entire endpoint, not just a dev/prod label.
nonisolated struct DrawingEnvironment: Codable, Equatable, Sendable {
    enum Namespace: String, Codable, Sendable { case production, development }

    let namespace: Namespace
    let socketURL: URL
    let origin: String
    var identityAccount: String { "v1|\(namespace.rawValue)|\(socketURL.absoluteString)|\(origin)" }

    init(namespace: Namespace, socketURL: URL, origin: String) throws {
        guard var socket = URLComponents(url: socketURL, resolvingAgainstBaseURL: false),
              let scheme = socket.scheme?.lowercased(), ["ws", "wss"].contains(scheme),
              let host = socket.host, !host.isEmpty, socket.path == "/ws",
              socket.user == nil, socket.password == nil, socket.query == nil, socket.fragment == nil,
              var source = URLComponents(string: origin),
              let sourceScheme = source.scheme?.lowercased(), ["http", "https"].contains(sourceScheme),
              let sourceHost = source.host, !sourceHost.isEmpty,
              ["", "/"].contains(source.path), source.user == nil, source.password == nil,
              source.query == nil, source.fragment == nil,
              [socket.port, source.port].compactMap({ $0 }).allSatisfy({ (1...65535).contains($0) }),
              namespace != .production || (scheme == "wss" && sourceScheme == "https") else {
            throw DrawingDataError.invalidEnvironment
        }
        socket.scheme = scheme
        socket.host = host.lowercased()
        source.scheme = sourceScheme
        source.host = sourceHost.lowercased()
        source.path = ""
        guard let canonicalSocket = socket.url, let canonicalOrigin = source.string,
              canonicalSocket.absoluteString.utf8.count <= 512, canonicalOrigin.utf8.count <= 512 else {
            throw DrawingDataError.invalidEnvironment
        }
        self.namespace = namespace
        self.socketURL = canonicalSocket
        self.origin = canonicalOrigin
    }

    static let live = try! DrawingEnvironment(namespace: .production,
        socketURL: URL(string: "wss://endlessdrawing.com/ws")!, origin: "https://endlessdrawing.com")

    func webSocketRequest() -> URLRequest {
        var request = URLRequest(url: socketURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.httpShouldHandleCookies = false
        return request
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(namespace: values.decode(Namespace.self, forKey: .namespace),
                      socketURL: values.decode(URL.self, forKey: .socketURL),
                      origin: values.decode(String.self, forKey: .origin))
    }

    private enum CodingKeys: String, CodingKey { case namespace, socketURL, origin }
}
