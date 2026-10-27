import SwiftUI
import TLottieKit
import TLottieKitMedia
import UniformTypeIdentifiers

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var model = DemoModel()
    @State private var isPlaying = true
    @State private var loops = true
    @State private var speed = 1.0
    @State private var showsGrid = ProcessInfo.processInfo.arguments.contains("-grid")
    @State private var isImporting = false

    private let gridColumns = [GridItem(.adaptive(minimum: 72), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    nowPlaying
                    player
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .accessibilityIdentifier("player")
                        .frame(maxWidth: 280)
                        .background(RoundedRectangle(cornerRadius: 24).fill(.quaternary))

                    if let error = model.error {
                        Text(error).foregroundStyle(.red)
                            .accessibilityIdentifier("error")
                    }
                    Text(model.info)
                        .accessibilityIdentifier("info")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    files
                    controls

                    if showsGrid {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            if let media = model.media {
                                // One TLottieMedia can back many views; each decodes on its own.
                                ForEach(0 ..< DemoModel.gridSize, id: \.self) { _ in
                                    TLottieMediaPlayer(media, isPlaying: isPlaying, speed: speed)
                                        .aspectRatio(1, contentMode: .fit)
                                        .accessibilityIdentifier("grid-cell")
                                        .accessibilityValue(media.url.lastPathComponent)
                                }
                            } else {
                                ForEach(model.gridAnimations.indices, id: \.self) { index in
                                    TLottiePlayer(model.gridAnimations[index], isPlaying: isPlaying, speed: speed)
                                        .aspectRatio(1, contentMode: .fit)
                                        .accessibilityIdentifier("grid-cell")
                                        .accessibilityValue(model.nowPlaying?.name ?? "")
                                }
                            }
                        }
                        // Lazy grids reuse cells by id, and both branches count 0..<12, so
                        // without a new id per file the previous file's cells stayed on screen.
                        .id(model.nowPlaying?.name)
                    }
                }
                .padding()
            }
            .navigationTitle("TLottieKit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Open…") { isImporting = true }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: DemoModel.contentTypes) { result in
                if case .success(let url) = result {
                    model.importFile(url)
                }
            }
        }
        .task { model.reload() }
    }

    /// What is loaded, in which format (detected from the file contents) and
    /// which part of the package plays it.
    @ViewBuilder
    private var nowPlaying: some View {
        if let now = model.nowPlaying {
            VStack(spacing: 2) {
                Label("\(now.format.title) · \(now.name)", systemImage: now.format.symbol)
                    .font(.headline)
                Text(now.format.engine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("now-playing")
        }
    }

    @ViewBuilder
    private var player: some View {
        if let media = model.media {
            TLottieMediaPlayer(media, loopMode: loops ? .loop : .playOnce, isPlaying: isPlaying, speed: speed)
        } else {
            TLottiePlayer(model.animation, loopMode: loops ? .loop : .playOnce, isPlaying: isPlaying, speed: speed)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                Button(isPlaying ? "Pause" : "Play") { isPlaying.toggle() }
                    .buttonStyle(.borderedProminent)
                Toggle("Loop", isOn: $loops)
                    .fixedSize()
                Toggle("Grid", isOn: $showsGrid)
                    .fixedSize()
            }
            HStack {
                Text("Speed")
                Slider(value: $speed, in: 0.25 ... 3)
                Text(String(format: "%.2fx", speed))
                    .font(.footnote.monospacedDigit())
            }
        }
    }

    /// Every file, grouped by format, so each kind can be tried in turn.
    private var files: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(DemoFormat.allCases, id: \.self) { format in
                let items = model.items.filter { $0.format == format }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(format.title, systemImage: format.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 8) {
                            ForEach(items) { item in
                                Button(item.name) { model.select(item) }
                                    .buttonStyle(.bordered)
                                    .tint(item == model.selected ? .accentColor : .secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The kinds of file the demo shows, each with the part of the package that plays it.
enum DemoFormat: CaseIterable {
    case json, tgs, dotLottie, gif, video

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "json": self = .json
        case "tgs": self = .tgs
        case "lottie": self = .dotLottie
        case "gif": self = .gif
        case "mp4", "mov": self = .video
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .json: "Lottie JSON"
        case .tgs: "Telegram sticker (.tgs)"
        case .dotLottie: "dotLottie (.lottie)"
        case .gif: "GIF"
        case .video: "MP4 / MOV video"
        }
    }

    var engine: String {
        switch self {
        case .json: "TLottieKit · tlottie (Rust)"
        case .tgs: "TLottieKit · gzip → tlottie"
        case .dotLottie: "TLottieKit · ZIP → tlottie"
        case .gif: "TLottieKitMedia · ImageIO"
        case .video: "TLottieKitMedia · AVFoundation"
        }
    }

    var symbol: String {
        switch self {
        case .json: "curlybraces"
        case .tgs: "paperplane"
        case .dotLottie: "doc.zipper"
        case .gif: "photo.stack"
        case .video: "film"
        }
    }

    var isMedia: Bool { self == .gif || self == .video }
}

struct NowPlaying {
    let name: String
    let format: DemoFormat
}

/// Lays chips out left to right and wraps them, so every file stays visible.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(subviews, width: bounds.width).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}

struct DemoItem: Identifiable, Hashable {
    let id: URL
    var name: String { id.deletingPathExtension().lastPathComponent }
    var format: DemoFormat? { DemoFormat(fileExtension: id.pathExtension) }
}

@MainActor
final class DemoModel: ObservableObject {
    static let lottieExtensions = ["json", "tgs", "lottie"]
    static let mediaExtensions = ["gif", "mp4", "mov"]
    static let fileExtensions = lottieExtensions + mediaExtensions
    static let gridSize = 12
    static let contentTypes: [UTType] = fileExtensions.map { UTType(filenameExtension: $0) ?? .data }

    @Published private(set) var items: [DemoItem] = []
    @Published private(set) var selected: DemoItem?
    @Published private(set) var animation: TLottieAnimation?
    @Published private(set) var gridAnimations: [TLottieAnimation] = []
    @Published private(set) var media: TLottieMedia?
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var info = ""
    @Published private(set) var error: String?

    /// Bundled samples plus every supported file in the app's Documents folder.
    func reload() {
        var urls = Self.fileExtensions.flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let files = try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) {
            urls += files.filter { Self.fileExtensions.contains($0.pathExtension.lowercased()) }
        }
        items = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(DemoItem.init)
        if selected == nil {
            // `-select cat` on the command line opens cat.mp4 first.
            let requested = UserDefaults.standard.string(forKey: "select")
            select(items.first { $0.name == requested } ?? items.first)
        }
    }

    func importFile(_ url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        if Self.isMedia(url) {
            // Video is read while it plays, after this access has ended, so play a copy.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                self.error = "Could not read \(url.lastPathComponent)"
                return
            }
            loadMedia(copy)
            selected = nil
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            error = "Could not read \(url.lastPathComponent)"
            return
        }
        load(data, name: url.lastPathComponent)
        selected = nil
    }

    func select(_ item: DemoItem?) {
        selected = item
        if let item, Self.isMedia(item.id) {
            loadMedia(item.id)
            return
        }
        guard let item, let data = try? Data(contentsOf: item.id) else { return }
        load(data, name: item.id.lastPathComponent)
    }

    private func load(_ data: Data, name: String) {
        do {
            let parseStart = CFAbsoluteTimeGetCurrent()
            let animation = try TLottieAnimation(data: data)
            let parseTime = (CFAbsoluteTimeGetCurrent() - parseStart) * 1000

            let renderStart = CFAbsoluteTimeGetCurrent()
            _ = try animation.makeImage(frame: 0, width: 512, height: 512)
            let renderTime = (CFAbsoluteTimeGetCurrent() - renderStart) * 1000

            // Separate instances, so the grid renders on several threads at once.
            gridAnimations = (0 ..< Self.gridSize).compactMap { _ in try? TLottieAnimation(data: data) }
            self.animation = animation
            media = nil
            nowPlaying = NowPlaying(name: name, format: Self.lottieFormat(of: data))
            error = nil
            info = String(
                format: "%@\n%.0f×%.0f · %d frames · %.0f fps · %.2f s\nparse %.2f ms · first frame %.2f ms at 512 px",
                name, animation.size.width, animation.size.height, animation.frameCount,
                animation.frameRate, animation.duration, parseTime, renderTime
            )
        } catch {
            nowPlaying = nil
            self.error = "\(name): \(error)"
        }
    }

    private static func isMedia(_ url: URL) -> Bool {
        DemoFormat(fileExtension: url.pathExtension)?.isMedia == true
    }

    /// TLottieAnimation tells the formats apart by their first bytes, not the file name.
    private static func lottieFormat(of data: Data) -> DemoFormat {
        if data.starts(with: [0x1F, 0x8B]) { return .tgs }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .dotLottie }
        return .json
    }

    private func loadMedia(_ url: URL) {
        let name = url.lastPathComponent
        do {
            let openStart = CFAbsoluteTimeGetCurrent()
            let media = try TLottieMedia(contentsOf: url)
            let openTime = (CFAbsoluteTimeGetCurrent() - openStart) * 1000
            animation = nil
            gridAnimations = []
            self.media = media
            nowPlaying = NowPlaying(name: name, format: media.kind == .gif ? .gif : .video)
            error = nil
            info = String(
                format: "%@\n%.0f×%.0f · %@ · %.2f s\nopened in %.2f ms",
                name, media.size.width, media.size.height, media.kind == .gif ? "GIF" : "video",
                media.duration, openTime
            )
        } catch {
            nowPlaying = nil
            self.error = "\(name): \(error)"
        }
    }
}
