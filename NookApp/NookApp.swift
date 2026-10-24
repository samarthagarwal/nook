import SwiftUI
import NookUI
import NookRuntime
import NookCore
import NookDesign
import FirebaseCore

@main
struct NookApp: App {
    
    init() {
        FirebaseApp.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
