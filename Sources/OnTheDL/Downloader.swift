import AppKit
import Foundation
import Network
import SwiftUI
import UserNotifications

enum DLState: String, Codable {
    case queued, running, paused, waiting, done, failed
}

/// One download. Bytes land in `<name>.otdl` next to the final file and are resumed with HTTP
/// Range requests, so a download survives sleep, network drops, and quitting the app.
struct DLItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var fileName: String
    var folder: URL
    var state: DLState = .queued
    var received: Int64 = 0
    var total: Int64?
    /// Strong ETag or Last-Modified, sent as If-Range so a file that changed on the server restarts cleanly.
    var validator: String?
    /// True once the server's suggested file name has been applied.
    var named = false
    var added = Date()
    var finished: Date?
    var message: String?
    var attempts = 0

    var finalURL: URL { folder.appendingPathComponent(fileName) }
    var partURL: URL { folder.appendingPathComponent(fileName + ".otdl") }
    var fraction: Double? {
        guard let total, total > 0 else { return state == .done ? 1 : nil }
        return min(1, Double(received) / Double(total))
    }
}

struct Dialog: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var color: Color = Pixel.red
}

/// Why we cancelled a task ourselves, so its completion knows what to do next.
private enum StopIntent { case pause, remove, restart, sleep }

private enum Key {
    static let folder = "saveFolder", stayAwake = "stayAwake", maxActive = "maxActive"
}

@MainActor
final class Downloader: NSObject, ObservableObject {
    @Published private(set) var items: [DLItem] = []
    @Published private(set) var speeds: [UUID: Double] = [:]
    @Published private(set) var retryAt: [UUID: Date] = [:]
    @Published private(set) var online = true
    @Published var dialog: Dialog?

    @Published var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: Key.folder) }
    }
    @Published var stayAwake: Bool {
        didSet { UserDefaults.standard.set(stayAwake, forKey: Key.stayAwake); updatePower() }
    }
    @Published var maxActive: Int {
        didSet { UserDefaults.standard.set(maxActive, forKey: Key.maxActive); pump() }
    }

    /// No bytes for this long while connected counts as a dead connection.
    static let stallTimeout: TimeInterval = 30

    private let preview: Bool
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private var owners: [Int: UUID] = [:]
    private var handles: [UUID: FileHandle] = [:]
    private var intents: [UUID: StopIntent] = [:]
    private var live: [UUID: Int64] = [:]
    private var lastByte: [UUID: Date] = [:]
    private var lastSample: [UUID: (Date, Int64)] = [:]
    private var activity: NSObjectProtocol?
    private var activityAwake = false
    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private var sleeping = false
    private var ticks = 0

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnTheDL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }

    init(preview items: [DLItem]? = nil) {
        let d = UserDefaults.standard
        folder = d.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        stayAwake = d.object(forKey: Key.stayAwake) as? Bool ?? true
        maxActive = d.object(forKey: Key.maxActive) as? Int ?? 3
        preview = items != nil
        super.init()
        if let items {
            self.items = items
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24 * 7
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        load()
        observeSystem()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        pump()
    }

    // MARK: - Public actions

    /// Adds every link found in `text` (one per line). Returns false if none were usable.
    @discardableResult
    func add(_ text: String) -> Bool {
        let links = text.split(whereSeparator: \.isNewline).compactMap { Self.parseLink(String($0)) }
        guard !links.isEmpty else {
            dialog = Dialog(title: "BAD LINK", message: "That doesn't look like a download link.\nPaste an http:// or https:// address.")
            return false
        }
        for url in links {
            let base = Self.sanitize(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
            let name = uniqueName(base.isEmpty || base == "/" ? (url.host ?? "download") : base, in: folder)
            items.insert(DLItem(url: url, fileName: name, folder: folder), at: 0)
        }
        save()
        pump()
        return true
    }

    func pause(_ id: UUID) {
        guard let i = index(id) else { return }
        retryAt[id] = nil
        if tasks[id] != nil {
            stop(id, .pause)
        } else {
            items[i].state = .paused
            save()
        }
    }

    func resume(_ id: UUID) {
        guard let i = index(id), [.paused, .failed, .waiting].contains(items[i].state) else { return }
        items[i].state = .queued
        items[i].attempts = 0
        items[i].message = nil
        retryAt[id] = nil
        save()
        pump()
    }

    func remove(_ id: UUID) {
        guard let i = index(id) else { return }
        if tasks[id] != nil {
            stop(id, .remove)
        } else {
            if items[i].state != .done { try? FileManager.default.removeItem(at: items[i].partURL) }
            items.remove(at: i)
            save()
        }
    }

    func clearFinished() {
        items.removeAll { $0.state == .done }
        save()
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let url = item.state == .done ? item.finalURL : item.partURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(item.folder)
        }
    }

    func received(_ item: DLItem) -> Int64 { live[item.id] ?? item.received }
    var activeCount: Int { items.filter { [.running, .waiting, .queued].contains($0.state) }.count }
    var totalSpeed: Double { speeds.values.reduce(0, +) }

    // MARK: - Scheduling

    /// Starts queued downloads up to the concurrency limit.
    private func pump() {
        guard !preview, !sleeping else { return }
        for item in items.reversed() where item.state == .queued {
            if tasks.count >= maxActive { break }
            start(item.id)
        }
        updatePower()
    }

    private func start(_ id: UUID) {
        guard let i = index(id), tasks[id] == nil else { return }
        let have = (try? FileManager.default.attributesOfItem(atPath: items[i].partURL.path)[.size] as? Int64) ?? 0
        items[i].received = have
        items[i].state = .running
        retryAt[id] = nil

        var req = URLRequest(url: items[i].url)
        // Compressed transfers would make byte offsets disagree with the file on disk.
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if have > 0 {
            req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
            if let v = items[i].validator { req.setValue(v, forHTTPHeaderField: "If-Range") }
        }
        let task = session.dataTask(with: req)
        tasks[id] = task
        owners[task.taskIdentifier] = id
        live[id] = have
        lastByte[id] = Date()
        lastSample[id] = (Date(), have)
        task.resume()
    }

    private func stop(_ id: UUID, _ intent: StopIntent) {
        guard let task = tasks[id] else { return }
        intents[id] = intent
        task.cancel()
    }

    /// Network or server trouble: wait and try again from where we left off, backing off up to a minute.
    private func retryLater(_ i: Int, _ reason: String) {
        let delay = min(60, pow(2, Double(items[i].attempts)))
        items[i].attempts += 1
        items[i].state = .waiting
        items[i].message = reason
        retryAt[items[i].id] = Date().addingTimeInterval(delay)
    }

    private func fail(_ i: Int, _ reason: String) {
        items[i].state = .failed
        items[i].message = reason
        retryAt[items[i].id] = nil
    }

    private func tick() {
        let now = Date()
        for (id, task) in tasks {
            // Publish progress and a smoothed speed once a second instead of on every packet.
            if let i = index(id), let bytes = live[id] {
                items[i].received = bytes
                if let (t, b) = lastSample[id], now.timeIntervalSince(t) > 0 {
                    let rate = Double(bytes - b) / now.timeIntervalSince(t)
                    speeds[id] = (speeds[id] ?? rate) * 0.6 + rate * 0.4
                }
                lastSample[id] = (now, bytes)
            }
            // A connection that stops sending (common after sleep or a Wi-Fi change) gets restarted.
            if online, let last = lastByte[id], now.timeIntervalSince(last) > Self.stallTimeout,
               task.state == .running, let i = index(id) {
                items[i].message = "STALLED, RECONNECTING"
                stop(id, .restart)
            }
        }
        for (id, at) in retryAt where at <= now && online && !sleeping {
            guard let i = index(id), items[i].state == .waiting else { retryAt[id] = nil; continue }
            items[i].state = .queued
            retryAt[id] = nil
        }
        pump()
        ticks += 1
        if ticks % 5 == 0, !tasks.isEmpty { save() }
    }

    // MARK: - Sleep, wake and network

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for h in self.handles.values { try? h.synchronize() }
                self.syncLive()
                self.save()
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async { self?.networkChanged(up) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// Close connections cleanly before sleep; they'd come back dead anyway.
    private func willSleep() {
        sleeping = true
        for id in tasks.keys { stop(id, .sleep) }
        syncLive()
        save()
    }

    private func didWake() {
        // Give Wi-Fi a moment to rejoin before reconnecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.sleeping = false
            // Restart anything still holding a pre-sleep connection, then everything that was waiting.
            for id in self.tasks.keys { self.stop(id, .restart) }
            for i in self.items.indices where self.items[i].state == .waiting || (self.items[i].state == .running && self.tasks[self.items[i].id] == nil) {
                self.items[i].state = .queued
                self.items[i].message = "RESUMED AFTER SLEEP"
                self.retryAt[self.items[i].id] = nil
            }
            self.pump()
        }
    }

    private func networkChanged(_ up: Bool) {
        let cameBack = up && !online
        online = up
        guard cameBack else { return }
        for i in items.indices where items[i].state == .waiting {
            items[i].state = .queued
            items[i].attempts = 0
            retryAt[items[i].id] = nil
        }
        pump()
    }

    /// Keeps the Mac from idle-sleeping (and the app from napping) while anything is downloading.
    private func updatePower() {
        guard !preview else { return }
        let busy = items.contains { [.running, .waiting, .queued].contains($0.state) }
        let wantAwake = busy && stayAwake
        if activity != nil, !busy || activityAwake != wantAwake {
            ProcessInfo.processInfo.endActivity(activity!)
            activity = nil
        }
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: wantAwake ? [.userInitiated, .idleSystemSleepDisabled] : .userInitiatedAllowingIdleSystemSleep,
                reason: "Downloading files")
            activityAwake = wantAwake
        }
        let n = activeCount
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: - Transfer events

    fileprivate func handleResponse(_ task: URLSessionDataTask, _ response: URLResponse) -> URLSession.ResponseDisposition {
        guard let id = owners[task.taskIdentifier], let i = index(id) else { return .cancel }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        var have = items[i].received
        let fm = FileManager.default

        switch status {
        case 206:
            let range = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
            let start = Int64(range.split(separator: " ").last?.split(separator: "-").first ?? "") ?? -1
            if let size = range.split(separator: "/").last.flatMap({ Int64($0) }) { items[i].total = size }
            guard start == have else {
                // The server sent a different slice than we asked for; start over.
                try? fm.removeItem(at: items[i].partURL)
                items[i].received = 0
                items[i].message = "SERVER SENT WRONG PIECE, RESTARTING"
                stop(id, .restart)
                return .cancel
            }
        case 200..<300:
            if have > 0 {
                // No resume support (or the file changed): start from the top.
                items[i].message = "SERVER CAN'T RESUME, RESTARTED"
                have = 0
            }
            items[i].total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        case 416:
            if let total = items[i].total, have >= total {
                complete(i)
                settle(id)
            } else {
                try? fm.removeItem(at: items[i].partURL)
                items[i].received = 0
                stop(id, .restart)
            }
            return .cancel
        case 408, 425, 429, 500...599:
            retryLater(i, "SERVER SAID \(status)")
            settle(id)
            return .cancel
        default:
            fail(i, "SERVER SAID \(status)")
            settle(id)
            return .cancel
        }

        if !items[i].named, have == 0 {
            items[i].named = true
            if let suggested = response.suggestedFilename.map(Self.sanitize), !suggested.isEmpty, suggested != items[i].fileName {
                items[i].fileName = uniqueName(suggested, in: items[i].folder, ignoring: id)
            }
        }
        if let etag = http?.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") {
            items[i].validator = etag
        } else {
            items[i].validator = http?.value(forHTTPHeaderField: "Last-Modified")
        }

        do {
            let part = items[i].partURL
            if have == 0 || !fm.fileExists(atPath: part.path) {
                try fm.createDirectory(at: items[i].folder, withIntermediateDirectories: true)
                fm.createFile(atPath: part.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: part)
            try h.truncate(atOffset: UInt64(have))
            try h.seekToEnd()
            handles[id] = h
        } catch {
            fail(i, "CAN'T WRITE FILE: \(error.localizedDescription)")
            settle(id)
            return .cancel
        }
        items[i].received = have
        live[id] = have
        lastSample[id] = (Date(), have)
        save()
        return .allow
    }

    fileprivate func handleData(_ task: URLSessionDataTask, _ data: Data) {
        guard let id = owners[task.taskIdentifier], let h = handles[id] else { return }
        do {
            try h.write(contentsOf: data)
        } catch {
            if let i = index(id) { fail(i, "CAN'T WRITE FILE: \(error.localizedDescription)") }
            stop(id, .pause)
            return
        }
        live[id, default: 0] += Int64(data.count)
        lastByte[id] = Date()
        if let i = index(id), items[i].attempts > 0 {
            items[i].attempts = 0
            items[i].message = nil
        }
    }

    fileprivate func handleComplete(_ task: URLSessionTask, _ error: Error?) {
        guard let id = owners[task.taskIdentifier] else { return }
        let intent = intents[id]
        cleanup(id)
        guard let i = index(id) else { return }
        items[i].received = live.removeValue(forKey: id) ?? items[i].received

        switch intent {
        case .pause:
            if items[i].state == .running { items[i].state = .paused }
        case .remove:
            try? FileManager.default.removeItem(at: items[i].partURL)
            items.remove(at: i)
        case .restart:
            items[i].state = .queued
        case .sleep:
            items[i].state = .waiting
            items[i].message = "MAC WENT TO SLEEP"
            retryAt[id] = Date().addingTimeInterval(5)
        case nil:
            if let error {
                retryLater(i, Self.describe(error))
            } else if let total = items[i].total, items[i].received < total {
                retryLater(i, "CONNECTION CUT SHORT")
            } else {
                complete(i)
            }
        }
        save()
        pump()
    }

    /// Drops a task we've already dealt with, so its cancellation callback is ignored.
    private func settle(_ id: UUID) {
        cleanup(id)
        live[id] = nil
        save()
        pump()
    }

    private func cleanup(_ id: UUID) {
        if let task = tasks.removeValue(forKey: id) { owners[task.taskIdentifier] = nil }
        if let h = handles.removeValue(forKey: id) {
            try? h.synchronize()
            try? h.close()
        }
        intents[id] = nil
        speeds[id] = nil
        lastByte[id] = nil
        lastSample[id] = nil
    }

    private func complete(_ i: Int) {
        let fm = FileManager.default
        // partURL follows fileName, so grab it before a clash forces a rename.
        let part = items[i].partURL
        if fm.fileExists(atPath: items[i].finalURL.path) {
            items[i].fileName = uniqueName(items[i].fileName, in: items[i].folder, ignoring: items[i].id)
        }
        do {
            try fm.moveItem(at: part, to: items[i].finalURL)
        } catch {
            fail(i, "CAN'T FINISH FILE: \(error.localizedDescription)")
            return
        }
        items[i].state = .done
        items[i].finished = Date()
        items[i].message = nil
        if items[i].total == nil { items[i].total = items[i].received }
        notifyDone(items[i])
    }

    private func notifyDone(_ item: DLItem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Got it"
            content.body = item.fileName
            center.add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - Helpers

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func syncLive() {
        for (id, bytes) in live { if let i = index(id) { items[i].received = bytes } }
    }

    /// `name`, or `name (2).ext` etc., so nothing on disk or in the list gets overwritten.
    private func uniqueName(_ name: String, in folder: URL, ignoring: UUID? = nil) -> String {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 1
        var candidate = name
        func taken(_ c: String) -> Bool {
            fm.fileExists(atPath: folder.appendingPathComponent(c).path)
                || fm.fileExists(atPath: folder.appendingPathComponent(c + ".otdl").path)
                || items.contains { $0.id != ignoring && $0.folder == folder && $0.fileName == c && $0.state != .done }
        }
        while taken(candidate) {
            n += 1
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
        }
        return candidate
    }

    static func parseLink(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'")))
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        return String(name.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        switch e.code {
        case NSURLErrorNotConnectedToInternet: return "NO INTERNET"
        case NSURLErrorNetworkConnectionLost: return "CONNECTION LOST"
        case NSURLErrorTimedOut: return "TIMED OUT"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "CAN'T FIND SERVER"
        case NSURLErrorCannotConnectToHost: return "CAN'T REACH SERVER"
        default: return e.localizedDescription.uppercased()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let saved = try? JSONDecoder().decode([DLItem].self, from: data) else { return }
        items = saved
        // Anything mid-flight when the app last quit picks back up.
        for i in items.indices where [.running, .waiting].contains(items[i].state) {
            items[i].state = .queued
        }
    }

    private func save() {
        guard !preview, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
        updatePower()
    }
}

extension Downloader: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated { completionHandler(handleResponse(dataTask, response)) }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated { handleData(dataTask, data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { handleComplete(task, error) }
    }
}
