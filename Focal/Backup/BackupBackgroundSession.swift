import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Background transfers always read a bounded on-disk chunk. There is no
/// completion-handler upload task, in-memory RAW upload or camera dependency.
final class BackupBackgroundSession:NSObject,URLSessionDataDelegate,BackupTransferTransport,@unchecked Sendable {
    typealias Completion = @Sendable(String,BackupHTTPResult?,BackupProblem?) async -> Void
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var handler:Completion?
    private var eventsFinished = false
    private var finishedEvents:(@Sendable()->Void)?
    private var bytes:[Int:Data] = [:]
    private var sessions:URLSession?
    let identifier:String
    init(identifier:String) { self.identifier = identifier;super.init() }
    func install(_ handler:@escaping Completion) { lock.lock();self.handler = handler;lock.unlock() }
    private func session() -> URLSession {
        lock.lock();defer{lock.unlock()}
        if let sessions { return sessions }
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier:identifier)
        config.sessionSendsLaunchEvents = true;config.isDiscretionary = false;config.waitsForConnectivity = true
        config.allowsConstrainedNetworkAccess = true;config.allowsExpensiveNetworkAccess = true
        #else
        let config = URLSessionConfiguration.ephemeral
        #endif
        config.allowsCellularAccess = true;config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil;config.httpCookieStorage = nil;config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60;config.timeoutIntervalForResource = 7*86_400
        let session = URLSession(configuration:config,delegate:self,delegateQueue:nil)
        self.sessions = session;return session
    }
    func start(_ transfer:BackupTransfer) async throws {
        guard transfer.request.url?.scheme == "https",transfer.file.isFileURL else { throw BackupProblem.configuration }
        let task = session().uploadTask(with:transfer.request,fromFile:transfer.file)
        task.taskDescription = transfer.tag;task.resume()
    }
    func activeTags() async -> Set<String> {
        await withCheckedContinuation { continuation in
            session().getAllTasks { tasks in continuation.resume(returning:Set(tasks.compactMap(\.taskDescription))) }
        }
    }
    func cancelAll() async {
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            session().getAllTasks { tasks in for task in tasks { task.cancel() };continuation.resume() }
        }
    }
    func handleEvents(completion:@escaping @Sendable()->Void) {
        lock.lock()
        let alreadyFinished = eventsFinished;eventsFinished = false
        if !alreadyFinished { finishedEvents = completion }
        lock.unlock()
        if alreadyFinished { group.notify(queue:.main,execute:completion) }
        _ = session()
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        lock.lock();let next = (bytes[dataTask.taskIdentifier]?.count ?? 0)+data.count
        if next <= 131_072 { bytes[dataTask.taskIdentifier,default:Data()].append(data) }
        lock.unlock();if next > 131_072 { dataTask.cancel() }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        lock.lock();let body = bytes.removeValue(forKey:task.taskIdentifier) ?? Data(),handler = self.handler;lock.unlock()
        guard let tag = task.taskDescription,let handler else { return }
        var result:BackupHTTPResult?
        if let http = task.response as? HTTPURLResponse {
            var headers:[String:String] = [:]
            for (key,value) in http.allHeaderFields { headers[String(describing:key)] = String(describing:value) }
            result = .init(status:http.statusCode,headers:headers,data:body)
        }
        let problem = error.map{BackupProblem.safe($0)}
        group.enter()
        Task { await handler(tag,result,problem);self.group.leave() }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session:URLSession) {
        // Persist delegate results before acknowledging delivery to iOS.
        lock.lock();let completion = finishedEvents;finishedEvents = nil;eventsFinished = completion == nil;lock.unlock()
        if let completion { group.notify(queue:.main,execute:completion) }
    }
}
