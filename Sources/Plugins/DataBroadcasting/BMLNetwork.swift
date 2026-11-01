// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// 通信コンテンツ: the requests of BML documents. Pages cannot reach the network themselves.
/// Servers are checked against the certificates this Mac trusts, unlike on a TV, which has roots of
/// its own: a broadcaster's server under such a root fails here rather than go unverified.
final class BMLNetwork {
    /// Requests to the network, once the viewer allows them.
    var isEnabled = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["Accept-Language": "ja", "Pragma": "no-cache"]
        return URLSession(configuration: config)
    }()

    /// `completion` runs on the main thread, with what the page expects, or nil if there is no response.
    func request(method: String, uri: String, body: Data?, completion: @escaping ([String: Any]?) -> Void) {
        guard isEnabled, let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased()) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if method == "POST" { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        session.dataTask(with: request) { data, response, _ in
            var reply: [String: Any]?
            if let http = response as? HTTPURLResponse {
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
                reply = ["statusCode": http.statusCode, "headers": headers, "body": (data ?? Data()).base64EncodedString()]
            }
            DispatchQueue.main.async { completion(reply) }
        }.resume()
    }

    func cancelAll() {
        session.getAllTasks { $0.forEach { $0.cancel() } }
    }
}
