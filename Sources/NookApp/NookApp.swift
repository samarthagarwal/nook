import SwiftUI
import NookDesign
import NookCore
import NookRuntime
import NookUI

@main
struct NookApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
                #if os(macOS)
                .frame(minWidth: 402, idealWidth: 402, maxWidth: 450, minHeight: 874, idealHeight: 874, maxHeight: 920)
                #endif
        }
    }
}
