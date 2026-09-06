// Compiled with the production Config and STTStreamClient by test_native.py.
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let testDirectory = CommandLine.arguments[1]
let settingsPath = testDirectory + "/config"
try """
SPEED="nan"
LOCAL_SPEED="inf"
LOCAL_IDLE_TIMEOUT="-20"
STT_IDLE_TIMEOUT="9223372036854775807"
WPM="-4"
TTS_BACKEND="typo"
FILTER_FILLERS="false"
""".write(toFile: settingsPath, atomically: true, encoding: .utf8)
var settings = Config.load(from: settingsPath)
require(settings.speed == 1 && settings.localSpeed == 1, "nonfinite speeds use defaults")
require(settings.localIdleTimeout == 5 && settings.sttIdleTimeout == 86400, "bounded idle settings")
require(settings.wpm == 50 && settings.ttsBackend == "auto", "invalid reader/backend settings")
settings.intentOpenAIModel = "model\"\nINTENT_REWRITE_PROVIDER=\"openai"
settings.save(to: settingsPath)
let reloaded = Config.load(from: settingsPath)
require(reloaded.intentRewriteProvider == "off", "multiline model cannot enable remote rewrite")
let savedSettings = try String(contentsOfFile: settingsPath)
require(savedSettings.contains("FILTER_FILLERS=\"false\""), "helper settings preserved")
let permissions = try FileManager.default.attributesOfItem(atPath: settingsPath)[.posixPermissions] as! NSNumber
require(permissions.intValue == 0o600, "configuration permissions")
require(runIntentRewriteSelfTest(), "existing provider request/response regressions")
let fencedLines = Data(#"{"choices":[{"message":{"content":"```\nHello.\nWorld.\n```"}}]}"#.utf8)
let decoded = try IntentRewriteClient.rewrittenText(from: fencedLines, provider: .compatible,
                                                   original: "Hello. World.")
require(decoded == "Hello.\nWorld.", "unlabelled code fence preserves the first line")
require(IntentRewriteClient.isLoopbackEndpoint("http://[::1]:11434/v1"), "IPv6 loopback")
require(runPasteboardSnapshotSelfTest(), "existing clipboard snapshot regression")

func withServer(_ name: String, response: String?, body: (STTStreamClient, String, DispatchSemaphore) -> Void) {
    let path = testDirectory + "/" + name
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    require(listener >= 0, "create listener")
    defer { Darwin.close(listener); unlink(path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, source, capacity - 1) }
        }
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    require(bound == 0 && listen(listener, 1) == 0, "bind listener")
    let ended = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        defer { ended.signal() }
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        var noSignal: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if let response {
            // Consume the actual framed request through its explicit terminator.
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(peer, &buffer, buffer.count, 0)
                if n <= 0 { return }
                data.append(contentsOf: buffer[0..<n])
                if let newline = data.firstIndex(of: 10), data.count >= newline + 5 {
                    let frames = Array(data[(newline + 1)...])
                    var offset = 0
                    var done = false
                    while offset + 4 <= frames.count {
                        let size = frames[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                        if size == 0 { done = true; break }
                        if offset + 4 + size > frames.count { break }
                        offset += 4 + size
                    }
                    if done { break }
                }
            }
            let bytes = Data(response.utf8)
            _ = bytes.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
        }
    }
    let client = STTStreamClient()
    body(client, path, ended)
    client.close()
    require(ended.wait(timeout: .now() + 5) == .success, "server terminated")
}

withServer("final.sock", response: "{\"status\":\"ok\",\"final\":\"hello world\"}\n") { client, path, _ in
    let done = DispatchSemaphore(value: 0)
    client.onFinal = { text, _ in require(text == "hello world", "final transcript delivered"); done.signal() }
    client.onFailure = { message in fputs("Unexpected failure: \(message)\n", stderr); exit(1) }
    client.send(samples: [0, 0.1, -0.1])
    client.finish() // stopping during cold load must flush an end marker on connect
    require(client.connect(socketPath: path, sampleRate: 16000, wantsPartials: true), "connect buffered stream")
    require(done.wait(timeout: .now() + 5) == .success, "buffered final delivered")
}

withServer("eof.sock", response: nil) { client, path, _ in
    let failed = DispatchSemaphore(value: 0)
    client.onFailure = { _ in failed.signal() }
    _ = client.connect(socketPath: path, sampleRate: 16000, wantsPartials: true)
    require(failed.wait(timeout: .now() + 5) == .success, "unexpected EOF reported")
    require(client.isClosed, "failed connection is closed")
}

withServer("error.sock", response: "{\"status\":\"error\",\"message\":\"model failed\"}\n") { client, path, _ in
    let failed = DispatchSemaphore(value: 0)
    client.onFailure = { _ in failed.signal() }
    client.finish()
    _ = client.connect(socketPath: path, sampleRate: 16000, wantsPartials: false)
    require(failed.wait(timeout: .now() + 5) == .success, "daemon errors are reported")
}

let cancelled = STTStreamClient()
cancelled.close()
require(cancelled.isClosed, "cancellation is immediate")
require(!cancelled.connect(socketPath: testDirectory + "/missing.sock", sampleRate: 16000, wantsPartials: false), "closed client cannot reconnect")

let bounded = STTStreamClient()
let overflow = DispatchSemaphore(value: 0)
bounded.onFailure = { _ in overflow.signal() }
bounded.send(samples: [Float](repeating: 0, count: 2 * 1024 * 1024))
require(overflow.wait(timeout: .now() + 2) == .success && bounded.isClosed, "microphone backlog is bounded")
print("PASS: configuration, clipboard, rewrite, socket finalization, EOF, errors, cancellation and backlog")
