import SwiftUI
import AppKit
struct ContentView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    // Keep older MP4s on disk, but require a fresh export for the Main10 preset.
    @AppStorage("officialWallpaperLocalFilesMain10") private var localFilesData = Data()
    @State private var localFiles: [String: URL] = [:]
    @State private var isConverting = false
    @State private var isDownloading = false
    @State private var conversionProgress: Double?
    @State private var conversionTask: Task<Void, Never>?
    @State private var officialWallpapers: [OfficialWallpaper] = []

    @State private var selectedCategory = "all"
    @State private var showCategoryMenu = false

    private var filteredWallpapers: [OfficialWallpaper] {
        officialWallpapers.filter {
            if selectedCategory == "downloaded" { return localFile(for: $0) != nil }
            if selectedCategory == "limited" { return $0.isLimited }
            return selectedCategory == "all" || $0.normalizedCategory == selectedCategory
        }
    }
    private var categoryTitle: String {
        switch selectedCategory {
        case "featured": return "精选"
        case "games": return "游戏"
        case "xbox": return "XBOX"
        case "limited": return "限定"
        case "downloaded": return "已下载"
        default: return "全部"
        }
    }
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
                .gesture(WindowDragGesture())

            if isConverting {
                conversionIndicator
            } else {
                officialSelector
            }

            VStack {
                HStack {
                    closeButton
                    Spacer()
                    categoryButton
                }
                .overlay {
                    Text(categoryTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .ignoresSafeArea()
        .frame(minWidth: 440, minHeight: 320)

        .background(BadgeWindowHost().frame(width: 0, height: 0))
        .onAppear {
            localFiles = ((try? JSONDecoder().decode([String: URL].self, from: localFilesData)) ?? [:])
                .filter { FileManager.default.fileExists(atPath: $0.value.path) }
            do { officialWallpapers = try OfficialWallpaperCatalog.load() }
            catch { errorMessage = error.localizedDescription }
        }
        .onDisappear { conversionTask?.cancel() }
        .alert("无法打开壁纸", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var conversionIndicator: some View {
        VStack(spacing: 12) {
            ProgressView(value: conversionProgress)
                .progressViewStyle(.linear)
                .tint(.primary)
                .frame(width: 180)
            VStack(spacing: 4) {
                Text(isDownloading ? "正在下载" : "正在转换")
                    .font(.system(size: 11))
                if let conversionProgress {
                    Text(conversionProgress, format: .percent.precision(.fractionLength(0)))
                } else {
                    Text("—%")
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityLabel(isDownloading ? "下载进度" : "转换进度")
    }

    private var officialSelector: some View {
        GeometryReader { geometry in
        ScrollView {
            let columns = max(1, Int((geometry.size.width - 40 + 12) / (194 + 12)))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(194), spacing: 12, alignment: .top),
                                     count: columns),
                      alignment: .leading, spacing: 16) {
                ForEach(filteredWallpapers) { wallpaper in
                    Button {
                        if let file = localFile(for: wallpaper) {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        } else {
                            startConversion(official: wallpaper)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Color.clear
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .overlay {
                                    CachedWallpaperThumbnail(url: wallpaper.thumbnailUrl)
                                }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .bottomTrailing) {
                                if localFile(for: wallpaper) != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.8))
                                        .padding(8)
                                        .allowsHitTesting(false)
                                }
                            }
                            Text(wallpaper.displayTitle)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(width: 194, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isConverting)
                    .help(wallpaper.displayTitle)
                    .accessibilityLabel(localFile(for: wallpaper) == nil
                                        ? "下载并转换：\(wallpaper.displayTitle)"
                                        : "在 Finder 中显示：\(wallpaper.displayTitle)")
                }
            }
            .frame(width: CGFloat(columns) * 194 + CGFloat(columns - 1) * 12)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.top, 76)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("官方壁纸")
        }
    }

    private var categoryButton: some View {
        circularButton(symbol: "line.3.horizontal.decrease") {
            showCategoryMenu = true
        }
        .background(CategoryMenuPresenter(isPresented: $showCategoryMenu, selection: $selectedCategory))
        .help("分类")
        .accessibilityLabel("壁纸分类")
    }

    private var closeButton: some View {
        circularButton(symbol: "xmark") {
            dismissWindow(id: "main")
        }
        .keyboardShortcut(.cancelAction)
        .help("关闭")
        .accessibilityLabel("关闭")
    }

    private func circularButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private func startConversion(official: OfficialWallpaper) {
        guard !isConverting else { return }
        isConverting = true
        conversionProgress = nil
        isDownloading = true
        conversionTask = Task { @MainActor in
            defer {
                isConverting = false
                isDownloading = false
                conversionProgress = nil
                conversionTask = nil
            }
            do {
                // Present the preparation indicator before decoding resources.
                try await Task.sleep(for: .milliseconds(30))
                var temporaryDirectory: URL?
                defer {
                    if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
                }
                let project = try await OfficialWallpaperCatalog.download(official) { fraction in
                    guard isDownloading else { return }
                    if let fraction {
                        conversionProgress = max(conversionProgress ?? 0, fraction)
                    }
                }
                temporaryDirectory = project.temporaryDirectory
                let folder = project.folder
                isDownloading = false
                conversionProgress = 0
                try Task.checkCancellation()
                let accessing = folder.startAccessingSecurityScopedResource()
                defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
                let output = try await WallpaperVideoConverter.convert(folder: folder) {
                    conversionProgress = $0
                }
                localFiles[official.id.absoluteString] = output
                localFilesData = try JSONEncoder().encode(localFiles)
                openResult(output)
            } catch is CancellationError {
                // Closing the window cancels conversion and removes partial output.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func localFile(for wallpaper: OfficialWallpaper) -> URL? {
        guard let url = localFiles[wallpaper.id.absoluteString],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func openResult(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "转换结果已被移动或删除：\(url.lastPathComponent)"
            return
        }
        if !NSWorkspace.shared.open(url) {
            errorMessage = "系统无法打开该视频，请在 Finder 中设置 MP4 的默认打开应用。"
        }
    }
}

/// The visible control remains the same SwiftUI Button as Close. AppKit only
/// presents a native, single-level menu anchored beneath that control.
private struct CategoryMenuPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.selection = $selection
        guard isPresented, !context.coordinator.scheduled else { return }
        let coordinator = context.coordinator
        coordinator.scheduled = true
        DispatchQueue.main.async {
            isPresented = false
            defer { coordinator.scheduled = false }
            guard view.window != nil else { return }
            let menu = NSMenu()
            for (title, value) in [("全部", "all"), ("精选", "featured"), ("游戏", "games"), ("XBOX", "xbox"), ("限定", "limited"), ("已下载", "downloaded")] {
                let item = NSMenuItem(title: title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.target = coordinator
                item.representedObject = value
                item.state = coordinator.selection.wrappedValue == value ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: view.bounds.minY), in: view)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        var scheduled = false

        init(selection: Binding<String>) { self.selection = selection }

        @objc func choose(_ sender: NSMenuItem) {
            if let value = sender.representedObject as? String { selection.wrappedValue = value }
        }
    }
}

/// Keep a normal, key-capable system window beneath the sheet's custom controls.
/// Only the native titlebar buttons are hidden; the titled style is retained.
private struct BadgeWindowHost: NSViewRepresentable {
    func makeNSView(context: Context) -> HostView { HostView() }
    func updateNSView(_ nsView: HostView, context: Context) {}

    final class HostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.toolbar = nil
            window.setAutorecalculatesContentBorderThickness(false, for: .minY)
            window.setContentBorderThickness(0, for: .minY)
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for button in buttons {
                window.standardWindowButton(button)?.isHidden = true
            }
        }
    }
}
