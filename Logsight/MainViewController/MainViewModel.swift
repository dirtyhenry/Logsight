import Foundation

struct Log {
    let date: Date
    let appName: String
    let level: LogLevel
    let message: String
    let data: [String:String]
}

enum LogLevel {
    case trace, debug, info, warn, error
    
    static func from(string levelString: String) -> LogLevel? {
        switch levelString {
        case "TRACE": return .trace
        case "DEBUG": return .debug
        case "INFO": return .info
        case "WARN": return .warn
        case "ERROR": return .error
        default: return nil
        }
    }
}

class MainViewModel {
    
    private static let dateFormatter: ISO8601DateFormatter = {
        var formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter
    }()
    
    private(set) var logs: [Log] = []
    
    private(set) var columns: Set<String> = []
    private var fileBookmarks: [String: Data] =
        (UserDefaults.standard.dictionary(forKey: "bookmarks")) as? [String : Data] ?? [:] {
        didSet {
            UserDefaults.standard.set(fileBookmarks, forKey: "bookmarks")
        }
    }
    
    private var apps: [FileHandle: String] = [:]
    
    var delegate: MainViewModelDelegate?
    
    init() {
        NotificationCenter.default.addObserver(
            forName: .NSFileHandleReadToEndOfFileCompletion,
            object: nil, queue: nil,
            using: { notification in
                let fileHandle = notification.object as! FileHandle
                let data = notification.userInfo![NSFileHandleNotificationDataItem] as! Data
                self.readChunkData(data: data, app: self.apps[fileHandle]!)
                fileHandle.waitForDataInBackgroundAndNotify()
        })
        
        NotificationCenter.default.addObserver(
            forName: FileHandle.readCompletionNotification,
            object: nil, queue: nil,
            using: { notification in
                let fileHandle = notification.object as! FileHandle
                let data = notification.userInfo![NSFileHandleNotificationDataItem] as! Data
                self.readChunkData(data: data, app: self.apps[fileHandle]!)
                fileHandle.waitForDataInBackgroundAndNotify()
        })
        
        NotificationCenter.default.addObserver(
            forName: .NSFileHandleDataAvailable,
            object: nil, queue: nil,
            using: { notification in
                let fileHandle = notification.object as! FileHandle
                fileHandle.readInBackgroundAndNotify()
        })
        
        // Load previously saved file bookmarks
        fileBookmarks.forEach({(key, value) in loadBookMarkData(bookmarkData: value)})
    }
    
    func loadNewFile(url: URL) {
        
        // Make sure we don't read twice the same file
        if fileBookmarks.contains(where: { (key, value) in key == url.absoluteString }) {
            print("Already reading \(url.absoluteString)")
            return
        }
        
        // Create a security-scope bookmark to be able
        // to reopen the file when the app is restarted.
        let bookmarkData = try! url.bookmarkData(
            options: URL.BookmarkCreationOptions(rawValue:
                URL.BookmarkCreationOptions.withSecurityScope.rawValue
                    | URL.BookmarkCreationOptions.securityScopeAllowOnlyReadAccess.rawValue),
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        
        // Save the bookmark data for later
        fileBookmarks[url.absoluteString] = bookmarkData
        
        // Then load the file
        loadBookMarkData(bookmarkData: bookmarkData)
    }
    
    /// Load a log file, parse its content and merge the new logs with existing logs.
    func loadBookMarkData(bookmarkData: Data) {
        
        // Recreate file URL from bookmark data
        var isStale: Bool = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
            ) else {
                print("Unable to recreate file URL from saved security-scope bookmark.")
                return
        }
        
        if !url.startAccessingSecurityScopedResource() {
            print("Could not reuse access to file \(url.absoluteString).")
            fileBookmarks.removeValue(forKey: url.absoluteString)
            return
        }
        
        // Open a read-only file descriptor on the file
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            print("Unable to open a file handle on \(url.absoluteString).")
            fileBookmarks.removeValue(forKey: url.absoluteString)
            return
        }
        
        // Retain the app name related to this file handle
        apps[handle] = String(url.lastPathComponent.split(separator: ".").first!)
        
        // Starts by reading all the file and extract existing logs from it
        print("Start reading file \(url.absoluteString)")
        handle.readToEndOfFileInBackgroundAndNotify()
    }
    
    // TODO: remove "backend", infer it for the file handler instead
    func readChunkData(data: Data, app: String) {
        guard let text = String(data: data, encoding: .utf8) else {
            print("Unable to read incoming data as UTF8.")
            return
        }
        
        let lines = text.components(separatedBy: .newlines)
        let newLogs: [Log] = lines.compactMap {
            // Micro optimization to prevent parsing empty lines
            if ($0.isEmpty) {
                return nil
            }
            
            // Parse each JSON line as a dictionary of [String:Any]. If a line is made
            // of invalid JSON or anything else than a JSON object, the line is silently
            // ignored.
            guard
                let jsonObject = try? JSONSerialization.jsonObject(with: $0.data(using: .utf8)!),
                let jsonDict = jsonObject as? [String: Any]
                else {
                    print("Ignoring line due to failure during parsing: \($0)")
                    return nil
            }
            
            // In case the JSON is multiple levels deep, flatten it to one by transforming
            // the second level into strings.
            var data = jsonDict.mapValues { value in String(describing: value) }
            
            // Find the date of the log, or ignore it if it doesn't have one.
            guard let dateString = data.removeValue(forKey: "@timestamp")
                else {
                    print("Ignoring line without a date: \(data)")
                    return nil
            }
            
            // Find and parse the date of the log, or ignore the log if it doesn't have one.
            // Note that it removes the date from the data, since we'll have one ourselves.
            guard let date = MainViewModel.dateFormatter.date(from: dateString)
                else {
                    print("Ignoring line because unable to parse the date \(dateString)")
                    return nil
            }
            
            // Find the level of the log, or ignore the log if it doesn't have one.
            // Note that it removes the date from the data, since we'll have one ourselves.
            guard let levelString = data.removeValue(forKey: "level")
                else {
                    print("Ignoring line without a level: \(data)")
                    return nil
            }
            
            guard let level = LogLevel.from(string: levelString) else {
                print("Unknown log level: \(levelString)")
                return nil
            }
            
            guard let message = data.removeValue(forKey: "stack_trace")
                ?? data.removeValue(forKey: "message")
                else {
                    print("Ignoring line without a message: \(data)")
                    return nil
            }
            
            // Create a Log from the gathered data
            return Log(
                date: date, appName: app,
                level: level, message: message.trimmingCharacters(in: ["\n", " "]),
                data: data
            )
        }
        
        // Append the logs and notify the delegate
        let initialSize = logs.count
        logs.append(contentsOf: newLogs)
        let finalSize = logs.count
        delegate?.logsDidUpdate(update: .added(initialSize..<finalSize))
    }
}

protocol MainViewModelDelegate {
    
    func logsDidUpdate(update: LogsUpdate)
}

enum LogsUpdate {
    case added(CountableRange<Int>)
}
