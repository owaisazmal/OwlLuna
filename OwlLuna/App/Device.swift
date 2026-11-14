import UIKit

/// What the device the app runs on can do. An iPhone has no Apple Pencil and one window.
enum Device {
    @MainActor static let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    /// The iPad app running on a Mac.
    static let isMac = ProcessInfo.processInfo.isiOSAppOnMac
}
