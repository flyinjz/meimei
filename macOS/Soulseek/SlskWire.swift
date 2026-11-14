import Foundation
import Compression

// Soulseek wire format. Everything is little-endian; strings are a uint32
// byte count then the bytes (UTF-8, older clients Latin-1). Three framings:
//   server:     uint32 length, uint32 code, payload
//   peer init:  uint32 length, uint8 code,  payload   (first message on a peer socket)
//   peer:       uint32 length, uint32 code, payload
// File sockets carry raw values after init: the uploader's uint32 token, the
// downloader's uint64 offset, then the file bytes.
//
// Pure Swift and Foundation only, so it ports as is. The one platform piece
// is zlib, via Apple's Compression; see the port notes.

enum SlskWireError: Error { case short, malformed(String) }

struct SlskWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func str(_ s: String) {
        let bytes = Data(s.utf8)
        u32(UInt32(bytes.count))
        data.append(bytes)
    }
    mutating func raw(_ d: Data) { data.append(d) }

    /// `uint32 length, uint32 code, payload` (server and peer messages).
    static func frame(code: UInt32, _ build: (inout SlskWriter) -> Void = { _ in }) -> Data {
        var body = SlskWriter()
        body.u32(code)
        build(&body)
        var out = SlskWriter()
        out.u32(UInt32(body.data.count))
        out.raw(body.data)
        return out.data
    }

    /// `uint32 length, uint8 code, payload` (peer init messages).
    static func initFrame(code: UInt8, _ build: (inout SlskWriter) -> Void) -> Data {
        var body = SlskWriter()
        body.u8(code)
        build(&body)
        var out = SlskWriter()
        out.u32(UInt32(body.data.count))
        out.raw(body.data)
        return out.data
    }
}

struct SlskReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var atEnd: Bool { offset >= data.endIndex }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.endIndex else { throw SlskWireError.short }
        defer { offset += n }
        return data[offset..<offset + n]
    }

    private mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        var v: T = 0
        for (i, b) in bytes.enumerated() { v |= T(b) << (8 * i) }
        return v
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u16() throws -> UInt16 { try int(UInt16.self) }
    mutating func u32() throws -> UInt32 { try int(UInt32.self) }
    mutating func u64() throws -> UInt64 { try int(UInt64.self) }
    mutating func str() throws -> String {
        let n = Int(try u32())
        guard n < 16 << 20 else { throw SlskWireError.malformed("string length \(n)") }
        let bytes = try take(n)
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }
    /// An IPv4 address, sent as a uint32 whose high byte is the first octet.
    mutating func ip() throws -> String {
        let v = try u32()
        return "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }
    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data[offset..<data.endIndex]
    }
}

// MARK: - zlib

/// Soulseek compresses shared lists and search results as zlib streams
/// (2-byte header, raw DEFLATE, Adler-32 trailer). Apple's Compression speaks
/// raw DEFLATE, so the header and trailer are handled here.
enum SlskZlib {
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        // Header off the front, Adler-32 off the back: raw DEFLATE in between.
        let body = data.dropFirst(2).dropLast(4)
        var capacity = max(body.count * 6, 64 << 10)
        while capacity <= 256 << 20 {
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { dst in
                body.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n == 0 { return nil }
            if n < capacity { return out.prefix(n) }
            capacity *= 4
        }
        return nil
    }

    static func deflate(_ data: Data) -> Data {
        let capacity = data.count + data.count / 10 + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        var w = SlskWriter()
        w.u8(0x78); w.u8(0x9C)
        w.raw(out.prefix(n))
        let adler = adler32(data)
        // Adler-32 is big-endian, unlike everything else on the wire.
        w.u8(UInt8(adler >> 24 & 255)); w.u8(UInt8(adler >> 16 & 255)); w.u8(UInt8(adler >> 8 & 255)); w.u8(UInt8(adler & 255))
        return w.data
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}

// MARK: - Shared values

/// A file as Soulseek describes it: a backslash-separated virtual path, a
/// size, and a few audio attributes.
struct SlskFile: Hashable, Sendable {
    var path: String { didSet { derive() } }
    var size: UInt64
    var ext: String { didSet { derive() } }
    var bitrate: Int?
    var duration: Int?
    var vbr: Bool = false
    var sampleRate: Int?
    var bitDepth: Int?

    /// Worked out once from the path: search filters and result lists ask
    /// for these for every file, many times over.
    private(set) var name = ""
    private(set) var lowerName = ""
    /// The format from the extension, normalized ("aif" is "aiff"); see `kind`.
    private(set) var baseKind = ""
    /// A music format (`SlskFile.audioKinds`).
    private(set) var isAudio = false
    /// Lossless by extension alone; m4a/mp4 also need a bit depth (ALAC).
    private(set) var losslessKind = false
    /// m4a/mp4: ALAC with a bit depth, AAC without.
    private(set) var isMPEG4 = false

    init(path: String, size: UInt64, ext: String, bitrate: Int? = nil, duration: Int? = nil, vbr: Bool = false,
         sampleRate: Int? = nil, bitDepth: Int? = nil) {
        self.path = path
        self.size = size
        self.ext = ext
        self.bitrate = bitrate
        self.duration = duration
        self.vbr = vbr
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        derive()
    }

    private mutating func derive() {
        name = path.lastIndex(of: "\\").map { String(path[path.index(after: $0)...]) } ?? path
        lowerName = name.lowercased()
        var e = ext.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        if e.isEmpty, let dot = lowerName.lastIndex(of: ".") { e = String(lowerName[lowerName.index(after: dot)...]) }
        switch e {
        case "aif": baseKind = "aiff"
        case "oga": baseKind = "ogg"
        default: baseKind = e
        }
        isMPEG4 = baseKind == "m4a" || baseKind == "mp4"
        isAudio = isMPEG4 || Self.audioKinds.contains(baseKind)
        losslessKind = SearchFilters.lossless.contains(baseKind)
    }
    var folder: String {
        guard let i = path.lastIndex(of: "\\") else { return "" }
        return String(path[..<i])
    }

    static func read(_ r: inout SlskReader) throws -> SlskFile {
        _ = try r.u8()
        var f = SlskFile(path: try r.str(), size: try r.u64(), ext: try r.str())
        let count = try r.u32()
        for _ in 0..<min(count, 32) {
            let code = try r.u32(), value = Int(try r.u32())
            switch code {
            case 0: f.bitrate = value
            case 1: f.duration = value
            case 2: f.vbr = value != 0
            case 4: f.sampleRate = value
            case 5: f.bitDepth = value
            default: break
            }
        }
        return f
    }

    func write(_ w: inout SlskWriter) {
        w.u8(1)
        w.str(path)
        w.u64(size)
        w.str(ext)
        var attrs: [(UInt32, UInt32)] = []
        if let bitrate { attrs.append((0, UInt32(bitrate))) }
        if let duration { attrs.append((1, UInt32(duration))) }
        if bitrate != nil { attrs.append((2, vbr ? 1 : 0)) }
        if let sampleRate { attrs.append((4, UInt32(sampleRate))) }
        if let bitDepth { attrs.append((5, UInt32(bitDepth))) }
        w.u32(UInt32(attrs.count))
        for (c, v) in attrs { w.u32(c); w.u32(v) }
    }
}

/// A peer's answer to one of our searches.
struct SlskSearchReply: Sendable {
    var username: String
    var token: UInt32
    var files: [SlskFile]
    var freeSlot: Bool
    var speed: Int
    var queue: Int

    static func decode(_ compressed: Data) throws -> SlskSearchReply {
        guard let data = SlskZlib.inflate(compressed) else { throw SlskWireError.malformed("search reply zlib") }
        var r = SlskReader(data)
        let user = try r.str(), token = try r.u32()
        let n = try r.u32()
        var files: [SlskFile] = []
        files.reserveCapacity(Int(min(n, 2000)))
        for _ in 0..<min(n, 5000) { files.append(try SlskFile.read(&r)) }
        let free = (try? r.bool()) ?? false
        let speed = Int((try? r.u32()) ?? 0)
        let queue = Int((try? r.u32()) ?? 0)
        return SlskSearchReply(username: user, token: token, files: files, freeSlot: free, speed: speed, queue: queue)
    }

    func encode() -> Data {
        var w = SlskWriter()
        w.str(username); w.u32(token)
        w.u32(UInt32(files.count))
        for f in files { f.write(&w) }
        w.bool(freeSlot); w.u32(UInt32(speed)); w.u32(UInt32(queue)); w.u32(0)
        w.u32(0) // private files
        return SlskZlib.deflate(w.data)
    }
}

/// A folder in a shared-file list.
struct SlskFolder: Sendable {
    var path: String
    var files: [SlskFile]
}

enum SlskShareList {
    static func decode(_ compressed: Data) throws -> [SlskFolder] {
        guard let data = SlskZlib.inflate(compressed) else { throw SlskWireError.malformed("share list zlib") }
        var r = SlskReader(data)
        var folders: [SlskFolder] = []
        let n = try r.u32()
        for _ in 0..<min(n, 200_000) {
            let path = try r.str()
            let count = try r.u32()
            var files: [SlskFile] = []
            for _ in 0..<min(count, 100_000) {
                var f = try SlskFile.read(&r)
                f.path = path + "\\" + f.path
                files.append(f)
            }
            folders.append(SlskFolder(path: path, files: files))
        }
        return folders
    }

    /// Shared-file lists name files relative to their folder.
    static func encode(_ folders: [SlskFolder]) -> Data {
        var w = SlskWriter()
        w.u32(UInt32(folders.count))
        for folder in folders {
            w.str(folder.path)
            w.u32(UInt32(folder.files.count))
            for var f in folder.files {
                f.path = f.name
                f.write(&w)
            }
        }
        w.u32(0) // unknown
        w.u32(0) // private folders
        return SlskZlib.deflate(w.data)
    }
}

// MARK: - Codes

enum SlskServerCode: UInt32 {
    case login = 1, setWaitPort = 2, getPeerAddress = 3, watchUser = 5, getUserStatus = 7
    case messageUser = 22, messageAcked = 23, userSearch = 42
    case connectToPeer = 18, fileSearch = 26, setStatus = 28, serverPing = 32, sharedFoldersFiles = 35
    case getUserStats = 36, relogged = 41, roomList = 64, privilegedUsers = 69, haveNoParent = 71
    case parentMinSpeed = 83, parentSpeedRatio = 84, checkPrivileges = 92, acceptChildren = 100
    case possibleParents = 102, wishlistInterval = 104, excludedSearchPhrases = 160, cantConnectToPeer = 1001
}

enum SlskPeerCode: UInt32 {
    case sharedFileListRequest = 4, sharedFileListResponse = 5, fileSearchResponse = 9
    case userInfoRequest = 15, userInfoResponse = 16, folderContentsRequest = 36, folderContentsResponse = 37
    case transferRequest = 40, transferResponse = 41, queueUpload = 43, placeInQueueResponse = 44
    case uploadFailed = 46, uploadDenied = 50, placeInQueueRequest = 51
}

enum SlskInitCode: UInt8 {
    case pierceFirewall = 0, peerInit = 1
}

/// Transfer directions in TransferRequest.
enum SlskDirection: UInt32 { case download = 0, upload = 1 }

enum SlskOut {
    static func login(_ user: String, _ password: String) -> Data {
        SlskWriter.frame(code: SlskServerCode.login.rawValue) { w in
            w.str(user); w.str(password); w.u32(160)
            w.str(md5Hex(user + password)); w.u32(3)
        }
    }
    static func setWaitPort(_ port: UInt16) -> Data { SlskWriter.frame(code: SlskServerCode.setWaitPort.rawValue) { $0.u32(UInt32(port)) } }
    static func getPeerAddress(_ user: String) -> Data { SlskWriter.frame(code: SlskServerCode.getPeerAddress.rawValue) { $0.str(user) } }
    static func connectToPeer(token: UInt32, user: String, type: String) -> Data {
        SlskWriter.frame(code: SlskServerCode.connectToPeer.rawValue) { w in w.u32(token); w.str(user); w.str(type) }
    }
    static func fileSearch(token: UInt32, query: String) -> Data {
        SlskWriter.frame(code: SlskServerCode.fileSearch.rawValue) { w in w.u32(token); w.str(query) }
    }
    static func userSearch(user: String, token: UInt32, query: String) -> Data {
        SlskWriter.frame(code: SlskServerCode.userSearch.rawValue) { $0.str(user); $0.u32(token); $0.str(query) }
    }
    /// A private message to one user, relayed (in plain text) by the server.
    static func messageUser(_ user: String, _ text: String) -> Data {
        SlskWriter.frame(code: SlskServerCode.messageUser.rawValue) { $0.str(user); $0.str(text) }
    }
    static func messageAcked(_ id: UInt32) -> Data { SlskWriter.frame(code: SlskServerCode.messageAcked.rawValue) { $0.u32(id) } }
    static func setStatus(_ status: UInt32) -> Data { SlskWriter.frame(code: SlskServerCode.setStatus.rawValue) { $0.u32(status) } }
    static func sharedFoldersFiles(folders: Int, files: Int) -> Data {
        SlskWriter.frame(code: SlskServerCode.sharedFoldersFiles.rawValue) { w in w.u32(UInt32(folders)); w.u32(UInt32(files)) }
    }
    static func haveNoParent(_ v: Bool) -> Data { SlskWriter.frame(code: SlskServerCode.haveNoParent.rawValue) { $0.bool(v) } }
    static func acceptChildren(_ v: Bool) -> Data { SlskWriter.frame(code: SlskServerCode.acceptChildren.rawValue) { $0.bool(v) } }
    static func serverPing() -> Data { SlskWriter.frame(code: SlskServerCode.serverPing.rawValue) }
    static func cantConnectToPeer(token: UInt32, user: String) -> Data {
        SlskWriter.frame(code: SlskServerCode.cantConnectToPeer.rawValue) { w in w.u32(token); w.str(user) }
    }

    static func peerInit(user: String, type: String, token: UInt32 = 0) -> Data {
        SlskWriter.initFrame(code: SlskInitCode.peerInit.rawValue) { w in w.str(user); w.str(type); w.u32(token) }
    }
    static func pierceFirewall(token: UInt32) -> Data {
        SlskWriter.initFrame(code: SlskInitCode.pierceFirewall.rawValue) { $0.u32(token) }
    }

    static func queueUpload(_ path: String) -> Data { SlskWriter.frame(code: SlskPeerCode.queueUpload.rawValue) { $0.str(path) } }
    static func placeInQueueRequest(_ path: String) -> Data { SlskWriter.frame(code: SlskPeerCode.placeInQueueRequest.rawValue) { $0.str(path) } }
    static func placeInQueueResponse(_ path: String, place: Int) -> Data {
        SlskWriter.frame(code: SlskPeerCode.placeInQueueResponse.rawValue) { w in w.str(path); w.u32(UInt32(place)) }
    }
    static func transferRequest(upload token: UInt32, path: String, size: UInt64) -> Data {
        SlskWriter.frame(code: SlskPeerCode.transferRequest.rawValue) { w in
            w.u32(SlskDirection.upload.rawValue); w.u32(token); w.str(path); w.u64(size)
        }
    }
    static func transferResponse(token: UInt32, allowed: Bool, reason: String? = nil) -> Data {
        SlskWriter.frame(code: SlskPeerCode.transferResponse.rawValue) { w in
            w.u32(token); w.bool(allowed)
            if !allowed { w.str(reason ?? "Cancelled") }
        }
    }
    static func uploadDenied(_ path: String, reason: String) -> Data {
        SlskWriter.frame(code: SlskPeerCode.uploadDenied.rawValue) { w in w.str(path); w.str(reason) }
    }
    static func uploadFailed(_ path: String) -> Data { SlskWriter.frame(code: SlskPeerCode.uploadFailed.rawValue) { $0.str(path) } }
    static func sharedFileListRequest() -> Data { SlskWriter.frame(code: SlskPeerCode.sharedFileListRequest.rawValue) }
    static func sharedFileListResponse(_ compressed: Data) -> Data {
        SlskWriter.frame(code: SlskPeerCode.sharedFileListResponse.rawValue) { $0.raw(compressed) }
    }
    static func searchReply(_ compressed: Data) -> Data {
        SlskWriter.frame(code: SlskPeerCode.fileSearchResponse.rawValue) { $0.raw(compressed) }
    }
    static func userInfoResponse(description: String, uploadSlots: Int, queue: Int, freeSlot: Bool) -> Data {
        SlskWriter.frame(code: SlskPeerCode.userInfoResponse.rawValue) { w in
            w.str(description); w.bool(false)
            w.u32(UInt32(uploadSlots)); w.u32(UInt32(queue)); w.bool(freeSlot)
        }
    }
}

private func md5Hex(_ s: String) -> String {
    SlskMD5.hex(Data(s.utf8))
}

/// MD5 for the login hash. Written out because CryptoKit is Apple-only.
enum SlskMD5 {
    static func hex(_ message: Data) -> String {
        let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        var bytes = [UInt8](message)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for i in 0..<8 { bytes.append(UInt8(bitLength >> (8 * UInt64(i)) & 0xff)) }
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = chunk + i * 4
                m[i] = UInt32(bytes[j]) | UInt32(bytes[j + 1]) << 8 | UInt32(bytes[j + 2]) << 16 | UInt32(bytes[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32, g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ (f << s[i] | f >> (32 - s[i]))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].map { v in
            (0..<4).map { String(format: "%02x", v >> (8 * UInt32($0)) & 0xff) }.joined()
        }.joined()
    }
}
