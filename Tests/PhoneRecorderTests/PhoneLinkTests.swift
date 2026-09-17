import Foundation
import XCTest
@testable import PhoneRecorder

private final class BoundPort: @unchecked Sendable { var port: UInt16 = 0 }

// Accepts the self-signed certificate the link server presents so the test
// can exercise the real TLS path.
private final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class PhoneLinkTests: XCTestCase {
    func testAcceptKeyMatchesRFC6455Example() {
        XCTAssertEqual(WebSocketFrameParser.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
                       "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testParsesMaskedBinaryFrameAcrossChunks() throws {
        let payload = Data((0..<300).map { UInt8($0 % 251) })
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        var masked = payload
        for i in masked.indices { masked[i] ^= mask[i % 4] }
        var frame = Data([0x82, 0x80 | 126, 0x01, 0x2C])
        frame.append(contentsOf: mask)
        frame.append(masked)
        var parser = WebSocketFrameParser()
        XCTAssertEqual(try parser.append(Data(frame[0..<97])), [])
        XCTAssertEqual(try parser.append(Data(frame[97..<210])), [])
        XCTAssertEqual(try parser.append(Data(frame[210...])), [.binary(payload)])
    }

    func testReassemblesFragmentsWithInterleavedPing() throws {
        let firstHalf = Data("hello ".utf8)
        let secondHalf = Data("world".utf8)
        var a = Data([0x02]) // binary, FIN clear: first fragment
        a.append(UInt8(firstHalf.count))
        a.append(firstHalf)
        var b = Data([0x89, 2]) // ping, FIN set
        b.append(contentsOf: [0x68, 0x69])
        var c = Data([0x80]) // continuation, FIN set: last fragment
        c.append(UInt8(secondHalf.count))
        c.append(secondHalf)
        var parser = WebSocketFrameParser()
        XCTAssertEqual(try parser.append(a), [])
        XCTAssertEqual(try parser.append(b + c),
                       [.ping(Data("hi".utf8)), .binary(Data("hello world".utf8))])
    }

    func testParses64BitLength() throws {
        let payload = Data((0..<70_000).map { UInt8($0 % 251) })
        var frame = Data([0x82, 0x7F])
        var length = UInt64(payload.count)
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in (0..<8).reversed() { bytes[i] = UInt8(length & 0xFF); length >>= 8 }
        frame.append(contentsOf: bytes)
        frame.append(payload)
        var parser = WebSocketFrameParser()
        XCTAssertEqual(try parser.append(frame), [.binary(payload)])
    }

    func testServesPageAndAcceptsFramesOverTLS() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuddyCamLinkTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try LinkIdentity.makeSelfSigned(directory: directory,
                                                       hosts: ["localhost"],
                                                       ips: ["127.0.0.1"])
        let server = PhoneLinkServer(identity: identity, page: PhonePage.html)
        defer { server.stop() }

        let listening = expectation(description: "listening")
        let bound = BoundPort()
        server.start(ports: [18443, 18444, 18445]) { result in
            if case .success(let port) = result { bound.port = port }
            listening.fulfill()
        }
        wait(for: [listening], timeout: 15)
        let port = bound.port
        XCTAssertNotEqual(port, 0)
        guard port != 0 else { return }

        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let pageDone = expectation(description: "page")
        session.dataTask(with: URL(string: "https://127.0.0.1:\(port)/")!) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data ?? Data(), as: UTF8.self).contains("<video"))
            pageDone.fulfill()
        }.resume()

        let missing = expectation(description: "404")
        session.dataTask(with: URL(string: "https://127.0.0.1:\(port)/nope")!) { _, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            missing.fulfill()
        }.resume()

        let connected = expectation(description: "ws client")
        server.onClients = { count in
            if count > 0 { connected.fulfill() }
        }

        let gotFrame = expectation(description: "frame")
        gotFrame.assertForOverFulfill = false
        let decoded = expectation(description: "decoded")
        decoded.assertForOverFulfill = false
        let jpeg = try makeTestJPEG()
        let decoder = JPEGDecoder()
        decoder.onImage = { image in
            XCTAssertEqual(image.width, 160)
            XCTAssertEqual(image.height, 160)
            decoded.fulfill()
        }
        server.onFrame = { data in
            if data == jpeg {
                gotFrame.fulfill()
                decoder.submit(data)
            }
        }

        let ws = session.webSocketTask(with: URL(string: "wss://127.0.0.1:\(port)/ws")!)
        ws.resume()
        wait(for: [connected, pageDone, missing], timeout: 15)
        ws.send(.data(jpeg)) { _ in }
        ws.send(.data(jpeg)) { _ in }
        wait(for: [gotFrame, decoded], timeout: 15)
        ws.cancel(with: .normalClosure, reason: nil)
    }
}
