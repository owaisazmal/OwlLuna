import PencilKit

enum DrawingInput: String, CaseIterable, Identifiable {
    case system, pencilOnly, anyInput
    var id: String { rawValue }

    /// What draws until the setting is changed.
    @MainActor static var initial: DrawingInput {
        initial(isMac: ProcessInfo.processInfo.isiOSAppOnMac, isPhone: Device.isPhone,
                pencilSeen: UserDefaults.standard.bool(forKey: SettingsKey.pencilSeen))
    }

    /// Whether the Pencil's choices apply: always on an iPad, and on an iPhone once a Pencil has touched it.
    @MainActor static var hasPencil: Bool { !Device.isPhone || UserDefaults.standard.bool(forKey: SettingsKey.pencilSeen) }

    /// A Mac has no Pencil to draw with, so there the pointer and fingers draw from the start. So do they on an iPhone,
    /// until a Pencil has touched its pages; from then on it is as on an iPad.
    static func initial(isMac: Bool, isPhone: Bool = false, pencilSeen: Bool = false) -> DrawingInput {
        isMac || (isPhone && !pencilSeen) ? .anyInput : .pencilOnly
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "System Setting")
        case .pencilOnly: String(localized: "Apple Pencil Only")
        case .anyInput: String(localized: "Pencil and Finger")
        }
    }

    var policy: PKCanvasViewDrawingPolicy {
        switch self {
        case .system: .default
        case .pencilOnly: .pencilOnly
        case .anyInput: .anyInput
        }
    }
}

/// The notice for a finger that dragged on a page and drew nothing because only the Pencil draws: once per install.
enum FingerDrawHint {
    /// UI tests drag fingers on Pencil-only pages all the time, so there it is off unless one asks for it fresh with `-freshFingerDrawHint`.
    static let isAllowed: Bool = {
        #if DEBUG
        guard LaunchOptions.usesTestStorage else { return true }
        guard LaunchOptions.arguments.contains("-freshFingerDrawHint") else { return false }
        UserDefaults.standard.removeObject(forKey: SettingsKey.fingerDrawHintSeen)
        #endif
        return true
    }()

    /// Whether it is due now. After a yes it isn't again.
    static func take(input: DrawingInput, penInHand: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard input == .pencilOnly, penInHand, !defaults.bool(forKey: SettingsKey.fingerDrawHintSeen) else { return false }
        defaults.set(true, forKey: SettingsKey.fingerDrawHintSeen)
        return true
    }

    /// Whoever has a Pencil on the pages knows it draws, so the notice isn't needed. The first touch is told, for an
    /// iPhone that has drawn with fingers until now.
    static func pencilTouched(defaults: UserDefaults = .standard) {
        if !defaults.bool(forKey: SettingsKey.fingerDrawHintSeen) { defaults.set(true, forKey: SettingsKey.fingerDrawHintSeen) }
        if !defaults.bool(forKey: SettingsKey.pencilSeen) {
            defaults.set(true, forKey: SettingsKey.pencilSeen)
            NotificationCenter.default.post(name: .owlLunaPencilSeen, object: nil)
        }
    }
}

enum SettingsKey {
    static let drawingInput = "drawingInput"
    static let defaultTemplate = "defaultTemplate"
    static let defaultPaperColor = "defaultPaperColor"
    static let defaultPageSize = "defaultPageSize"
    /// The user's own paper for Quick Note, by its ID; the template stands in when it is gone.
    static let defaultPaper = "defaultPaper"
    static let darkPaper = "darkPaper"
    static let librarySort = "librarySort"
    static let librarySortReversed = "librarySortReversed"
    static let libraryLayout = "libraryLayout"
    static let dailyJournalID = "dailyJournalID"
    static let whiteboardTipSeen = "whiteboardTipSeen"
    static let fingerDrawHintSeen = "fingerDrawHintSeen"
    /// A Pencil has touched the pages on this device.
    static let pencilSeen = "pencilSeen"
    static let dailyJournalPromptHidden = "dailyJournalPromptHidden"
    static let showsOnThisDay = "showsOnThisDay"
    static let onThisDayHiddenDay = "onThisDayHiddenDay"
    static let keepsWritingHistory = "keepsWritingHistory"
    static let snapsShapes = "snapsShapes"
    static let scribbleErases = "scribbleErases"
    static let circleSelects = "circleSelects"
    static let pencilDoubleTap = "pencilDoubleTap"
    static let pencilSqueeze = "pencilSqueeze"
    static let syncsWithICloud = "syncsWithICloud"
    static let lastSynced = "lastSynced"
    static let syncConflictCopies = "syncConflictCopies"
    static let syncSetAsideJournals = "syncSetAsideJournals"
    static let tapeColor = "tapeColor"
    static let transcriptLanguage = "transcriptLanguage"
    static let indexSchema = "libraryIndexSchema"
    static let journalAgenda = "journalAgenda"
    static let spotlight = "showsInSpotlight"
    static let toolPresets = "toolPresets"
    static let toolPresetsChangedAt = "toolPresetsChangedAt"
    static let snapsHighlighter = "snapsHighlighter"
    static let highlightColor = "highlightColor"
    static let toolbox = "toolbox"
    static let appearance = "appearance"
    static let leftHanded = "leftHanded"
    static let trashLength = "trashLength"
    static let playbackSpeed = "playbackSpeed"
}

extension UserDefaults {
    /// A setting's switch, `value` until it is first changed.
    func bool(forKey key: String, default value: Bool) -> Bool { object(forKey: key) as? Bool ?? value }

    /// The paper Settings chose for new notebooks.
    var defaultTemplate: PaperTemplate { string(forKey: SettingsKey.defaultTemplate).flatMap(PaperTemplate.init(rawValue:)) ?? .narrowRuled }
    var defaultPaperColor: PaperColor { string(forKey: SettingsKey.defaultPaperColor).flatMap(PaperColor.init(rawValue:)) ?? .white }
    var defaultPageSize: PageSize { string(forKey: SettingsKey.defaultPageSize).flatMap(PageSize.init(rawValue:)) ?? .letter }
}

extension Notification.Name {
    static let owlLunaPencilSeen = Notification.Name("OwlLunaPencilSeen")
}
