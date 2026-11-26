import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum Tab: String, CaseIterable {
    case downloads = "DOWNLOADS", options = "OPTIONS"
}

struct ContentView: View {
    @EnvironmentObject var dl: Downloader
    @State private var tab: Tab
    @State private var dropping = false
    @AppStorage(TextSize.key) private var textScale: Double = TextSize.medium.rawValue

    init(initialTab: Tab = .downloads) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            Pixel.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(tab: $tab)
                Rectangle().fill(Pixel.edge).frame(height: 3)
                switch tab {
                case .downloads: DownloadsScreen()
                case .options: OptionsScreen()
                }
            }
            Scanlines()
            if dropping {
                PixelRect(step: 8).stroke(Pixel.green, style: StrokeStyle(lineWidth: 4, dash: [12, 8]))
                    .padding(10).allowsHitTesting(false)
            }
            if let d = dl.dialog { DialogView(dialog: d) { dl.dialog = nil } }
        }
        // Fonts read the scale directly, so rebuild the tree when it changes.
        .id(textScale)
        .frame(minWidth: Pixel.ui(640), minHeight: Pixel.ui(460))
        .preferredColorScheme(.dark)
        .onDrop(of: [.url, .plainText], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    guard let s = s as? String else { return }
                    DispatchQueue.main.async { dl.add(s); tab = .downloads }
                }
            }
            return true
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var dl: Downloader
    @Binding var tab: Tab

    var body: some View {
        HStack(spacing: 16) {
            Logo(pixel: Pixel.ui(2.5))
            VStack(alignment: .leading, spacing: 6) {
                Text("ON THE DL").font(Pixel.font(20)).foregroundStyle(Pixel.yellow)
                    .shadow(color: Pixel.red, radius: 0, x: 3, y: 3)
                StatusLine()
            }
            Spacer()
            ForEach(Tab.allCases, id: \.self) { t in
                PixelChip(label: t.rawValue, selected: tab == t, color: Pixel.cyan) { tab = t }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Pixel.panel)
    }
}

struct StatusLine: View {
    @EnvironmentObject var dl: Downloader

    var body: some View {
        let active = dl.activeCount
        HStack(spacing: 14) {
            if !dl.online {
                Text("OFFLINE").font(Pixel.font(8)).foregroundStyle(Pixel.red).blinking()
            }
            Text("\(active) ACTIVE").font(Pixel.font(8)).foregroundStyle(active > 0 ? Pixel.green : Pixel.inkDim)
            if dl.totalSpeed > 0 {
                Text(rateString(dl.totalSpeed)).font(Pixel.font(8)).foregroundStyle(Pixel.cyan)
            }
            if active > 0, dl.stayAwake {
                Text("NO SLEEP").font(Pixel.font(8)).foregroundStyle(Pixel.magenta)
            }
        }
    }
}

// MARK: - Downloads

struct DownloadsScreen: View {
    @EnvironmentObject var dl: Downloader
    @State private var link = ""

    var body: some View {
        VStack(spacing: 14) {
            PixelPanel(title: "NEW DOWNLOAD", accent: Pixel.green) {
                HStack(spacing: 10) {
                    PixelField(placeholder: "PASTE A LINK", text: $link)
                        .onSubmit(submit)
                    Button("GET IT", action: submit)
                        .buttonStyle(PixelButtonStyle(color: Pixel.green))
                        .keyboardShortcut(.defaultAction)
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("SAVING TO \(abbreviate(dl.folder.path).uppercased())")
                    .font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted).lineLimit(1).truncationMode(.middle)
            }
            if dl.items.isEmpty {
                EmptyState()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(dl.items) { DownloadRow(item: $0) }
                    }
                    .padding(.bottom, 4)
                }
                if dl.items.contains(where: { $0.state == .done }) {
                    HStack {
                        Spacer()
                        Button("CLEAR FINISHED") { dl.clearFinished() }
                            .buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink, size: 8))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: prefillFromClipboard)
    }

    private func submit() {
        if dl.add(link) { link = "" }
    }

    /// If a link is sitting on the clipboard, offer it.
    private func prefillFromClipboard() {
        guard link.isEmpty, let s = NSPasteboard.general.string(forType: .string),
              Downloader.parseLink(s) != nil, s.contains("://"),
              !dl.items.contains(where: { $0.url.absoluteString == s.trimmingCharacters(in: .whitespacesAndNewlines) }) else { return }
        link = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Logo(pixel: 8)
            Text("NOTHING ON THE DL").font(Pixel.font(16)).foregroundStyle(Pixel.yellow)
            Text("PASTE OR DROP A LINK").font(Pixel.font(9)).foregroundStyle(Pixel.inkDim).blinking(0.7)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct DownloadRow: View {
    @EnvironmentObject var dl: Downloader
    let item: DLItem

    var body: some View {
        let got = dl.received(item)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.fileName).font(Pixel.font(10)).foregroundStyle(Pixel.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(item.url.absoluteString).font(Pixel.mono(10)).foregroundStyle(Pixel.inkMuted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                StateTag(text: tagText, color: tagColor)
            }
            if item.state != .done {
                if let total = item.total, total > 0 {
                    PixelBar(fraction: Double(got) / Double(total), color: tagColor, cells: 32, height: 12)
                } else {
                    SweepBar(color: tagColor, running: item.state == .running)
                }
            }
            HStack(spacing: 12) {
                Text(detailText(got)).font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
                if let m = item.message, item.state != .done {
                    Text(m.uppercased()).font(Pixel.font(7)).foregroundStyle(item.state == .failed ? Pixel.red : Pixel.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                buttons
            }
        }
        .padding(12)
        .background(PixelRect().fill(Pixel.panel))
        .overlay(PixelRect().stroke(Pixel.edge, lineWidth: 3))
        .overlay(PixelRect(step: 4).inset(by: 3).stroke(Pixel.panelHi, lineWidth: 2))
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .done: Sprites.check(2.5)
        case .failed: Sprites.skull(2.5)
        case .waiting where item.message == "MAC WENT TO SLEEP": Sprites.moon(2.5)
        default: Sprite(rows: Logo.rows, palette: ["k": Pixel.edge, "y": tagColor, "w": Pixel.cyan], scale: 1.5)
        }
    }

    @ViewBuilder private var buttons: some View {
        let small = PixelButtonStyle(color: Pixel.yellow, size: 7)
        switch item.state {
        case .running, .queued, .waiting:
            Button("PAUSE") { dl.pause(item.id) }.buttonStyle(small)
            if item.state == .waiting { Button("RETRY NOW") { dl.resume(item.id) }.buttonStyle(PixelButtonStyle(color: Pixel.cyan, size: 7)) }
        case .paused:
            Button("RESUME") { dl.resume(item.id) }.buttonStyle(PixelButtonStyle(color: Pixel.green, size: 7))
        case .failed:
            Button("RETRY") { dl.resume(item.id) }.buttonStyle(PixelButtonStyle(color: Pixel.green, size: 7))
        case .done:
            Button("SHOW") { dl.reveal(item.id) }.buttonStyle(PixelButtonStyle(color: Pixel.cyan, size: 7))
        }
        Button(item.state == .done ? "X" : "CANCEL") { dl.remove(item.id) }
            .buttonStyle(PixelButtonStyle(color: Pixel.red, size: 7))
            .help(item.state == .done ? "Remove from list (keeps the file)" : "Stop and delete the partial file")
    }

    private var tagText: String {
        switch item.state {
        case .queued: return "QUEUED"
        case .running: return dl.speeds[item.id] == nil ? "CONNECTING" : "DOWNLOADING"
        case .paused: return "PAUSED"
        case .waiting:
            if let at = dl.retryAt[item.id] {
                let s = max(0, Int(at.timeIntervalSinceNow.rounded(.up)))
                return "RETRY IN \(s)S"
            }
            return "WAITING"
        case .done: return "GOT IT"
        case .failed: return "FAILED"
        }
    }

    private var tagColor: Color {
        switch item.state {
        case .queued: return Pixel.inkDim
        case .running: return Pixel.cyan
        case .paused: return Pixel.yellow
        case .waiting: return Pixel.magenta
        case .done: return Pixel.green
        case .failed: return Pixel.red
        }
    }

    private func detailText(_ got: Int64) -> String {
        var parts = [item.total.map { "\(bytesString(got)) / \(bytesString($0))" } ?? bytesString(got)]
        if item.state == .running, let speed = dl.speeds[item.id], speed > 0 {
            parts.append(rateString(speed))
            if let total = item.total, total > got {
                parts.append(etaString(Double(total - got) / speed) + " LEFT")
            }
        }
        if item.state == .done, let f = item.finished {
            parts.append(f.formatted(date: .abbreviated, time: .shortened).uppercased())
        }
        return parts.joined(separator: "  ")
    }
}

struct StateTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(Pixel.font(7)).foregroundStyle(Pixel.edge)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(color)
    }
}

/// Progress for downloads with no known size: a block of cells that slides across.
struct SweepBar: View {
    var color: Color
    var running: Bool
    var cells = 32

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
            let pos = running ? Int(ctx.date.timeIntervalSinceReferenceDate / 0.12) % (cells + 6) - 6 : -99
            HStack(spacing: 2) {
                ForEach(0..<cells, id: \.self) { i in
                    Rectangle().fill(i >= pos && i < pos + 6 ? color : Pixel.panelHi)
                }
            }
            .frame(height: 12)
            .padding(3)
            .background(Rectangle().fill(Pixel.bg))
            .overlay(Rectangle().stroke(Pixel.edge, lineWidth: 2))
        }
    }
}

// MARK: - Options

struct OptionsScreen: View {
    @EnvironmentObject var dl: Downloader
    @AppStorage(TextSize.key) private var textScale: Double = TextSize.medium.rawValue
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                PixelPanel(title: "SAVE TO", accent: Pixel.cyan) {
                    HStack(spacing: 10) {
                        Text(abbreviate(dl.folder.path)).font(Pixel.mono(12)).foregroundStyle(Pixel.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("CHANGE", action: chooseFolder).buttonStyle(PixelButtonStyle(color: Pixel.cyan, size: 8))
                    }
                }
                PixelPanel(title: "STAYING ALIVE", accent: Pixel.magenta) {
                    PixelToggle(label: "KEEP THE MAC AWAKE", isOn: $dl.stayAwake,
                                detail: "Stops idle sleep while anything is downloading. Closing the lid still sleeps - downloads reconnect and pick up where they left off on wake.")
                    PixelToggle(label: "OPEN AT LOGIN", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin),
                                detail: "Unfinished downloads resume after a restart.")
                }
                PixelPanel(title: "AT ONCE", accent: Pixel.yellow) {
                    HStack(spacing: 8) {
                        ForEach([1, 2, 3, 5], id: \.self) { n in
                            PixelChip(label: "\(n)", selected: dl.maxActive == n) { dl.maxActive = n }
                        }
                    }
                }
                PixelPanel(title: "TEXT SIZE", accent: Pixel.green) {
                    HStack(spacing: 8) {
                        ForEach(TextSize.allCases, id: \.self) { s in
                            PixelChip(label: s.label, selected: textScale == s.rawValue, color: Pixel.green) { textScale = s.rawValue }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = dl.folder
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { dl.folder = url }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            dl.dialog = Dialog(title: "NO DICE", message: "Couldn't change the login item:\n\(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct DialogView: View {
    let dialog: Dialog
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(spacing: 18) {
                Text(dialog.title).font(Pixel.font(18)).foregroundStyle(dialog.color)
                Text(dialog.message).font(Pixel.font(9)).foregroundStyle(Pixel.ink)
                    .multilineTextAlignment(.center).lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                Button("CONTINUE", action: dismiss)
                    .buttonStyle(PixelButtonStyle(color: dialog.color))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(28)
            .frame(maxWidth: 460)
            .background(PixelRect(step: 6).fill(Pixel.panel))
            .overlay(PixelRect(step: 6).stroke(dialog.color, lineWidth: 3))
        }
    }
}

// MARK: - Formatting

func bytesString(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file).uppercased()
}

func rateString(_ bytesPerSecond: Double) -> String { bytesString(Int64(bytesPerSecond)) + "/S" }

func etaString(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return "\(h)H \(m)M" }
    if m > 0 { return "\(m)M \(sec)S" }
    return "\(sec)S"
}

func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
