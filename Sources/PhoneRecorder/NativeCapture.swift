@preconcurrency import AVFoundation
import ScreenCaptureKit

final class PreviewCapture: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "org.buddytools.BuddyCam.capture", qos: .userInitiated)
    private var started: CheckedContinuation<Date, Error>?
    private var stopped: CheckedContinuation<Void, Error>?
    private let callbackLock = NSLock()
    private var unexpectedStop: ((Error?) -> Void)?
    var onUnexpectedStop: ((Error?) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return unexpectedStop }
        set { callbackLock.lock(); defer { callbackLock.unlock() }; unexpectedStop = newValue }
    }

    func select(_ device: AVCaptureDevice?) {
        queue.async {
            guard !self.movie.isRecording else { return }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if self.session.canSetSessionPreset(.hd1920x1080) { self.session.sessionPreset = .hd1920x1080 }
            if let device, let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if self.session.canAddOutput(self.movie) { self.session.addOutput(self.movie) }
            self.session.commitConfiguration()
            if !self.session.isRunning, !self.session.inputs.isEmpty { self.session.startRunning() }
        }
    }

    func startRecording(to url: URL, microphone: AVCaptureDevice?) async throws -> Date {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    do {
                        self.session.beginConfiguration()
                        defer { self.session.commitConfiguration() }
                        for input in self.session.inputs where input.ports.contains(where: { $0.mediaType == .audio }) {
                            self.session.removeInput(input)
                        }
                        if let microphone {
                            let audio = try AVCaptureDeviceInput(device: microphone)
                            guard self.session.canAddInput(audio) else { throw CaptureError.message("Cannot use the selected microphone.") }
                            self.session.addInput(audio)
                        }
                    }
                    if let camera = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) })?.device,
                       camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                        try camera.lockForConfiguration()
                        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        camera.unlockForConfiguration()
                    }
                    if let connection = self.movie.connection(with: .video) {
                        self.movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                    }
                    if !self.session.isRunning { self.session.startRunning() }
                    self.started = continuation
                    self.queue.async { self.movie.startRecording(to: url, recordingDelegate: self) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.movie.isRecording else { continuation.resume(); return }
                self.stopped = continuation
                self.movie.stopRecording()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let date = Date()
        queue.async { self.started?.resume(returning: date); self.started = nil }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            let failure = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true ? nil : error
            if let started = self.started {
                started.resume(throwing: failure ?? CaptureError.message("The camera did not start recording."))
                self.started = nil
            } else if let stopped = self.stopped {
                if let failure { stopped.resume(throwing: failure) } else { stopped.resume() }
                self.stopped = nil
            } else { self.onUnexpectedStop?(failure) }
        }
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
final class ScreenCapture: NSObject, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var started: CheckedContinuation<Date, Error>?
    private var stopped: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var ended = false

    func start(displayID: CGDirectDisplayID, file: URL) async throws -> Date {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.message("The selected display is disconnected.")
        }
        let config = SCStreamConfiguration()
        let scale = min(1, 1920.0 / Double(display.width))
        config.width = Int(Double(display.width) * scale) / 2 * 2
        config.height = Int(Double(display.height) * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = file
        recordingConfig.videoCodecType = .h264
        recordingConfig.outputFileType = .mp4
        let recording = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        try stream.addRecordingOutput(recording)
        self.stream = stream
        self.recording = recording
        return try await withCheckedThrowingContinuation { continuation in
            started = continuation
            Task {
                do { try await stream.startCapture() }
                catch { self.started?.resume(throwing: error); self.started = nil }
            }
        }
    }

    func stop() async throws {
        if let failure { throw failure }
        guard let stream, !ended else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stopped = continuation
            Task {
                do { try await stream.stopCapture() }
                catch { self.stopped?.resume(throwing: error); self.stopped = nil }
            }
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let date = Date()
        Task { @MainActor in self.started?.resume(returning: date); self.started = nil }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.ended = true; self.stopped?.resume(); self.stopped = nil }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.failure = error
            self.started?.resume(throwing: error); self.started = nil
            self.stopped?.resume(throwing: error); self.stopped = nil
        }
    }
}
