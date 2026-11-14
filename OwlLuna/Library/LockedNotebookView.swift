import SwiftUI

/// What stands in for a locked notebook until it is unlocked, and whenever the app isn't in front.
struct LockedNotebookView: View {
    let title: String
    let closeTitle: LocalizedStringKey
    let unlock: () -> Void
    let close: () -> Void

    var body: some View {
        EmptyShelf(title: String(localized: "“\(title)” is locked"),
                   message: (Device.isMac
                       ? String(localized: "Unlock it with Touch ID or this Mac's password.")
                       : String(localized: "Unlock it with Face ID, Touch ID or this iPad's passcode."))) {
            Button("Unlock", action: unlock)
                .buttonStyle(.owlLuna(.primary))
                .accessibilityIdentifier("lock.unlock")
            Button(closeTitle, action: close)
                .buttonStyle(.owlLuna)
                .accessibilityIdentifier("lock.close")
        } illustration: {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 84, height: 84)
                .background(Color.surface, in: Circle())
                .overlay { Circle().strokeBorder(Color.hairline) }
                .accessibilityHidden(true)
        }
        .background(Color.desk.ignoresSafeArea())
        .accessibilityIdentifier("lock.screen")
    }
}

/// The padlock on a locked notebook's cover.
struct LockBadge: View {
    var diameter: CGFloat = 44

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(Color.labelInk)
            .frame(width: diameter, height: diameter)
            .background(Color.labelCream, in: Circle())
            .overlay { Circle().strokeBorder(Color.labelInk.opacity(0.25), lineWidth: 1) }
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}
