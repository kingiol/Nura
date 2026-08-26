import SwiftUI

@main
struct NuraMacApp: App {
    var body: some Scene {
        WindowGroup("Nura") {
            PlayerView()
        }
        .defaultSize(width: 1080, height: 680)
    }
}
