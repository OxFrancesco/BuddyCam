import SwiftUI
import AVFoundation
import AppKit
import CoreImage

@main
struct PhoneRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var recorder = Recorder()

    init() {
        Fonts.register()
    }

    var body: some Scene {
        Window("BuddyCam", id: "recorder") {
            RecorderView(recorder: recorder)
                .onOpenURL { url in Task { await recorder.handleURL(url) } }
                .task {
                    delegate.recorder = recorder
                    await recorder.prepare()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: Recorder?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder, recorder.busy else { return .terminateNow }
        recorder.quitAfterSaving = true
        recorder.stop()
        return .terminateLater
    }
}

struct RecorderView: View {
    @Bindable var recorder: Recorder
    @State private var linkQRPresented = false

    private var canRecord: Bool {
        switch recorder.source {
        case .usb: return !recorder.cameraID.isEmpty
        case .link: return recorder.link.state == .live
        case .network: return !recorder.networkURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            preview
            controls
            if let error = recorder.error {
                MonoText(error, size: 12, color: Theme.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(24)
        .frame(width: 648)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.primary)
        .onChange(of: recorder.cameraID) { recorder.changePreview() }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("BUDDYCAM")
                    .font(Fonts.display(20)).fontWeight(.black).tracking(-0.4)
                    .foregroundStyle(Theme.foreground)
                Rectangle().fill(Theme.primary).frame(width: 64, height: 4)
            }
            Spacer()
            SegmentedControl(
                options: [("USB", CameraSource.usb), ("Link", CameraSource.link), ("Stream", CameraSource.network)],
                selection: $recorder.source,
                height: 28
            )
            .frame(width: 270)
            .disabled(recorder.busy)
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            // The USB preview layer stays mounted in every mode: letting the
            // AVCaptureVideoPreviewLayer deallocate while the capture queue is
            // mid-configuration deadlocks the session lock against the main thread.
            CameraPreview(session: recorder.preview.session)
                .frame(width: recorder.rotation % 180 == 0 ? recorder.format.previewWidth : 342,
                       height: recorder.rotation % 180 == 0 ? 342 : recorder.format.previewWidth)
                .rotationEffect(.degrees(Double(recorder.rotation)))
                .opacity(recorder.source == .usb ? 1 : 0)
            if recorder.source == .link {
                NetworkPreview(frame: recorder.link.feed.latestFrame)
                    .frame(width: recorder.rotation % 180 == 0 ? recorder.format.previewWidth : 342,
                           height: recorder.rotation % 180 == 0 ? 342 : recorder.format.previewWidth)
                    .rotationEffect(.degrees(Double(recorder.rotation)))
            }
            if recorder.source == .network {
                NetworkPreview(frame: recorder.network.feed.latestFrame)
                    .frame(width: recorder.rotation % 180 == 0 ? recorder.format.previewWidth : 342,
                           height: recorder.rotation % 180 == 0 ? 342 : recorder.format.previewWidth)
                    .rotationEffect(.degrees(Double(recorder.rotation)))
            }

            previewOverlay
        }
        .frame(width: recorder.format.previewWidth, height: 342)
        .frame(maxWidth: .infinity)
        .brutalOutline(3)
        .accessibilityLabel("Camera preview")
    }

    @ViewBuilder private var previewOverlay: some View {
        switch recorder.source {
        case .usb:
            if recorder.cameras.isEmpty {
                PreviewState(title: "Connect your phone", detail: "USB cable · choose Webcam on the phone")
            }
        case .link:
            switch recorder.link.state {
            case .preparing:
                PreviewState(title: "Preparing link", detail: "Certificate and server starting")
            case .waiting:
                LinkQRState(url: recorder.link.url, trusted: recorder.link.trusted)
            case .live:
                EmptyView()
            case .failed(let message):
                PreviewState(title: "Link failed", detail: message)
            case .off:
                PreviewState(title: "Link off", detail: "")
            }
        case .network:
            switch recorder.network.state {
            case .live:
                EmptyView()
            case .connecting:
                PreviewState(title: "Connecting", detail: recorder.networkURL)
            case .reconnecting:
                PreviewState(title: "Reconnecting", detail: recorder.network.errorDetail ?? "Stream interrupted")
            case .failed(let message):
                PreviewState(title: "Stream failed", detail: message)
            case .off:
                PreviewState(title: "Enter stream address", detail: "IP Webcam or DroidCam /video URL · LAN or Tailscale IP")
            }
        }
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow(alignment: .center) {
                FieldLabel("Record")
                SegmentedControl(
                    options: [("Camera only", RecordingMode.camera), ("Screen + camera", RecordingMode.screen)],
                    selection: $recorder.mode
                )
            }
            GridRow(alignment: .center) {
                FieldLabel("Format")
                SegmentedControl(
                    options: RecordingFormat.allCases.map { ($0.rawValue, $0) },
                    selection: $recorder.format
                )
                .frame(maxWidth: 320)
            }
            if recorder.source == .usb {
                GridRow(alignment: .center) {
                    FieldLabel("Camera")
                    HStack(spacing: 8) {
                        MenuField(value: recorder.cameras.first { $0.uniqueID == recorder.cameraID }?.localizedName ?? "",
                                  placeholder: "No camera connected") {
                            ForEach(recorder.cameras, id: \.uniqueID) { device in
                                Button(device.localizedName) { recorder.cameraID = device.uniqueID }
                            }
                        }
                        Button { recorder.rotate() } label: {
                            Image(systemName: "rotate.right")
                        }
                        .buttonStyle(BrutalButtonStyle(height: 36))
                        .frame(width: 36)
                        .help("Rotate preview and recording 90° clockwise")
                        .accessibilityLabel("Rotate")
                    }
                }
            } else if recorder.source == .link {
                GridRow(alignment: .center) {
                    FieldLabel("Link")
                    HStack(spacing: 8) {
                        MonoText(recorder.link.url.isEmpty ? "Preparing…" : recorder.link.url, size: 11, color: Theme.foreground.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button { linkQRPresented = true } label: {
                            Image(systemName: "qrcode")
                        }
                        .buttonStyle(BrutalButtonStyle(height: 36))
                        .frame(width: 36)
                        .help("Show the QR code")
                        .accessibilityLabel("QR code")
                        .disabled(recorder.link.url.isEmpty)
                        .popover(isPresented: $linkQRPresented, arrowEdge: .bottom) {
                            VStack(spacing: 12) {
                                QRCodeImage(text: recorder.link.url)
                                    .frame(width: 200, height: 200)
                                    .padding(16)
                                    .background(Color.white)
                                    .brutalOutline(3)
                                Text(recorder.link.url)
                                    .font(Fonts.mono(10))
                                    .foregroundStyle(Theme.foreground.opacity(0.7))
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(20)
                            .background(Theme.background)
                            .preferredColorScheme(.dark)
                        }
                        Button { recorder.rotate() } label: {
                            Image(systemName: "rotate.right")
                        }
                        .buttonStyle(BrutalButtonStyle(height: 36))
                        .frame(width: 36)
                        .help("Rotate preview and recording 90° clockwise")
                        .accessibilityLabel("Rotate")
                    }
                }
                if !recorder.link.detailText.isEmpty {
                    GridRow(alignment: .center) {
                        FieldLabel("Feed")
                        HStack(spacing: 8) {
                            if recorder.link.state == .live { StatusDot() }
                            MonoText(recorder.link.detailText, size: 11, color: Theme.foreground.opacity(0.7))
                        }
                    }
                }
            } else {
                GridRow(alignment: .center) {
                    FieldLabel("Stream")
                    HStack(spacing: 8) {
                        BrutalField(placeholder: "http://192.168.1.10:8080/video or phone.tailnet.ts.net:8080/video", text: $recorder.networkURL)
                        Button { recorder.rotate() } label: {
                            Image(systemName: "rotate.right")
                        }
                        .buttonStyle(BrutalButtonStyle(height: 36))
                        .frame(width: 36)
                        .help("Rotate preview and recording 90° clockwise")
                        .accessibilityLabel("Rotate")
                    }
                }
                if !recorder.network.detailText.isEmpty {
                    GridRow(alignment: .center) {
                        FieldLabel("Feed")
                        HStack(spacing: 8) {
                            if recorder.network.state == .live { StatusDot() }
                            MonoText(recorder.network.detailText, size: 11, color: Theme.foreground.opacity(0.7))
                        }
                    }
                }
            }
            GridRow(alignment: .center) {
                FieldLabel("Mic")
                MenuField(value: recorder.microphones.first { $0.uniqueID == recorder.microphoneID }?.localizedName ?? "No microphone") {
                    Button("No microphone") { recorder.microphoneID = "" }
                    ForEach(recorder.microphones, id: \.uniqueID) { device in
                        Button(device.localizedName) { recorder.microphoneID = device.uniqueID }
                    }
                }
            }
            if recorder.mode == .screen {
                GridRow(alignment: .center) {
                    FieldLabel("Screen")
                    MenuField(value: recorder.screens.first { $0.id == recorder.screenIndex }?.name ?? "") {
                        ForEach(recorder.screens) { screen in
                            Button(screen.name) { recorder.screenIndex = screen.id }
                        }
                    }
                }
            }
            GridRow(alignment: .center) {
                FieldLabel("Save to")
                HStack(spacing: 8) {
                    MonoText(recorder.folder?.path ?? "Choose a folder", size: 11, color: Theme.foreground.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(recorder.folder?.path ?? "")
                    Spacer()
                    Button("Choose…") { recorder.chooseFolder() }
                        .buttonStyle(BrutalButtonStyle(height: 28))
                }
            }
        }
        .disabled(recorder.busy)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if recorder.busy {
                HStack(spacing: 10) {
                    if recorder.phase == .recording { StatusDot() }
                    MonoText(recorder.status, size: 12)
                        .monospacedDigit()
                }
            } else {
                Button("Refresh devices") { Task { await recorder.prepare() } }
                    .buttonStyle(.brutalGhost)
                if let lastFile = recorder.lastFile {
                    Button("Show recording") { NSWorkspace.shared.activateFileViewerSelecting([lastFile]) }
                        .buttonStyle(.brutalGhost)
                }
            }
            Spacer()
            if recorder.busy {
                Button(recorder.phase == .stopping ? "Saving…" : "Stop and save") { recorder.stop() }
                    .buttonStyle(.brutal)
                    .disabled(recorder.phase == .stopping)
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Start recording") { Task { await recorder.start() } }
                    .buttonStyle(.brutalFill)
                    .disabled(!canRecord)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct LinkQRState: View {
    let url: String
    let trusted: Bool
    var body: some View {
        HStack(spacing: 24) {
            QRCodeImage(text: url)
                .frame(width: 160, height: 160)
                .padding(12)
                .background(Color.white)
                .brutalOutline(3)
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Theme.primary).frame(width: 32, height: 4)
                Text("SCAN WITH YOUR PHONE")
                    .font(Fonts.mono(12)).fontWeight(.bold).tracking(1.2)
                    .foregroundStyle(Theme.foreground)
                Text(url)
                    .font(Fonts.mono(11))
                    .foregroundStyle(Theme.foreground.opacity(0.7))
                    .textSelection(.enabled)
                    .lineLimit(2)
                if !trusted {
                    Text("Accept the certificate warning once")
                        .font(Fonts.mono(10))
                        .foregroundStyle(Theme.foreground.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.opacity(0.85))
    }
}

struct PreviewState: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Rectangle().fill(Theme.primary).frame(width: 32, height: 4)
            Text(title.uppercased())
                .font(Fonts.mono(12)).fontWeight(.bold).tracking(1.2)
                .foregroundStyle(Theme.foreground)
            MonoText(detail, size: 11, color: Theme.foreground.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.opacity(0.6))
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

final class PreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

struct QRCodeImage: View {
    let text: String
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
        } else {
            Color.white
        }
    }
    private var image: CGImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

struct NetworkPreview: NSViewRepresentable {
    let frame: CGImage?
    func makeNSView(context: Context) -> FrameView { FrameView() }
    func updateNSView(_ nsView: FrameView, context: Context) { nsView.image = frame }
}

final class FrameView: NSView {
    var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = .black
    }
    required init?(coder: NSCoder) { nil }
}
