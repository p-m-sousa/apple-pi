import Foundation
import CoreServices

public struct RecursiveFileSystemChange: Sendable {
    public let paths: [URL]
    public let directoryPaths: [URL]
    public let requiresFullScan: Bool

    public init(
        paths: [URL],
        directoryPaths: [URL] = [],
        requiresFullScan: Bool
    ) {
        self.paths = paths
        self.directoryPaths = directoryPaths
        self.requiresFullScan = requiresFullScan
    }
}

/// A recursive FSEvents watcher backed by one stream and one dispatch queue,
/// regardless of the number of subdirectories below the watched roots.
public final class RecursiveFileSystemWatcher: @unchecked Sendable {
    private final class CallbackContext: @unchecked Sendable {
        let callback: @Sendable (RecursiveFileSystemChange) -> Void

        init(callback: @escaping @Sendable (RecursiveFileSystemChange) -> Void) {
            self.callback = callback
        }
    }

    private let urls: [URL]
    private let latency: CFTimeInterval
    private let callback: @Sendable (RecursiveFileSystemChange) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(
        urls: [URL],
        latency: CFTimeInterval = 0.25,
        callback: @escaping @Sendable (RecursiveFileSystemChange) -> Void
    ) {
        self.urls = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        self.latency = latency
        self.callback = callback
        queue = DispatchQueue(label: "com.paulsousa.ApplePi.recursive-file-watcher", qos: .utility)
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !urls.isEmpty else { return }

        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }

        let callbackContext = CallbackContext(callback: callback)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(callbackContext).toOpaque(),
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<CallbackContext>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, contextPointer, count, rawPaths, rawFlags, _ in
                guard let contextPointer else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(contextPointer)
                    .takeUnretainedValue()
                let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
                var urls: [URL] = []
                urls.reserveCapacity(paths.count)
                var directoryURLs: [URL] = []
                var requiresFullScan = false

                for index in 0..<count {
                    let flags = rawFlags[index]
                    if index < paths.count {
                        let url = URL(filePath: paths[index])
                        urls.append(url)
                        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                            directoryURLs.append(url)
                        }
                    }
                    let invalidatingFlags = FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs |
                        kFSEventStreamEventFlagUserDropped |
                        kFSEventStreamEventFlagKernelDropped |
                        kFSEventStreamEventFlagEventIdsWrapped |
                        kFSEventStreamEventFlagRootChanged
                    )
                    if flags & invalidatingFlags != 0 {
                        requiresFullScan = true
                    }
                }
                context.callback(RecursiveFileSystemChange(
                    paths: urls,
                    directoryPaths: directoryURLs,
                    requiresFullScan: requiresFullScan
                ))
            },
            &context,
            urls.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Unmanaged<CallbackContext>.fromOpaque(context.info!).release()
            throw CocoaError(.fileReadUnknown)
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            throw CocoaError(.fileReadUnknown)
        }
        stream = newStream
    }

    public func stop() {
        lock.lock()
        let oldStream = stream
        stream = nil
        lock.unlock()
        guard let oldStream else { return }
        FSEventStreamStop(oldStream)
        FSEventStreamInvalidate(oldStream)
        FSEventStreamRelease(oldStream)
    }
}
