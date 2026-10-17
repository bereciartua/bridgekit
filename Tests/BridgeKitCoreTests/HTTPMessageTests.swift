import Foundation
import Testing
@testable import BridgeKitCore

/// The strict HTTP/1.1 parser: every table row is fed whole, byte by byte and split at every offset,
/// and must give the same result each way.
@Suite("HTTP message")
struct HTTPMessageTests {
    static let small = HTTPLimits(maxHeaderBytes: 64, maxHeaderFields: 3, maxBodyBytes: 8,
                                  maxChunkLineBytes: 16, maxTrailerBytes: 24)

    struct Row: Sendable, CustomTestStringConvertible {
        let input: [UInt8]
        let expected: [String]
        var limits = HTTPLimits.standard

        init(_ input: String, _ expected: [String], limits: HTTPLimits = .standard) {
            self.input = Array(input.utf8)
            self.expected = expected
            self.limits = limits
        }

        init(bytes: [UInt8], _ expected: [String]) {
            input = bytes
            self.expected = expected
        }

        var testDescription: String { String(decoding: input.prefix(120), as: UTF8.self).debugDescription }
    }

    static let tableRows: [Row] = {
        let h = "Host: a\r\n"
        let post = "POST /mcp HTTP/1.1\r\n\(h)"
        let chunked = "\(post)Transfer-Encoding: chunked\r\n\r\n"
        let ok = ["POST /mcp body="]
        let bad = ["error 400"]
        let rows: [(String, [String])] = [
            ("", []),
            ("GET /mcp HTTP/1.1\r\n\(h)\r\n", ["GET /mcp body="]),
            ("\(post)Content-Length: 5\r\n\r\nhello", ["POST /mcp body=hello"]),
            ("\(post)Content-Length:005  \r\n\r\nhello", ["POST /mcp body=hello"]),
            ("\(post)Content-Length: 0000000000000000001\r\n\r\nx", ["POST /mcp body=x"]),
            ("POST /mcp?x=1&y=%20 HTTP/1.1\r\n\(h)Content-Length: 0\r\n\r\n", ok),
            ("\r\n\(post)\r\n", ok),
            ("get /mcp HTTP/1.1\r\n\(h)\r\n", ["get /mcp body="]),
            ("OPTIONS * HTTP/1.1\r\n\(h)\r\n", ["OPTIONS * body="]),
            ("X-Y.Z~ /a/b HTTP/1.1\r\n\(h)\r\n", ["X-Y.Z~ /a/b body="]),
            // Chunked: extensions, upper-case hex, leading zeros and ignored trailers.
            (chunked + "5\r\nhello\r\n6;ext=1;q=\"a b\"\r\n world\r\n0\r\nX-Trailer: t\r\nY: \r\n\r\n",
             ["POST /mcp body=hello world"]),
            (chunked + "A \t;x\r\n0123456789\r\n000\r\n\r\n", ["POST /mcp body=0123456789"]),
            ("\(post)Transfer-Encoding: Chunked\r\n\r\n00000000000003\r\nabc\r\n0\r\n\r\n",
             ["POST /mcp body=abc"]),
            (chunked + "0\r\nContent-Length: 99\r\n\r\n", ok),
            (chunked + "g\r\n", bad),
            (chunked + "\r\n", bad),
            (chunked + "-5\r\n", bad),
            (chunked + "0x5\r\n", bad),
            (chunked + "5 x\r\n", bad),
            (chunked + "5;a\u{0}\r\n", bad),
            (chunked + "5\nhello\r\n0\r\n\r\n", bad),
            (chunked + "5\r\nhelloX\r\n0\r\n\r\n", bad),
            (chunked + "5\r\nhello\n0\r\n\r\n", bad),
            (chunked + "0\r\n folded: x\r\n\r\n", bad),
            (chunked + "0\r\nno colon\r\n\r\n", bad),
            (chunked + "10001\r\n", ["error 413"]),
            (chunked + "FFFFFFFFF\r\n", ["error 413"]),
            (chunked + "5;" + String(repeating: "e", count: 1100) + "\r\n", bad),
            (chunked + "0\r\nX: " + String(repeating: "t", count: 4100) + "\r\n\r\n", ["error 431"]),
            // Framing headers.
            ("\(post)Transfer-Encoding: gzip, chunked\r\n\r\n", bad),
            ("\(post)Transfer-Encoding: identity\r\n\r\n", bad),
            ("\(post)Transfer-Encoding: chunked, chunked\r\n\r\n", bad),
            ("\(post)Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n", bad),
            ("\(post)Transfer-Encoding:\r\n\r\n", bad),
            ("\(post)Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello", bad),
            ("\(post)Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello", bad),
            ("\(post)Content-Length: 5\r\nContent-Length: 5\r\n\r\nhello", bad),
            ("\(post)content-length: 5\r\nCONTENT-LENGTH: 6\r\n\r\nhello!", bad),
            ("\(post)Host: a\r\n\r\n", bad),
            ("\(post)Authorization: Bearer a\r\nauthorization: Bearer a\r\n\r\n", bad),
            ("\(post)Content-Length: abc\r\n\r\n", bad),
            ("\(post)Content-Length: -1\r\n\r\n", bad),
            ("\(post)Content-Length: +5\r\n\r\nhello", bad),
            ("\(post)Content-Length: 5,5\r\n\r\nhello", bad),
            ("\(post)Content-Length: 1 2\r\n\r\n", bad),
            ("\(post)Content-Length: \r\n\r\n", bad),
            ("\(post)Content-Length: 65537\r\n\r\n", ["error 413"]),
            ("\(post)Content-Length: 99999999999999999999\r\n\r\n", ["error 413"]),
            // Field syntax.
            ("\(post)X: a\u{0}b\r\n\r\n", bad),
            ("\(post)X: a\rb\r\n\r\n", bad),
            ("\(post)X: a\u{1}b\r\n\r\n", bad),
            ("\(post)X: a\u{7F}\r\n\r\n", bad),
            ("\(post)X: a\r\n\r\n", ok),
            ("\(post)X: a\n\r\n", bad),
            ("\(post)X: a\r\n b\r\n\r\n", bad),
            ("POST /mcp HTTP/1.1\r\n Host: a\r\n\r\n", bad),
            ("\(post)No colon\r\n\r\n", bad),
            ("\(post)X : a\r\n\r\n", bad),
            ("\(post)X\t: a\r\n\r\n", bad),
            ("\(post)X Y: a\r\n\r\n", bad),
            ("\(post): a\r\n\r\n", bad),
            ("\(post)Hōst: a\r\n\r\n", bad),
            ("\(post)X(: a\r\n\r\n", bad),
            // Request line.
            ("GET /mcp HTTP/1.1\n\(h)\r\n", bad),
            ("GET /mcp\rx HTTP/1.1\r\n\(h)\r\n", bad),
            ("GET /mcp HTTP/2.0\r\n\(h)\r\n", bad),
            ("GET /mcp http/1.1\r\n\(h)\r\n", bad),
            ("GET /mcp\r\n\(h)\r\n", bad),
            ("GET  /mcp HTTP/1.1\r\n\(h)\r\n", bad),
            ("GET /mcp HTTP/1.1 \r\n\(h)\r\n", bad),
            (" GET /mcp HTTP/1.1\r\n\(h)\r\n", bad),
            ("G(T /mcp HTTP/1.1\r\n\(h)\r\n", bad),
            ("GET /m\u{7F}cp HTTP/1.1\r\n\(h)\r\n", bad),
            ("GET /mcp HTTP/1.1\r\n\r\n", bad),
            // Connection handling.
            ("GET /mcp HTTP/1.0\r\n\r\n", ["GET /mcp body= close"]),
            ("POST /mcp HTTP/1.0\r\nContent-Length: 2\r\n\r\nhi", ["POST /mcp body=hi close"]),
            ("POST /mcp HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", bad),
            ("\(post)Connection: keep-alive, Close\r\n\r\n", ["POST /mcp body= close"]),
            ("\(post)Connection: keep-alive\r\nConnection: close\r\n\r\n", ["POST /mcp body= close"]),
            ("\(post)Connection: keep-alive\r\n\r\n", ok),
            // Pipelining and partial input.
            ("\(post)Content-Length: 1\r\n\r\nA\(post)Content-Length: 1\r\n\r\nB",
             ["POST /mcp body=A", "POST /mcp body=B"]),
            (chunked + "1\r\nA\r\n0\r\n\r\nGET /x?q HTTP/1.1\r\n\(h)\r\n",
             ["POST /mcp body=A", "GET /x body="]),
            ("\(post)\r\nBAD\r\n", ["POST /mcp body=", "error 400"]),
            ("\(post)\r\nGET /mcp HTT", ["POST /mcp body=", "partial"]),
            ("\r\n", ["partial"]),
            ("POST /mcp HTTP/1.1\r\n", ["partial"]),
            ("\(post)Content-Length: 5\r\n\r\nhell", ["partial"]),
            (chunked + "5\r\nhel", ["partial"]),
            (chunked + "0\r\nX: y\r\n", ["partial"]),
            // Standard limits.
            ("\(post)X: \(String(repeating: "a", count: 16 * 1024))\r\n\r\n", ["error 431"]),
            (String(repeating: "a", count: 17 * 1024), ["error 431"]),
            ("\(post)" + (1..<64).map { "X\($0): v\r\n" }.joined() + "\r\n", ok),
            ("\(post)" + (1...64).map { "X\($0): v\r\n" }.joined() + "\r\n", ["error 431"]),
            ("\(post)Content-Length: 65536\r\n\r\n" + String(repeating: "b", count: 65536),
             ["POST /mcp body=<65536 bytes>"]),
            (chunked + "10000\r\n" + String(repeating: "b", count: 65536) + "\r\n0\r\n\r\n",
             ["POST /mcp body=<65536 bytes>"]),
            (chunked + "10000\r\n" + String(repeating: "b", count: 65536) + "\r\n1\r\n", ["error 413"]),
        ]
        // Field values are trimmed, keep inner HTAB, and map obs-text bytes to Latin-1 losslessly.
        return rows.map { Row($0.0, $0.1) } + [Row(bytes: obsTextRequest, ok)]
    }()

    static let obsTextRequest: [UInt8] = {
        var raw = Array("POST /mcp HTTP/1.1\r\nHost: a\r\nX-Tab: \t a\tb \t\r\nX-Latin: ".utf8)
        raw += [0xE9, 0xFF] + Array("\r\nX-Tab: second\r\n\r\n".utf8)
        return raw
    }()

    static let limitRows: [Row] = {
        let start = "GET / HTTP/1.1\r\nHost: a\r\n"  // 25 bytes
        let rows: [(String, [String])] = [
            (start + "X: \(String(repeating: "a", count: 32))\r\n\r\n", ["GET / body="]),
            (start + "X: \(String(repeating: "a", count: 33))\r\n\r\n", ["error 431"]),
            (start + "A: 1\r\nB: 2\r\n\r\n", ["GET / body="]),
            (start + "A: 1\r\nB: 2\r\nC: 3\r\n\r\n", ["error 431"]),
            (start + "Content-Length: 8\r\n\r\n12345678", ["GET / body=12345678"]),
            (start + "Content-Length: 9\r\n\r\n123456789", ["error 413"]),
        ]
        let chunkRows: [(String, [String])] = [
            ("4\r\nabcd\r\n4\r\nefgh\r\n0\r\n\r\n", ["POST / body=abcdefgh"]),
            ("4\r\nabcd\r\n4\r\nefgh\r\n1\r\n", ["error 413"]),
            ("9\r\n", ["error 413"]),
            ("8;abcdefghijkl\r\n12345678\r\n0\r\n\r\n", ["POST / body=12345678"]),
            ("8;abcdefghijklm\r\n", ["error 400"]),
            ("0\r\nX: abcdefghijklmnopq\r\n\r\n", ["POST / body="]),
            ("0\r\nX: abcdefghijklmnopqr\r\n\r\n", ["error 431"]),
        ]
        return rows.map { Row($0.0, $0.1, limits: small) }
            + chunkRows.map { Row(chunkedPrefix + $0.0, $0.1, limits: small) }
    }()

    static let chunkedPrefix = "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n"

    @Test("table cases at every split", arguments: tableRows)
    func table(_ row: Row) {
        check(row)
    }

    @Test("small-limit cases at every split", arguments: limitRows)
    func limitCases(_ row: Row) {
        check(row)
    }

    @Test func tableSizes() {
        #expect(Self.tableRows.count == 97)
        #expect(Self.limitRows.count == 13)
        #expect(Self.chunkedPrefix.utf8.count == 56)
    }

    @Test func headerValuesAndTarget() throws {
        let request = try #require(onlyRequest(Self.obsTextRequest))
        #expect(request.header("x-TAB") == "a\tb")
        #expect(request.headerValues("X-Tab") == ["a\tb", "second"])
        #expect(request.header("x-latin") == "\u{E9}\u{FF}")
        #expect(request.header("missing") == nil)
        #expect(request.headers.map(\.name) == ["host", "x-tab", "x-latin", "x-tab"])
        let query = try #require(onlyRequest(Array("POST /mcp?a=b?c HTTP/1.1\r\nHost: a\r\n\r\n".utf8)))
        #expect(query.target == "/mcp?a=b?c")
        #expect(query.path == "/mcp")
        #expect(query.version == "HTTP/1.1")
        #expect(!query.wantsClose)
        #expect(query.body.isEmpty)
    }

    @Test("100-continue") func expectContinue() {
        let head = "POST /mcp HTTP/1.1\r\nHost: a\r\nExpect: 100-Continue\r\n"
        var parser = HTTPParser()
        #expect(isContinue(parser.feed(Data((head + "Content-Length: 5\r\n\r\n").utf8))))
        #expect(parser.isReadingBody)
        #expect(isNeedMore(parser.feed(Data())))
        #expect(isNeedMore(parser.feed(Data("hel".utf8))))
        #expect(body(parser.feed(Data("lo".utf8))) == "hello")
        // Offered again for the next request on the same connection.
        #expect(isContinue(parser.feed(Data((head + "Transfer-Encoding: chunked\r\n\r\n2\r\nab").utf8))))
        #expect(isNeedMore(parser.feed(Data("\r\n0\r\n".utf8))))
        #expect(body(parser.feed(Data("\r\n".utf8))) == "ab")

        // The body already arrived, or there is none: no 100 Continue.
        var whole = HTTPParser()
        #expect(body(whole.feed(Data((head + "Content-Length: 2\r\n\r\nhi").utf8))) == "hi")
        #expect(body(whole.feed(Data((head + "Content-Length: 0\r\n\r\n").utf8))) == "")
        #expect(body(whole.feed(Data((head + "\r\n").utf8))) == "")
        var old = HTTPParser()
        let legacy = "POST /mcp HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n"
        #expect(isNeedMore(old.feed(Data(legacy.utf8))))
        // Header checks come first: a bad head is an error, never a 100 Continue.
        var rejected = HTTPParser()
        #expect(status(rejected.feed(Data((head + "Content-Length: 70000\r\n\r\n").utf8))) == 413)
    }

    @Test func flags() {
        var parser = HTTPParser()
        #expect(!parser.hasBufferedBytes && !parser.isReadingBody && parser.bufferedByteCount == 0)
        #expect(isNeedMore(parser.feed(Data("P".utf8))))
        #expect(parser.hasBufferedBytes && !parser.isReadingBody && parser.bufferedByteCount == 1)
        let rest = "OST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\n\r\nab"
        #expect(isNeedMore(parser.feed(Data(rest.utf8))))
        #expect(parser.hasBufferedBytes && parser.isReadingBody && parser.bufferedByteCount == 2)
        #expect(body(parser.feed(Data("c".utf8))) == "abc")
        #expect(!parser.hasBufferedBytes && !parser.isReadingBody && parser.bufferedByteCount == 0)
        #expect(status(parser.feed(Data("BAD\r\n".utf8))) == 400)
        #expect(!parser.hasBufferedBytes && parser.bufferedByteCount == 0)
        #expect(status(parser.feed(Data("GET / HTTP/1.1\r\nHost: a\r\n\r\n".utf8))) == 400)
        #expect(status(parser.feed(Data())) == 400)
    }

    @Test func responses() {
        let allow = HTTPResponse(status: 405, headers: [("Allow", "POST")]).serialized(close: true)
        #expect(String(decoding: allow, as: UTF8.self) == "HTTP/1.1 405 Method Not Allowed\r\n"
            + "Allow: POST\r\nContent-Length: 0\r\nCache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n")

        let messy = HTTPResponse(status: 200, headers: [
            ("Content-Type", "application/json"), ("Content-Length", "99"), ("cache-control", "private"),
            ("Access-Control-Allow-Origin", "*"), ("Connection", "keep-alive"),
            ("Transfer-Encoding", "chunked"), ("X-Bad", "a\r\nInjected: x"), ("Bad Name", "x"),
            ("X-CONTENT-TYPE-OPTIONS", "nosniff"),
        ], body: Data("{}".utf8))
        let text = String(decoding: messy.serialized(close: false), as: UTF8.self)
        #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\ncache-control: private\r\n"
            + "X-CONTENT-TYPE-OPTIONS: nosniff\r\nContent-Length: 2\r\n\r\n{}")
        let accepted = String(decoding: HTTPResponse(status: 202).serialized(close: false), as: UTF8.self)
        #expect(accepted.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(!accepted.contains("Connection"))
        #expect(accepted.components(separatedBy: "Cache-Control: no-store").count == 2)
        #expect(HTTPResponse.continueBytes == Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        for code in [100, 200, 202, 400, 401, 403, 404, 405, 406, 408, 413, 415, 421, 429, 431, 500, 503] {
            #expect(HTTPResponse.reason(code) != "Status", "\(code)")
        }
    }

    /// Mutates valid requests (flip, insert, delete, duplicate, long runs) and feeds each one whole and
    /// in random pieces: no crash, identical results, and bounded buffering throughout.
    @Test("10,000 deterministic fuzz cases") func fuzz() {
        let seeds = [
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47615\r\nContent-Type: application/json\r\n"
                + "Authorization: Bearer ekb_mcp_v1_abc\r\nContent-Length: 13\r\n\r\n{\"jsonrpc\":1}",
            "POST /mcp?x HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n"
                + "4;e=1\r\nabcd\r\n3\r\nefg\r\n0\r\nT: x\r\n\r\n",
            "GET /mcp HTTP/1.0\r\nConnection: close\r\n\r\nGET / HTTP/1.1\r\nHost: b\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\nhiPOST / HTTP/1.1\r\nHost: a\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n",
        ].map { Array($0.utf8) }
        let interesting: [UInt8] = [13, 10, 32, 9, 0, 58, 59, 48, 57, 70, 97, 0x7F, 0xFF]
        var rng = XorShift(state: 0x9E37_79B9_7F4A_7C15)
        var cases = 0
        for index in 0..<10_000 {
            var bytes = seeds[rng.below(seeds.count)]
            for _ in 0...rng.below(4) {
                let at = rng.below(bytes.count + 1)
                let byte = rng.below(2) == 0
                    ? interesting[rng.below(interesting.count)] : UInt8(rng.below(256))
                switch rng.below(16) {
                case 0..<5 where at < bytes.count: bytes[at] = byte
                case 5..<10: bytes.insert(byte, at: at)
                case 10..<14 where at < bytes.count: bytes.remove(at: at)
                case 14:
                    let end = min(bytes.count, at + rng.below(64))
                    bytes.insert(contentsOf: bytes[at..<end], at: at)
                case 15 where rng.below(4) == 0:
                    bytes.insert(contentsOf: repeatElement(byte, count: rng.below(20_000)), at: at)
                default: break
                }
            }
            var cuts: [Int] = []
            var cut = 0
            while true {
                cut += 1 + rng.below(rng.below(2) == 0 ? 8 : 300)
                if cut >= bytes.count { break }
                cuts.append(cut)
            }
            let limits = index % 3 == 0 ? Self.small : .standard
            let pieces = run(bytes, cuts: cuts, limits: limits)
            let whole = run(bytes, cuts: [], limits: limits)
            #expect(pieces.violation == nil, "fuzz case \(index)")
            #expect(whole.violation == nil, "fuzz case \(index)")
            #expect(pieces.out == whole.out, "fuzz case \(index)")
            cases += 1
        }
        #expect(cases == 10_000)
    }

    // MARK: Helpers

    func check(_ row: Row) {
        let input = row.input
        let limits = row.limits
        let actual = run(input, cuts: [], limits: limits, short: true)
        #expect(actual.violation == nil)
        #expect(actual.out == row.expected)
        let whole = run(input, cuts: [], limits: limits)
        #expect(run(input, cuts: Array(0..<input.count), limits: limits) == whole, "bytewise")
        let step = input.count > 2048 ? 97 : 1
        for cut in stride(from: 0, through: input.count, by: step) {
            let split = run(input, cuts: [cut], limits: limits)
            if split != whole {
                Issue.record("split at \(cut): \(split) != \(whole)")
            }
        }
        if input.count > 2048 {
            #expect(run(input, cuts: Array(stride(from: 0, to: input.count, by: 1000)), limits: limits) == whole,
                    "in 1000-byte reads")
        }
    }

    struct Outcome: Equatable {
        var out: [String] = []
        /// The first buffering or state invariant that didn't hold, if any.
        var violation: String?
    }

    /// Feeds `input` in pieces ending at `cuts`, draining pipelined requests after each read. Whether
    /// 100 Continue is offered depends on the split, so it isn't recorded.
    func run(_ input: [UInt8], cuts: [Int], limits: HTTPLimits, short: Bool = false) -> Outcome {
        var parser = HTTPParser(limits: limits)
        let bound = limits.maxHeaderBytes + limits.maxBodyBytes
        var outcome = Outcome()
        func violated(_ what: String) {
            if outcome.violation == nil { outcome.violation = what }
        }
        var from = 0
        for cut in cuts + [input.count] {
            var result = parser.feed(Data(input[from..<cut]))
            if parser.bufferedByteCount > bound + cut - from { violated("buffered more than the read allows") }
            from = cut
            drain: while true {
                switch result {
                case .needMore:
                    if parser.bufferedByteCount > bound { violated("buffered more than the bound") }
                    break drain
                case .expectContinue:
                    if !parser.isReadingBody { violated("100 Continue outside a body") }
                case .request(let request):
                    outcome.out.append(describe(request, short: short))
                case .error(let status):
                    if parser.bufferedByteCount != 0 || parser.hasBufferedBytes {
                        violated("bytes kept after an error")
                    }
                    outcome.out.append("error \(status)")
                    return outcome
                }
                result = parser.feed(Data())
            }
        }
        if parser.hasBufferedBytes { outcome.out.append("partial") }
        return outcome
    }

    func describe(_ request: HTTPRequest, short: Bool) -> String {
        let text = request.body.count > 64 ? "<\(request.body.count) bytes>"
            : String(decoding: request.body, as: UTF8.self)
        let close = request.wantsClose ? " close" : ""
        if short { return "\(request.method) \(request.path) body=\(text)\(close)" }
        let headers = request.headers.map { "\($0.name)=\($0.value.debugDescription)" }.joined(separator: ",")
        return "\(request.method) \(request.target) \(request.version) [\(headers)] "
            + "\(request.body.base64EncodedString())\(close)"
    }

    func onlyRequest(_ input: [UInt8]) -> HTTPRequest? {
        var parser = HTTPParser()
        guard case .request(let request) = parser.feed(Data(input)) else { return nil }
        return request
    }

    func isContinue(_ result: HTTPParseResult) -> Bool {
        if case .expectContinue = result { return true }
        return false
    }

    func isNeedMore(_ result: HTTPParseResult) -> Bool {
        if case .needMore = result { return true }
        return false
    }

    func body(_ result: HTTPParseResult) -> String? {
        guard case .request(let request) = result else { return nil }
        return String(decoding: request.body, as: UTF8.self)
    }

    func status(_ result: HTTPParseResult) -> Int? {
        guard case .error(let status) = result else { return nil }
        return status
    }
}

/// Deterministic, so a failing fuzz case reproduces.
struct XorShift {
    var state: UInt64

    mutating func below(_ bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}
