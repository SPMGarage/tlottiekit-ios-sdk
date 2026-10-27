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
                    player
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                    .frame(maxWidth: 320)
                    .background(RoundedRectangle(cornerRadius: 24).fill(.quaternary))

                    if let error = model.error {
                        Text(error).foregroundStyle(.red)
                    }
                    Text(model.info)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    controls
                    files

                    if showsGrid {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            if let media = model.media {
                                // One TLottieMedia can back many views; each decodes on its own.
                                ForEach(0 ..< DemoModel.gridSize, id: \.self) { _ in
                                    TLottieMediaPlayer(media, isPlaying: isPlaying, speed: speed)
                                        .aspectRatio(1, contentMode: .fit)
                                }
                            } else {
                                ForEach(model.gridAnimations.indices, id: \.self) { index in
                                    TLottiePlayer(model.gridAnimations[index], isPlaying: isPlaying, speed: speed)
                                        .aspectRatio(1, contentMode: .fit)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("TLottieKit")
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

    private var files: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(model.items) { item in
                    Button(item.name) { model.select(item) }
                        .buttonStyle(.bordered)
                        .tint(item == model.selected ? .accentColor : .secondary)
                }
            }
        }
    }
}

struct DemoItem: Identifiable, Hashable {
    let id: URL
    var name: String { id.deletingPathExtension().lastPathComponent }
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
            error = nil
            info = String(
                format: "%@\n%.0f×%.0f · %d frames · %.0f fps · %.2f s\nparse %.2f ms · first frame %.2f ms at 512 px",
                name, animation.size.width, animation.size.height, animation.frameCount,
                animation.frameRate, animation.duration, parseTime, renderTime
            )
        } catch {
            self.error = "\(name): \(error)"
        }
    }

    private static func isMedia(_ url: URL) -> Bool {
        mediaExtensions.contains(url.pathExtension.lowercased())
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
            error = nil
            info = String(
                format: "%@\n%.0f×%.0f · %@ · %.2f s\nopened in %.2f ms",
                name, media.size.width, media.size.height, media.kind == .gif ? "GIF" : "video",
                media.duration, openTime
            )
        } catch {
            self.error = "\(name): \(error)"
        }
    }
}
