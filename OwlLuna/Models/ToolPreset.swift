import UIKit
import PencilKit
import Observation

/// A pen, pencil or marker in the tool tray: its kind, its colour and its width.
struct ToolPreset: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// PencilKit's own name for the kind of ink, so a kind this build doesn't know is kept and left out.
    var ink: String
    /// Red, green, blue and alpha, a byte each, as the ink is on light paper.
    var color: UInt32
    var width: Double

    init(id: UUID = UUID(), ink: PKInkingTool.InkType, color: UInt32, width: Double) {
        self.id = id
        self.ink = ink.rawValue
        self.color = color
        self.width = width
    }

    /// A tool as it is on a canvas; nil for the eraser and the lasso.
    init?(_ tool: PKTool) {
        guard let inking = tool as? PKInkingTool else { return nil }
        self.init(ink: inking.inkType, color: Self.bytes(of: inking.color), width: inking.width)
    }

    /// A colour as it is on light paper, a byte each for red, green, blue and alpha.
    static func bytes(of color: UIColor) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | byte(alpha)
    }

    var inkType: PKInkingTool.InkType? { PKInkingTool.InkType(rawValue: ink) }

    /// The faintest a pen can be set, so it never writes nothing.
    static let leastOpacity = 0.1

    /// The colour as the palette lists it, at full strength.
    var tint: UInt32 { color | 0xFF }

    /// How much of the paper the ink covers: the colour's last byte, from `leastOpacity` to 1.
    var opacity: Double {
        get { Double(color & 0xFF) / 255 }
        set { color = color & 0xFFFF_FF00 | UInt32((min(max(newValue, Self.leastOpacity), 1) * 255).rounded()) }
    }

    /// Another colour, as faint as the pen was.
    mutating func setTint(_ tint: UInt32) {
        color = tint & 0xFFFF_FF00 | color & 0xFF
    }

    /// "60%".
    var opacityName: String { opacity.formatted(.percent.precision(.fractionLength(0))) }

    var uiColor: UIColor { Self.uiColor(color) }

    static func uiColor(_ color: UInt32) -> UIColor {
        UIColor(red: CGFloat(color >> 24 & 0xFF) / 255, green: CGFloat(color >> 16 & 0xFF) / 255,
                blue: CGFloat(color >> 8 & 0xFF) / 255, alpha: CGFloat(color & 0xFF) / 255)
    }

    var tool: PKInkingTool? {
        guard let inkType else { return nil }
        let range = inkType.validWidthRange
        return PKInkingTool(inkType, color: uiColor, width: min(max(width, range.lowerBound), range.upperBound))
    }

    /// Where the width lies in what this kind of ink allows, from 0 to 1.
    var widthFraction: Double {
        guard let range = inkType?.validWidthRange, range.upperBound > range.lowerBound else { return 0.5 }
        return min(max((width - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    /// The same tool, whichever one of them was saved.
    func isSameTool(as other: ToolPreset) -> Bool {
        ink == other.ink && color == other.color && abs(width - other.width) < 0.15
    }

    var kindName: String { inkType.map(Self.name(of:)) ?? String(localized: "Pen") }

    var symbol: String { inkType.map(Self.symbol(of:)) ?? "pencil.tip" }

    static func name(of ink: PKInkingTool.InkType) -> String {
        switch ink {
        case .pen: String(localized: "Pen")
        case .pencil: String(localized: "Pencil")
        case .marker: String(localized: "Highlighter")
        case .monoline: String(localized: "Fineliner")
        case .fountainPen: String(localized: "Fountain Pen")
        case .watercolor: String(localized: "Watercolour")
        case .crayon: String(localized: "Crayon")
        default: String(localized: "Calligraphy Pen")
        }
    }

    static func symbol(of ink: PKInkingTool.InkType) -> String {
        switch ink {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .marker: "highlighter"
        case .monoline: "pencil.line"
        case .watercolor: "paintbrush"
        case .crayon: "scribble"
        default: "paintbrush.pointed"
        }
    }

    /// The kinds of ink a pen can be given, in the order they are offered.
    static var kinds: [PKInkingTool.InkType] {
        var kinds: [PKInkingTool.InkType] = [.pen, .monoline, .fountainPen, .pencil, .marker, .crayon, .watercolor]
        if #available(iOS 26, *) { kinds.insert(.reed, at: 3) }
        return kinds
    }

    /// The app's inks, and four tints for the highlighter.
    static let inks: [UInt32] = [0x1B22_30FF, 0x6E73_7CFF, 0x7A52_30FF, 0xC945_2FFF, 0xE07A_1FFF, 0xE8B0_23FF,
                                 0x2F8F_4EFF, 0x1F8A_8AFF, 0x2747_B8FF, 0x3D8F_D9FF, 0x7A3E_9DFF, 0xD957_8CFF]
    static let tints: [UInt32] = [0xFFD4_26FF, 0x7ED9_8BFF, 0xFF8F_B8FF, 0x7CC4_FFFF]

    /// The colours offered for a kind of ink: the highlighter's own tints come first for it, and last for the rest.
    static func palette(for ink: PKInkingTool.InkType?) -> [UInt32] {
        ink == .marker ? tints + inks : inks + tints
    }

    /// Where a width at `fraction` of the way lies for a kind of ink. The thin end has most of the travel, where
    /// writing is done.
    static func width(at fraction: Double, of ink: PKInkingTool.InkType) -> Double {
        let range = ink.validWidthRange, clamped = min(max(fraction, 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * clamped * clamped
    }

    /// The reverse of `width(at:of:)`.
    var widthTravel: Double { widthFraction.squareRoot() }

    /// The colour in a word, for VoiceOver and the Large Content Viewer.
    var colorName: String { Self.colorName(color) }

    /// The palette's colours that share a hue with another have names of their own; the rest are named by hue.
    static func colorName(_ color: UInt32) -> String {
        switch color | 0xFF {
        case 0xE8B0_23FF: return String(localized: "Mustard")
        case 0x3D8F_D9FF: return String(localized: "Sky Blue")
        case 0x7A3E_9DFF: return String(localized: "Plum")
        case 0x7ED9_8BFF: return String(localized: "Light Green")
        case 0xFF8F_B8FF: return String(localized: "Light Pink")
        case 0x7CC4_FFFF: return String(localized: "Light Blue")
        default: break
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        uiColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if brightness < 0.2 { return String(localized: "Black") }
        if saturation < 0.12 { return brightness > 0.9 ? String(localized: "White") : String(localized: "Grey") }
        switch hue * 360 {
        case ..<15, 345...: return String(localized: "Red")
        case ..<40: return brightness < 0.6 ? String(localized: "Brown") : String(localized: "Orange")
        case ..<65: return String(localized: "Yellow")
        case ..<165: return String(localized: "Green")
        case ..<195: return String(localized: "Teal")
        case ..<255: return String(localized: "Blue")
        case ..<290: return String(localized: "Purple")
        default: return String(localized: "Pink")
        }
    }

    /// "Pen, Blue".
    var name: String { String(localized: "\(kindName), \(colorName)") }
}

/// The pens in the tray as sync carries them between devices: the list, and when it was last changed.
struct SyncedPens: Sendable, Equatable {
    var presets: [ToolPreset]
    /// Nil for pens not changed since changes were stamped, which another device's changed pens win over.
    var changedAt: Date?

    /// Still the four pens a new tray starts with.
    var isAsItStarted: Bool {
        presets.count == ToolShelf.starters.count && zip(presets, ToolShelf.starters).allSatisfy { $0.isSameTool(as: $1) }
    }

    /// `first`, then the pens of `second` it lacks, as many as the tray has room for.
    static func merged(_ first: [ToolPreset], _ second: [ToolPreset]) -> [ToolPreset] {
        var result = first
        for pen in second where !result.contains(where: { $0.isSameTool(as: pen) }) {
            guard pen.inkType == nil || result.filter({ $0.inkType != nil }).count < ToolShelf.limit else { continue }
            result.append(pen)
        }
        return result
    }
}

/// The pens in the tool tray, the same in every notebook and window. Kept in the app's settings, and synced.
@MainActor
@Observable
final class ToolShelf {
    nonisolated static let limit = 8

    /// A new shelf starts with the app's own inks.
    nonisolated static let starters = [ToolPreset(ink: .pen, color: 0x1B22_30FF, width: 2.7), ToolPreset(ink: .pen, color: 0x2747_B8FF, width: 2.7),
                           ToolPreset(ink: .pen, color: 0xC945_2FFF, width: 2.7), ToolPreset(ink: .marker, color: 0xE8B0_23FF, width: 20)]

    private(set) var presets: [ToolPreset]
    /// When the pens were last changed here, or on the device they came from.
    @ObservationIgnored private(set) var changedAt: Date?
    @ObservationIgnored private let defaults: UserDefaults?
    /// Called after a change made here, so a sync can follow it.
    @ObservationIgnored var onChanged: (() -> Void)?

    /// Without `defaults` the shelf lasts as long as the app does.
    init(defaults: UserDefaults? = .standard) {
        var store = defaults
        #if DEBUG
        if LaunchOptions.arguments.contains("-freshToolPresets") { store = nil }
        #endif
        self.defaults = store
        presets = store?.data(forKey: SettingsKey.toolPresets).flatMap { try? JSONDecoder().decode([ToolPreset].self, from: $0) } ?? Self.starters
        changedAt = store?.object(forKey: SettingsKey.toolPresetsChangedAt) as? Date
    }

    var synced: SyncedPens { SyncedPens(presets: presets, changedAt: changedAt) }

    /// Takes the pens another device changed. False when they were changed here since `since`, the stamp the sync
    /// read, or there is nothing usable among them: what is here then stays, and goes to the other device next time.
    @discardableResult
    func take(_ pens: SyncedPens, since: Date?) -> Bool {
        guard changedAt == since, pens.presets.contains(where: { $0.inkType != nil }) else { return false }
        presets = pens.presets
        changedAt = pens.changedAt
        write()
        return true
    }

    /// The tools this build can use; one of a kind it doesn't know stays saved and isn't shown.
    var usable: [ToolPreset] { presets.filter { $0.inkType != nil } }

    var isFull: Bool { usable.count >= Self.limit }

    func holds(_ tool: ToolPreset) -> Bool { presets.contains { $0.isSameTool(as: tool) } }

    @discardableResult
    func add(_ tool: ToolPreset) -> Bool {
        guard !isFull, !holds(tool), tool.inkType != nil else { return false }
        presets.append(tool)
        save()
        return true
    }

    /// Gives a pen another kind, colour or width, where it stands.
    func change(_ id: UUID, _ change: (inout ToolPreset) -> Void) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        var changed = presets[index]
        change(&changed)
        changed.id = id
        guard changed != presets[index], changed.inkType != nil else { return }
        presets[index] = changed
        save()
    }

    func remove(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    /// One place along among the tools that are shown.
    func move(_ id: UUID, by step: Int) {
        let shown = usable
        guard let from = shown.firstIndex(where: { $0.id == id }), shown.indices.contains(from + step),
              let source = presets.firstIndex(where: { $0.id == id }),
              let target = presets.firstIndex(where: { $0.id == shown[from + step].id }) else { return }
        presets.swapAt(source, target)
        save()
    }

    /// A tray needs something to write with: a shelf left with nothing usable gets the starters back.
    func restock() {
        guard usable.isEmpty else { return }
        presets += Self.freshStarters
        save()
    }

    /// Holds the tools a new shelf starts with, and nothing else.
    var isAsItStarted: Bool { synced.isAsItStarted }

    /// Back to the four tools a new shelf starts with; everything added or changed since goes.
    func reset() {
        presets = Self.freshStarters
        save()
    }

    private static var freshStarters: [ToolPreset] {
        starters.map { ToolPreset(ink: $0.inkType ?? .pen, color: $0.color, width: $0.width) }
    }

    private func save() {
        changedAt = .now
        write()
        onChanged?()
    }

    private func write() {
        guard let defaults, let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: SettingsKey.toolPresets)
        defaults.set(changedAt, forKey: SettingsKey.toolPresetsChangedAt)
    }
}

/// What is in hand: one of the pens on the shelf, the eraser or the lasso.
enum ToolChoice: Codable, Hashable, Sendable {
    case pen(UUID), eraser, lasso
}

/// The eraser takes whole strokes at a touch, or only the ink it passes over, as wide as it is set.
struct Eraser: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case strokes, part
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .strokes: String(localized: "Whole Strokes")
            case .part: String(localized: "Part of a Stroke")
            }
        }
    }

    var kind = Kind.strokes
    var width = Double(PKEraserTool.EraserType.fixedWidthBitmap.defaultWidth)

    static var widths: ClosedRange<Double> {
        let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    var tool: PKEraserTool {
        switch kind {
        case .strokes: PKEraserTool(.vector)
        case .part: PKEraserTool(.fixedWidthBitmap, width: min(max(width, Self.widths.lowerBound), Self.widths.upperBound))
        }
    }
}

/// Something from the Add menu or the page's helpers that can be kept in the tray, beside the tools.
enum ToolExtra: String, Codable, CaseIterable, Identifiable, Sendable {
    case picture, text, sticker, link, tape, ruler, zoomWindow, typing, shapes
    var id: String { rawValue }

    static let starters: [ToolExtra] = [.picture, .text]

    var title: String {
        switch self {
        case .picture: String(localized: "Picture")
        case .text: String(localized: "Text Box")
        case .sticker: String(localized: "Sticker")
        case .link: String(localized: "Link")
        case .tape: String(localized: "Study Tape")
        case .ruler: String(localized: "Ruler")
        case .zoomWindow: String(localized: "Zoom Window")
        case .typing: String(localized: "Handwriting to Text")
        case .shapes: String(localized: "Shapes")
        }
    }

    var symbol: String {
        switch self {
        case .picture: "photo"
        case .text: "character.textbox"
        case .sticker: "seal"
        case .link: "link"
        case .tape: "rectangle.dashed"
        case .ruler: "ruler"
        case .zoomWindow: "plus.magnifyingglass"
        case .typing: "character.cursor.ibeam"
        case .shapes: "square.on.circle"
        }
    }
}

/// The tools at the foot of the editor, the same in every notebook and window: the pens on the shelf, the eraser
/// and the lasso, which of them is in hand, and the shortcuts kept beside them.
@MainActor
@Observable
final class Toolbox {
    static let shared = Toolbox()
    /// Posted when the tool in hand or the ruler changes, so every open page takes it.
    static let didChange = Notification.Name("owlluna.toolbox.changed")

    private struct Saved: Codable {
        var choice: ToolChoice?
        var eraser: Eraser?
        var extras: [String]?
    }

    let shelf: ToolShelf
    private(set) var choice: ToolChoice
    private(set) var eraser: Eraser
    /// The shortcuts in the tray. They stand in the order `ToolExtra` lists them.
    private(set) var extras: Set<ToolExtra>
    var isRulerActive = false {
        didSet {
            guard isRulerActive != oldValue else { return }
            // The ruler and the shapes both take the drags on the page.
            if isRulerActive { shape = nil }
            post()
        }
    }
    /// While this is on, what a pen writes is read after a pause and set as typed text in its place. Like the ruler,
    /// it lasts as long as the app does.
    var typesHandwriting = false {
        didSet { if typesHandwriting != oldValue { post() } }
    }
    /// What a drag on the page draws while the strip of shapes is out over the tray; nil while it is put away. Like
    /// the ruler, it lasts as long as the app does.
    private(set) var shape: ShapeKind? {
        didSet { if shape != oldValue { post() } }
    }
    /// The shape the strip comes out with: the one last picked.
    @ObservationIgnored private var lastShape = ShapeKind.circle
    /// Saved shortcuts a later build added, kept so that saving here doesn't lose them.
    @ObservationIgnored private var unknownExtras: [String] = []
    @ObservationIgnored private var memory = PencilToolMemory<ToolChoice>()
    /// The pen that was last in hand, for a new pen to be like while the eraser or the lasso is.
    @ObservationIgnored private var lastPen: UUID?
    @ObservationIgnored private let defaults: UserDefaults?

    /// Without `defaults` the toolbox lasts as long as the app does.
    init(defaults: UserDefaults? = .standard) {
        var store = defaults
        #if DEBUG
        if LaunchOptions.arguments.contains("-freshToolPresets") { store = nil }
        #endif
        self.defaults = store
        shelf = ToolShelf(defaults: store)
        shelf.restock()
        let saved = store?.data(forKey: SettingsKey.toolbox).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        eraser = saved?.eraser ?? Eraser()
        extras = saved?.extras.map { Set($0.compactMap(ToolExtra.init(rawValue:))) } ?? Set(ToolExtra.starters)
        unknownExtras = saved?.extras?.filter { ToolExtra(rawValue: $0) == nil } ?? []
        let pens = shelf.usable
        switch saved?.choice {
        case .pen(let id)? where pens.contains { $0.id == id }: choice = .pen(id)
        case .eraser?: choice = .eraser
        case .lasso?: choice = .lasso
        default: choice = pens.first.map { .pen($0.id) } ?? .eraser
        }
        memory.select(choice, isEraser: choice == .eraser)
    }

    /// The pen in hand; nil while it is the eraser or the lasso.
    var pen: ToolPreset? {
        guard case .pen(let id) = choice else { return nil }
        return shelf.usable.first { $0.id == id }
    }

    /// The tool in hand, as a canvas takes it.
    var tool: PKTool {
        switch choice {
        case .pen: pen?.tool ?? PKInkingTool(.pen)
        case .eraser: eraser.tool
        case .lasso: PKLassoTool()
        }
    }

    func take(_ new: ToolChoice) {
        if case .pen(let id) = new, !shelf.usable.contains(where: { $0.id == id }) { return }
        guard new != choice else { return }
        if case .pen(let id) = choice { lastPen = id }
        memory.select(new, isEraser: new == .eraser)
        // A shape is drawn in a pen's ink.
        if new == .eraser || new == .lasso { shape = nil }
        choice = new
        save()
        post()
    }

    func changePen(_ id: UUID, _ change: (inout ToolPreset) -> Void) {
        shelf.change(id, change)
        if choice == .pen(id) { post() }
    }

    /// A new pen like the one in hand, or the one last in hand, in the first of its colours the shelf doesn't have
    /// yet. It is taken up.
    @discardableResult
    func addPen() -> UUID? {
        let pens = shelf.usable
        guard let like = pen ?? pens.first(where: { $0.id == lastPen }) ?? pens.first, let ink = like.inkType else { return nil }
        let taken = Set(shelf.usable.filter { $0.ink == like.ink }.map(\.tint))
        guard let color = ToolPreset.palette(for: ink).first(where: { !taken.contains($0) }) else { return nil }
        var new = ToolPreset(ink: ink, color: color, width: like.width)
        new.opacity = like.opacity
        guard shelf.add(new) else { return nil }
        take(.pen(new.id))
        return new.id
    }

    /// Takes a pen off the shelf, unless it is the last one. If it was in hand, the pen beside it is taken up.
    func removePen(_ id: UUID) {
        let pens = shelf.usable
        guard pens.count > 1, let index = pens.firstIndex(where: { $0.id == id }) else { return }
        if choice == .pen(id) { take(.pen(pens[index == 0 ? 1 : index - 1].id)) }
        shelf.remove(id)
    }

    /// The tray's pens go back to the four it started with. A pen in hand gives way to the first of them; the eraser,
    /// the lasso and the shortcuts stay as they are.
    func resetPens() {
        let hadPen = choice != .eraser && choice != .lasso
        shelf.reset()
        lastPen = nil
        memory = PencilToolMemory()
        if let first = shelf.usable.first {
            if hadPen { choice = .pen(first.id) }
            // So the Pencil's switches still come back to a pen.
            memory.select(.pen(first.id), isEraser: false)
        }
        memory.select(choice, isEraser: choice == .eraser)
        save()
        post()
    }

    func setEraser(_ new: Eraser) {
        guard new != eraser else { return }
        eraser = new
        save()
        if choice == .eraser { post() }
    }

    func setExtra(_ extra: ToolExtra, shown: Bool) {
        guard extras.contains(extra) != shown else { return }
        if shown { extras.insert(extra) } else { extras.remove(extra) }
        // A helper taken off the tray is put away, or it would stay on with nothing to turn it off.
        if !shown, extra == .ruler { isRulerActive = false }
        if !shown, extra == .typing { typesHandwriting = false }
        if !shown, extra == .shapes { shape = nil }
        save()
    }

    /// Brings the strip of shapes out with the shape last picked, taking up a pen if the eraser or the lasso was in
    /// hand, or puts it away.
    func setShapesOut(_ out: Bool) {
        guard out != (shape != nil) else { return }
        guard out else { return shape = nil }
        takePen()
        isRulerActive = false
        shape = lastShape
    }

    func pick(_ kind: ShapeKind) {
        lastShape = kind
        if shape == nil { setShapesOut(true) }
        shape = kind
    }

    /// Takes the pens another device changed, unless they were changed here since the sync read them. A pen in hand
    /// that went with them gives way to the one now in its place, or the first.
    func takePens(_ pens: SyncedPens, since: Date?) {
        let before = shelf.usable
        guard shelf.take(pens, since: since) else { return }
        let usable = shelf.usable
        if case .pen(let id) = choice, !usable.contains(where: { $0.id == id }) {
            let place = before.firstIndex { $0.id == id } ?? 0
            if let pen = usable.indices.contains(place) ? usable[place] : usable.first {
                choice = .pen(pen.id)
                memory.select(choice, isEraser: false)
                save()
            }
        }
        if let lastPen, !usable.contains(where: { $0.id == lastPen }) { self.lastPen = nil }
        post()
    }

    /// The Pencil's eraser switch: to the eraser, or from it back to what was in hand before.
    func switchEraser() {
        if let tool = memory.eraserSwitch(eraser: .eraser) { take(tool) }
    }

    /// The Pencil's switch to the tool that was in hand before this one.
    func switchPrevious() {
        if let tool = memory.previous { take(tool) }
    }

    /// Takes up the pen last in hand, or the first on the shelf, unless a pen is in hand already.
    func takePen() {
        let pens = shelf.usable
        if pen == nil, let id = (pens.first { $0.id == lastPen } ?? pens.first)?.id { take(.pen(id)) }
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func save() {
        let saved = Saved(choice: choice, eraser: eraser, extras: ToolExtra.allCases.filter(extras.contains).map(\.rawValue) + unknownExtras)
        guard let defaults, let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: SettingsKey.toolbox)
    }
}
