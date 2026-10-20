import SwiftUI

/// Identify Players in its own window, so it can be moved and sized freely next to Find Rallies.
struct IdentifyPlayersWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let finder = model.rallies
        Group {
            if let url = finder.sourceURL, finder.canTeach {
                TeachPlayerScreen(finder: finder, url: url, time: finder.currentTime) {
                    dismissWindow(id: "identify")
                }
                .id(url)
            } else {
                ContentUnavailableView("No Match Open", systemImage: "film",
                                       description: Text("Open a match in Find Rallies first."))
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .onAppear { finder.pause() }
    }
}

/// Check Accuracy in its own window.
struct CheckAccuracyWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let finder = model.rallies
        if finder.sourceURL != nil, finder.canTeach {
            CheckAccuracyScreen(finder: finder) { dismissWindow(id: "accuracy") }
                .id(finder.sourceURL)
        } else {
            ContentUnavailableView("No Match Open", systemImage: "film",
                                   description: Text("Open a match in Find Rallies first."))
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
