import UIKit

/// What the device the app runs on can do. An iPhone has no Apple Pencil and one window.
enum Device {
    @MainActor static let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    /// On a Mac, built for it with Mac Catalyst or as the iPad app.
    static let isMac = ProcessInfo.processInfo.isMacCatalystApp
}
