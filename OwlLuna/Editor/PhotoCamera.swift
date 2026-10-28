import SwiftUI
import AVFoundation
import AVKit
import ImageIO

/// The camera kept open for photo after photo. Each one goes straight onto the page with no step to look it over;
/// it is moved, sized and turned there afterwards.
struct PhotoCamera: View {
    let take: (Data) -> Void
    let done: () -> Void

    @State private var feed = CameraFeed()
    @State private var flash = false
    @State private var zoomFrom: CGFloat?
    @Environment(\.openURL) private var openURL

    static var isAvailable: Bool {
        #if DEBUG
        if LaunchOptions.arguments.contains("-fakeCamera") { return true }
        #endif
        return hasCamera
    }

    private static let hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            let stack = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                viewfinder
                controls(wide: wide)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onCameraCaptureEvent { event in
            if event.phase == .ended { shoot() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: feed.taken)
        .onChange(of: feed.taken) { _, count in
            AccessibilityNotification.Announcement(String(localized: "\(count) photos on the page")).post()
        }
        .task {
            feed.onPhoto = take
            await feed.start()
        }
        .onDisappear { feed.stop() }
    }

    // MARK: Viewfinder

    @ViewBuilder
    private var viewfinder: some View {
        ZStack {
            switch feed.state {
            case .denied:
                blocked("OwlLuna can't use the camera", "Turn on Camera for OwlLuna in Settings to take photos for your pages.", settings: true)
            case .failed:
                blocked("The camera couldn't start", "Close the camera and try again.", settings: false)
            case .starting, .running, .paused:
                preview
                    .overlay { Color.white.opacity(flash ? 0.5 : 0).allowsHitTesting(false) }
                    .overlay(alignment: .bottom) { zoomPlate }
                    .overlay { if feed.state == .paused { pausedPlate } }
                    .contentShape(Rectangle())
                    .gesture(zoomGesture)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var preview: some View {
        #if DEBUG
        if feed.isFake {
            Image(uiImage: FakeCamera.frame(feed.taken + 1)).resizable().scaledToFit().scaleEffect(feed.zoom)
        } else {
            CameraPreview(feed: feed)
        }
        #else
        CameraPreview(feed: feed)
        #endif
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let from = zoomFrom ?? feed.zoom
                zoomFrom = from
                feed.setZoom(from * value.magnification)
            }
            .onEnded { _ in zoomFrom = nil }
    }

    @ViewBuilder
    private var zoomPlate: some View {
        if feed.zoom > 1.01 {
            Button { withAnimation(Motion.quick) { feed.setZoom(1) } } label: {
                Text(verbatim: Double(feed.zoom).formatted(.number.precision(.fractionLength(1))) + "×")
                    .monospacedDigit()
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Space.x3)
            .frame(minWidth: 56, minHeight: 36)
            .background(.black.opacity(0.55), in: RoundedRectangle.plate)
            .overlay { RoundedRectangle.plate.strokeBorder(.white.opacity(0.35), lineWidth: 1) }
            .padding(Space.x4)
            .accessibilityLabel("Zoom")
            .accessibilityHint("Goes back to no zoom")
        }
    }

    private var pausedPlate: some View {
        Text("The camera is paused")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Space.x4)
            .padding(.vertical, Space.x2)
            .background(.black.opacity(0.65), in: RoundedRectangle.plate)
    }

    private func blocked(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, settings: Bool) -> some View {
        VStack(spacing: Space.x3) {
            Image(systemName: "camera")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            if settings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.owlLuna(.secondary))
                    .padding(.top, Space.x2)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 360)
        .padding(Space.x6)
    }

    // MARK: Controls

    private func controls(wide: Bool) -> some View {
        let stack = wide ? AnyLayout(VStackLayout(spacing: Space.x4)) : AnyLayout(HStackLayout(spacing: Space.x4))
        return stack {
            Group { if wide { doneButton } else { tally } }
                .frame(width: wide ? nil : 120, height: wide ? 96 : nil)
            Spacer(minLength: 0)
            shutter
            Spacer(minLength: 0)
            Group { if wide { tally } else { doneButton } }
                .frame(width: wide ? nil : 120, height: wide ? 96 : nil)
        }
        .padding(Space.x6)
        .frame(width: wide ? 160 : nil, height: wide ? nil : 136)
        .frame(maxWidth: wide ? nil : .infinity, maxHeight: wide ? .infinity : nil)
    }

    private var doneButton: some View {
        Button("Done", action: done)
            .buttonStyle(.owlLuna(.primary))
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("camera.done")
    }

    private var shutter: some View {
        Button(action: shoot) {
            Color.clear.frame(width: 76, height: 76)
        }
        .buttonStyle(ShutterStyle())
        .disabled(feed.state != .running)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel("Take Photo")
        .accessibilityIdentifier("camera.shutter")
    }

    @ViewBuilder
    private var tally: some View {
        if let shot = feed.lastShot {
            Image(decorative: shot.image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle.thumb)
                .overlay { RoundedRectangle.thumb.strokeBorder(.white.opacity(0.9), lineWidth: 2) }
                .overlay(alignment: .topTrailing) {
                    Text(feed.taken, format: .number)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.onPrimaryCloth)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 20)
                        .background(Color.primaryCloth, in: RoundedRectangle.thumb)
                        .offset(x: 8, y: -8)
                }
                .id(feed.taken)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityElement()
                .accessibilityLabel(Text("\(feed.taken) photos on the page"))
        } else {
            Text("Each photo goes straight onto the page.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shoot() {
        guard feed.shoot() else { return }
        withAnimation(.linear(duration: 0.04)) { flash = true } completion: {
            withAnimation(.easeOut(duration: 0.22)) { flash = false }
        }
    }
}

/// A square shutter in a ring, pressed in a little while held.
private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Shutter(configuration: configuration)
    }

    private struct Shutter: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous)
                        .fill(.white.opacity(pressed ? 0.7 : 1))
                        .padding(7)
                        .scaleEffect(pressed && !reduceMotion ? 0.9 : 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.sheet + 6, style: .continuous)
                        .strokeBorder(.white, lineWidth: 3)
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .animation(Motion.quick, value: pressed)
        }
    }
}

// MARK: - Feed

/// What the camera screen shows: whether the camera is working, how far it is zoomed, and what it has taken.
@MainActor @Observable
final class CameraFeed {
    enum State { case starting, running, paused, denied, failed }

    private(set) var state = State.starting
    private(set) var zoom: CGFloat = 1
    private(set) var taken = 0
    private(set) var lastShot: SharedImage?
    @ObservationIgnored var onPhoto: ((Data) -> Void)?
    @ObservationIgnored let engine = CameraEngine()
    @ObservationIgnored var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var maxZoom: CGFloat = 1
    @ObservationIgnored private var shooting = 0
    @ObservationIgnored private var watchers: [any NSObjectProtocol] = []
    #if DEBUG
    let isFake = LaunchOptions.arguments.contains("-fakeCamera")
    #endif

    func start() async {
        #if DEBUG
        if isFake { maxZoom = 4; state = .running; return }
        #endif
        var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard allowed else { state = .denied; return }
        watch()
        guard let most = await engine.start() else { state = .failed; return }
        maxZoom = most
        if state == .starting { state = .running }
    }

    func stop() {
        for watcher in watchers { NotificationCenter.default.removeObserver(watcher) }
        watchers = []
        engine.stop()
    }

    func setZoom(_ factor: CGFloat) {
        zoom = min(max(factor, 1), maxZoom)
        engine.zoom(to: zoom)
    }

    /// Takes a photo unless the camera isn't ready or a few are still being made.
    func shoot() -> Bool {
        guard state == .running, shooting < 4 else { return false }
        shooting += 1
        #if DEBUG
        if isFake {
            let data = FakeCamera.photo(taken + shooting)
            Task { self.delivered(data, CameraEngine.thumbnail(data)) }
            return true
        }
        #endif
        engine.shoot(angle: rotation?.videoRotationAngleForHorizonLevelCapture) { [weak self] data, thumbnail in
            Task { @MainActor in self?.delivered(data, thumbnail) }
        }
        return true
    }

    private func delivered(_ data: Data?, _ thumbnail: SharedImage?) {
        shooting -= 1
        guard let data else { return }
        withAnimation(Motion.ribbon) {
            taken += 1
            lastShot = thumbnail ?? lastShot
        }
        onPhoto?(data)
    }

    private func watch() {
        let centre = NotificationCenter.default, session = engine.session
        watchers = [
            centre.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.state == .running { self?.state = .paused } }
            },
            centre.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.state == .paused { self?.state = .running } }
            },
            centre.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.state = .failed }
            },
        ]
    }
}

// MARK: - Engine

/// The capture session, worked on a queue of its own.
final class CameraEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private(set) var device: AVCaptureDevice?
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "OwlLuna.camera")
    private var shots: [Int64: Shot] = [:]

    /// Sets the camera up the first time and starts it. The most it zooms, or nil when it couldn't start.
    func start() async -> CGFloat? {
        await withCheckedContinuation { done in
            queue.async { [self] in
                guard device != nil || configure(), let device else { return done.resume(returning: nil) }
                session.startRunning()
                done.resume(returning: session.isRunning ? max(1, min(device.activeFormat.videoMaxZoomFactor, 6)) : nil)
            }
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    func zoom(to factor: CGFloat) {
        queue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = min(factor, device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        }
    }

    /// `delivered` gets the photo as its file has it and a small picture of it, or nothing when it failed.
    func shoot(angle: CGFloat?, delivered: @escaping @Sendable (Data?, SharedImage?) -> Void) {
        queue.async { [self] in
            guard session.isRunning else { return delivered(nil, nil) }
            if let angle, let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            let shot = Shot { [weak self] id, data in
                if let self { queue.async { self.shots[id] = nil } }
                delivered(data, data.flatMap(Self.thumbnail))
            }
            shots[settings.uniqueID] = shot
            output.capturePhoto(with: settings, delegate: shot)
        }
    }

    static func thumbnail(_ data: Data) -> SharedImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return SharedImage(image: image)
    }

    private func configure() -> Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
        device = camera
        return true
    }

    private final class Shot: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        let finished: (Int64, Data?) -> Void

        init(finished: @escaping (Int64, Data?) -> Void) { self.finished = finished }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
            finished(photo.resolvedSettings.uniqueID, error == nil ? photo.fileDataRepresentation() : nil)
        }
    }
}

// MARK: - Preview

private struct CameraPreview: UIViewRepresentable {
    let feed: CameraFeed

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.preview.session = feed.engine.session
        view.preview.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if feed.state == .running, feed.rotation == nil, let device = feed.engine.device {
            feed.rotation = view.follow(device)
        }
    }
}

/// Keeps the picture upright however the iPad is held.
private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var turning: NSKeyValueObservation?

    func follow(_ device: AVCaptureDevice) -> AVCaptureDevice.RotationCoordinator {
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        turn(rotation.videoRotationAngleForHorizonLevelPreview)
        turning = Self.watch(rotation) { [weak self] angle in
            Task { @MainActor in self?.turn(angle) }
        }
        return rotation
    }

    private func turn(_ angle: CGFloat) {
        guard let connection = preview.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private nonisolated static func watch(_ rotation: AVCaptureDevice.RotationCoordinator,
                                          turned: @escaping @Sendable (CGFloat) -> Void) -> NSKeyValueObservation {
        rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { rotation, _ in
            turned(rotation.videoRotationAngleForHorizonLevelPreview)
        }
    }
}

#if DEBUG
/// `-fakeCamera` stands in for the camera a simulator doesn't have: a numbered slide on a desk.
enum FakeCamera {
    static func frame(_ number: Int) -> UIImage {
        UIImage(data: photo(number)) ?? UIImage()
    }

    static func photo(_ number: Int) -> Data {
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat(scale: 1)
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor(red: 0.36, green: 0.3, blue: 0.26, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.97, alpha: 1).setFill()
            context.fill(CGRect(x: 160, y: 130, width: 1280, height: 940))
            ("Slide \(number)" as NSString).draw(at: CGPoint(x: 240, y: 220),
                                                 withAttributes: [.font: UIFont.systemFont(ofSize: 96, weight: .bold), .foregroundColor: UIColor.black])
            for line in 0..<4 {
                UIColor(white: 0.55, alpha: 1).setFill()
                context.fill(CGRect(x: 240, y: 420 + CGFloat(line) * 130, width: 1120 - CGFloat(line % 2) * 260, height: 34))
            }
        }
    }
}
#endif
