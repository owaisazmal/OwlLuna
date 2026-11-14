import UIKit
import PencilKit
import AVFoundation

/// Films a page being written: the paper, then every stroke drawn in the order and at the pace it was written,
/// with the waits between strokes taken out, then a moment on the finished page.
enum InkTimelapse {
    static let framesPerSecond = 30
    static let hold: TimeInterval = 1.5

    enum Failure: LocalizedError {
        case noInk, writer(String)

        var errorDescription: String? {
            switch self {
            case .noInk: String(localized: "There is no ink on this page to film.")
            case .writer(let reason): String(localized: "The video couldn't be made: \(reason)")
            }
        }
    }

    /// When each stroke is drawn in the film.
    struct Plan: Sendable, Equatable {
        struct Span: Sendable, Equatable {
            let stroke: Int
            let start: TimeInterval
            let end: TimeInterval
        }

        /// In the order the strokes were written.
        let spans: [Span]
        /// How long the writing takes in the film, before the hold on the finished page.
        let duration: TimeInterval

        /// `strokes` gives each stroke's date and how long it took to draw. A long page is sped up to twenty seconds,
        /// a short one slowed to three, and each stroke keeps its share of the time.
        init(strokes: [(date: Date, seconds: TimeInterval)]) {
            let order = strokes.indices.sorted { (strokes[$0].date, $0) < (strokes[$1].date, $1) }
            let lengths = order.map { min(max(strokes[$0].seconds, 0.06), 4) }
            let written = lengths.reduce(0, +)
            guard written > 0 else {
                spans = []
                duration = 0
                return
            }
            let film = min(max(written / 4, 3), 20)
            var time: TimeInterval = 0, result: [Span] = []
            for (index, length) in zip(order, lengths) {
                let share = length / written * film
                result.append(Span(stroke: index, start: time, end: time + share))
                time += share
            }
            spans = result
            duration = film
        }

        init(drawing: PKDrawing) {
            self.init(strokes: drawing.strokes.map { ($0.path.creationDate, $0.path.last?.timeOffset ?? 0) })
        }

        var frameCount: Int { spans.isEmpty ? 0 : Int((duration * Double(InkTimelapse.framesPerSecond)).rounded(.up)) }

        /// How many strokes are finished at `time`, and how much of the next one has been drawn.
        func state(at time: TimeInterval) -> (finished: Int, partial: Double) {
            var low = 0, high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if spans[middle].end <= time { low = middle + 1 } else { high = middle }
            }
            guard low < spans.count else { return (spans.count, 0) }
            let span = spans[low]
            return (low, span.end > span.start ? min(max((time - span.start) / (span.end - span.start), 0), 1) : 0)
        }
    }

    /// The film's size in pixels: the page's shape, within 1080 by 1920 either way up, with even sides.
    static func frameSize(for page: CGSize) -> (width: Int, height: Int) {
        let scale = min(1080 / max(min(page.width, page.height), 1), 1920 / max(page.width, page.height, 1))
        func even(_ value: CGFloat) -> Int { max(Int((value * scale / 2).rounded()) * 2, 2) }
        return (even(page.width), even(page.height))
    }

    /// The first part of a stroke, as far as it had been drawn.
    static func partial(_ stroke: PKStroke, fraction: Double) -> PKStroke? {
        let points = Array(stroke.path)
        let count = Int((Double(points.count) * fraction).rounded(.down))
        guard count >= 2 else { return nil }
        let path = PKStrokePath(controlPoints: Array(points.prefix(count)), creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }

    static func export(_ input: NotebookExporter.Input, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        guard let page = input.pages.first else { throw Failure.noInk }
        let ink = input.ink(for: page)
        let plan = Plan(drawing: ink)
        guard !plan.spans.isEmpty else { throw Failure.noInk }

        return try await ExportFolder.make(.export) { directory in
            let url = directory.appending(path: NotebookExporter.fileName(input.title, extension: "mp4"))
            try await film(page, ink: ink, plan: plan, assets: input.package.assetsDirectory, links: LinkTitles(pages: input.allPages), to: url, progress: progress)
            return url
        }
    }

    private static func film(_ page: NotebookPage, ink: PKDrawing, plan: Plan, assets: URL, links: LinkTitles, to url: URL,
                             progress: @escaping @Sendable (Double) async -> Void) async throws {
        let page = Whiteboard.whole(page, ink: ink)
        let (width, height) = frameSize(for: page.size)
        let size = CGSize(width: width, height: height), scale = size.width / page.size.width
        let pageRect = page.inkRect, whole = CGRect(origin: .zero, size: size)
        let appearance = UITraitCollection(userInterfaceStyle: page.effectivePaperColor.inkAppearance)
        let onDark = page.effectivePaperColor.isDark

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 4],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(video) else { throw Failure.writer((Device.isMac
            ? String(localized: "this Mac can't encode it")
            : String(localized: "this iPad can't encode it"))) }
        writer.add(video)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)

        let space = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let base = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmap) else {
            throw Failure.writer("")
        }
        let format = UIGraphicsImageRendererFormat(scale: 1, opaque: true)
        let paper = UIGraphicsImageRenderer(size: size, format: format).image { context in
            PageRenderer.drawBackground(page, assets: assets, in: context.cgContext, size: size, links: links)
        }
        if let image = paper.cgImage { base.draw(image, in: whole) }
        var tape: CGImage?
        if page.hasItems, page.items.contains(where: \.isOverInk) {
            format.opaque = false
            tape = UIGraphicsImageRenderer(size: size, format: format).image { context in
                PageRenderer.drawOverInk(page, assets: assets, in: context.cgContext, size: size)
            }.cgImage
        }

        /// One stroke as a picture, and where it goes in a frame, whose rows run up from the bottom.
        func picture(of stroke: PKStroke) -> (image: CGImage, rect: CGRect, multiplies: Bool)? {
            let bounds = stroke.renderBounds.insetBy(dx: -2, dy: -2).integral.intersection(pageRect)
            guard !bounds.isNull, !bounds.isEmpty else { return nil }
            var image: UIImage?
            appearance.performAsCurrent { image = PKDrawing(strokes: [stroke]).image(from: bounds, scale: scale) }
            guard let cgImage = image?.cgImage else { return nil }
            let rect = CGRect(x: (bounds.minX - pageRect.minX) * scale, y: size.height - (bounds.maxY - pageRect.minY) * scale,
                              width: bounds.width * scale, height: bounds.height * scale)
            return (cgImage, rect, stroke.ink.inkType == .marker && !onDark)
        }

        func paint(_ picture: (image: CGImage, rect: CGRect, multiplies: Bool), on context: CGContext) {
            context.setBlendMode(picture.multiplies ? .multiply : .normal)
            context.draw(picture.image, in: picture.rect)
            context.setBlendMode(.normal)
        }

        var baseImage = base.makeImage()
        var finished = 0
        let total = plan.frameCount, holdFrames = Int(hold * Double(framesPerSecond)), frames = total + holdFrames
        let strokes = ink.strokes

        do {
            for frame in 0..<frames {
                try Task.checkCancellation()
                while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
                var partial: (image: CGImage, rect: CGRect, multiplies: Bool)?
                if frame < total {
                    let state = plan.state(at: Double(frame) / Double(framesPerSecond))
                    if state.finished > finished {
                        for span in plan.spans[finished..<state.finished] {
                            autoreleasepool { if let done = picture(of: strokes[span.stroke]) { paint(done, on: base) } }
                        }
                        finished = state.finished
                        baseImage = base.makeImage()
                    }
                    if state.finished < plan.spans.count, let stroke = Self.partial(strokes[plan.spans[state.finished].stroke], fraction: state.partial) {
                        partial = autoreleasepool { picture(of: stroke) }
                    }
                } else if frame == total {
                    // The finished page is drawn from the whole drawing, the way every other export draws it.
                    if let image = paper.cgImage { base.draw(image, in: whole) }
                    for run in PageRenderer.inkRuns(ink, within: pageRect, multiplying: !onDark) {
                        autoreleasepool {
                            var page: UIImage?
                            appearance.performAsCurrent { page = run.ink.image(from: pageRect, scale: scale) }
                            if let image = page?.cgImage { paint((image, whole, run.multiplies), on: base) }
                        }
                    }
                    baseImage = base.makeImage()
                }

                guard let pool = adaptor.pixelBufferPool else { throw Failure.writer(writer.error?.localizedDescription ?? "") }
                var made: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
                guard let buffer = made else { throw Failure.writer("") }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space, bitmapInfo: bitmap) {
                    if let baseImage { context.draw(baseImage, in: whole) }
                    if let partial { paint(partial, on: context) }
                    if let tape { context.draw(tape, in: whole) }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond))) else {
                    throw Failure.writer(writer.error?.localizedDescription ?? "")
                }
                if frame % 5 == 0 { await progress(Double(frame + 1) / Double(frames)) }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(framesPerSecond)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "") }
        await progress(1)
    }
}
