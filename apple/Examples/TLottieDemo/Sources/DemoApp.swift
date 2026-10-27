import SwiftUI
import TLottieKit
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
                    TLottiePlayer(
                        model.animation,
                        loopMode: loops ? .loop : .playOnce,
                        isPlaying: isPlaying,
                        speed: speed
                    )
                    .aspectRatio(1, contentMode: .fit)
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
                            ForEach(model.gridAnimations.indices, id: \.self) { index in
                                TLottiePlayer(model.gridAnimations[index], isPlaying: isPlaying, speed: speed)
                                    .aspectRatio(1, contentMode: .fit)
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
    static let fileExtensions = ["json", "tgs", "lottie"]
    static let contentTypes: [UTType] = fileExtensions.map { UTType(filenameExtension: $0) ?? .data }

    @Published private(set) var items: [DemoItem] = []
    @Published private(set) var selected: DemoItem?
    @Published private(set) var animation: TLottieAnimation?
    @Published private(set) var gridAnimations: [TLottieAnimation] = []
    @Published private(set) var info = ""
    @Published private(set) var error: String?

    private static let gridSize = 12

    /// Bundled samples plus every .tgs / .json / .lottie in the app's Documents folder.
    func reload() {
        var urls = Self.fileExtensions.flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let files = try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) {
            urls += files.filter { Self.fileExtensions.contains($0.pathExtension.lowercased()) }
        }
        items = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(DemoItem.init)
        if selected == nil {
            select(items.first)
        }
    }

    func importFile(_ url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = "Could not read \(url.lastPathComponent)"
            return
        }
        load(data, name: url.lastPathComponent)
        selected = nil
    }

    func select(_ item: DemoItem?) {
        selected = item
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
}
