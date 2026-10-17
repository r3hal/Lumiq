import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol BackupCredentialStore:Sendable {
    func token(for destination:BackupDestination) async throws -> String
    func save(_ token:String,for destination:BackupDestination) async throws
    func remove(for destination:BackupDestination) async
}
protocol BackupHTTPTransport:Sendable { func send(_ request:URLRequest) async throws -> BackupHTTPResult }

struct BackupWireFailure:Error {
    let problem:BackupProblem
    let retryAfter:TimeInterval?
}

struct BackendResourceStatus:Decodable,Sendable {
    let destinationId:String
    let resourceId:String
    let state:String
    let offset:Int64
    let size:Int64
    let sha256:String
    let driveFileId:String?
    let error:String?
    func verify(_ job:BackupJob) throws {
        guard destinationId == job.destinationID,resourceId == job.id,size == job.size,sha256 == job.sha256,
              offset >= 0,offset <= size else { throw BackupProblem.integrity }
        if state == "complete" {
            guard offset == size,let id = driveFileId,!id.isEmpty,id.utf8.count <= 256 else { throw BackupProblem.integrity }
        }
    }
}

struct BackendDeviceStatus:Decodable,Sendable {
    let destinationId:String
    let deviceId:String
    let ownerLabel:String
    let driveConnected:Bool
}

struct BackendEnrollment:Decodable,Sendable {
    let destinationId:String
    let deviceId:String
    let deviceToken:String
    let ownerLabel:String
}

struct OwnerBackupAPI:Sendable {
    let http:any BackupHTTPTransport
    let credentials:any BackupCredentialStore
    func enroll(server:URL,code:String) async throws -> (BackupDestination,String) {
        guard OwnerBackupURLs.validServer(server),code.count >= 16,code.count <= 256 else { throw BackupProblem.configuration }
        let data = try JSONSerialization.data(withJSONObject:["code":code])
        var request = URLRequest(url:server.appendingPathComponent("v1/enroll"));request.httpMethod = "POST"
        request.httpBody = data;request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let result = try await http.send(request);try Self.check(result)
        let enrolled = try Self.decode(BackendEnrollment.self,result.data)
        guard OwnerBackupURLs.validID(enrolled.destinationId),OwnerBackupURLs.validID(enrolled.deviceId),
              enrolled.deviceToken.count >= 32,enrolled.deviceToken.count <= 256,enrolled.ownerLabel.utf8.count <= 120 else { throw BackupProblem.invalidResponse }
        return (.init(id:enrolled.destinationId,deviceID:enrolled.deviceId,label:enrolled.ownerLabel,server:server),enrolled.deviceToken)
    }
    func status(_ destination:BackupDestination) async throws -> BackendDeviceStatus {
        let result = try await send(destination,path:"status")
        let status = try Self.decode(BackendDeviceStatus.self,result.data)
        guard status.destinationId == destination.id,status.deviceId == destination.deviceID else { throw BackupProblem.destinationMismatch }
        return status
    }
    func reserve(_ job:BackupJob,destination:BackupDestination) async throws -> BackendResourceStatus {
        guard let size = job.size,let sha = job.sha256,job.destinationID == destination.id && job.deviceID == destination.deviceID && job.server == destination.server else { throw BackupProblem.integrity }
        let body:[String:Any] = ["resourceId":job.id,"captureId":job.captureID.uuidString.lowercased(),
            "destinationId":destination.id,"filename":job.source.filename,"role":job.source.role.rawValue,
            "mimeType":job.source.mimeType,"datePath":job.datePath,"createdAt":ISO8601DateFormatter().string(from:job.createdAt),
            "size":size,"sha256":sha]
        let result = try await send(destination,path:"resources",method:"POST",body:JSONSerialization.data(withJSONObject:body))
        return try resourceResponse(result,job:job)
    }
    func resource(_ job:BackupJob,destination:BackupDestination) async throws -> BackendResourceStatus {
        guard OwnerBackupURLs.validID(job.id),job.destinationID == destination.id && job.deviceID == destination.deviceID && job.server == destination.server else { throw BackupProblem.integrity }
        let result = try await send(destination,path:"resources/"+job.id)
        return try resourceResponse(result,job:job)
    }
    func uploadRequest(_ job:BackupJob,destination:BackupDestination,bytes:Int64) async throws -> URLRequest {
        guard let total = job.size,job.destinationID == destination.id && job.deviceID == destination.deviceID && job.server == destination.server,OwnerBackupURLs.validID(job.id),
              bytes > 0,bytes <= BackupQueue.chunkBytes,job.offset >= 0,job.offset+bytes <= total else { throw BackupProblem.integrity }
        var request = try await request(destination,path:"resources/"+job.id+"/data",method:"PUT")
        request.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
        request.setValue(String(bytes),forHTTPHeaderField:"Content-Length")
        request.setValue("bytes \(job.offset)-\(job.offset+bytes-1)/\(total)",forHTTPHeaderField:"Content-Range")
        return request
    }
    func retry(_ job:BackupJob,destination:BackupDestination) async throws {
        _ = try await send(destination,path:"resources/"+job.id+"/retry",method:"POST")
    }
    private func resourceResponse(_ result:BackupHTTPResult,job:BackupJob) throws -> BackendResourceStatus {
        let status = try Self.decode(BackendResourceStatus.self,result.data)
        try status.verify(job);return status
    }
    private func request(_ destination:BackupDestination,path:String,method:String) async throws -> URLRequest {
        let url = destination.server.appendingPathComponent("v1/"+path)
        guard OwnerBackupURLs.permitted(url,server:destination.server) else { throw BackupProblem.configuration }
        let token = try await credentials.token(for:destination)
        guard token.count >= 32,token.count <= 256,!token.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw BackupProblem.authorization }
        var request = URLRequest(url:url);request.httpMethod = method;request.timeoutInterval = 45
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue(destination.id,forHTTPHeaderField:"X-Focal-Destination")
        return request
    }
    private func send(_ destination:BackupDestination,path:String,method:String = "GET",body:Data? = nil) async throws -> BackupHTTPResult {
        var req = try await request(destination,path:path,method:method);req.httpBody = body
        if body != nil { req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let result = try await http.send(req);try Self.check(result);return result
    }
    static func decode<T:Decodable>(_ type:T.Type,_ data:Data) throws -> T {
        guard data.count <= 131_072 else { throw BackupProblem.invalidResponse }
        do { return try JSONDecoder().decode(type,from:data) } catch { throw BackupProblem.invalidResponse }
    }
    static func check(_ result:BackupHTTPResult) throws {
        if (200...299).contains(result.status) { return }
        let code = (try? JSONSerialization.jsonObject(with:result.data) as? [String:String])?["error"]
        let problem:BackupProblem
        switch result.status {
        case 401: problem = .authorization
        case 403: problem = code == "drive_quota" ? .quota : .permission
        case 409: problem = code == "destination_mismatch" ? .destinationMismatch : code == "offset_mismatch" ? .temporaryService : .integrity
        case 404,410: problem = .missingOriginal
        case 413: problem = .storage
        case 429: problem = .temporaryService
        case 507: problem = .ownerStorage
        case 500...599: problem = .temporaryService
        default: problem = .invalidResponse
        }
        throw BackupWireFailure(problem:problem,retryAfter:result.headers["retry-after"].flatMap(TimeInterval.init))
    }
}

struct EphemeralBackupHTTP:BackupHTTPTransport {
    func send(_ request:URLRequest) async throws -> BackupHTTPResult { try await BackupDataRequest().send(request) }
}

/// Metadata only. No cookies/cache, no redirects, bounded responses and no logs.
private final class BackupDataRequest:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    private let lock = NSLock()
    private var continuation:CheckedContinuation<BackupHTTPResult,Error>?
    private var session:URLSession?
    private var bytes = Data()
    private var response:HTTPURLResponse?
    private var finished = false
    func send(_ request:URLRequest) async throws -> BackupHTTPResult {
        guard request.url?.scheme == "https" else { throw BackupProblem.configuration }
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished { lock.unlock();continuation.resume(throwing:BackupProblem.cancelled);return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil;config.httpCookieStorage = nil;config.httpShouldSetCookies = false
                config.timeoutIntervalForRequest = 45;config.timeoutIntervalForResource = 60
                #if os(iOS)
                config.allowsCellularAccess = true;config.allowsConstrainedNetworkAccess = true
                #endif
                let session = URLSession(configuration:config,delegate:self,delegateQueue:nil);self.session = session
                lock.unlock();session.dataTask(with:request).resume()
            }
        },onCancel:{ self.finish(.failure(BackupProblem.cancelled)) })
    }
    private func finish(_ result:Result<BackupHTTPResult,Error>) {
        lock.lock();guard !finished else { lock.unlock();return };finished = true
        let continuation = self.continuation,session = self.session
        self.continuation = nil;self.session = nil;self.bytes = Data();lock.unlock()
        session?.invalidateAndCancel();continuation?.resume(with:result)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        guard let http = response as? HTTPURLResponse,http.expectedContentLength <= 131_072 else { completionHandler(.cancel);finish(.failure(BackupProblem.invalidResponse));return }
        lock.lock();self.response = http;lock.unlock();completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        lock.lock();let tooLarge = bytes.count+data.count > 131_072
        if !tooLarge { bytes.append(data) };lock.unlock()
        if tooLarge { finish(.failure(BackupProblem.invalidResponse)) }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        if let error { finish(.failure(BackupProblem.safe(error)));return }
        lock.lock();let response = self.response,bytes = self.bytes;lock.unlock()
        guard let response else { finish(.failure(BackupProblem.invalidResponse));return }
        var headers:[String:String] = [:]
        for (key,value) in response.allHeaderFields { headers[String(describing:key)] = String(describing:value) }
        finish(.success(.init(status:response.statusCode,headers:headers,data:bytes)))
    }
}
