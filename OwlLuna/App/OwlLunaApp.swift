import SwiftUI
import SwiftData
import CoreSpotlight

/// Only here to give a second screen its own scene; every other scene is SwiftUI's.
final class OwlLunaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive { configuration.delegateClass = ExternalDisplaySceneDelegate.self }
        return configuration
    }
}

@main
struct OwlLunaApp: App {
    @UIApplicationDelegateAdaptor(OwlLunaAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            OwlLunaRoot()
        }
    }
}

struct OwlLunaRoot: View {
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("owlluna.openNotebook") private var restoredNotebook = ""
    @State private var curtain = LaunchCurtain()
    /// The launch overlay has begun handing over, so the library is there under it.
    @State private var libraryShown = false

    private var libraryOpacity: Double {
        if curtain.isUp { return libraryShown ? 1 : 0 }
        return app.phase == .ready ? 1 : 0
    }

    /// Under the splash the library waits a little large, and settles as the tiles leave it.
    private var libraryScale: CGFloat {
        curtain.isUp && !libraryShown && !reduceMotion ? LaunchOverlay.libraryStart : 1
    }

    /// A launch that is about to show something, a notebook left open or what a shortcut asked for, goes straight to it.
    private var opensSomething: Bool {
        if curtain.isHurried || app.pendingAction != nil { return true }
        let windows = UIApplication.shared.connectedScenes.filter { $0.session.role == .windowApplication }.map(\.session.persistentIdentifier)
        return windows.contains { WindowMemory.reopens(in: $0, fallback: windows.count == 1 ? restoredNotebook : "") }
    }

    var body: some View {
        ZStack {
            LibraryRootView()
                .opacity(libraryOpacity)
                .animation(libraryShown ? LaunchOverlay.settle : nil) { $0.scaleEffect(libraryScale) }
                .accessibilityHidden(curtain.isUp && !libraryShown)
                .allowsHitTesting(!curtain.isUp || libraryShown)
            if curtain.isUp {
                LaunchOverlay(isReady: app.phase == .ready, isHurried: curtain.isHurried || app.pendingAction != nil,
                              onHandOver: { withAnimation(reduceMotion ? .easeOut(duration: LaunchOverlay.stillFade) : nil) { libraryShown = true } },
                              onFinished: { curtain.isUp = false })
            }
        }
        .background(Color.paper.ignoresSafeArea())
        .progressViewStyle(.thread)
        .environment(app)
        .environment(curtain)
        .environment(app.library)
        .environment(app.activity)
        .environment(app.flashcards)
        .modelContainer(app.container)
        .task {
            let enabled = LaunchAnimation.isEnabled
            app.takeControlAction()
            curtain.isUp = enabled && app.phase != .ready && !opensSomething
            #if DEBUG
            if LaunchOptions.arguments.contains("-framePacing") { FramePacingWindow.install() }
            WindowButtons.shared.install()
            #endif
            await app.start()
            app.takeControlAction()
            await WidgetBridge.update(app)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let action = AppAction(spotlight: activity) { app.pendingAction = action }
        }
        .onReceive(NotificationCenter.default.publisher(for: .owlLunaControlAction).receive(on: DispatchQueue.main)) { _ in app.takeControlAction() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                app.sync.schedule(after: .seconds(1))
                app.takeControlAction()
            }
            if phase != .active {
                app.flushOpenDocuments()
                app.activity.flush()
                app.sync.schedule(after: .seconds(1))
                Task { await WidgetBridge.update(app) }
            }
        }
    }
}
