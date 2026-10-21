import SwiftUI

@main struct XBOXABApp: App {
    init() {
        // Preserve completed-download markers after the product/bundle rename.
        if let identifier = Bundle.main.bundleIdentifier {
            let previousIdentifier = identifier.replacingOccurrences(of: ".XBOXAB", with: ".XBEditor")
            if previousIdentifier != identifier,
               let previous = UserDefaults.standard.persistentDomain(forName: previousIdentifier) {
                let key = "officialWallpaperLocalFilesMain10"
                if UserDefaults.standard.object(forKey: key) == nil, let value = previous[key] {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
        }
    }

    var body: some Scene {
        Window("XBOXAB", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 480, height: 632)
        .defaultPosition(.center)
    }
}
