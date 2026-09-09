import Flutter
import Foundation

/// Legacy cache channel, restricted to known regenerable AlnPlay directories.
/// Dart owns quota eviction and playback leases. Never wipe the entire Caches
/// or tmp tree: unknown engine files and user-owned files are out of scope.
enum CacheCleaner {
    private static var playbackActive = false
    private static let managedNames = ["danmaku", "cover_art", "sidecar_subs", "opensubs", "native_subtitles"]

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "dreamplayer/cache",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "policy":
                let args = call.arguments as? [String: Any]
                playbackActive = args?["playbackActive"] as? Bool ?? false
                result(nil)
            case "size":
                DispatchQueue.global(qos: .utility).async {
                    let bytes = diskSizeBytes()
                    DispatchQueue.main.async { result(bytes) }
                }
            case "clear":
                if playbackActive { result(Int64(0)); return }
                DispatchQueue.global(qos: .utility).async {
                    let bytes = clearCacheBytes()
                    DispatchQueue.main.async { result(bytes) }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static var cacheDirectories: [URL] {
        var urls: [URL] = []
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            urls.append(caches)
        }
        urls.append(FileManager.default.temporaryDirectory)
        return urls.flatMap { root in managedNames.map { root.appendingPathComponent($0, isDirectory: true) } }
    }

    private static func diskSizeBytes() -> Int64 {
        var total: Int64 = 0
        for dir in cacheDirectories {
            if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
                for case let url as URL in enumerator {
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                          values.isDirectory != true,
                          let size = values.fileSize else { continue }
                    total += Int64(size)
                }
            }
        }
        return total
    }

    private static func clearCacheBytes() -> Int64 {
        var freed: Int64 = 0
        for dir in cacheDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirectory {
                    continue
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    freed += Int64(size)
                }
            }
        }
        return freed
    }
}
