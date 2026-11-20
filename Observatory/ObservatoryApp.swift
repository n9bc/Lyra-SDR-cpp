import SwiftUI

@main
struct ObservatoryApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Observatory")
                .foregroundStyle(LyraTheme.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LyraTheme.background)
        }
    }
}
