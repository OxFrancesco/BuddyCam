import AVFoundation
import AppKit
import CoreVideo
import ImageIO
import Observation
import QuartzCore

// Receives a motion JPEG stream over HTTP (multipart/x-mixed-replace), the
// format IP Webcam, DroidCam and most Android camera apps serve. Decoding
// always takes the newest frame so latency stays bounded when the network
// stutters, which keeps WiFi and Tailscale links feeling like a cable.
// URLSession splits multipart/x-mixed-replace itself: the stream response
// arrives once, then every part arrives as its own response followed by the
// part body. Bodies are emitted when their declared length arrives, or by
// scanning for JPEG SOI/EOI markers when parts carry no length.
final class MJPEGStream: NSObject, URLSessionDataDelegate {
    enum Event {
        case connected
        case failed(String)
        case closed
    }

    private let queue = DispatchQueue(label: "org.buddytools.BuddyCam.mjpeg", qos: .userInitiated)
    private let soi = Data([0xFF, 0xD8])
    private let eoi = Data([0xFF, 0xD9])
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var frameBuffer = Data()
    private var frameExpected: Int64 = -1
    private var sawHead = false
    private var pendingJPEG: Data?
    private var decoding = false
    private var stopped = false

    var onFrame: (@Sendable (CGImage) -> Void)?
    var onEvent: (@Sendable (Event) -> Void)?

    func start(url: URL) {
        queue.async { self.startLocked(url: url) }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.stopLocked()
        }
    }

    private func startLocked(url: URL) {
        stopLocked()
        stopped = false
        frameBuffer.removeAll(keepingCapacity: true)
        frameExpected = -1
        sawHead = false
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = false
        config.allowsExpensiveNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("multipart/x-mixed-replace, image/*", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    private func stopLocked() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let contentType = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !sawHead {
            guard contentType.contains("multipart") || contentType.hasPrefix("image/") else {
                completionHandler(.cancel)
                onEvent?(.failed("The stream is not motion JPEG. Use the camera app's MJPEG endpoint, like /video."))
                return
            }
            sawHead = true
            completionHandler(.allow)
            onEvent?(.connected)
            if contentType.contains("multipart") { return }
        }
        // A part response in a split multipart stream, or a still image.
        let expected = response.expectedContentLength
        queue.async {
            self.flush()
            self.frameExpected = expected
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            self.frameBuffer.append(data)
            if self.frameExpected > 0, self.frameBuffer.count >= self.frameExpected {
                self.flush()
                self.frameExpected = -1
            } else if self.frameExpected <= 0 {
                self.scanFrames()
            }
            if self.frameBuffer.count > 32 * 1024 * 1024 { self.frameBuffer.removeAll(keepingCapacity: false) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            guard !self.stopped else { return }
            if let error {
                self.onEvent?(.failed(error.localizedDescription))
            } else {
                self.onEvent?(.closed)
            }
        }
    }

    private func flush() {
        guard !frameBuffer.isEmpty else { return }
        let data = frameBuffer
        frameBuffer.removeAll(keepingCapacity: true)
        emit(data)
    }

    private func scanFrames() {
        while true {
            guard let start = frameBuffer.range(of: soi) else { return }
            guard let end = frameBuffer.range(of: eoi, in: start.upperBound..<frameBuffer.endIndex) else {
                if start.lowerBound > frameBuffer.startIndex { frameBuffer = frameBuffer[start.lowerBound...] }
                return
            }
            emit(Data(frameBuffer[start.lowerBound..<end.upperBound]))
            frameBuffer = frameBuffer[end.upperBound...]
        }
    }

    private func emit(_ data: Data) {
        guard data.count > 100 else { return }
        pendingJPEG = data
        pump()
    }

    private func pump() {
        guard !decoding, let data = pendingJPEG else { return }
        decoding = true
        pendingJPEG = nil
        queue.async {
            let image = CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            self.decoding = false
            if let image { self.onFrame?(image) }
            self.pump()
        }
    }
}

// Writes decoded frames to a .mov with real arrival timestamps so export sees
// a normal H.264 file, identical in shape to the USB camera's output.
final class VideoSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.buddytools.BuddyCam.sink", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private var startTime: CFTimeInterval?
    private var finished = false

    init(url: URL, size: CGSize) throws {
        self.size = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw CaptureError.message("Cannot write the network camera video track.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.message("Cannot start the video writer.") }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage) {
        queue.async {
            guard !self.finished else { return }
            let now = CACurrentMediaTime()
            let origin = self.startTime ?? now
            self.startTime = origin
            guard self.input.isReadyForMoreMediaData, let pool = self.adaptor.pixelBufferPool else { return }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { return }
            CVPixelBufferLockBaseAddress(pixel, [])
            defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixel),
                width: Int(self.size.width),
                height: Int(self.size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(origin: .zero, size: self.size))
            let pts = CMTime(seconds: now - origin, preferredTimescale: 600)
            self.adaptor.append(pixel, withPresentationTime: pts)
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.finished = true
                self.input.markAsFinished()
                self.writer.finishWriting {
                    if let error = self.writer.error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }
}

final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VideoSink?
    var sink: VideoSink? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

@MainActor @Observable
final class NetworkCamera {
    enum State: Equatable {
        case off, connecting, live, reconnecting
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var fps = 0
    private(set) var frameSize = CGSize.zero
    private(set) var errorDetail: String?
    var latestFrame: CGImage?

    private var stream: MJPEGStream?
    private var url: URL?
    private let sinkBox = SinkBox()
    private var reconnectTask: Task<Void, Never>?
    private var retryDelay: Double = 1
    private var frameTimes: [CFAbsoluteTime] = []

    var statusText: String {
        switch state {
        case .off: return "Off"
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .reconnecting: return "Reconnecting"
        case .failed(let message): return message
        }
    }

    var detailText: String {
        switch state {
        case .live:
            return "\(Int(frameSize.width))×\(Int(frameSize.height)) · \(fps) fps"
        case .reconnecting:
            return errorDetail ?? ""
        default:
            return ""
        }
    }

    func connect(urlString: String) {
        reconnectTask?.cancel()
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { disconnect(); return }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: candidate), url.host != nil else {
            stream?.stop(); stream = nil
            state = .failed("Enter a valid stream address, like 192.168.1.10:8080/video.")
            return
        }
        if url == self.url, state == .live || state == .connecting { return }
        start(url)
    }

    func disconnect() {
        reconnectTask?.cancel()
        stream?.stop()
        stream = nil
        state = .off
        fps = 0
        errorDetail = nil
    }

    private func start(_ url: URL) {
        self.url = url
        state = .connecting
        errorDetail = nil
        retryDelay = 1
        let stream = MJPEGStream()
        stream.onFrame = { [weak self] image in
            self?.sinkBox.sink?.append(image)
            Task { @MainActor in self?.didFrame(image) }
        }
        stream.onEvent = { [weak self] event in
            Task { @MainActor in self?.didEvent(event) }
        }
        self.stream = stream
        stream.start(url: url)
    }

    private func didFrame(_ image: CGImage) {
        latestFrame = image
        frameSize = CGSize(width: image.width, height: image.height)
        let now = CFAbsoluteTimeGetCurrent()
        frameTimes.append(now)
        frameTimes = frameTimes.filter { now - $0 < 2 }
        fps = frameTimes.count / 2
    }

    private func didEvent(_ event: MJPEGStream.Event) {
        switch event {
        case .connected:
            state = .live
            retryDelay = 1
        case .closed:
            scheduleRetry()
        case .failed(let message):
            errorDetail = message
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard stream != nil, state != .off else { return }
        state = .reconnecting
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let url = self.url, !Task.isCancelled else { return }
            self.start(url)
        }
    }

    func startRecording(to file: URL) throws -> Date {
        guard state == .live, latestFrame != nil, frameSize.width > 0 else {
            throw CaptureError.message("The network camera is not connected.")
        }
        sinkBox.sink = try VideoSink(url: file, size: frameSize)
        return Date()
    }

    func stopRecording() async throws {
        let sink = sinkBox.sink
        sinkBox.sink = nil
        try await sink?.finish()
    }
}
