import SwiftUI

enum MainWindow {
    static let id = "main"
}

@main
struct DoppelScreenApp: App {
    @State private var session = SessionController()

    var body: some Scene {
        Window("DoppelScreen", id: MainWindow.id) {
            MainView(session: session)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 960, height: 640)

        MenuBarExtra("DoppelScreen", systemImage: "rectangle.on.rectangle") {
            MenuBarView(session: session)
        }
        .menuBarExtraStyle(.window)
    }
}
