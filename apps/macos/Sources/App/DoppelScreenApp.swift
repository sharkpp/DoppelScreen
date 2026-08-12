import SwiftUI

/// 起動引数で通常のアプリと検証モードを振り分ける（`SelfTest`）。
@main
enum DoppelScreenMain {
    @MainActor
    static func main() {
        if SelfTest.Options.isRequested(CommandLine.arguments) {
            SelfTest.run(arguments: CommandLine.arguments)
        }
        DoppelScreenApp.main()
    }
}

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
