import AppKit
import AVFoundation
import Observation

enum RecordingMode: String { case camera, screen }
enum CameraSource: String { case usb, network }
enum RecordingFormat: String, CaseIterable, Identifiable {
    case square = "1:1", portrait = "9:16", landscape = "16:9"
    var id: String { rawValue }
    var width: Int { self == .landscape ? 1920 : 1080 }
    var height: Int { self == .portrait ? 1920 : 1080 }
    var previewWidth: Double { 342 * Double(width) / Double(height) }
}
enum RecordingPhase { case idle, preparing, recording, stopping }
struct ScreenChoice: Identifiable { let id: Int; let displayID: CGDirectDisplayID; let name: String }

@MainActor @Observable
final class Recorder {
    var mode = RecordingMode(rawValue: UserDefaults.standard.string(forKey: "recordingMode") ?? "camera") ?? .camera {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "recordingMode") }
    }
    var format = RecordingFormat(rawValue: UserDefaults.standard.string(forKey: "recordingFormat") ?? "9:16") ?? .portrait {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "recordingFormat") }
    }
    var phase: RecordingPhase = .idle
    var cameras: [AVCaptureDevice] = []
    var microphones: [AVCaptureDevice] = []
    var screens: [ScreenChoice] = []
    var source = CameraSource(rawValue: UserDefaults.standard.string(forKey: "cameraSource") ?? "usb") ?? .usb {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "cameraSource")
            changePreview()
        }
    }
    var networkURL = UserDefaults.standard.string(forKey: "networkCameraURL") ?? "" {
        didSet {
            UserDefaults.standard.set(networkURL, forKey: "networkCameraURL")
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, !Task.isCancelled, self.source == .network, !self.busy else { return }
                self.network.connect(urlString: self.networkURL)
            }
        }
    }
    var cameraID = UserDefaults.standard.string(forKey: "cameraID") ?? "" {
        didSet { UserDefaults.standard.set(cameraID, forKey: "cameraID") }
    }
    var microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? "" {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID") }
    }
    var screenIndex = 0
    var rotation = UserDefaults.standard.integer(forKey: "cameraRotation")
    var folder: URL?
    var lastFile: URL?
    var error: String?
    var elapsed = 0.0
    var quitAfterSaving = false
    let preview = PreviewCapture()
    let network = NetworkCamera()
    private var reconnectTask: Task<Void, Never>?
    private var process: Process?
    private var errors: Pipe?
    private var errorBuffer = ""
    private var outputURL: URL?
    private var folderAccess = false
    private var recordingActivity: NSObjectProtocol?
    private var screenCapture: ScreenCapture?
    private var timer: Task<Void, Never>?
    private var workingDirectory: URL?
    private var rawCamera: URL?
    private var rawScreen: URL?
    private var rawAudio: URL?
    private var cameraStart = Date()
    private var screenStart = Date()
    private var expectedAudio = false
    private var cancelStart = false

    var busy: Bool { phase != .idle }
    var status: String {
        switch phase {
        case .idle: return ""
        case .preparing: return "Starting…"
        case .stopping: return "Saving…"
        case .recording:
            let seconds = Int(elapsed)
            return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "recordingFolder") {
            var stale = false
            folder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        }
    }

    func prepare() async {
        guard !busy else { return }
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            error = "Allow BuddyCam in System Settings > Privacy & Security > Camera, then refresh devices."
            return
        }
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if !cameras.contains(where: { $0.uniqueID == cameraID }) {
            cameraID = cameras.first(where: { $0.localizedName.localizedCaseInsensitiveContains("samsung") })?.uniqueID ?? cameras.first?.uniqueID ?? ""
        }
        if microphoneID.isEmpty && UserDefaults.standard.string(forKey: "microphoneID") == nil {
            microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID ?? ""
        } else if !microphones.contains(where: { $0.uniqueID == microphoneID }) {
            microphoneID = ""
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)
        screens = displayIDs.prefix(Int(count)).enumerated().map { index, displayID in
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
            return ScreenChoice(id: index, displayID: displayID, name: screen?.localizedName ?? "Screen \(index + 1)")
        }
        if !screens.contains(where: { $0.id == screenIndex }) { screenIndex = screens.first?.id ?? 0 }
        changePreview()
    }

    func changePreview() {
        guard !busy else { return }
        if source == .network {
            preview.select(nil)
            network.connect(urlString: networkURL)
        } else {
            network.disconnect()
            preview.select(cameras.first { $0.uniqueID == cameraID })
        }
    }

    func rotate() {
        rotation = (rotation + 90) % 360
        UserDefaults.standard.set(rotation, forKey: "cameraRotation")
    }

    func handleURL(_ url: URL) async {
        guard url.scheme == "buddycam" else { return }
        NSApp.activate(ignoringOtherApps: true)
        if url.host == "stop" { stop(); return }
        guard url.host == "record" else { return }
        guard !busy else { error = "A recording is already in progress."; return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let value = items.first(where: { $0.name == "mode" })?.value {
            guard let parsed = RecordingMode(rawValue: value) else { error = "Unknown recording mode."; return }
            mode = parsed
        }
        if let value = items.first(where: { $0.name == "format" })?.value {
            guard let parsed = RecordingFormat(rawValue: value) else { error = "Unknown recording format."; return }
            format = parsed
        }
        if let value = items.first(where: { $0.name == "source" })?.value {
            guard let parsed = CameraSource(rawValue: value) else { error = "Unknown camera source."; return }
            source = parsed
        }
        if let value = items.first(where: { $0.name == "camera_url" })?.value {
            networkURL = value
        }
        if let path = items.first(where: { $0.name == "folder" })?.value {
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                error = "Choose an existing recording folder."; return
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            folder = url
            if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: "recordingFolder")
            }
        }
        if cameras.isEmpty { await prepare() }
        await start()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save recordings here"
        panel.directoryURL = folder ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "recordingFolder")
        }
    }

    func start() async {
        guard !busy else { return }
        error = nil
        if folder == nil { chooseFolder() }
        guard let folder else { return }
        if source == .usb {
            guard let camera = cameras.first(where: { $0.uniqueID == cameraID }), camera.isConnected else {
                error = "Your selected camera is disconnected. Reconnect it and refresh devices."
                return
            }
        } else {
            guard !networkURL.trimmingCharacters(in: .whitespaces).isEmpty else {
                error = "Enter the camera stream address first."
                return
            }
            if network.latestFrame == nil {
                network.connect(urlString: networkURL)
                let deadline = Date().addingTimeInterval(10)
                while network.latestFrame == nil, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            guard network.latestFrame != nil else {
                error = "The network camera did not send frames. Check the stream address."
                return
            }
        }
        guard ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "FFmpeg is missing. Install it with brew install ffmpeg."
            return
        }
        phase = .preparing
        cancelStart = false
        let microphone = microphones.first { $0.uniqueID == microphoneID }
        if microphone != nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            error = "Allow BuddyCam in System Settings > Privacy & Security > Microphone, or choose No microphone."
            reset(); return
        }
        if mode == .screen, !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            error = "Allow BuddyCam in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen the app."
            reset(); return
        }
        if cancelStart { reset(); return }
        folderAccess = folder.startAccessingSecurityScopedResource()
        recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording camera and screen video")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        outputURL = folder.appendingPathComponent("\(mode == .camera ? "Camera" : "Screen and camera") \(formatter.string(from: Date())) \(UUID().uuidString.prefix(4)).mp4")
        let working = FileManager.default.temporaryDirectory.appendingPathComponent("BuddyCam-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = working
        rawCamera = working.appendingPathComponent("camera.mov")
        rawScreen = working.appendingPathComponent("screen.mp4")
        rawAudio = source == .network && microphone != nil ? working.appendingPathComponent("audio.mov") : nil
        expectedAudio = microphone != nil
        elapsed = 0
        errorBuffer = ""
        do {
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
            if mode == .screen {
                guard let screen = screens.first(where: { $0.id == screenIndex }) else { throw CaptureError.message("Select a connected screen.") }
                let capture = ScreenCapture()
                screenCapture = capture
                screenStart = try await capture.start(displayID: screen.displayID, file: rawScreen!)
            }
            preview.onUnexpectedStop = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.error = error?.localizedDescription ?? "The camera stopped recording unexpectedly."
                    self.stop()
                }
            }
            let began: Date
            if source == .network {
                if let rawAudio, let microphone {
                    _ = try await preview.startRecording(to: rawAudio, microphone: microphone)
                }
                began = try network.startRecording(to: rawCamera!)
            } else {
                began = try await preview.startRecording(to: rawCamera!, microphone: microphone)
            }
            cameraStart = began
            phase = .recording
            if cancelStart { stop(); return }
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.phase == .recording else { return }
                    self.elapsed = Date().timeIntervalSince(began)
                }
            }
        } catch {
            try? await preview.stopRecording()
            try? await screenCapture?.stop()
            self.error = error.localizedDescription
            reset()
        }
    }

    func stop() {
        guard busy, phase != .stopping else { return }
        if phase == .preparing { cancelStart = true; return }
        phase = .stopping
        timer?.cancel()
        Task {
            do {
                if source == .network { try await network.stopRecording() }
                try await preview.stopRecording()
                try await screenCapture?.stop()
                try exportRecording()
            } catch {
                self.error = "Could not finish saving. \(error.localizedDescription)\nOriginal clips are in \(workingDirectory?.path ?? "the temporary folder")."
                reset()
            }
        }
    }

    private func exportRecording() throws {
        guard let cameraFile = rawCamera, let file = outputURL else { throw CaptureError.message("Recording files are missing.") }
        let executable = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })!
        var args = ["-hide_banner", "-loglevel", "warning", "-nostdin", "-n", "-i", cameraFile.path]
        let rotationFilter: String
        switch rotation {
        case 90: rotationFilter = ",transpose=clock"
        case 180: rotationFilter = ",hflip,vflip"
        case 270: rotationFilter = ",transpose=cclock"
        default: rotationFilter = ""
        }
        let width = format.width, height = format.height
        let cameraFilter = "setpts=PTS-STARTPTS\(rotationFilter)"
        var nextInput = 1
        var audioIndex: Int?
        if let audioFile = rawAudio {
            args += ["-i", audioFile.path]
            audioIndex = nextInput
            nextInput += 1
        } else if expectedAudio {
            audioIndex = 0
        }
        if mode == .screen, let screenFile = rawScreen {
            let offset = max(0, cameraStart.timeIntervalSince(screenStart))
            let screenIndex = nextInput
            args += ["-ss", String(format: "%.6f", offset), "-i", screenFile.path,
                     "-filter_complex", "[\(screenIndex):v]setpts=PTS-STARTPTS,fps=30,scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1[screen];[0:v]\(cameraFilter),scale=\(width / 4):\(height / 4):force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1[cam];[screen][cam]overlay=W-w-24:H-h-24:shortest=1[v]", "-map", "[v]"]
        } else {
            args += ["-map", "0:v:0", "-vf", "\(cameraFilter),scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1"]
        }
        if let audioIndex { args += ["-map", "\(audioIndex):a:0", "-af", "asetpts=PTS-STARTPTS", "-c:a", "aac", "-b:a", "192k"] }
        args += ["-r", "30", "-c:v", "h264_videotoolbox", "-b:v", "8M", "-pix_fmt", "yuv420p", "-movflags", "+faststart", file.path]
        let task = Process()
        task.qualityOfService = .userInitiated
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        task.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.errorBuffer = String((self.errorBuffer + text).suffix(6000))
            }
        }
        let audio = expectedAudio
        task.terminationHandler = { [weak self] task in
            Task { @MainActor in await self?.finished(exitCode: task.terminationStatus, file: file, expectedAudio: audio) }
        }
        process = task
        errors = stderr
        try task.run()
    }

    private func finished(exitCode: Int32, file: URL, expectedAudio: Bool) async {
        let asset = AVURLAsset(url: file)
        do {
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            guard exitCode == 0, !video.isEmpty, !expectedAudio || !audio.isEmpty, duration.seconds > 0 else {
                throw CaptureError.message("The export did not produce a complete video.")
            }
            lastFile = file
            if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
        } catch {
            self.error = "Could not save the MP4. \(error.localizedDescription)\n\(String(errorBuffer.suffix(600)))\nOriginal clips are in \(workingDirectory?.path ?? "the temporary folder")."
        }
        reset()
    }

    private func reset() {
        timer?.cancel()
        timer = nil
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
        errors?.fileHandleForReading.readabilityHandler = nil
        process = nil
        errors = nil
        screenCapture = nil
        preview.onUnexpectedStop = nil
        if folderAccess { folder?.stopAccessingSecurityScopedResource(); folderAccess = false }
        phase = .idle
        if quitAfterSaving { NSApp.reply(toApplicationShouldTerminate: true) }
    }
}
