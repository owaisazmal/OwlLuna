import UIKit

/// What every SVG writer needs: short numbers, escaped text, colours and path data.
enum SVGText {
    /// Two decimals at most, with no trailing zeros.
    static func number(_ value: CGFloat) -> String {
        let scaled = (Double(value) * 100).rounded()
        guard scaled.isFinite, abs(scaled) < 1e17 else { return "0" }
        let hundredths = Int64(scaled), whole = abs(hundredths) / 100, part = Int(abs(hundredths) % 100)
        var text = hundredths < 0 ? "-" : ""
        text += String(whole)
        if part != 0 { text += part < 10 ? ".0\(part)" : part % 10 == 0 ? ".\(part / 10)" : ".\(part)" }
        return text
    }

    /// Safe between tags and inside a quoted attribute.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default: if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// The colour as `#rrggbb` in sRGB, with how opaque it is beside it.
    static func color(_ color: UIColor) -> (hex: String, opacity: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return (String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b)), min(max(a, 0), 1))
    }

    /// Points joined by straight lines, as the `d` of a `<path>`.
    static func path(_ points: [CGPoint], closed: Bool = false) -> String {
        guard let first = points.first else { return "" }
        var d = "M\(number(first.x)) \(number(first.y))"
        for point in points.dropFirst() { d += "L\(number(point.x)) \(number(point.y))" }
        return closed ? d + "Z" : d
    }

    /// A path with its curves, as the `d` of a `<path>`.
    static func path(_ path: CGPath) -> String {
        var d = ""
        path.applyWithBlock { element in
            let points = element.pointee.points
            func pair(_ index: Int) -> String { "\(number(points[index].x)) \(number(points[index].y))" }
            switch element.pointee.type {
            case .moveToPoint: d += "M" + pair(0)
            case .addLineToPoint: d += "L" + pair(0)
            case .addQuadCurveToPoint: d += "Q" + pair(0) + " " + pair(1)
            case .addCurveToPoint: d += "C" + pair(0) + " " + pair(1) + " " + pair(2)
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }
}
