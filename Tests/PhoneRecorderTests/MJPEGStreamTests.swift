import AVFoundation
import XCTest
@testable import PhoneRecorder

// Serves a multipart/x-mixed-replace stream of generated JPEG frames on
// 127.0.0.1 so the ingest path can be tested without a phone.
private final class TestMJPEGServer {
    private var process: Process?
    let port: UInt16

    init(port: UInt16, frames: Int = 8) throws {
        self.port = port
        let jpeg = try makeTestJPEG()
        let script = """
        import socket, sys, time
        payload = sys.stdin.buffer.read()
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        while True:
            try:
                srv.bind(("127.0.0.1", \(port)))
                break
            except OSError:
                time.sleep(0.05)
        srv.listen(4)
        for _ in range(8):
            try:
                conn, _ = srv.accept()
            except OSError:
                break
            conn.settimeout(2)
            try:
                conn.recv(4096)
                conn.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Type: multipart/x-mixed-replace; boundary=frame\\r\\n\\r\\n")
                for _ in range(\(frames)):
                    conn.sendall(b"--frame\\r\\nContent-Type: image/jpeg\\r\\nContent-Length: " + str(len(payload)).encode() + b"\\r\\n\\r\\n" + payload + b"\\r\\n")
                    time.sleep(0.03)
            except OSError:
                pass
            conn.close()
        srv.close()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = ["-c", script]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(jpeg)
        try? stdin.fileHandleForWriting.close()
        self.process = process
    }

    deinit { process?.terminate() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class MJPEGStreamTests: XCTestCase {
    func testDecodesFramesFromMultipartStream() throws {
        let server = try TestMJPEGServer(port: 18321)
        let stream = MJPEGStream()
        let url = URL(string: "http://127.0.0.1:18321/video")!
        let connected = expectation(description: "connected")
        connected.assertForOverFulfill = false
        let gotFrames = expectation(description: "frames")
        gotFrames.assertForOverFulfill = false
        let frames = Counter()
        let attempts = Counter()
        stream.onEvent = { event in
            switch event {
            case .connected:
                connected.fulfill()
            case .failed, .closed:
                // The server may not be listening yet; retry like NetworkCamera does.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    if attempts.increment() < 30 { stream.start(url: url) }
                }
            }
        }
        stream.onFrame = { image in
            XCTAssertEqual(image.width, 160)
            if frames.increment() >= 3 { gotFrames.fulfill() }
        }
        stream.start(url: url)
        wait(for: [connected, gotFrames], timeout: 15)
        stream.stop()
        _ = server
    }

    func testRejectsNonMultipartResponse() throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        server.arguments = ["-c", """
        import socket
        srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 18322)); srv.listen(1)
        conn, _ = srv.accept(); conn.recv(4096)
        conn.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Type: text/plain\\r\\nContent-Length: 2\\r\\n\\r\\nhi")
        conn.close()
        """]
        try server.run()
        defer { server.terminate() }

        let stream = MJPEGStream()
        let failed = expectation(description: "failed")
        stream.onEvent = { event in
            if case .failed = event { failed.fulfill() }
        }
        stream.start(url: URL(string: "http://127.0.0.1:18322/")!)
        wait(for: [failed], timeout: 10)
        stream.stop()
    }
}
