import SwiftUI

/// Top-level layout: panel sidebar + radio detail. Pure composition, no logic.
struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            DetailView()
        }
        .background(LyraTheme.background)
        .preferredColorScheme(.dark)
    }
}
