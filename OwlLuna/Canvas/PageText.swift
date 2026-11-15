import UIKit

extension TextBox.Tint {
    var displayName: String {
        switch self {
        case .ink: String(localized: "Ink")
        case .tomato: String(localized: "Tomato")
        case .cobalt: String(localized: "Cobalt")
        case .moss: String(localized: "Moss")
        case .plum: String(localized: "Plum")
        }
    }

    /// Lighter on Charcoal and Chalkboard, so typed text stays readable there.
    func color(onDark: Bool) -> UIColor {
        switch self {
        case .ink: UIColor(hex: onDark ? 0xF7F1E3 : 0x1B2230)
        case .tomato: UIColor(hex: onDark ? 0xFF9A86 : 0xC9452F)
        case .cobalt: UIColor(hex: onDark ? 0xA6BBFF : 0x2F4DA0)
        case .moss: UIColor(hex: onDark ? 0xA9D6AD : 0x3D5A40)
        case .plum: UIColor(hex: onDark ? 0xE5B1DB : 0x5A2F52)
        }
    }
}

extension TextBox.Alignment {
    var displayName: String {
        switch self {
        case .leading: String(localized: "Left")
        case .center: String(localized: "Centre")
        case .trailing: String(localized: "Right")
        }
    }

    var symbol: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }

    var textAlignment: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }
}

extension TextBox.Face {
    var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .serif: String(localized: "Serif")
        case .mono: String(localized: "Mono")
        case .fraunces: "Fraunces"
        }
    }
}

extension TextBox.List {
    var displayName: String {
        switch self {
        case .bullet: String(localized: "Bullets")
        case .number: String(localized: "Numbers")
        case .check: String(localized: "Checklist")
        }
    }

    var symbol: String {
        switch self {
        case .bullet: "list.bullet"
        case .number: "list.number"
        case .check: "checklist"
        }
    }
}

extension TextBox.Highlight {
    /// The highlighter's tint of the same name.
    private var tint: UInt32 {
        switch self {
        case .yellow: ToolPreset.tints[0]
        case .green: ToolPreset.tints[1]
        case .pink: ToolPreset.tints[2]
        case .blue: ToolPreset.tints[3]
        }
    }

    var displayName: String { ToolPreset.colorName(tint) }

    /// Fainter on Charcoal and Chalkboard, so the light text over it stays readable there.
    func color(onDark: Bool) -> UIColor {
        ToolPreset.uiColor(tint).withAlphaComponent(onDark ? 0.4 : 0.55)
    }
}

/// Laying out and drawing typed text, the same way in the editor, thumbnails and exported PDFs. Thread-safe.
extension TextBox {
    static let sizes: [(name: String, points: CGFloat)] = [
        (String(localized: "Small"), 13), (String(localized: "Body"), 17), (String(localized: "Large"), 24), (String(localized: "Title"), 34),
    ]

    /// At a `scale`, the type size's own cut and spacing enlarged, so zoomed-in typing wraps where the page does.
    func font(scale: CGFloat = 1) -> UIFont {
        let size = fontSize, weight: UIFont.Weight = isBold ? .bold : .regular
        let upright: UIFont = switch face {
        case .system: .systemFont(ofSize: size, weight: weight)
        case .serif: Self.system(.serif, size: size, weight: weight)
        case .mono: Self.system(.monospaced, size: size, weight: weight)
        case .fraunces: OwlLunaFonts.text(size: size, bold: isBold) as UIFont
        }
        let font = isItalic ? Self.italic(upright, ownCut: face != .fraunces) : upright
        guard scale != 1 else { return font }
        let pinned = font.fontDescriptor.addingAttributes([.init(rawValue: kCTFontOpticalSizeAttribute as String): size])
        return UIFont(descriptor: pinned, size: size * scale)
    }

    private static func system(_ design: UIFontDescriptor.SystemDesign, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? font
    }

    /// The face's own italic, or the upright leant over where it has none.
    private static func italic(_ font: UIFont, ownCut: Bool) -> UIFont {
        let descriptor = font.fontDescriptor
        if ownCut, let italic = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            let cut = UIFont(descriptor: italic, size: font.pointSize)
            if cut.fontDescriptor.symbolicTraits.contains(.traitItalic) { return cut }
        }
        let lean = NSValue(cgAffineTransform: CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0))
        return UIFont(descriptor: descriptor.addingAttributes([.matrix: lean]), size: font.pointSize)
    }

    /// The text as it is measured and drawn, and where a checklist's boxes and its formulas go in it.
    private struct Typeset {
        var text: NSAttributedString
        /// The tab that starts each item of a checklist, by line.
        var checks: [(line: Int, location: Int)] = []
        var font: UIFont
        /// Between a marker and the words.
        var gap: CGFloat = 0
        var formulas: [Formula] = []
    }

    /// A formula set in the text, where an attachment the size of it holds its place.
    private struct Formula {
        var location: Int
        var math: MathFormula
        /// How much it was shrunk to fit the box's width.
        var fit: CGFloat
        var color: UIColor
    }

    /// The text laid out at a width, the way it is drawn.
    private struct Layout {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer

        init(_ text: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: text)
            container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }
    }

    /// A list's lines start with their marker and a tab across to the indent the rest of the line keeps to, each tab joined
    /// to what follows so a long first word can't leave its marker alone on a line; a checklist's boxes are drawn in the
    /// room its tab leaves. With `markersOnly` the words are there but clear, for drawing under the editor's own; `editing`
    /// leaves the markers out and stands every line at the indent, as the editor holds the words. Formulas are set unless
    /// `typed`, shrunk to fit `width`.
    private func typeset(_ string: String, color: UIColor, highlight: UIColor? = nil, scale: CGFloat = 1, markersOnly: Bool = false,
                         editing: Bool = false, typed: Bool = false, width: CGFloat? = nil) -> Typeset {
        let font = font(scale: scale), setsMath = !(typed || editing || markersOnly)
        var words: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: markersOnly ? UIColor.clear : color]
        if !markersOnly, isUnderlined { words[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if !markersOnly, let highlight { words[.backgroundColor] = highlight }
        guard let list else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment.textAlignment
            paragraph.lineBreakMode = .byWordWrapping
            if scale != 1 {
                paragraph.tabStops = paragraph.tabStops?.map { NSTextTab(textAlignment: $0.alignment, location: $0.location * scale, options: $0.options) }
                paragraph.defaultTabInterval *= scale
            }
            words[.paragraphStyle] = paragraph
            let text = NSMutableAttributedString(string: string, attributes: words)
            if words.count > 3 { Self.plainNewlines(in: text) }
            return Typeset(text: text, font: font, formulas: setsMath ? Self.setMath(in: text, font: font, room: width) : [])
        }
        let lines = (string as NSString).components(separatedBy: "\n"), numbers = Self.numbers(of: lines)
        let side = Self.checkSide(font), gap = font.pointSize * 0.4
        let markers = lines.indices.map { index -> String? in
            guard let number = numbers[index] else { return nil }
            return switch list {
            case .bullet: "•"
            case .number: "\(number)."
            case .check: ""
            }
        }
        let widest = list == .check ? side : markers.compactMap { $0 }.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let indent = max(widest + gap, font.pointSize * 1.5)
        let tabs = list == .check ? [NSTextTab(textAlignment: .natural, location: indent)]
            : [NSTextTab(textAlignment: .right, location: indent - gap), NSTextTab(textAlignment: .natural, location: indent)]
        func paragraph(first: CGFloat) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .natural
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.firstLineHeadIndent = first
            paragraph.headIndent = indent
            paragraph.tabStops = tabs
            paragraph.defaultTabInterval = indent
            return paragraph
        }
        let item = paragraph(first: editing ? indent : 0), plain = paragraph(first: indent)
        let text = NSMutableAttributedString()
        var checks: [(line: Int, location: Int)] = [], formulas: [Formula] = []
        for (index, line) in lines.enumerated() {
            var look = words
            look[.paragraphStyle] = markers[index] == nil ? plain : item
            if list == .check, checked.contains(index), !markersOnly { look[.foregroundColor] = color.withAlphaComponent(0.5) }
            if let marker = markers[index], !editing {
                if list == .check { checks.append((index, text.length)) }
                text.append(NSAttributedString(string: list == .check ? "\t\u{2060}" : "\t\u{2060}\(marker)\t\u{2060}",
                                               attributes: [.font: font, .foregroundColor: color, .paragraphStyle: item]))
            }
            let written = NSMutableAttributedString(string: index < lines.count - 1 ? line + "\n" : line, attributes: look)
            if setsMath {
                let start = text.length
                formulas += Self.setMath(in: written, font: font, room: width.map { $0 - indent }).map { formula in
                    var formula = formula
                    formula.location += start
                    return formula
                }
            }
            text.append(written)
        }
        Self.plainNewlines(in: text)
        return Typeset(text: text, checks: checks, font: font, gap: gap, formulas: formulas)
    }

    /// Stands each formula in for an attachment its size and shows `\$` as `$`; one that can't be set stays as typed.
    private static func setMath(in text: NSMutableAttributedString, font: UIFont, room: CGFloat?) -> [Formula] {
        let runs = MathRun.find(in: text.string as NSString)
        guard !runs.isEmpty else { return [] }
        let size = MathFormula.size(beside: font)
        var formulas: [Formula] = [], shift = 0
        for run in runs {
            let range = NSRange(location: run.range.location - shift, length: run.range.length)
            if run.isEscape {
                text.replaceCharacters(in: range, with: "$")
            } else if let math = MathFormula(run.source, size: size, display: run.display, textFont: font) {
                var look = text.attributes(at: range.location, effectiveRange: nil)
                let fit = room.map { min(1, max($0, 1) / math.width) } ?? 1
                let stand = NSTextAttachment()
                stand.image = UIImage()
                stand.bounds = CGRect(x: 0, y: -math.descent * fit, width: math.width * fit, height: (math.ascent + math.descent) * fit)
                look[.attachment] = stand
                look[.underlineStyle] = nil
                text.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: look))
                formulas.append(Formula(location: range.location, math: math, fit: fit, color: look[.foregroundColor] as? UIColor ?? .black))
            } else {
                continue
            }
            shift += range.length - 1
        }
        return formulas
    }

    /// The returns between lines are neither underlined nor washed.
    private static func plainNewlines(in text: NSMutableAttributedString) {
        let string = text.string as NSString
        var range = string.range(of: "\n")
        while range.location != NSNotFound {
            text.removeAttribute(.underlineStyle, range: range)
            text.removeAttribute(.backgroundColor, range: range)
            range = string.range(of: "\n", range: NSRange(location: NSMaxRange(range), length: string.length - NSMaxRange(range)))
        }
    }

    private static func checkSide(_ font: UIFont) -> CGFloat { font.capHeight * 1.12 }

    /// Each box of a checklist by line, and the room beside its first line where a tap ticks it, from the box's top
    /// left, at the scale it was set at.
    private func checkboxes(_ set: Typeset, width: CGFloat, layout: Layout? = nil) -> [(line: Int, box: CGRect, room: CGRect)] {
        guard !set.checks.isEmpty else { return [] }
        let layout = layout ?? Layout(set.text, width: width), manager = layout.manager, container = layout.container
        let side = Self.checkSide(set.font)
        return set.checks.map { check in
            let glyph = manager.glyphIndexForCharacter(at: check.location)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + manager.location(forGlyphAt: glyph).y
            let tab = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let x = tab.minX < 0.5 ? tab.maxX - set.gap - side : tab.minX + set.gap
            let box = CGRect(x: x, y: baseline - set.font.capHeight / 2 - side / 2, width: side, height: side)
            return (check.line, box, CGRect(x: tab.minX, y: line.minY, width: tab.width, height: line.height))
        }
    }

    /// Where each formula's baseline starts, from the box's top left; an attachment's glyph is located by its foot.
    private func formulas(_ set: Typeset, in layout: Layout) -> [(formula: Formula, origin: CGPoint)] {
        set.formulas.map { formula in
            let glyph = layout.manager.glyphIndexForCharacter(at: formula.location)
            let line = layout.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil), at = layout.manager.location(forGlyphAt: glyph)
            return (formula, CGPoint(x: line.minX + at.x, y: line.minY + at.y - formula.math.descent * formula.fit))
        }
    }

    private static func drawCheckbox(_ box: CGRect, ticked: Bool, color: UIColor, in ctx: CGContext) {
        let line = max(box.width * 0.1, 0.75), side = box.width
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(line)
        ctx.addPath(CGPath(roundedRect: box.insetBy(dx: line / 2, dy: line / 2), cornerWidth: side * 0.14, cornerHeight: side * 0.14, transform: nil))
        ctx.strokePath()
        if ticked {
            ctx.setLineWidth(line * 1.6)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addLines(between: [CGPoint(x: box.minX + side * 0.24, y: box.minY + side * 0.52), CGPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.72),
                                   CGPoint(x: box.minX + side * 0.78, y: box.minY + side * 0.28)])
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// An empty box, or one ending in a return, is as tall as the line the caret sits on; `typed`, as the editor holds it.
    func height(width: CGFloat, typed: Bool = false) -> CGFloat {
        let measured = string.isEmpty || string.hasSuffix("\n") ? string + " " : string
        let bounds = typeset(measured, color: .black, typed: typed, width: width).text
            .boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return max(bounds.height, font().lineHeight).rounded(.up)
    }

    /// The width its longest line wants, for a box that hasn't been given one.
    func naturalWidth(limit: CGFloat) -> CGFloat {
        let bounds = typeset(string, color: .black, width: limit).text.boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude),
                                                                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return min(bounds.width.rounded(.up) + 2, limit)
    }

    /// Draws in page points, in a y-down context; at a `scale`, in points that many times larger. With `markersOnly`
    /// only a list's bullets, numbers and boxes are drawn, where the editor's words leave room for them.
    func draw(in ctx: CGContext, rect: CGRect, onDark: Bool, scale: CGFloat = 1, markersOnly: Bool = false) {
        guard !string.isEmpty else { return }
        let color = tint.color(onDark: onDark)
        let set = typeset(string, color: color, highlight: highlight?.color(onDark: onDark), scale: scale, markersOnly: markersOnly, width: rect.width)
        UIGraphicsPushContext(ctx)
        set.text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
        guard !set.checks.isEmpty || !set.formulas.isEmpty else { return }
        let layout = Layout(set.text, width: rect.width)
        for check in checkboxes(set, width: rect.width, layout: layout) {
            Self.drawCheckbox(check.box.offsetBy(dx: rect.minX, dy: rect.minY), ticked: checked.contains(check.line), color: color, in: ctx)
        }
        for (formula, origin) in formulas(set, in: layout) {
            formula.math.draw(in: ctx, at: CGPoint(x: rect.minX + origin.x, y: rect.minY + origin.y), color: formula.color.cgColor, scale: formula.fit)
        }
    }

    /// The words as the editor's text view holds them, set as they are drawn.
    func editingText(scale: CGFloat, onDark: Bool) -> NSAttributedString {
        typeset(string, color: tint.color(onDark: onDark), highlight: highlight?.color(onDark: onDark), scale: scale, editing: true).text
    }

    /// What a new line typed into the editor's text view starts with.
    func typingAttributes(scale: CGFloat, onDark: Bool) -> [NSAttributedString.Key: Any] {
        var fresh = self
        fresh.checked = []
        return fresh.typeset("x", color: tint.color(onDark: onDark), highlight: highlight?.color(onDark: onDark), scale: scale, editing: true)
            .text.attributes(at: 0, effectiveRange: nil)
    }

    /// The line of a checklist whose box is at a point, in page points from the box's top left; `reach` is how far past
    /// the box's room a tap still counts, and `typed` finds it in the text as the editor holds it.
    func checkbox(at point: CGPoint, width: CGFloat, reach: CGFloat = 6, typed: Bool = false) -> Int? {
        checkboxes(typeset(string, color: .black, typed: typed, width: width), width: width)
            .filter { $0.room.insetBy(dx: -reach, dy: -2).contains(point) }
            .min { hypot($0.box.midX - point.x, $0.box.midY - point.y) < hypot($1.box.midX - point.x, $1.box.midY - point.y) }?.line
    }

    /// Where each box of a checklist is, by line, from the box's top left; at a `scale`, `width` and the boxes are in
    /// points that many times larger.
    func checkboxes(width: CGFloat, scale: CGFloat = 1) -> [(line: Int, rect: CGRect)] {
        checkboxes(typeset(string, color: .black, scale: scale, width: width), width: width).map { ($0.line, $0.box) }
    }
}

extension PageItem {
    /// The upright rectangle that holds the item however it is turned.
    var boundingBox: CGRect {
        let w = abs(size.width * cos(rotation)) + abs(size.height * sin(rotation))
        let h = abs(size.width * sin(rotation)) + abs(size.height * cos(rotation))
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    /// From the item's own points, top left at the origin, to the page's, turned about its centre.
    var placement: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation).translatedBy(x: -size.width / 2, y: -size.height / 2)
    }
}
