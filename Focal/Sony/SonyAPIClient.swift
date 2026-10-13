import Foundation

actor SonyAPIClient {
    private let endpoint: URL
    private let session: URLSession
    private var nextID = 1
    private var tail: Task<Void,Never>?
    private var closed = false
    private var cancellationGeneration = 0
    init(endpoint:URL) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 35
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration:config,delegate:SonyLocalSessionDelegate(),delegateQueue:nil)
    }
    func call(_ method:String,params:[Any] = [],timeout:TimeInterval = 5) async throws -> Data {
        guard !closed else { throw CancellationError() }
        let previous = tail
        let generation = cancellationGeneration
        let operation = Task { () throws -> Data in
            await previous?.value
            try Task.checkCancellation()
            guard generation == self.cancellationGeneration else { throw CancellationError() }
            return try await self.request(method,params:params,timeout:timeout)
        }
        tail = Task { _ = try? await operation.value }
        return try await operation.value
    }
    private func request(_ method:String,params:[Any],timeout:TimeInterval) async throws -> Data {
        guard !closed else { throw CancellationError() }
        let id = nextID; nextID += 1
        var request = URLRequest(url:endpoint,timeoutInterval:timeout)
        request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["method":method,"params":params,"id":id,"version":"1.0"])
        let (data,response) = try await session.data(for:request)
        guard let response = response as? HTTPURLResponse,(200..<300).contains(response.statusCode),data.count <= 2*1024*1024 else { throw SonyRemoteError(message:"Sony control request failed.") }
        let object = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        if let object, let error = SonyAPIError.parse(object, method: method) { throw error }
        if object?["error"] != nil { throw SonyRemoteError(message: "Sony returned an unreadable error for \(method).") }
        guard object?["result"] != nil else { throw SonyRemoteError(message:"Sony returned no result.") }
        return data
    }
    func cancelPendingRequests() async {
        cancellationGeneration += 1
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            session.getAllTasks { tasks in
                tasks.forEach { $0.cancel() }; continuation.resume()
            }
        }
    }
    func shutdown() { closed = true; session.invalidateAndCancel() }
    static func result(_ data:Data) throws -> [Any] {
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],let result = object["result"] as? [Any] else { throw SonyRemoteError(message:"Invalid Sony API result.") }
        return result
    }
}

/// Camera URLs are local and validated; redirects must not leave that address.
final class SonyLocalSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
