import SwiftUI
import PencilKit

#if DEBUG
/// A notebook with a silent recording and ink dated inside it, for trying the replay.
enum ReplaySeed {
    static func write(root: StorageRoot) async {
        let paper = PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter)
        var manifest = NotebookManifest(title: "Lecture Replay", defaults: paper, pages: [paper.newPage(), paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        let start = Date.now.addingTimeInterval(-3600), duration: TimeInterval = 20, file = "\(UUID().uuidString).wav"
        try? await package.create(manifest)
        try? FileManager.default.createDirectory(at: package.assetsDirectory, withIntermediateDirectories: true)
        try? silence(seconds: duration).write(to: package.assetURL(file))
        var entry = RecordingEntry(id: UUID(), file: file, createdAt: start.addingTimeInterval(duration), duration: duration)
        entry.startedAt = start
        entry.inkedPages = manifest.pages.map(\.id)
        manifest.recordings = [entry]
        let first = [stroke(y: 140, at: start.addingTimeInterval(-60)), stroke(y: 220, at: start.addingTimeInterval(2)),
                     stroke(y: 300, at: start.addingTimeInterval(6)), stroke(y: 380, at: start.addingTimeInterval(10))]
        let second = [stroke(y: 160, at: start.addingTimeInterval(14)), stroke(y: 240, at: start.addingTimeInterval(18))]
        _ = try? await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: PKDrawing(strokes: first),
                                                                              manifest.pages[1].id: PKDrawing(strokes: second)]))
    }

    static func stroke(y: CGFloat, at date: Date) -> PKStroke {
        let points = (0...12).map { index in
            PKStrokePoint(location: CGPoint(x: 120 + CGFloat(index) * 30, y: y + 12 * sin(CGFloat(index))), timeOffset: Double(index) * 0.05,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: date))
    }

    /// A mono 16-bit WAV file of silence.
    static func silence(seconds: TimeInterval, rate: Int = 8000) -> Data {
        let bytes = Int(seconds * Double(rate)) * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }
}

/// Capital letters made of straight strokes, so tests have handwriting the recogniser can read.
enum BlockLetters {
    private static let shapes: [Character: [[(CGFloat, CGFloat)]]] = [
        "A": [[(0, 6), (2, 0), (4, 6)], [(1, 3.6), (3, 3.6)]],
        "E": [[(4, 0), (0, 0), (0, 6), (4, 6)], [(0, 3), (3, 3)]],
        "F": [[(4, 0), (0, 0), (0, 6)], [(0, 3), (3, 3)]],
        "H": [[(0, 0), (0, 6)], [(4, 0), (4, 6)], [(0, 3), (4, 3)]],
        "I": [[(2, 0), (2, 6)]],
        "K": [[(0, 0), (0, 6)], [(4, 0), (0, 3.4), (4, 6)]],
        "L": [[(0, 0), (0, 6), (4, 6)]],
        "M": [[(0, 6), (0, 0), (2, 3.5), (4, 0), (4, 6)]],
        "N": [[(0, 6), (0, 0), (4, 6), (4, 0)]],
        "O": [[(1, 0), (3, 0), (4, 1.5), (4, 4.5), (3, 6), (1, 6), (0, 4.5), (0, 1.5), (1, 0)]],
        "T": [[(0, 0), (4, 0)], [(2, 0), (2, 6)]],
        "V": [[(0, 0), (2, 6), (4, 0)]],
        "W": [[(0, 0), (1, 6), (2, 2.5), (3, 6), (4, 0)]],
        "X": [[(0, 0), (4, 6)], [(4, 0), (0, 6)]],
        "Y": [[(0, 0), (2, 3)], [(4, 0), (2, 3)], [(2, 3), (2, 6)]],
        "Z": [[(0, 0), (4, 0), (0, 6), (4, 6)]],
    ]

    /// `text` written from `origin`, each letter `height` tall, one stroke after another from `date`.
    static func strokes(_ text: String, origin: CGPoint, height: CGFloat = 48, from date: Date = .now) -> [PKStroke] {
        let unit = height / 6
        var x = origin.x, strokes: [PKStroke] = []
        for letter in text.uppercased() {
            for line in shapes[letter] ?? [] {
                let corners = line.map { CGPoint(x: x + $0.0 * unit, y: origin.y + $0.1 * unit) }
                var points: [PKStrokePoint] = []
                for (a, b) in zip(corners, corners.dropFirst()) {
                    let steps = max(Int(hypot(b.x - a.x, b.y - a.y) / 4), 1)
                    for step in (points.isEmpty ? 0 : 1)...steps {
                        let t = CGFloat(step) / CGFloat(steps)
                        points.append(PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(points.count) * 0.01,
                                                    size: CGSize(width: 3.5, height: 3.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
                    }
                }
                strokes.append(PKStroke(ink: PKInk(.pen, color: .black),
                                        path: PKStrokePath(controlPoints: points, creationDate: date.addingTimeInterval(Double(strokes.count) * 0.6))))
            }
            x += unit * (letter == " " ? 4 : 6)
        }
        return strokes
    }
}

/// A notebook with a line of handwriting, for trying handwriting to text, study tape and the time-lapse.
enum HandwritingSeed {
    static func write(root: StorageRoot) async {
        let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
        let manifest = NotebookManifest(title: "Study Notes", defaults: paper, pages: [paper.newPage(), paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try? await package.create(manifest)
        let ink = PKDrawing(strokes: BlockLetters.strokes("HELLO", origin: CGPoint(x: 150, y: 160), from: Date.now.addingTimeInterval(-600)))
        guard let saved = try? await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink])),
              LaunchOptions.arguments.contains("-indexSeed") else { return }
        _ = await HandwritingIndexer.shared.index(HandwritingIndexer.Job(package: package, pages: saved.manifest.pages))
    }
}

/// A notebook of typed notes with a strip of study tape and three flashcards, two of them due (`-seedStudy`).
enum StudySeed {
    static let notes = """
        Mitochondria make ATP, the cell's energy.
        Ribosomes build proteins from amino acids.
        The nucleus holds the cell's DNA.
        Chloroplasts turn light into sugar in plants.
        The cell membrane decides what goes in and out.
        """

    static func write(root: StorageRoot) async {
        let paper = PageDefaults(template: .dotted, paperColor: .ivory, pageSize: .letter)
        var page = paper.newPage()
        var box = TextBox(string: notes)
        box.fontSize = 17
        let width: CGFloat = 400
        page.items = [PageItem(content: .text(box), center: CGPoint(x: 280, y: 220), size: CGSize(width: width, height: box.height(width: width))),
                      PageItem(content: .tape(.mustard), center: CGPoint(x: 240, y: 178), size: CGSize(width: 120, height: 24))]
        var manifest = NotebookManifest(title: "Biology", defaults: paper, pages: [page, paper.newPage()])
        manifest.cover.cloth = .moss
        let package = NotebookPackage(root: root, id: manifest.id)
        try? await package.create(manifest)
        let ink = PKDrawing(strokes: BlockLetters.strokes("HELLO", origin: CGPoint(x: 90, y: 420), from: Date.now.addingTimeInterval(-600)))
        _ = try? await package.write(SaveSnapshot(manifest: manifest, ink: [page.id: ink]))
        var later = Flashcard(front: CardSide(text: "What does the nucleus hold?"), back: CardSide(text: "The cell's DNA"), pageID: page.id)
        later = CardSchedule.graded(later, .easy)
        let cards = [Flashcard(front: CardSide(text: "What makes ATP?"), back: CardSide(text: "Mitochondria"), pageID: page.id),
                     Flashcard(front: CardSide(text: "What do ribosomes build?"), back: CardSide(text: "Proteins, from amino acids"), pageID: page.id),
                     later]
        try? CardFiles.write(CardFiles.Deck(cards: cards), to: package.url)
    }
}

enum LibrarySeed {
    /// Writes `count` notebooks with a mix of cover styles and a few folders, for scrolling tests.
    static func write(count: Int, root: StorageRoot) async {
        var folderFile = FolderFile()
        let folders = ["Biology", "Studio", "Physics", "Journal"].enumerated().map { index, name in
            FolderEntry(id: UUID(), name: name, clothRaw: ClothColor.allCases[index * 2].rawValue, createdAt: .now, sortIndex: index)
        }
        folderFile.folders = folders
        try? folderFile.write(root)
        let titles = ["Cell Biology", "Studio Notes", "Physics II", "Recipes", "Field Journal", "Ideas", "Genetics", "Lab Book", "Reading Notes", "Exam Prep"]
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    let id = UUID()
                    var cover = CoverSpec.defaultCloth(for: id)
                    cover.style = [CoverStyle.cloth, .print, .cloth, .firstPage][index % 4]
                    cover.inks = RisoInk.pairs[index % RisoInk.pairs.count]
                    var manifest = NotebookManifest(id: id, title: "\(titles[index % titles.count]) \(index + 1)",
                                                    createdAt: Date.now.addingTimeInterval(-Double(index) * 3600 * 7), cover: cover,
                                                    defaults: PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter),
                                                    pages: (0..<(1 + index % 6)).map { _ in .template(.narrowRuled, color: .white, size: .letter) })
                    manifest.modifiedAt = manifest.createdAt
                    manifest.library.isFavorite = index % 7 == 0
                    if index == 0 { manifest.library.lastOpenedAt = .now }
                    manifest.library.folderID = index % 3 == 0 ? folders[index % folders.count].id : nil
                    try? await NotebookPackage(root: root, id: id).create(manifest)
                }
            }
        }
    }

    /// One notebook made from a generated 300-page PDF, for scrolling and zoom tests in the editor. Its contents list six
    /// parts of fifty pages, with every tenth chapter under its part.
    static func writeLongPDF(root: StorageRoot) async {
        let id = UUID()
        let package = NotebookPackage(root: root, id: id)
        let source = FileManager.default.temporaryDirectory.appending(path: "seed-\(id.uuidString).pdf")
        let bounds = CGRect(origin: .zero, size: PageSize.letter.points)
        try? UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: source) { context in
            let parts: [[String: Any]] = (0..<6).map { part in
                let chapters: [[String: Any]] = stride(from: 1, to: 50, by: 10).map { chapter in
                    [kCGPDFOutlineTitle as String: "Chapter \(part * 50 + chapter)", kCGPDFOutlineDestination as String: part * 50 + chapter]
                }
                return [kCGPDFOutlineTitle as String: "Part \(part + 1)", kCGPDFOutlineDestination as String: part * 50 + 1,
                        kCGPDFOutlineChildren as String: chapters]
            }
            CGPDFContextSetOutline(context.cgContext, [kCGPDFOutlineChildren as String: parts] as CFDictionary)
            for index in 0..<300 {
                context.beginPage()
                ("Chapter \(index + 1)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
                for line in 0..<30 {
                    ("Body text line \(line + 1) on page \(index + 1)." as NSString)
                        .draw(at: CGPoint(x: 72, y: 130 + CGFloat(line) * 20), withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
                }
            }
        }
        guard let file = try? await package.importAsset(from: source, ext: "pdf"),
              let pages = try? PDFImport.pages(at: package.assetURL(file), file: file) else { return }
        var cover = CoverSpec.defaultCloth(for: id)
        cover.style = .firstPage
        try? await package.create(NotebookManifest(id: id, title: "Textbook", cover: cover,
                                                   defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter), pages: pages))
        if LaunchOptions.arguments.contains("-indexSeed") {
            _ = await HandwritingIndexer.shared.index(HandwritingIndexer.Job(package: package, pages: pages))
        }
    }
}

/// `-seedPaper` puts a ruled lab sheet on the shelf of the user's own paper.
enum PaperSeed {
    static func write(root: StorageRoot) {
        guard PaperShelf.list(root).isEmpty else { return }
        let source = FileManager.default.temporaryDirectory.appending(path: "Lab Sheet.pdf")
        let bounds = CGRect(origin: .zero, size: PageSize.a4.points)
        try? UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: source) { context in
            context.beginPage()
            ("LAB SHEET" as NSString).draw(at: CGPoint(x: 48, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .heavy)])
            UIColor(red: 0.2, green: 0.45, blue: 0.75, alpha: 1).setStroke()
            for line in 0..<24 {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 48, y: 110 + CGFloat(line) * 28))
                path.addLine(to: CGPoint(x: bounds.width - 48, y: 110 + CGFloat(line) * 28))
                path.stroke()
            }
        }
        _ = try? PaperShelf.add(file: source, to: root)
    }
}
#endif
