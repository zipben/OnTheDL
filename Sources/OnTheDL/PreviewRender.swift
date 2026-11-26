import AppKit
import SwiftUI

/// `OnTheDL --render-preview <dir>` writes PNGs of the screens with sample data, for checking layout.
enum PreviewRender {
    @MainActor
    static func run(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        func item(_ name: String, _ url: String, _ state: DLState, _ got: Int64, _ total: Int64?, _ msg: String? = nil) -> DLItem {
            var i = DLItem(url: URL(string: url)!, fileName: name, folder: folder, state: state, received: got, total: total)
            i.message = msg
            if state == .done { i.finished = Date() }
            return i
        }
        let items = [
            item("ubuntu-26.04-desktop-amd64.iso", "https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso", .running, 2_140_000_000, 6_100_000_000),
            item("dataset.tar.zst", "https://example.org/files/dataset.tar.zst", .waiting, 410_000_000, 900_000_000, "MAC WENT TO SLEEP"),
            item("stream.bin", "https://example.org/stream", .running, 52_000_000, nil),
            item("old-build.zip", "https://example.org/old-build.zip", .paused, 12_000_000, 80_000_000),
            item("secret.pdf", "https://example.org/secret.pdf", .failed, 0, nil, "SERVER SAID 404"),
            item("album.flac.zip", "https://example.org/album.flac.zip", .done, 640_000_000, 640_000_000),
        ]
        for (name, tab, list) in [("downloads", Tab.downloads, items), ("empty", .downloads, []), ("options", .options, items)] {
            let dl = Downloader(preview: list)
            save(ContentView(initialTab: tab).environmentObject(dl), size: CGSize(width: 1100, height: 900), to: "\(dir)/\(name).png")
        }
    }

    @MainActor
    static func save<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
