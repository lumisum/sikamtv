import SwiftUI

@main
struct MTVMusicVideoApp: App {
    @StateObject private var workspace = WorkspaceState()

    var body: some Scene {
        WindowGroup("SikaMTV") {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入背景…") { workspace.importBackground() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("导入音乐…") { workspace.importAudio() }
                Button("导入 LRC 歌词…") { workspace.importLyrics() }
            }
        }
    }
}
