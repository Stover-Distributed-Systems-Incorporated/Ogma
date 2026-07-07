import Cocoa
import ApplicationServices
import Carbon.HIToolbox   // IsSecureEventInputEnabled
import CoreAudio
import AVFoundation
import ServiceManagement

// MARK: - Config paths

private let configDir  = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ogma")
private let configPath = (configDir as NSString).appendingPathComponent("config")
private let speakPath  = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/speak.sh")

// MARK: - Config model

struct Config {
    // Backend selection
    var ttsBackend:         String = "auto"          // "auto", "elevenlabs", or "local"
    var backendsInstalled:  String = "elevenlabs"   // "elevenlabs", "local", or "both"

    // ElevenLabs settings
    var voiceId:         String = "pFZP5JQG7iQjIQuC4Bku"
    var modelId:         String = "eleven_flash_v2_5"
    var stability:       Double = 0.5
    var similarityBoost: Double = 0.75
    var style:           Double = 0.0
    var useSpeakerBoost: Bool   = true

    // Local TTS settings
    var localVoice:      String = "bf_lily"
    var localSpeed:      Double = 1.0
    var localIdleTimeout: Int   = 120   // seconds before the TTS model unloads
    var sttIdleTimeout:   Int   = 120   // seconds before the STT model unloads

    // Dictation: show the review card (✓ insert / ✎ edit / ✗ discard) instead
    // of pasting the transcript immediately when recording stops.
    var dictationReview: Bool   = true

    // ElevenLabs speed (shared name kept for config compat)
    var speed:           Double = 1.0

    // Inter-sentence pause (milliseconds at 1.0x speed, scales with speed)
    var sentencePause:   Int    = 400

    static func load() -> Config {
        var c = Config()
        guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else { return c }
        for line in raw.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eqRange = line.range(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var value = String(line[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'")  && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "TTS_BACKEND":          c.ttsBackend        = value
            case "TTS_BACKENDS_INSTALLED":c.backendsInstalled = value
            case "VOICE_ID":             c.voiceId            = value
            case "MODEL_ID":             c.modelId            = value
            case "STABILITY":            c.stability          = Double(value) ?? c.stability
            case "SIMILARITY_BOOST":     c.similarityBoost    = Double(value) ?? c.similarityBoost
            case "STYLE":                c.style              = Double(value) ?? c.style
            case "USE_SPEAKER_BOOST":    c.useSpeakerBoost    = value == "true" || value == "1"
            case "SPEED":                c.speed              = Double(value) ?? c.speed
            case "LOCAL_VOICE":          c.localVoice         = value
            case "LOCAL_SPEED":          c.localSpeed         = Double(value) ?? c.localSpeed
            case "LOCAL_IDLE_TIMEOUT":   c.localIdleTimeout   = Int(value) ?? c.localIdleTimeout
            case "STT_IDLE_TIMEOUT":     c.sttIdleTimeout     = Int(value) ?? c.sttIdleTimeout
            case "DICTATION_REVIEW":     c.dictationReview    = value != "false" && value != "0"
            case "SENTENCE_PAUSE":       c.sentencePause      = Int(value) ?? c.sentencePause
            default: break
            }
        }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        let lines = [
            "TTS_BACKEND=\"\(ttsBackend)\"",
            "TTS_BACKENDS_INSTALLED=\"\(backendsInstalled)\"",
            "VOICE_ID=\"\(voiceId)\"",
            "MODEL_ID=\"\(modelId)\"",
            "STABILITY=\"\(String(format: "%.2f", stability))\"",
            "SIMILARITY_BOOST=\"\(String(format: "%.2f", similarityBoost))\"",
            "STYLE=\"\(String(format: "%.2f", style))\"",
            "USE_SPEAKER_BOOST=\"\(useSpeakerBoost ? "true" : "false")\"",
            "SPEED=\"\(String(format: "%.2f", speed))\"",
            "LOCAL_VOICE=\"\(localVoice)\"",
            "LOCAL_SPEED=\"\(String(format: "%.2f", localSpeed))\"",
            "LOCAL_IDLE_TIMEOUT=\"\(localIdleTimeout)\"",
            "STT_IDLE_TIMEOUT=\"\(sttIdleTimeout)\"",
            "DICTATION_REVIEW=\"\(dictationReview ? "true" : "false")\"",
            "SENTENCE_PAUSE=\"\(sentencePause)\"",
        ]
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Static data

// ElevenLabs voices
private let knownVoices: [(name: String, id: String)] = [
    ("Lily — British, raspy",     "pFZP5JQG7iQjIQuC4Bku"),
    ("Alice — British, confident","Xb7hH8MSUJpSbSDYk0k2"),
    ("Rachel — calm",             "21m00Tcm4TlvDq8ikWAM"),
    ("Adam — deep",               "pNInz6obpgDQGcFmaJgB"),
    ("Domi — strong",             "AZnzlk1XvdvUeBnXmlld"),
    ("Josh — young, deep",        "TxGEqnHWrfWFTfGW9XjX"),
    ("Sam — raspy",               "yoZ06aMxZJJ28mfd3POQ"),
]

// Kokoro voices (curated English subset)
private let kokoroVoices: [(name: String, id: String)] = [
    ("Lily — British, bright", "bf_lily"),
    ("Heart — warm",           "af_heart"),
    ("Bella — soft",           "af_bella"),
    ("Nova — confident",       "af_nova"),
    ("Sarah — gentle",         "af_sarah"),
    ("Sky — bright",           "af_sky"),
    ("Adam — deep",            "am_adam"),
    ("Echo — clear",           "am_echo"),
    ("Eric — steady",          "am_eric"),
    ("Michael — warm",         "am_michael"),
    ("Emma — British, warm",   "bf_emma"),
    ("George — British, deep", "bm_george"),
]

private let knownModels: [(name: String, id: String)] = [
    ("v3 — best quality",         "eleven_v3"),
    ("Flash v2.5 — fastest",      "eleven_flash_v2_5"),
    ("Turbo v2.5 — fast, ½ cost", "eleven_turbo_v2_5"),
    ("Multilingual v2 — 29 langs","eleven_multilingual_v2"),
]

// ElevenLabs API accepts speed in [0.7, 1.2]
private let elSpeedSteps: [(label: String, value: Double)] = [
    ("0.7×", 0.7), ("0.85×", 0.85), ("1×", 1.0), ("1.1×", 1.1), ("1.2×", 1.2),
]

// Kokoro accepts a wider speed range
private let localSpeedSteps: [(label: String, value: Double)] = [
    ("0.5×", 0.5), ("0.75×", 0.75), ("1×", 1.0), ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0),
]

// How long the local model stays in memory before auto-unloading (seconds).
private let idleTimeoutSteps: [(label: String, value: Int)] = [
    ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600), ("30 minutes", 1800),
]

private let stabilitySteps: [(label: String, value: Double)] = [
    ("0.0 — expressive", 0.0), ("0.25", 0.25), ("0.5 — default", 0.5),
    ("0.75", 0.75), ("1.0 — steady", 1.0),
]

private let similaritySteps: [(label: String, value: Double)] = [
    ("0.0 — low", 0.0), ("0.25", 0.25), ("0.5", 0.5),
    ("0.75 — default", 0.75), ("1.0 — high", 1.0),
]

private let styleSteps: [(label: String, value: Double)] = [
    ("0.0 — none (default)", 0.0), ("0.25", 0.25), ("0.5", 0.5),
    ("0.75", 0.75), ("1.0 — max", 1.0),
]

// MARK: - CoreAudio mute check (in-process, microseconds)

private func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else { return nil }
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    return (err == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
}

func isOutputMuted() -> Bool {
    guard let deviceID = getDefaultOutputDevice() else { return false }
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
    return err == noErr && muted == 1
}

func unmuteOutput() {
    guard let deviceID = getDefaultOutputDevice() else { return }
    var muted: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return }
    AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted)
}

// MARK: - Global hotkey ⌥⇧/ → speak.sh
//
// Keycode 44 = forward slash on ANSI/ISO keyboards (US and most layouts).
// Option+Shift must be set — no Control or Command.

private let kHotkeyCode: Int64 = 44
// Keycode 2 = "D" → ⌥⇧D toggles push-to-talk dictation (Parakeet STT).
private let kDictateHotkeyCode: Int64 = 2

// Module-level tap reference so the C callback can re-enable it after a timeout.
private var globalTap: CFMachPort?
// Its run-loop source, kept so the health check can tear a dead tap down.
private var globalTapRunLoopSource: CFRunLoopSource?
// Weak ref so the C callback can update the menu bar icon.
private weak var appDelegateRef: AppDelegate?
// Last time the user pressed any non-hotkey key (tap runs on the main run
// loop; read on the main thread). Used to avoid stealing keyboard focus for
// the review card while the user is typing.
private var lastUserKeyDownAt: CFAbsoluteTime = 0

private let hotkeyCallback: CGEventTapCallBack = { _, type, event, _ in
    // If the tap was disabled (e.g. callback was too slow), re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else { return Unmanaged.passRetained(event) }

    let code  = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.intersection([.maskAlternate, .maskShift, .maskControl, .maskCommand])

    guard flags == [.maskAlternate, .maskShift],
          code == kHotkeyCode || code == kDictateHotkeyCode else {
        lastUserKeyDownAt = CFAbsoluteTimeGetCurrent()
        return Unmanaged.passRetained(event)
    }

    // Swallow key autorepeats — a held hotkey must not thrash start/stop.
    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }

    // Fire on a background thread — never block the event tap.
    DispatchQueue.global(qos: .userInitiated).async {
        if code == kDictateHotkeyCode {
            appDelegateRef?.handleDictateHotkey()
        } else {
            appDelegateRef?.handleHotkey()
        }
    }
    return nil  // consume the keystroke
}

// MARK: - STT streaming client (Unix socket)
//
// Streams float32 audio frames to the STT daemon and relays partial/final
// transcripts back. All socket writes are serialized on `sendQueue`; audio
// captured before the daemon socket is ready is buffered and flushed on
// connect so the start of speech is never lost.

// A transcribed word plus the model's confidence (0–1) that it heard it
// right, and optionally the daemon's context-based autocorrect suggestion.
struct STTWord {
    let text: String
    let confidence: Double
    var suggestion: String? = nil
}

final class STTStreamClient {
    private var fd: Int32 = -1
    private var pending: [Data] = []
    private var closed = false     // guarded by sendQueue
    private var finished = false   // guarded by sendQueue
    private let sendQueue = DispatchQueue(label: "ogma.stt.send")
    var onPartial: ((String, [STTWord]) -> Void)?
    var onFinal: ((String, [STTWord]) -> Void)?

    // True once close() ran. The connect poller checks this to stop early;
    // connect() itself re-checks on sendQueue, which closes the race — a
    // closed client can never adopt a socket and wedge the single-flight
    // daemon with a dead stream.
    var isClosed: Bool { sendQueue.sync { closed } }

    func connect(socketPath: String, sampleRate: Int) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        // Without this, a daemon dying mid-stream (e.g. unloaded from the
        // menu while dictating) raises SIGPIPE on the next send and kills
        // the whole app; with it, send just returns EPIPE.
        var noSigpipe: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sp in
                sp.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    _ = strncpy(dst, cstr, cap - 1)
                }
            }
        }
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(s, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else { Darwin.close(s); return false }

        var adopted = false
        sendQueue.sync {
            guard !self.closed else { Darwin.close(s); return }
            self.fd = s
            let header = "{\"mode\":\"stream\",\"sample_rate\":\(sampleRate)}\n"
            _ = self.writeAll(Data(header.utf8))
            for f in self.pending { _ = self.writeAll(f) }
            self.pending.removeAll()
            adopted = true
        }
        guard adopted else { return false }
        startReading()
        return true
    }

    func send(samples: [Float]) {
        guard !samples.isEmpty else { return }
        var len = UInt32(samples.count * 4).bigEndian
        var frame = Data(bytes: &len, count: 4)
        samples.withUnsafeBytes { frame.append(contentsOf: $0) }
        sendQueue.async {
            guard !self.closed, !self.finished else { return }
            if self.fd >= 0 { _ = self.writeAll(frame) }
            else { self.pending.append(frame) }
        }
    }

    func finish() {
        sendQueue.async {
            guard !self.closed, !self.finished else { return }
            self.finished = true
            var zero = UInt32(0).bigEndian
            let frame = Data(bytes: &zero, count: 4)
            // Not connected yet (daemon still loading): queue the terminator
            // so the flush-on-connect still ends the stream and a final comes
            // back — instead of silently dropping it.
            if self.fd >= 0 { _ = self.writeAll(frame) }
            else { self.pending.append(frame) }
        }
    }

    func close() {
        sendQueue.async {
            self.closed = true
            self.pending.removeAll()
            if self.fd >= 0 {
                // shutdown only — the read thread owns the descriptor and
                // closes it when recv() returns. Closing here would free the
                // fd number for reuse while the reader still holds it, letting
                // a stale reader consume a NEWER session's stream.
                Darwin.shutdown(self.fd, SHUT_RDWR)
                self.fd = -1
            }
        }
    }

    // Must be called on sendQueue.
    private func writeAll(_ data: Data) -> Bool {
        var ok = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.send(self.fd, ptr, remaining, 0)
                if n <= 0 { ok = false; break }
                ptr = ptr.advanced(by: n); remaining -= n
            }
        }
        return ok
    }

    private func startReading() {
        let readFd = fd
        Thread.detachNewThread { [weak self] in
            var buf = Data()
            var tmp = [UInt8](repeating: 0, count: 8192)
            defer { Darwin.close(readFd) }   // reader owns the fd; see close()
            while true {
                let n = tmp.withUnsafeMutableBytes { recv(readFd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { break }
                buf.append(contentsOf: tmp[0..<n])
                while let idx = buf.firstIndex(of: 0x0A) {
                    let line = buf.subdata(in: buf.startIndex..<idx)
                    buf.removeSubrange(buf.startIndex...idx)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { continue }
                    // "words" is absent when talking to an older daemon —
                    // callers render plain text then.
                    let words = (obj["words"] as? [[String: Any]])?.compactMap { w -> STTWord? in
                        guard let t = w["text"] as? String else { return nil }
                        let c = (w["confidence"] as? NSNumber)?.doubleValue ?? 1.0
                        return STTWord(text: t, confidence: c,
                                       suggestion: w["suggestion"] as? String)
                    } ?? []
                    if let f = obj["final"] as? String { self?.onFinal?(f, words) }
                    else if let p = obj["partial"] as? String { self?.onPartial?(p, words) }
                }
            }
        }
    }
}

// MARK: - Floating dictation caption overlay / review card

// Marks a low-confidence word; the value is the confidence. Travels with the
// text through edits, so click-to-fix keeps working after the user types.
private let kConfidenceAttr = NSAttributedString.Key("ogma.confidence")
// The daemon's context-based replacement suggestion for a flagged word.
private let kSuggestionAttr = NSAttributedString.Key("ogma.suggestion")

// Borderless panels refuse key status by default; the review card needs it
// for text editing and Return/Esc. .nonactivatingPanel means taking key
// focus does NOT activate this app, so the target app stays frontmost with
// its insertion point intact (the Spotlight pattern).
private final class ReviewPanel: NSPanel {
    var allowsKey = false
    var becameKeyAt: TimeInterval = 0
    var keyStateChanged: ((Bool) -> Void)?
    var fallbackKeyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { allowsKey }
    override func becomeKey() {
        becameKeyAt = ProcessInfo.processInfo.systemUptime
        super.becomeKey()
        keyStateChanged?(true)
    }
    override func resignKey() {
        super.resignKey()
        keyStateChanged?(false)
    }
    override func sendEvent(_ event: NSEvent) {
        // Swallow keystrokes that were already in flight when the card took
        // key focus — they were aimed at the user's document, not the card
        // (a stray Return must not trigger an instant insert). Synthesized
        // events (timestamp 0 — e.g. our own ⌘C for ⌥⇧/ speak-selection)
        // and deliberate ⌘-chords always pass.
        if allowsKey, event.type == .keyDown, event.timestamp > 0,
           !event.modifierFlags.contains(.command),
           event.timestamp < becameKeyAt {
            return
        }
        super.sendEvent(event)
    }
    override func keyDown(with event: NSEvent) {
        if fallbackKeyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
    // Accessory apps have no Edit menu, so ⌘V/C/X/A/Z would be dead inside
    // the review text view (the classic LSUIElement gotcha). Route the
    // standard editing equivalents to the first responder ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift] else { return false }
        let shift = mods.contains(.shift)
        switch event.charactersIgnoringModifiers {
        case "a" where !shift: return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "c" where !shift: return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v" where !shift: return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "x" where !shift: return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "z", "Z": return NSApp.sendAction(shift ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: self)
        default: return false
        }
    }
}

// The app is never active, so button clicks on a non-key card are "first
// mouse" — accept them so a single click always works.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Text view that reports clicks on confidence-flagged words (for the tiny
// ✓/✗ fix-up chip) without disturbing normal caret placement.
private final class TranscriptTextView: NSTextView {
    var onWordClick: ((NSRange, NSRect) -> Void)?
    var onPlainClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        var flagged = false
        if let lm = layoutManager, let tc = textContainer, let storage = textStorage {
            let p = convert(event.locationInWindow, from: nil)
            let inContainer = NSPoint(x: p.x - textContainerOrigin.x,
                                      y: p.y - textContainerOrigin.y)
            let idx = lm.characterIndex(for: inContainer, in: tc,
                                        fractionOfDistanceBetweenInsertionPoints: nil)
            if idx < (string as NSString).length {
                var range = NSRange()
                if storage.attribute(kConfidenceAttr, at: idx, effectiveRange: &range) != nil {
                    var rect = lm.boundingRect(
                        forGlyphRange: lm.glyphRange(forCharacterRange: range,
                                                     actualCharacterRange: nil), in: tc)
                    rect.origin.x += textContainerOrigin.x
                    rect.origin.y += textContainerOrigin.y
                    onWordClick?(range, rect)
                    flagged = true
                }
            }
        }
        if !flagged { onPlainClick?() }
        super.mouseDown(with: event)
    }
}

final class DictationOverlay: NSObject, NSTextViewDelegate {
    // Confidence tiers for word tinting. Word confidence is the minimum of
    // its tokens' scores (one shaky token flags the whole word). Calibrated
    // against live Parakeet output: correct words on clean audio score
    // ≥0.96, misrecognized words ~0.79–0.87, noise hallucinations <0.55.
    private static let lowConfidence: Double = 0.88      // yellow below this
    private static let veryLowConfidence: Double = 0.55  // red + underline below this

    private static let panelWidth: CGFloat = 760
    private static let buttonRowHeight: CGFloat = 48

    private enum Mode { case caption, review }
    private var mode: Mode = .caption

    private var panel: ReviewPanel?
    private var textView: TranscriptTextView?
    private var scroll: NSScrollView?
    private var buttonBar: NSView?
    private var discardButton: NSButton?
    private var insertButton: NSButton?
    private var actionButtons: [NSButton] = []
    private var hintLabel: NSTextField?
    private var wordPopup: NSView?
    private var popupRange: NSRange?
    private var isPanelKey = false
    private var cardDictating = false
    private var cardDictRange: NSRange?   // provisional span of ⌥⇧D-at-cursor dictation
    private var flashGeneration = 0

    // Set by the app delegate; fired from button clicks / keyboard.
    var onInsert: ((String) -> Void)?
    var onDiscard: (() -> Void)?

    // MARK: Live dictation — the card IS the recording view

    // ⌥⇧D from idle: show the card immediately, with partials streaming into
    // the transcript area. Buttons stay disabled and the text read-only until
    // the final lands (showReview). Never takes key focus — the user's app
    // keeps the keyboard while they talk.
    func beginLiveDictation() {
        DispatchQueue.main.async {
            if self.panel == nil { self.build() }
            guard let panel = self.panel, let tv = self.textView else { return }
            self.flashGeneration += 1   // a pending flash must not hide us
            self.mode = .review
            self.dismissWordPopup()
            tv.isSelectable = false
            tv.isEditable = false       // partials own the text while recording
            self.buttonBar?.isHidden = false
            self.setButtonsEnabled(false)
            // Pure display while recording — click-through and never key, so
            // the user's app keeps mouse and keyboard until the final lands
            // (showReview then makes the card interactive).
            panel.allowsKey = false
            panel.ignoresMouseEvents = true
            panel.makeFirstResponder(nil)
            self.cardDictating = true
            tv.textStorage?.setAttributedString(
                NSAttributedString(string: "", attributes: self.reviewAttrs()))
            self.cardDictRange = NSRange(location: 0, length: 0)
            self.updateCardDictationNow("Listening\u{2026}", words: [])
            self.setKeyAppearance(self.isPanelKey)
            self.relayout()
            panel.orderFrontRegardless()
        }
    }

    // Transient caption-style notice (e.g. the paste-fallback message).
    func flash(_ message: String) {
        DispatchQueue.main.async {
            if self.panel == nil { self.build() }
            self.enterCaptionMode()
            self.flashGeneration += 1
            let gen = self.flashGeneration
            self.setTranscript(message, words: [])
            self.panel?.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard self.flashGeneration == gen else { return }
                self.hide()
            }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.panel?.makeFirstResponder(nil)
            self.panel?.orderOut(nil)
            self.enterCaptionMode()
        }
    }

    // MARK: Review mode

    func showReview(text: String, words: [STTWord], takeKey: Bool) {
        DispatchQueue.main.async {
            if self.panel == nil { self.build() }
            guard let panel = self.panel else { return }
            self.flashGeneration += 1
            self.mode = .review
            self.cardDictating = false
            self.cardDictRange = nil
            self.dismissWordPopup()
            self.textView?.isEditable = true
            self.textView?.isSelectable = true
            self.buttonBar?.isHidden = false
            self.setButtonsEnabled(true)
            panel.allowsKey = true
            panel.ignoresMouseEvents = false
            panel.makeFirstResponder(nil)   // text view starts unfocused
            self.setTranscript(text, words: words)
            if takeKey {
                panel.makeKeyAndOrderFront(nil)
            } else {
                // The user has typed since stopping (or the final arrived
                // late): show the card without stealing keyboard focus.
                // Clicking it makes it key — still without activating us.
                self.setKeyAppearance(false)
                panel.orderFrontRegardless()
            }
        }
    }

    private func enterCaptionMode() {
        guard let panel = panel else { return }
        mode = .caption
        cardDictating = false
        cardDictRange = nil
        dismissWordPopup()
        panel.makeFirstResponder(nil)
        panel.allowsKey = false
        panel.ignoresMouseEvents = true
        panel.contentView?.alphaValue = 1.0
        textView?.isEditable = false
        textView?.isSelectable = false
        buttonBar?.isHidden = true
    }

    // MARK: ⌥⇧D on the card — dictate into the transcript at the caret

    func beginCardDictation() {
        DispatchQueue.main.async {
            guard self.mode == .review, let panel = self.panel, let tv = self.textView else { return }
            self.dismissWordPopup()
            if panel.firstResponder !== tv {
                panel.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
            if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
            self.cardDictating = true
            self.setButtonsEnabled(false)
            // Dictation replaces any selection, and separates itself from the
            // previous word with a space when needed.
            let sel = tv.selectedRange()
            tv.isEditable = false       // partials own the text while recording
            if sel.length > 0 {
                tv.textStorage?.replaceCharacters(in: sel, with: "")
            }
            var loc = sel.location
            let ns = tv.string as NSString
            if loc > 0, !Self.isWhitespace(ns.character(at: loc - 1)) {
                tv.textStorage?.replaceCharacters(
                    in: NSRange(location: loc, length: 0),
                    with: NSAttributedString(string: " ", attributes: self.reviewAttrs()))
                loc += 1
            }
            self.cardDictRange = NSRange(location: loc, length: 0)
            self.setKeyAppearance(self.isPanelKey)
            self.relayout()
        }
    }

    // With `words`, partials render fully tinted (initial dictation — the
    // whole card is the live transcript); without, they render gray
    // (dictate-at-cursor — provisional text amid committed words).
    func updateCardDictation(_ text: String, words: [STTWord] = []) {
        DispatchQueue.main.async {
            self.updateCardDictationNow(text, words: words)
        }
    }

    private func updateCardDictationNow(_ text: String, words: [STTWord]) {
        guard cardDictating, let tv = textView, let range = cardDictRange,
              let storage = tv.textStorage else { return }
        let repl: NSAttributedString
        if words.isEmpty {
            var attrs = reviewAttrs()
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
            repl = NSAttributedString(string: text, attributes: attrs)
        } else {
            repl = attributed(text, words: words)
        }
        // Replace only from the first character that actually changed: the
        // unchanged prefix never repaints, so earlier words stop flickering
        // and re-tinting while you keep talking. The final pass (showReview)
        // re-renders everything with the definitive confidences.
        let current = Array(((storage.string as NSString).substring(with: range)).utf16)
        let incoming = Array(repl.string.utf16)
        var keep = 0
        while keep < current.count && keep < incoming.count && current[keep] == incoming[keep] {
            keep += 1
        }
        if keep > 0, keep < incoming.count, UTF16.isLeadSurrogate(current[keep - 1]) {
            keep -= 1   // never split a surrogate pair
        }
        if keep < current.count || keep < incoming.count {
            let tail = repl.attributedSubstring(
                from: NSRange(location: keep, length: repl.length - keep))
            storage.replaceCharacters(
                in: NSRange(location: range.location + keep, length: range.length - keep),
                with: tail)
        }
        cardDictRange = NSRange(location: range.location, length: repl.length)
        relayout()
        tv.scrollRangeToVisible(NSRange(location: range.location + repl.length, length: 0))
    }

    func finishCardDictation(text: String, words: [STTWord]) {
        DispatchQueue.main.async {
            guard let tv = self.textView, let range = self.cardDictRange else {
                self.endCardDictation()
                return
            }
            let repl = self.attributed(text, words: words)
            tv.textStorage?.replaceCharacters(in: range, with: repl)
            tv.setSelectedRange(NSRange(location: range.location + repl.length, length: 0))
            self.endCardDictation()
            self.relayout()
        }
    }

    func cancelCardDictation() {
        DispatchQueue.main.async {
            if let tv = self.textView, let range = self.cardDictRange, range.length > 0 {
                tv.textStorage?.replaceCharacters(in: range, with: "")
            }
            self.endCardDictation()
            self.relayout()
        }
    }

    private func endCardDictation() {
        cardDictating = false
        cardDictRange = nil
        textView?.isEditable = mode == .review
        setButtonsEnabled(true)
        setKeyAppearance(isPanelKey)
    }

    // MARK: Text rendering + layout

    private func setTranscript(_ text: String, words: [STTWord]) {
        guard let tv = textView else { return }
        tv.textStorage?.setAttributedString(attributed(text, words: words))
        relayout()
        if mode == .caption {
            // Keep the newest words visible while dictating.
            tv.scrollRangeToVisible(NSRange(location: (tv.string as NSString).length, length: 0))
        }
    }

    private func reviewAttrs() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .natural
        para.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para]
    }

    // Words joined with single spaces reproduce Parakeet's transcript text
    // exactly, so coloring by word never changes the visible text. Empty
    // `words` → plain rendering (older daemon without confidence support).
    private func attributed(_ text: String, words: [STTWord]) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any]
        if mode == .caption {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byWordWrapping
            base = [.font: NSFont.systemFont(ofSize: 22, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: para]
        } else {
            base = reviewAttrs()
        }
        guard !words.isEmpty else { return NSAttributedString(string: text, attributes: base) }

        let out = NSMutableAttributedString()
        for (i, w) in words.enumerated() {
            var attrs = base
            if w.confidence < Self.veryLowConfidence {
                attrs[.foregroundColor] = NSColor.systemRed
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.underlineColor] = NSColor.systemRed
                attrs[kConfidenceAttr] = w.confidence
                if let s = w.suggestion { attrs[kSuggestionAttr] = s }
            } else if w.confidence < Self.lowConfidence {
                attrs[.foregroundColor] = NSColor.systemYellow
                attrs[kConfidenceAttr] = w.confidence
                if let s = w.suggestion { attrs[kSuggestionAttr] = s }
            }
            if i > 0 { out.append(NSAttributedString(string: " ", attributes: base)) }
            out.append(NSAttributedString(string: w.text, attributes: attrs))
        }
        return out
    }

    // One geometry pass for both modes: the panel grows upward from its
    // fixed bottom edge as the text wraps, capped at 40% of the screen;
    // beyond that the text scrolls vertically.
    private func relayout() {
        guard let panel = panel, let tv = textView, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let panelW = min(Self.panelWidth, vf.width - 80)
        // Margins + container inset + the text container's default 5pt
        // lineFragmentPadding per side.
        let textWidth = panelW - 40 - 16 - 10
        let measured = tv.attributedString().boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let maxH = vf.height * 0.4
        let bottomBar: CGFloat = mode == .review ? Self.buttonRowHeight : 0
        let minText: CGFloat = mode == .review ? 48 : 40
        let textH = min(max(ceil(measured) + 24, minText), maxH)
        // Panel first, THEN the subview frames — setting frames before a
        // panel resize lets autoresizing mangle them (invisible-text bug).
        // Equal-frame sets are skipped so per-partial updates that don't
        // change the height cause no window churn.
        let panelRect = NSRect(x: vf.midX - panelW / 2, y: vf.minY + 120,
                               width: panelW, height: textH + bottomBar + 24)
        if panel.frame != panelRect { panel.setFrame(panelRect, display: true) }
        let scrollRect = NSRect(x: 20, y: bottomBar + 12,
                                width: panelW - 40, height: textH)
        if scroll?.frame != scrollRect { scroll?.frame = scrollRect }
        if let bar = buttonBar, let discard = discardButton,
           let insert = insertButton, let hint = hintLabel {
            let barH = Self.buttonRowHeight - 20
            bar.frame = NSRect(x: 0, y: 10, width: panelW, height: barH)
            discard.setFrameOrigin(NSPoint(x: 20, y: (barH - discard.frame.height) / 2))
            insert.setFrameOrigin(NSPoint(x: panelW - 20 - insert.frame.width,
                                          y: (barH - insert.frame.height) / 2))
            let hintX = discard.frame.maxX + 12
            hint.frame = NSRect(x: hintX, y: (barH - 16) / 2,
                                width: max(0, insert.frame.minX - 12 - hintX), height: 16)
        }
    }

    // Live-grow the card while the user edits; edits also invalidate the chip.
    func textDidChange(_ notification: Notification) {
        dismissWordPopup()
        relayout()
    }

    // Typed edits render gray — they're the user's words, not the model's,
    // and must never inherit a neighboring word's yellow/red flag.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard mode == .review, let tv = textView else { return }
        var attrs = reviewAttrs()
        attrs[.foregroundColor] = NSColor.secondaryLabelColor
        tv.typingAttributes = attrs
    }

    // Dim the card and adjust the hint while it can't receive keys, so its
    // keyboard affordances never lie.
    private func setKeyAppearance(_ isKey: Bool) {
        isPanelKey = isKey
        guard mode == .review else { return }
        panel?.contentView?.alphaValue = isKey ? 1.0 : 0.9
        if cardDictating {
            hintLabel?.stringValue = "Listening\u{2026} \u{2325}\u{21E7}D to stop"
        } else {
            hintLabel?.stringValue = isKey
                ? "\u{21A9} insert \u{00B7} esc discard \u{00B7} \u{2325}\u{21E7}D dictate at cursor"
                : "Click to edit or insert"
        }
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        actionButtons.forEach { $0.isEnabled = enabled }
    }

    // MARK: Building

    private func build() {
        let panel = ReviewPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 64),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true          // click-through; never steals focus
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // NSPanel hides itself when the app deactivates by default. Ogma can
        // be the active app while the card is up (menu-bar menu, dictionary
        // editor), and switching apps then made the card vanish mid-recording.
        panel.hidesOnDeactivate = false
        // Return/Esc when the text view is NOT focused (Insert also carries
        // Return as a key equivalent; this covers any path it misses).
        panel.fallbackKeyHandler = { [weak self] event in
            switch event.keyCode {
            case 36, 76: self?.insertTapped(); return true   // return / enter
            case 53:     self?.discardTapped(); return true  // escape
            default:     return false
            }
        }
        panel.keyStateChanged = { [weak self] isKey in self?.setKeyAppearance(isKey) }

        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 16
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(bg)

        let tv = TranscriptTextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 18)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = self
        tv.onWordClick = { [weak self] range, rect in
            self?.handleWordClick(range: range, rectInTextView: rect)
        }
        tv.onPlainClick = { [weak self] in self?.dismissWordPopup() }

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        // Frame is fully managed by relayout — no autoresizing.
        bg.addSubview(sv)

        // No Esc keyEquivalent on Discard: key-equivalent dispatch order vs
        // the focused text view is ambiguous across AppKit versions, and
        // getting it wrong destroys edits. Esc is handled explicitly — by the
        // panel's fallback keyDown when browsing, by the text view delegate
        // (end editing) when editing. No Edit button either: the text is
        // directly clickable and typed edits render gray.
        let discard = FirstMouseButton(title: "\u{2717} Discard", target: self,
                                       action: #selector(discardTapped))
        discard.toolTip = "Esc"
        let insert = FirstMouseButton(title: "\u{2713} Insert", target: self,
                                      action: #selector(insertTapped))
        insert.keyEquivalent = "\r"                     // renders as default button
        insert.toolTip = "Return"
        [discard, insert].forEach { $0.bezelStyle = .rounded }
        actionButtons = [discard, insert]

        // The tip text right-aligns against Insert and truncates on the left —
        // changing its text must never shift the buttons. The bar is laid out
        // manually (frames pinned in relayout): Discard hard-left, tip and
        // Insert hard-right.
        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        hint.lineBreakMode = .byTruncatingHead
        self.hintLabel = hint

        let bar = NSView(frame: .zero)
        discard.sizeToFit()
        insert.sizeToFit()
        bar.addSubview(discard)
        bar.addSubview(hint)
        bar.addSubview(insert)
        bar.isHidden = true
        bg.addSubview(bar)
        self.discardButton = discard
        self.insertButton = insert

        self.panel = panel
        self.textView = tv
        self.scroll = sv
        self.buttonBar = bar
    }

    // MARK: Low-confidence word fix-up chip (✓ keep / ✗ remove)

    // Chip: ✓ keep · [↻ suggestion] · ✕ remove — rebuilt per click since the
    // suggestion button's width depends on the word.
    private func handleWordClick(range: NSRange, rectInTextView: NSRect) {
        guard mode == .review, !cardDictating, let tv = textView,
              let content = panel?.contentView, let storage = tv.textStorage else { return }
        let suggestion = storage.attribute(kSuggestionAttr, at: range.location,
                                           effectiveRange: nil) as? String

        wordPopup?.removeFromSuperview()
        let popup = NSVisualEffectView()
        popup.material = .menu
        popup.state = .active
        popup.wantsLayer = true
        popup.layer?.cornerRadius = 8
        popup.layer?.masksToBounds = true
        let keep = FirstMouseButton(title: "\u{2713}", target: self, action: #selector(popupKeep))
        keep.toolTip = "Keep this word"
        var buttons = [keep]
        if let s = suggestion {
            let sug = FirstMouseButton(title: "\u{21BB} \(s)", target: self,
                                       action: #selector(popupApplySuggestion))
            sug.toolTip = "Replace with the context suggestion"
            buttons.append(sug)
        }
        let cut = FirstMouseButton(title: "\u{2715}", target: self, action: #selector(popupCut))
        cut.toolTip = "Remove this word"
        buttons.append(cut)
        var bx: CGFloat = 4
        for b in buttons {
            b.bezelStyle = .rounded
            b.sizeToFit()
            let w = max(b.frame.width, 32)
            b.frame = NSRect(x: bx, y: 3, width: w, height: 24)
            popup.addSubview(b)
            bx += w + 4
        }
        popup.frame = NSRect(x: 0, y: 0, width: bx, height: 30)
        content.addSubview(popup)
        wordPopup = popup

        let rect = tv.convert(rectInTextView, to: content)
        let x = max(8, min(rect.midX - popup.frame.width / 2,
                           content.bounds.width - popup.frame.width - 8))
        var y = rect.maxY + 4   // just above the word
        if y + popup.frame.height > content.bounds.height - 4 {
            y = rect.minY - popup.frame.height - 4   // no room: below instead
        }
        popup.setFrameOrigin(NSPoint(x: x, y: y))
        popupRange = range
        hintLabel?.stringValue = suggestion == nil
            ? "Low confidence \u{2014} may be misheard"
            : "Low confidence \u{2014} \u{21BB} replaces it"
    }

    @objc private func popupApplySuggestion() {
        if let range = popupRange, let storage = textView?.textStorage,
           NSMaxRange(range) <= storage.length,
           let s = storage.attribute(kSuggestionAttr, at: range.location,
                                     effectiveRange: nil) as? String {
            storage.replaceCharacters(
                in: range, with: NSAttributedString(string: s, attributes: reviewAttrs()))
        }
        dismissWordPopup()
        relayout()
    }

    private func dismissWordPopup() {
        guard wordPopup?.isHidden == false || popupRange != nil else { return }
        wordPopup?.isHidden = true
        popupRange = nil
        setKeyAppearance(isPanelKey)   // restore the standard hint
    }

    @objc private func popupKeep() {
        if let range = popupRange, let storage = textView?.textStorage,
           NSMaxRange(range) <= storage.length {
            storage.removeAttribute(kConfidenceAttr, range: range)
            storage.removeAttribute(.underlineStyle, range: range)
            storage.removeAttribute(.underlineColor, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        dismissWordPopup()
    }

    @objc private func popupCut() {
        if let tv = textView, let range = popupRange, let storage = tv.textStorage,
           NSMaxRange(range) <= storage.length {
            var del = range
            let ns = tv.string as NSString
            if NSMaxRange(del) < ns.length, Self.isWhitespace(ns.character(at: NSMaxRange(del))) {
                del.length += 1                                   // take the trailing space
            } else if del.location > 0, Self.isWhitespace(ns.character(at: del.location - 1)) {
                del.location -= 1; del.length += 1                // else the leading one
            }
            storage.replaceCharacters(in: del, with: "")
        }
        dismissWordPopup()
        relayout()
    }

    private static func isWhitespace(_ ch: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(ch) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: Actions

    @objc private func insertTapped() {
        onInsert?(textView?.string ?? "")
    }

    @objc private func discardTapped() {
        onDiscard?()
    }

    // The current selection in the review card, when the card owns the
    // keyboard. Read directly — a synthesized ⌘C can't fetch it, because
    // posted session events go to the ACTIVE app and this app never
    // activates.
    func selectedTranscriptText() -> String? {
        guard mode == .review, let panel = panel, panel.isKeyWindow,
              let tv = textView else { return nil }
        let sel = tv.selectedRange()
        guard sel.length > 0 else { return nil }
        return (tv.string as NSString).substring(with: sel)
    }

    // While editing: Return inserts (Shift+Return for a literal newline),
    // Esc ends editing — pressing Esc again then discards.
    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            onInsert?(view.string)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) ||
           selector == #selector(NSStandardKeyBindingResponding.complete(_:)) {
            view.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - App delegate

@objc final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var config         = Config.load()
    private var accessTimer: Timer?
    private var hotkeyHealthTimer: Timer?
    private var wasAXTrusted = false
    private var animTimer:   Timer?
    private var countdownTimer: Timer?
    private var animPhase:   Double = 0

    // Respeak state — synchronized via speakLock
    private var speakGeneration = 0
    private var currentSpeakProcess: Process?
    private var isSpeakingFlag = false
    private var respeakTimer: Timer?
    private let speakLock = NSLock()

    // Credits cache (fetched from ElevenLabs API)
    private var cachedCredits: (used: Int, limit: Int, fetchedAt: Date)?

    // TTS daemon process (managed mode — started by this app)
    private var ttsDaemonProcess: Process?

    // STT (dictation) state
    private var sttDaemonProcess: Process?
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var sttClient: STTStreamClient?
    private let overlay = DictationOverlay()
    // .starting spans the async gap between the hotkey and the engine
    // actually running (e.g. the mic-permission prompt), so a second press
    // there can't double-start.
    private enum DictationState {
        case idle, starting, recording, awaitingFinal, reviewing
        case cardRecording, cardAwaitingFinal   // ⌥⇧D-at-cursor on the review card
    }
    // Read from the hotkey thread under recordLock; mutated on the main
    // thread only, so main-thread code can branch on it race-free.
    private var dictationState: DictationState = .idle
    private var dictationGeneration = 0
    private var dictationStopAt: CFAbsoluteTime = 0
    // The app that had focus when dictation started — reactivated before the
    // paste, since the review card takes key focus in between.
    private var dictationTargetApp: NSRunningApplication?
    private let recordLock = NSLock()

    private func setDictationState(_ s: DictationState) {
        recordLock.lock(); dictationState = s; recordLock.unlock()
    }
    private func currentDictationState() -> DictationState {
        recordLock.lock(); defer { recordLock.unlock() }
        return dictationState
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Ogma")
        appDelegateRef = self
        overlay.onInsert = { [weak self] text in self?.completeReview(insert: text) }
        overlay.onDiscard = { [weak self] in self?.completeReview(insert: nil) }
        syncBundledResources()
        installHotkey()
        startHotkeyHealthTimer()
        rebuildMenu()
        runFirstLaunchOnboardingIfNeeded()
        if !AXIsProcessTrusted() {
            requestAccessibility()
        }
        updateTTSDaemon()
        fetchCredits()
    }

    func applicationWillTerminate(_ notification: Notification) {
        killCurrentProcess()
        stopTTSDaemon()
        stopSTTDaemon()
    }

    // Re-read config every time the menu opens so we pick up changes from
    // speak.sh (e.g. when the 429 handler installs local TTS and updates the
    // config file).
    func menuWillOpen(_ menu: NSMenu) {
        let fresh = Config.load()
        if fresh.backendsInstalled != config.backendsInstalled ||
           fresh.ttsBackend != config.ttsBackend {
            config = fresh
            rebuildMenu()
            updateTTSDaemon()
        }
        fetchCredits()

        // Tick the load/unload toggle + countdown once a second while the menu
        // stays open. Added to .common modes so it fires during menu tracking.
        updateModelMenuItems()
        countdownTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateModelMenuItems()
        }
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    func setSpeaking(_ active: Bool) {
        // Always stop any existing animation first (prevents leaked timers
        // when the hotkey fires while a previous speak.sh is still running).
        animTimer?.invalidate()
        animTimer = nil

        if active {
            animPhase = 0
            statusItem.button?.image = waveformFrame(phase: 0)
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.animPhase += 0.5
                self.statusItem.button?.image = self.waveformFrame(phase: self.animPhase)
            }
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "waveform", accessibilityDescription: "Ogma")
        }
    }

    private func waveformFrame(phase: Double) -> NSImage {
        let w: CGFloat = 18, h: CGFloat = 18
        let barCount   = 5
        let barWidth:  CGFloat = 2
        let gap:       CGFloat = 1.5
        let totalW     = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX     = (w - totalW) / 2

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        for i in 0..<barCount {
            let t = phase + Double(i) * 0.8
            let norm = (sin(t) + 1) / 2          // 0…1
            let minH: CGFloat = 3
            let maxH: CGFloat = 14
            let barH = minH + CGFloat(norm) * (maxH - minH)
            let x = startX + CGFloat(i) * (barWidth + gap)
            let y = (h - barH) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: barH)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    // MARK: - Hotkey

    func handleHotkey() {
        speakLock.lock()
        let speaking = isSpeakingFlag
        speakLock.unlock()

        if speaking {
            stopSpeaking()
        } else {
            // A selection inside our own review card is read directly — the
            // synthetic ⌘C below lands in the ACTIVE app, which is never us.
            var cardSelection: String?
            DispatchQueue.main.sync {
                cardSelection = self.overlay.selectedTranscriptText()
            }
            if let text = cardSelection, !text.isEmpty {
                runSpeak(withText: text)
                return
            }

            // Simulate ⌘C directly via CGEvent so the settings app's own
            // Accessibility grant is used.
            let src = CGEventSource(stateID: .hidSystemState)
            let cDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
            cDown?.flags = .maskCommand
            let cUp   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
            cUp?.flags = .maskCommand
            cDown?.post(tap: .cgAnnotatedSessionEventTap)
            cUp?.post(tap: .cgAnnotatedSessionEventTap)
            // Wait for the clipboard to be updated before speak.sh reads it.
            Thread.sleep(forTimeInterval: 0.2)

            runSpeak()
        }
    }

    private func installHotkey() {
        guard AXIsProcessTrusted() else { return }
        guard globalTap == nil else { return }  // already installed

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap  = CGEvent.tapCreate(
            tap:              .cgSessionEventTap,
            place:            .headInsertEventTap,
            options:          .defaultTap,
            eventsOfInterest: mask,
            callback:         hotkeyCallback,
            userInfo:         nil)
        guard let tap = tap else { return }

        globalTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        globalTapRunLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeHotkey() {
        if let src = globalTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = globalTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        globalTap = nil
        globalTapRunLoopSource = nil
    }

    // MARK: - Hotkey health (auto-recovery)
    //
    // The event tap dies silently when Accessibility is revoked — and after a
    // re-grant the old tap object never receives events again, so re-enabling
    // is not enough: it needs a full reinstall. The C callback already
    // re-enables timeout-disabled taps; this periodic check covers TCC
    // round-trips and late grants so ⌥⇧/ and ⌥⇧D recover without a relaunch.
    private func startHotkeyHealthTimer() {
        wasAXTrusted = AXIsProcessTrusted()
        hotkeyHealthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkHotkeyHealth()
        }
    }

    private func checkHotkeyHealth() {
        let trusted = AXIsProcessTrusted()
        defer { wasAXTrusted = trusted }

        if !trusted {
            // Revoked: drop the dead tap so a later re-grant starts fresh.
            if globalTap != nil { removeHotkey() }
            if wasAXTrusted { rebuildMenu() }   // show the ⚠️ item
            return
        }
        if globalTap == nil {
            installHotkey()
            if !wasAXTrusted { rebuildMenu() }  // drop the ⚠️ item
            return
        }
        if let tap = globalTap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                removeHotkey()
                installHotkey()
            }
        }
    }

    // Poll until Accessibility is granted (e.g. after user clicks Allow).
    private func startAccessibilityPolling() {
        accessTimer?.invalidate()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.installHotkey()
            self?.rebuildMenu()
        }
    }

    @objc private func requestAccessibility() {
        let key  = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        startAccessibilityPolling()
    }

    // MARK: - Speak process management

    func runSpeak(withText text: String? = nil) {
        // Lazily load the local model on first use. It unloads itself after an
        // idle timeout, so this reloads it when needed. No-op for cloud
        // backends (needsDaemon) or when the daemon is already running.
        startTTSDaemon()

        // In-process mute check via CoreAudio (microseconds, no fork).
        if isOutputMuted() {
            let alert = NSAlert()
            alert.messageText = "Your Mac is muted."
            alert.addButton(withTitle: "Unmute & Play")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                unmuteOutput()
            } else {
                return
            }
        }

        speakLock.lock()
        speakGeneration += 1
        let gen = speakGeneration
        isSpeakingFlag = true
        speakLock.unlock()

        DispatchQueue.main.async { self.setSpeaking(true) }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments    = [speakPath]
            task.environment  = ProcessInfo.processInfo.environment.merging(
                ["OGMA_MUTE_CHECKED": "1"]) { _, new in new }

            if let text = text {
                let pipe = Pipe()
                pipe.fileHandleForWriting.write(text.data(using: .utf8) ?? Data())
                pipe.fileHandleForWriting.closeFile()
                task.standardInput = pipe
            } else {
                task.standardInput = FileHandle.nullDevice
            }

            speakLock.lock()
            currentSpeakProcess = task
            speakLock.unlock()

            do { try task.run() } catch {
                speakLock.lock()
                currentSpeakProcess = nil
                if speakGeneration == gen { isSpeakingFlag = false }
                speakLock.unlock()
                DispatchQueue.main.async {
                    self.speakLock.lock()
                    let current = self.speakGeneration
                    self.speakLock.unlock()
                    if current == gen { self.setSpeaking(false) }
                }
                return
            }

            task.waitUntilExit()

            speakLock.lock()
            currentSpeakProcess = nil
            let currentGen = speakGeneration
            if currentGen == gen { isSpeakingFlag = false }
            speakLock.unlock()

            DispatchQueue.main.async {
                if currentGen == gen { self.setSpeaking(false) }
            }
        }
    }

    func killCurrentProcess() {
        speakLock.lock()
        speakGeneration += 1
        let process = currentSpeakProcess
        currentSpeakProcess = nil  // prevent duplicate kill attempts
        speakLock.unlock()

        guard let process = process, process.isRunning else { return }
        let pid = process.processIdentifier

        // Kill child processes first (afplay, curl, python3).
        // bash 3.2 defers SIGTERM while a foreground child is running,
        // so we kill children first to let bash process the signal.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", String(pid)]
        try? pkill.run()
        pkill.waitUntilExit()

        process.terminate()
    }

    // MARK: - TTS daemon lifecycle

    private var needsDaemon: Bool {
        let b = config.ttsBackend
        return (b == "local" || b == "auto") && isLocalInstalled
    }

    private var venvPythonPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/ogma/venv/bin/python3")
    }

    // The daemon creates this socket only after the model is fully loaded and
    // warmed up, and removes it on shutdown — so its presence is an accurate
    // "model loaded & ready" signal.
    private var ttsSocketPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/ogma/tts.sock")
    }
    private var ttsStatePath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/ogma/tts_state.json")
    }
    private var ttsPidPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/ogma/tts_server.pid")
    }

    private var isModelLoaded: Bool {
        FileManager.default.fileExists(atPath: ttsSocketPath)
    }

    // Title for the clickable load/unload toggle line.
    private func modelToggleTitle() -> String {
        if isModelLoaded { return "\u{25C9} Model loaded — click to unload" }
        if let p = ttsDaemonProcess, p.isRunning {
            return "\u{25CC} Model loading\u{2026}"
        }
        return "\u{25CB} Model unloaded — click to load"
    }

    // Seconds until a daemon auto-unloads, from its state file. nil when not
    // loaded or unreadable. Shared by the TTS and STT menu countdowns.
    private func remainingSeconds(statePath: String, loaded: Bool) -> Int? {
        guard loaded,
              let data = FileManager.default.contents(atPath: statePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timeout = (obj["idle_timeout"] as? NSNumber)?.doubleValue,
              let last = (obj["last_request"] as? NSNumber)?.doubleValue
        else { return nil }
        return max(0, Int((timeout - (Date().timeIntervalSince1970 - last)).rounded()))
    }

    private func countdownTitle(_ s: Int?) -> String {
        guard let s = s else { return "Unloading in: \u{2014}" }
        return String(format: "Unloading in: %d:%02d", s / 60, s % 60)
    }

    // STT (dictation) status-line twins of the TTS helpers.
    private func sttModelToggleTitle() -> String {
        if isSTTModelLoaded { return "\u{25C9} Model loaded — click to unload" }
        if let p = sttDaemonProcess, p.isRunning { return "\u{25CC} Model loading\u{2026}" }
        return "\u{25CB} Model unloaded — click to load"
    }

    private var ttsServerPath: String {
        ((speakPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("tts_server.py")
    }

    private func startTTSDaemon() {
        guard needsDaemon else { return }
        if let existing = ttsDaemonProcess, existing.isRunning { return }

        let python = venvPythonPath
        let server = ttsServerPath

        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: server) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [server, "--managed"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            ttsDaemonProcess = task
        } catch {
            // Daemon failed to start — speak.sh will fall back to direct invocation
        }
    }

    private func stopTTSDaemon() {
        guard let process = ttsDaemonProcess, process.isRunning else {
            ttsDaemonProcess = nil
            return
        }
        process.terminate()  // sends SIGTERM → daemon cleans up and exits
        ttsDaemonProcess = nil
    }

    // The model is loaded lazily on first use (see runSpeak) and unloads
    // itself after an idle timeout, so we never eager-start here — we only
    // stop a running daemon when the active backend no longer needs local TTS.
    private func updateTTSDaemon() {
        if !needsDaemon { stopTTSDaemon() }
    }

    // MARK: - STT (dictation) daemon + paths

    private var sttServerPath: String {
        ((speakPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("stt_server.py")
    }
    private var sttSocketPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/ogma/stt.sock")
    }
    private var sttStatePath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/ogma/stt_state.json")
    }
    private var sttPidPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/ogma/stt_server.pid")
    }

    // Dictation needs the shared venv + the STT daemon script (installed
    // together with local TTS, which also pip-installs parakeet-mlx).
    private var isSTTInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: venvPythonPath) &&
        FileManager.default.fileExists(atPath: sttServerPath)
    }
    private var isSTTModelLoaded: Bool {
        FileManager.default.fileExists(atPath: sttSocketPath)
    }

    private func startSTTDaemon() {
        guard isSTTInstalled else { return }
        if let existing = sttDaemonProcess, existing.isRunning { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: venvPythonPath)
        task.arguments = [sttServerPath, "--managed"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); sttDaemonProcess = task } catch {}
    }

    private func stopSTTDaemon() {
        guard let process = sttDaemonProcess, process.isRunning else {
            sttDaemonProcess = nil
            return
        }
        process.terminate()
        sttDaemonProcess = nil
    }

    // Stop whichever STT daemon is running via its PID file.
    private func unloadSTTModel() {
        if let pidStr = try? String(contentsOfFile: sttPidPath, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        stopSTTDaemon()
    }

    // MARK: - Dictation flow (⌥⇧D)

    func handleDictateHotkey() {
        DispatchQueue.main.async {
            switch self.currentDictationState() {
            case .idle:
                self.startDictation()
            case .recording:
                self.stopDictation()
            case .starting, .awaitingFinal, .cardAwaitingFinal:
                break   // transition in flight; ignore
            case .reviewing:
                // On the card, the hotkey dictates MORE — into the transcript
                // at the caret. (Re-record = ✗ discard, then ⌥⇧D.)
                self.startCardDictation()
            case .cardRecording:
                self.stopCardDictation()
            }
        }
    }

    private func startDictation() {
        guard currentDictationState() == .idle else { return }
        setDictationState(.starting)
        // Where the text should land — captured before anything can shift focus.
        dictationTargetApp = NSWorkspace.shared.frontmostApplication
        guard isSTTInstalled else {
            setDictationState(.idle)
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Dictation not installed"
            a.informativeText = "Local dictation needs the Ogma local engine (Apple Silicon). Install it from the menu, then try ⌥⇧D again."
            a.runModal()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard self.currentDictationState() == .starting else { return }
                    if granted {
                        self.beginRecording()
                    } else {
                        self.setDictationState(.idle)
                        self.showMicDenied()
                    }
                }
            }
        default:
            setDictationState(.idle)
            showMicDenied()
        }
    }

    private func showMicDenied() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Microphone access needed"
        a.informativeText = "Enable Microphone for Ogma in System Settings → Privacy & Security → Microphone, then press ⌥⇧D to dictate."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static let sttSampleRate = 16000

    // Shared microphone + socket-stream setup for both dictation flows
    // (fresh dictation and dictate-into-card). Handlers run on main and only
    // for the session that is still current (identity-guarded). Returns the
    // engine-start error, or nil on success.
    private func startStreamingSession(
        onPartial: @escaping (String, [STTWord]) -> Void,
        onFinal: @escaping (String, [STTWord]) -> Void) -> Error? {
        // Warm the model now so it's ready by the time the user stops talking.
        startSTTDaemon()

        struct SetupError: Error, LocalizedError {
            var errorDescription: String? { "The microphone's audio format is unavailable." }
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Double(Self.sttSampleRate),
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: outFormat) else {
            return SetupError()
        }
        audioEngine = engine
        audioConverter = converter

        let client = STTStreamClient()
        // Identity guards: a late partial/final from an abandoned session
        // (fallback fired, or a new recording already started) is ignored.
        client.onPartial = { [weak self, weak client] p, words in
            DispatchQueue.main.async {
                guard let self = self, self.sttClient === client else { return }
                onPartial(p, words)
            }
        }
        client.onFinal = { [weak self, weak client] f, words in
            DispatchQueue.main.async {
                guard let self = self, self.sttClient === client else { return }
                onFinal(f, words)
            }
        }
        sttClient = client

        // The daemon may still be loading the model — connect in the
        // background once its socket appears. Audio captured meanwhile is
        // buffered by the client and flushed on connect, so nothing is lost.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var waited = 0.0
            while !self.isSTTModelLoaded && waited < 30 && !client.isClosed {
                Thread.sleep(forTimeInterval: 0.2); waited += 0.2
            }
            guard !client.isClosed else { return }   // session already torn down
            _ = client.connect(socketPath: self.sttSocketPath,
                               sampleRate: Self.sttSampleRate)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self, let conv = self.audioConverter else { return }
            let cap = AVAudioFrameCount(
                Double(buffer.frameLength) * Double(Self.sttSampleRate) / hwFormat.sampleRate) + 512
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            if let ch = outBuf.floatChannelData, outBuf.frameLength > 0 {
                let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
                self.sttClient?.send(samples: samples)
            }
        }

        do {
            try engine.start()
            dictationGeneration += 1
            return nil
        } catch {
            cleanupDictation()
            return error
        }
    }

    private func stopEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        setDictating(false)
        dictationStopAt = CFAbsoluteTimeGetCurrent()
    }

    private func beginRecording() {
        overlay.beginLiveDictation()
        let error = startStreamingSession(
            onPartial: { [weak self] p, words in
                self?.overlay.updateCardDictation(p.isEmpty ? "Listening\u{2026}" : p,
                                                  words: p.isEmpty ? [] : words)
            },
            onFinal: { [weak self] f, words in
                self?.finishDictation(final: f, words: words)
            })
        if let error = error {
            overlay.hide()
            setDictationState(.idle)
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Could not start recording"
            a.informativeText = "\(error.localizedDescription)"
            a.runModal()
            return
        }
        setDictationState(.recording)
        setDictating(true)
    }

    private func stopDictation() {
        guard currentDictationState() == .recording else { return }
        setDictationState(.awaitingFinal)
        stopEngine()
        sttClient?.finish()   // send end-of-stream; onFinal fires with the result

        // Fallback: if no final arrives, tear down so the overlay doesn't
        // linger. On a cold start the model can take a long time to load and
        // the connect poller waits up to 30s — give that path time instead of
        // silently discarding the dictation at 6s. Guarded so it can't touch
        // a newer session or a showing review card.
        let timeout: Double = isSTTModelLoaded ? 6 : 35
        let gen = dictationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self,
                  self.dictationGeneration == gen,
                  self.currentDictationState() == .awaitingFinal else { return }
            self.overlay.hide()
            self.cleanupDictation()
            self.setDictationState(.idle)
        }
    }

    // Called (on main, identity-guarded) when the daemon sends the final.
    private func finishDictation(final: String, words: [STTWord]) {
        // The daemon can end the stream on its own (60s of silence — e.g. a
        // Bluetooth mic died): tear the recording down first.
        if currentDictationState() == .recording {
            stopEngine()
        }
        cleanupDictation()
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            overlay.hide()
            setDictationState(.idle)
            return
        }
        if config.dictationReview {
            setDictationState(.reviewing)
            // Steal keyboard focus only when it's safe: the user hasn't typed
            // since stopping and the final came quickly. Otherwise the card
            // shows unfocused and a click arms it.
            let sinceStop = CFAbsoluteTimeGetCurrent() - dictationStopAt
            let takeKey = lastUserKeyDownAt <= dictationStopAt && sinceStop < 1.5
            overlay.showReview(text: text, words: words, takeKey: takeKey)
        } else {
            // Direct insert: the caption never took key focus, so the target
            // field is still active — paste straight in, as before.
            overlay.hide()
            setDictationState(.idle)
            injectText(text)
        }
    }

    // Review card resolution: insert the (possibly edited) text, or discard.
    private func completeReview(insert text: String?) {
        guard currentDictationState() == .reviewing else { return }
        setDictationState(.idle)
        overlay.hide()
        let captured = dictationTargetApp
        dictationTargetApp = nil
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        // Give the window server a beat to route key focus back to the
        // frontmost app after the panel orders out, then deliver.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.deliverTranscript(text, fallbackTarget: captured)
        }
    }

    // MARK: Dictate-into-card (⌥⇧D while reviewing)

    private func startCardDictation() {
        guard currentDictationState() == .reviewing else { return }
        overlay.beginCardDictation()
        let error = startStreamingSession(
            onPartial: { [weak self] p, _ in
                self?.overlay.updateCardDictation(p)
            },
            onFinal: { [weak self] f, words in
                self?.finishCardDictationFlow(final: f, words: words)
            })
        if error != nil {
            overlay.cancelCardDictation()
            return   // stays in .reviewing
        }
        setDictationState(.cardRecording)
        setDictating(true)
    }

    private func stopCardDictation() {
        guard currentDictationState() == .cardRecording else { return }
        setDictationState(.cardAwaitingFinal)
        stopEngine()
        sttClient?.finish()

        // Same lingering-session fallback as the main flow: on timeout the
        // provisional text is removed and the card stays up.
        let timeout: Double = isSTTModelLoaded ? 6 : 35
        let gen = dictationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self,
                  self.dictationGeneration == gen,
                  self.currentDictationState() == .cardAwaitingFinal else { return }
            self.cleanupDictation()
            self.overlay.cancelCardDictation()
            self.setDictationState(.reviewing)
        }
    }

    private func finishCardDictationFlow(final: String, words: [STTWord]) {
        if currentDictationState() == .cardRecording {   // daemon ended it on its own
            stopEngine()
        }
        cleanupDictation()
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            overlay.cancelCardDictation()
        } else {
            overlay.finishCardDictation(text: text, words: words)
        }
        setDictationState(.reviewing)
    }

    // Paste into whatever the user visibly has focused — normally the app
    // dictation started in; if they clicked elsewhere while reviewing, that
    // click placed the caret and is the intent. If nothing usable is
    // frontmost, try re-activating the app captured at dictation start; and
    // when no safe paste target exists, fall back to a plain clipboard copy
    // so the transcript is never lost.
    private func deliverTranscript(_ text: String, fallbackTarget: NSRunningApplication?,
                                   attempts: Int = 0) {
        let myPid = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != pid_t(myPid) {
            // Secure input (password field) or no focused UI element: a
            // synthetic ⌘V would vanish and the clipboard restore would then
            // destroy the transcript. Copy instead.
            if IsSecureEventInputEnabled() || !hasFocusedElement(pid: front.processIdentifier) {
                copyTranscriptFallback(text)
            } else {
                injectText(text)
            }
            return
        }
        // Nothing (or only us) frontmost — bring the original target back and
        // poll for it to land, then the branch above pastes.
        if attempts == 0 {
            guard let target = fallbackTarget, !target.isTerminated else {
                copyTranscriptFallback(text)
                return
            }
            target.activate()
        } else if attempts > 30 {   // ~1.5s: activation failed or was denied
            copyTranscriptFallback(text)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.deliverTranscript(text, fallbackTarget: fallbackTarget,
                                    attempts: attempts + 1)
        }
    }

    // The app already holds Accessibility trust — ask where keyboard focus
    // is. Only a definitive "nothing focused" blocks the paste; apps with
    // broken AX support get the benefit of the doubt.
    private func hasFocusedElement(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        // A hung target must not beachball us for the default ~6s AX timeout.
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &value)
        switch err {
        case .success: return value != nil
        case .noValue: return false
        default:       return true
        }
    }

    private func copyTranscriptFallback(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Don't clobber the caption if the user already started re-dictating.
        if currentDictationState() == .idle {
            overlay.flash("Transcript copied \u{2014} press \u{2318}V to paste")
        }
    }

    // Note: the client's callbacks are NOT nil'd here — the read thread may
    // be invoking them concurrently (unsynchronized closure vars). Stale
    // callbacks are already dropped by the `sttClient === client` guards.
    private func cleanupDictation() {
        sttClient?.close()
        sttClient = nil
        audioEngine = nil
        audioConverter = nil
    }

    // Insert transcribed text at the cursor via the pasteboard + ⌘V, then
    // restore the previous clipboard. Uses the app's existing Accessibility
    // grant (same as the ⌥⇧/ ⌘C synthesis). The restore is skipped if the
    // pasteboard changed again in the meantime (e.g. the user copied
    // something), and waits 1s so a busy target still pastes the transcript,
    // not the restored old clipboard.
    private func injectText(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let myChange = pb.changeCount

        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)  // 9 = V
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cgAnnotatedSessionEventTap)
        vUp?.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard pb.changeCount == myChange else { return }
            pb.clearContents()
            if let saved = saved { pb.setString(saved, forType: .string) }
        }
    }

    // Swap the menu bar icon to a mic while recording.
    private func setDictating(_ active: Bool) {
        if active {
            statusItem.button?.image = NSImage(
                systemSymbolName: "mic.fill", accessibilityDescription: "Dictating")
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "waveform", accessibilityDescription: "Ogma")
        }
    }

    private func stopSpeaking() {
        killCurrentProcess()
        speakLock.lock()
        isSpeakingFlag = false
        speakLock.unlock()
        DispatchQueue.main.async { self.setSpeaking(false) }
    }

    func calculateRemainingText() -> String? {
        let tmpDir = NSTemporaryDirectory()
        let textPath = (tmpDir as NSString).appendingPathComponent("ogma_text")
        let statusPath = (tmpDir as NSString).appendingPathComponent("ogma_status")

        guard let text = try? String(contentsOfFile: textPath, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }

        guard let statusStr = try? String(contentsOfFile: statusPath, encoding: .utf8) else {
            return text  // no status file (still generating) → restart from beginning
        }

        let lines = statusStr.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              let startTime = TimeInterval(lines[0]),
              let duration = TimeInterval(lines[1]),
              duration > 0 else {
            return text  // invalid status → restart from beginning
        }

        let elapsed = Date().timeIntervalSince1970 - startTime
        let ratio = min(max(elapsed / duration, 0), 1)

        // For short texts, restart from beginning
        if text.count < 100 { return text }

        // Use per-sentence offset from 4-line STATUS_FILE when available
        let approxCharPos: Int
        if lines.count >= 4,
           let charOffset = Int(lines[2]),
           let sentenceLen = Int(lines[3]),
           sentenceLen > 0 {
            approxCharPos = charOffset + Int(Double(sentenceLen) * ratio)
        } else {
            approxCharPos = Int(Double(text.count) * ratio)
        }

        // Near the end of the full text — restart from beginning
        if approxCharPos >= text.count - 50 { return text }

        // Find the nearest sentence boundary at or after approxCharPos
        let searchStart = max(0, approxCharPos - 20)
        let startIdx = text.index(text.startIndex, offsetBy: min(searchStart, text.count))
        let searchStr = String(text[startIdx...])

        // Look for sentence boundaries: .!? followed by whitespace, or newline
        var bestOffset: Int? = nil
        let chars = Array(searchStr.unicodeScalars)
        for i in 0..<chars.count {
            let absPos = searchStart + i
            guard absPos >= approxCharPos else { continue }
            if i > 0 && (chars[i-1] == "." || chars[i-1] == "!" || chars[i-1] == "?") &&
               (chars[i] == " " || chars[i] == "\n" || chars[i] == "\t") {
                bestOffset = absPos
                break
            }
            if chars[i] == "\n" && i + 1 < chars.count {
                bestOffset = absPos + 1
                break
            }
            // Don't search too far — 200 chars max
            if absPos - approxCharPos > 200 {
                bestOffset = approxCharPos
                break
            }
        }

        let resumePos = bestOffset ?? approxCharPos
        guard resumePos < text.count else { return text }
        let resumeIdx = text.index(text.startIndex, offsetBy: resumePos)
        let remaining = String(text[resumeIdx...]).trimmingCharacters(in: .whitespaces)
        return remaining.isEmpty ? text : remaining
    }

    func respeak() {
        let remainingText = calculateRemainingText()
        killCurrentProcess()
        // Brief delay to let the old process clean up
        Thread.sleep(forTimeInterval: 0.05)
        runSpeak(withText: remainingText)
    }

    func scheduleRespeak() {
        speakLock.lock()
        let speaking = isSpeakingFlag
        speakLock.unlock()
        guard speaking else { return }

        DispatchQueue.main.async { [self] in
            respeakTimer?.invalidate()
            respeakTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.respeak()
                }
            }
        }
    }

    // MARK: - Keychain helpers

    private func readAPIKey() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-a", "ogma", "-s", "ogma-api-key", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    private func saveAPIKey(_ key: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["add-generic-password", "-a", "ogma", "-s", "ogma-api-key", "-w", key, "-U"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private func deleteAPIKey() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["delete-generic-password", "-a", "ogma", "-s", "ogma-api-key"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Backend submenu — always visible so users can discover and switch
        menu.addItem(submenuItem("Backend", items: buildBackendItems()))
        menu.addItem(.separator())

        let showEl      = config.ttsBackend == "auto" || config.ttsBackend == "elevenlabs"
        let showLocal   = config.ttsBackend == "local" ||
                          (config.ttsBackend == "auto" && isLocalInstalled)
        let showHeaders = showEl && showLocal

        // ── ElevenLabs section ──
        if showEl {
            if showHeaders { menu.addItem(hintItem("ElevenLabs")) }
            menu.addItem(submenuItem("Voice", items: buildVoiceItems()))
            menu.addItem(submenuItem("Speed", items: buildElSpeedItems()))
            menu.addItem(submenuItem("Model", items: buildModelItems()))
            menu.addItem(submenuItem("Stability", items: buildStabilityItems()))
            menu.addItem(submenuItem("Similarity", items: buildSimilarityItems()))
            menu.addItem(submenuItem("Style", items: buildStyleItems()))
            let boost = NSMenuItem(
                title:  "Speaker Boost",
                action: #selector(toggleSpeakerBoost),
                keyEquivalent: "")
            boost.target = self
            boost.state = config.useSpeakerBoost ? .on : .off
            menu.addItem(boost)
            menu.addItem(.separator())
        }

        // ── Local (Kokoro) section ──
        if showLocal {
            if showHeaders { menu.addItem(hintItem("Local (Kokoro)")) }
            // Clickable load/unload toggle (tag 998) + live countdown (tag 997),
            // both refreshed by the menu-open timer in updateModelMenuItems().
            let toggle = NSMenuItem(title: modelToggleTitle(),
                                    action: #selector(toggleModel), keyEquivalent: "")
            toggle.target = self
            toggle.tag = 998
            menu.addItem(toggle)

            let countdown = NSMenuItem(
                title: countdownTitle(remainingSeconds(statePath: ttsStatePath, loaded: isModelLoaded)),
                action: nil, keyEquivalent: "")
            countdown.tag = 997
            countdown.isEnabled = false
            countdown.isHidden = !isModelLoaded
            menu.addItem(countdown)

            menu.addItem(submenuItem("Auto-unload after",
                                     items: buildIdleTimeoutItems()))
            menu.addItem(submenuItem("Voice", items: buildLocalVoiceItems()))
            menu.addItem(submenuItem("Speed", items: buildLocalSpeedItems()))
            menu.addItem(.separator())
        }

        // ── Dictation (Parakeet STT) section ──
        if isSTTInstalled {
            if showHeaders { menu.addItem(hintItem("Dictation \u{2014} \u{2325}\u{21E7}D")) }
            let sttToggle = NSMenuItem(title: sttModelToggleTitle(),
                                       action: #selector(toggleSttModel), keyEquivalent: "")
            sttToggle.target = self
            sttToggle.tag = 996
            menu.addItem(sttToggle)

            let sttCountdown = NSMenuItem(
                title: countdownTitle(remainingSeconds(statePath: sttStatePath, loaded: isSTTModelLoaded)),
                action: nil, keyEquivalent: "")
            sttCountdown.tag = 995
            sttCountdown.isEnabled = false
            sttCountdown.isHidden = !isSTTModelLoaded
            menu.addItem(sttCountdown)

            let review = NSMenuItem(title: "Review before insert",
                                    action: #selector(toggleDictationReview), keyEquivalent: "")
            review.target = self
            review.state = config.dictationReview ? .on : .off
            menu.addItem(review)

            let dict = NSMenuItem(title: "Dictionary\u{2026}",
                                  action: #selector(editDictionary), keyEquivalent: "")
            dict.target = self
            menu.addItem(dict)

            menu.addItem(submenuItem("Auto-unload after",
                                     items: buildSttIdleTimeoutItems()))
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                let warn = NSMenuItem(title: "\u{26A0}\u{FE0F}  Enable Microphone for dictation",
                                      action: #selector(requestMicPermission), keyEquivalent: "")
                warn.target = self
                menu.addItem(warn)
            }
            menu.addItem(.separator())
        }

        // Sentence Pause — playback-level setting, applies to all backends
        let pauseItem = NSMenuItem(
            title:  "Sentence Pause: \(config.sentencePause) ms",
            action: #selector(editSentencePause),
            keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        // API Key + Credits — when ElevenLabs is active
        if showEl {
            // Credits display (hidden until successfully fetched)
            let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            creditsItem.tag = 999
            creditsItem.isEnabled = false
            creditsItem.isHidden = true
            menu.addItem(creditsItem)

            let apiItem = NSMenuItem(
                title:  "API Key\u{2026}",
                action: #selector(manageAPIKey),
                keyEquivalent: "")
            apiItem.target = self
            menu.addItem(apiItem)
        }

        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(
                title:          "⚠️  Enable Accessibility for ⌥⇧/",
                action:         #selector(requestAccessibility),
                keyEquivalent:  "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: Menu builders

    private func buildBackendItems() -> [NSMenuItem] {
        [
            item("Auto", #selector(pickBackend(_:)),
                 repr: "auto", on: config.ttsBackend == "auto"),
            item("ElevenLabs", #selector(pickBackend(_:)),
                 repr: "elevenlabs", on: config.ttsBackend == "elevenlabs"),
            item("Local (Kokoro)", #selector(pickBackend(_:)),
                 repr: "local", on: config.ttsBackend == "local"),
        ]
    }

    private func buildVoiceItems() -> [NSMenuItem] {
        let isCustom = !knownVoices.contains { $0.id == config.voiceId }
        var items = knownVoices.map { v in
            item(v.name, #selector(pickVoice(_:)), repr: v.id, on: v.id == config.voiceId)
        }
        items.append(.separator())
        let customLabel = isCustom ? "Custom: \(config.voiceId)" : "Custom voice ID…"
        items.append(item(customLabel, #selector(customVoice), repr: "", on: isCustom))
        return items
    }

    private func buildLocalVoiceItems() -> [NSMenuItem] {
        kokoroVoices.map { v in
            item(v.name, #selector(pickLocalVoice(_:)), repr: v.id, on: v.id == config.localVoice)
        }
    }

    private func buildModelItems() -> [NSMenuItem] {
        knownModels.map { m in
            item(m.name, #selector(pickModel(_:)), repr: m.id, on: m.id == config.modelId)
        }
    }

    private func buildElSpeedItems() -> [NSMenuItem] {
        elSpeedSteps.map { s in
            item(s.label, #selector(pickSpeed(_:)),
                 repr: String(s.value), on: abs(s.value - config.speed) < 0.01)
        }
    }

    private func buildLocalSpeedItems() -> [NSMenuItem] {
        localSpeedSteps.map { s in
            item(s.label, #selector(pickLocalSpeed(_:)),
                 repr: String(s.value), on: abs(s.value - config.localSpeed) < 0.01)
        }
    }

    private func buildIdleTimeoutItems() -> [NSMenuItem] {
        var items = [hintItem("Unload the model after this long idle"), .separator()]
        items += idleTimeoutSteps.map { s in
            item(s.label, #selector(pickIdleTimeout(_:)),
                 repr: String(s.value), on: s.value == config.localIdleTimeout)
        }
        return items
    }

    private func buildSttIdleTimeoutItems() -> [NSMenuItem] {
        var items = [hintItem("Unload the model after this long idle"), .separator()]
        items += idleTimeoutSteps.map { s in
            item(s.label, #selector(pickSttIdleTimeout(_:)),
                 repr: String(s.value), on: s.value == config.sttIdleTimeout)
        }
        return items
    }

    private func buildStabilityItems() -> [NSMenuItem] {
        var items = [hintItem("Lower = expressive · Higher = steady"), .separator()]
        items += stabilitySteps.map { s in
            item(s.label, #selector(pickStability(_:)),
                 repr: String(s.value), on: abs(s.value - config.stability) < 0.01)
        }
        return items
    }

    private func buildSimilarityItems() -> [NSMenuItem] {
        var items = [hintItem("How closely output matches the original voice"), .separator()]
        items += similaritySteps.map { s in
            item(s.label, #selector(pickSimilarity(_:)),
                 repr: String(s.value), on: abs(s.value - config.similarityBoost) < 0.01)
        }
        return items
    }

    private func buildStyleItems() -> [NSMenuItem] {
        var items = [hintItem("Amplifies characteristic delivery · adds latency"), .separator()]
        items += styleSteps.map { s in
            item(s.label, #selector(pickStyle(_:)),
                 repr: String(s.value), on: abs(s.value - config.style) < 0.01)
        }
        return items
    }

    // MARK: Helpers

    private func hintItem(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector,
                      repr: String, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = repr
        i.state = on ? .on : .off
        return i
    }

    private func submenuItem(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        parent.submenu = sub
        return parent
    }

    // MARK: Backend setup helpers

    private var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }.hasPrefix("arm64")
    }

    private var isLocalInstalled: Bool {
        config.backendsInstalled == "local" || config.backendsInstalled == "both"
    }

    private var installLocalPath: String {
        ((speakPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("install-local.sh")
    }

    /// Show "Install Local TTS" dialog. Returns true if user clicked Install.
    private func offerLocalInstall(skipLabel: String = "Cancel") -> Bool {
        guard isAppleSilicon else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Apple Silicon Required"
            a.informativeText = "Local TTS (Kokoro) requires an Apple Silicon Mac (M1 or later)."
            a.alertStyle = .warning
            a.addButton(withTitle: "OK")
            a.runModal()
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Local TTS"
        alert.informativeText = "This will install mlx-audio and download the Kokoro voice model (~350 MB)."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: skipLabel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Run install-local.sh in background. On success, reload config, set
    /// desiredBackend (because install-local.sh forces TTS_BACKEND="local"),
    /// and rebuild the menu.
    private func runInstallLocal(desiredBackend: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [installLocalPath]
            task.standardOutput = FileHandle.nullDevice
            task.standardError  = FileHandle.nullDevice
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(false) }
                return
            }
            task.waitUntilExit()
            let success = task.terminationStatus == 0
            DispatchQueue.main.async { [self] in
                if success {
                    config = Config.load()
                    config.ttsBackend = desiredBackend
                    config.save()
                    rebuildMenu()
                }
                completion(success)
            }
        }
    }

    private func showInstallResult(success: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if success {
            a.messageText = "Local TTS Installed"
            a.informativeText = "mlx-audio and the Kokoro model are ready."
        } else {
            a.messageText = "Installation Failed"
            a.informativeText = "Could not install local TTS.\n\nAn internet connection is required for the first install.\nPlease check your connection and try again."
            a.alertStyle = .warning
        }
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: Packaged app — bundled-resource sync + first-run onboarding

    /// Directory of helper scripts bundled inside the app (packaged builds
    /// only — nil when running a bare swiftc binary during development).
    private var bundledScriptsDir: String? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let dir = (res as NSString).appendingPathComponent("scripts")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return dir
    }

    private var ogmaDataDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/ogma")
    }

    /// Copy the bundled helper scripts into ~/.local/bin whenever they are
    /// missing or the app version changed (first run after install or update).
    /// The scripts land quarantine-free because this app wrote them itself.
    private func syncBundledResources() {
        guard let scriptsDir = bundledScriptsDir else { return }
        let fm = FileManager.default
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let marker = (ogmaDataDir as NSString).appendingPathComponent("app-version")
        let installedVersion = (try? String(contentsOfFile: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if installedVersion == version, fm.isExecutableFile(atPath: speakPath) { return }

        let binDir = (speakPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: ogmaDataDir, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: scriptsDir)) ?? [] {
            let src = (scriptsDir as NSString).appendingPathComponent(name)
            let dst = (binDir as NSString).appendingPathComponent(name)
            try? fm.removeItem(atPath: dst)
            do {
                try fm.copyItem(atPath: src, toPath: dst)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
            } catch {
                NSLog("Ogma: failed to install \(name): \(error.localizedDescription)")
            }
        }
        installServicesWorkflow()
        try? version.write(toFile: marker, atomically: true, encoding: .utf8)
    }

    /// First launch of a packaged install: no config file exists yet, so walk
    /// through backend choice, API key, and the local-model download —
    /// everything install.command used to do with osascript dialogs.
    private func runFirstLaunchOnboardingIfNeeded() {
        guard bundledScriptsDir != nil,
              !FileManager.default.fileExists(atPath: configPath) else { return }

        NSApp.activate(ignoringOtherApps: true)

        var backend = "elevenlabs"          // Intel: cloud only
        if isAppleSilicon {
            let alert = NSAlert()
            alert.messageText = "Welcome to Ogma"
            alert.informativeText = """
                ⌥⇧/ reads your selected text aloud. ⌥⇧D types what you say.

                Choose your text-to-speech backend — you can change it anytime from the menu bar:

                • Both — ElevenLabs cloud with free local fallback
                • ElevenLabs Only — cloud voices (needs a free API key)
                • Local Only — free and private, runs entirely on your Mac
                """
            alert.addButton(withTitle: "Both")
            alert.addButton(withTitle: "ElevenLabs Only")
            alert.addButton(withTitle: "Local Only")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  backend = "auto"
            case .alertSecondButtonReturn: backend = "elevenlabs"
            default:                       backend = "local"
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "Welcome to Ogma"
            alert.informativeText = "⌥⇧/ reads your selected text aloud.\n\nOgma uses ElevenLabs cloud voices on Intel Macs — you'll need a free API key with Text-to-Speech and User Read permissions."
            alert.addButton(withTitle: "Continue")
            alert.runModal()
        }

        if backend == "auto" {
            _ = showAPIKeyDialog(forBackendSwitch: false, optional: true)
        } else if backend == "elevenlabs" {
            if !showAPIKeyDialog(forBackendSwitch: true) {
                showNote("No API Key Set",
                         "You can add one anytime via the menu bar icon → API Key…")
            }
        }

        config = Config.load()              // defaults — no file exists yet
        config.ttsBackend = backend
        config.backendsInstalled = backend == "local" ? "local" : "elevenlabs"
        config.save()
        rebuildMenu()

        if backend != "elevenlabs" && isAppleSilicon {
            showNote("Installing Local Speech Models",
                     "mlx-audio and the Kokoro voice model (~350 MB) are downloading in the background.\n\nYou'll be notified when local TTS is ready.")
            runInstallLocal(desiredBackend: backend) { [weak self] ok in
                self?.showInstallResult(success: ok)
                self?.updateTTSDaemon()
            }
        } else {
            ensureNormalizationVenv()
        }

        offerLoginItem()

        showNote("Ogma Is Ready",
                 "Select text anywhere and press ⌥⇧/ to hear it.\nPress ⌥⇧D and talk to type with your voice.\n\nGrant Accessibility access when prompted so the hotkeys can work.")
    }

    private func showNote(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func offerLoginItem() {
        guard Bundle.main.bundleIdentifier != nil,
              SMAppService.mainApp.status != .enabled else { return }
        let alert = NSAlert()
        alert.messageText = "Launch Ogma at Login?"
        alert.informativeText = "Ogma lives in your menu bar. Start it automatically so the hotkeys are always available."
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try SMAppService.mainApp.register() }
        catch { NSLog("Ogma: could not register login item: \(error.localizedDescription)") }
    }

    /// Best-effort: create the lightweight text-normalization venv (ftfy +
    /// pylatexenc) used by speak.sh. Non-fatal when no usable python3 exists —
    /// speak.sh degrades gracefully without it, and install-local.sh builds a
    /// full venv anyway when local TTS is chosen.
    private func ensureNormalizationVenv() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let venv = (ogmaDataDir as NSString).appendingPathComponent("venv")
            let venvPython = (venv as NSString).appendingPathComponent("bin/python3")
            let fm = FileManager.default
            if fm.isExecutableFile(atPath: venvPython),
               runQuiet(venvPython, ["-c", "import ftfy, pylatexenc"]) { return }
            guard let py = findUsablePython3() else { return }
            if !fm.isExecutableFile(atPath: venvPython) {
                guard runQuiet(py, ["-m", "venv", venv]) else { return }
            }
            let pip = (venv as NSString).appendingPathComponent("bin/pip")
            _ = runQuiet(pip, ["install", "--quiet", "ftfy", "pylatexenc"])
        }
    }

    /// A python3 that can run without triggering the Xcode CLT install prompt.
    private func findUsablePython3() -> String? {
        let fm = FileManager.default
        var candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Developer/CommandLineTools/usr/bin/python3",
        ]
        // /usr/bin/python3 is a shim that pops the developer-tools installer
        // when CLT is absent — only trust it when CLT is actually present.
        if fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3") {
            candidates.append("/usr/bin/python3")
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private func runQuiet(_ launchPath: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Write the "Speak Selection" Services Quick Action so users can bind an
    /// alternative shortcut in System Settings (same payload install.command
    /// creates).
    private func installServicesWorkflow() {
        let workflowDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Services/Speak Selection.workflow/Contents")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: workflowDir, withIntermediateDirectories: true)

        let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleName</key>
                <string>Speak Selection</string>
            </dict>
            </plist>
            """

        let documentWflow = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>AMApplicationBuild</key>
                <string>521.1</string>
                <key>AMApplicationVersion</key>
                <string>2.10</string>
                <key>AMDocumentVersion</key>
                <string>2</string>
                <key>actions</key>
                <array>
                    <dict>
                        <key>action</key>
                        <dict>
                            <key>AMAccepts</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Optional</key>
                                <true/>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.string</string>
                                </array>
                            </dict>
                            <key>AMActionVersion</key>
                            <string>2.0.3</string>
                            <key>AMApplication</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>AMParameterProperties</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <dict/>
                                <key>CheckedForUserDefaultShell</key>
                                <dict/>
                                <key>inputMethod</key>
                                <dict/>
                                <key>shell</key>
                                <dict/>
                                <key>source</key>
                                <dict/>
                            </dict>
                            <key>AMProvides</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.string</string>
                                </array>
                            </dict>
                            <key>ActionBundlePath</key>
                            <string>/System/Library/Automator/Run Shell Script.action</string>
                            <key>ActionName</key>
                            <string>Run Shell Script</string>
                            <key>ActionParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>~/.local/bin/speak.sh</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>0</integer>
                                <key>shell</key>
                                <string>/bin/bash</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>BundleIdentifier</key>
                            <string>com.apple.RunShellScript</string>
                            <key>CFBundleVersion</key>
                            <string>2.0.3</string>
                            <key>CanShowSelectedItemsWhenRun</key>
                            <false/>
                            <key>CanShowWhenRun</key>
                            <true/>
                            <key>Category</key>
                            <array>
                                <string>AMCategoryUtilities</string>
                            </array>
                            <key>Class Name</key>
                            <string>RunShellScriptAction</string>
                            <key>InputUUID</key>
                            <string>60C3B7C0-5F50-4654-B57F-8B4A5BB21BD8</string>
                            <key>Keywords</key>
                            <array>
                                <string>Shell</string>
                                <string>Script</string>
                                <string>Command</string>
                                <string>Run</string>
                                <string>Unix</string>
                            </array>
                            <key>OutputUUID</key>
                            <string>A0E8DB74-D54F-454E-BA0C-3D9C4F4E2501</string>
                            <key>UUID</key>
                            <string>86D36B84-D6AC-4D92-B7A4-C18A89D99C32</string>
                            <key>UnlocalizedApplications</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>arguments</key>
                            <dict>
                                <key>0</key>
                                <dict>
                                    <key>default value</key>
                                    <integer>0</integer>
                                    <key>name</key>
                                    <string>inputMethod</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>0</string>
                                </dict>
                                <key>1</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>source</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>1</string>
                                </dict>
                                <key>2</key>
                                <dict>
                                    <key>default value</key>
                                    <string></string>
                                    <key>name</key>
                                    <string>COMMAND_STRING</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>2</string>
                                </dict>
                                <key>3</key>
                                <dict>
                                    <key>default value</key>
                                    <string>/bin/sh</string>
                                    <key>name</key>
                                    <string>shell</string>
                                    <key>required</key>
                                    <string>0</string>
                                    <key>type</key>
                                    <string>0</string>
                                    <key>uuid</key>
                                    <string>3</string>
                                </dict>
                            </dict>
                            <key>isViewVisible</key>
                            <true/>
                            <key>location</key>
                            <string>309.000000:253.000000</string>
                            <key>nibPath</key>
                            <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/English.lproj/main.nib</string>
                        </dict>
                        <key>isViewVisible</key>
                        <true/>
                    </dict>
                </array>
                <key>connectors</key>
                <dict/>
                <key>workflowMetaData</key>
                <dict>
                    <key>applicationBundleIDsByPath</key>
                    <dict/>
                    <key>applicationPathsByUUID</key>
                    <dict/>
                    <key>inputTypeIdentifier</key>
                    <string>com.apple.Automator.text</string>
                    <key>outputTypeIdentifier</key>
                    <string>com.apple.Automator.nothing</string>
                    <key>presentationMode</key>
                    <integer>11</integer>
                    <key>processesInput</key>
                    <false/>
                    <key>serviceInputTypeIdentifier</key>
                    <string>com.apple.Automator.text</string>
                    <key>serviceOutputTypeIdentifier</key>
                    <string>com.apple.Automator.nothing</string>
                    <key>serviceProcessesInput</key>
                    <false/>
                    <key>systemImageName</key>
                    <string>NSActionTemplate</string>
                    <key>useAutomaticInputType</key>
                    <false/>
                    <key>workflowTypeIdentifier</key>
                    <string>com.apple.Automator.servicesMenu</string>
                </dict>
            </dict>
            </plist>
            """

        try? infoPlist.write(
            toFile: (workflowDir as NSString).appendingPathComponent("Info.plist"),
            atomically: true, encoding: .utf8)
        try? documentWflow.write(
            toFile: (workflowDir as NSString).appendingPathComponent("document.wflow"),
            atomically: true, encoding: .utf8)
    }

    // MARK: Actions

    @objc private func pickBackend(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }

        if id == "elevenlabs" {
            // ElevenLabs requires an API key
            if readAPIKey() == nil {
                if !showAPIKeyDialog(forBackendSwitch: true) { return }
            }
        } else if id == "local" {
            // Local requires mlx-audio installed
            if !isLocalInstalled {
                if !offerLocalInstall(skipLabel: "Cancel") { return }
                // User accepted — install in background, switch now
                config.ttsBackend = id
                config.save()
                rebuildMenu()
                scheduleRespeak()
                runInstallLocal(desiredBackend: id) { [weak self] ok in
                    self?.showInstallResult(success: ok)
                    self?.updateTTSDaemon()
                }
                return
            }
        } else {
            // auto — ensure at least one backend is available
            let hasKey   = readAPIKey() != nil
            let hasLocal = isLocalInstalled

            if !hasKey && !hasLocal {
                // Neither ready — need at least one
                if !showAPIKeyDialog(forBackendSwitch: true) {
                    // Skipped API key — try local install
                    if offerLocalInstall(skipLabel: "Cancel") {
                        config.ttsBackend = id
                        config.save()
                        rebuildMenu()
                        runInstallLocal(desiredBackend: id) { [weak self] ok in
                            self?.showInstallResult(success: ok)
                            self?.updateTTSDaemon()
                        }
                        return
                    }
                    return  // both skipped — don't switch
                }
            } else if !hasKey {
                // Has local, missing API key — soft prompt (Skip is fine)
                showAPIKeyDialog(forBackendSwitch: true, optional: true)
            } else if !hasLocal {
                // Has API key, missing local — offer install (Not Now is fine)
                if offerLocalInstall(skipLabel: "Not Now") {
                    config.ttsBackend = id
                    config.save()
                    rebuildMenu()
                    scheduleRespeak()
                    runInstallLocal(desiredBackend: id) { [weak self] ok in
                        self?.showInstallResult(success: ok)
                        self?.updateTTSDaemon()
                    }
                    return
                }
                // User chose "Not Now" — auto degrades to ElevenLabs-only
            }
        }

        config.ttsBackend = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
        updateTTSDaemon()
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.voiceId = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickLocalVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.localVoice = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func customVoice() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Custom Voice ID"
        alert.informativeText = "Enter a voice ID from elevenlabs.io/voice-library"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.stringValue = config.voiceId
        field.placeholderString = "e.g. pFZP5JQG7iQjIQuC4Bku"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let val = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !val.isEmpty else { return }
        config.voiceId = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.modelId = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.speed = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickLocalSpeed(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.localSpeed = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    // Auto-unload timeout picker. Saved to config; a running daemon re-reads
    // it within a few seconds (see effective_timeout in tts_server.py).
    @objc private func pickIdleTimeout(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Int(str) else { return }
        config.localIdleTimeout = val
        config.save()
        rebuildMenu()
    }

    // Clicking the "Model loaded/unloaded" line toggles it.
    @objc private func toggleModel() {
        if isModelLoaded {
            unloadModel()
        } else {
            startTTSDaemon()   // loads lazily; guarded by needsDaemon
        }
        updateModelMenuItems()
    }

    // Stop whichever daemon is running (app- or speak.sh-started) via its PID
    // file, so the model is released immediately.
    private func unloadModel() {
        if let pidStr = try? String(contentsOfFile: ttsPidPath, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        stopTTSDaemon()
    }

    @objc private func pickSttIdleTimeout(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Int(str) else { return }
        config.sttIdleTimeout = val
        config.save()
        rebuildMenu()
    }

    @objc private func toggleSttModel() {
        if isSTTModelLoaded { unloadSTTModel() } else { startSTTDaemon() }
        updateModelMenuItems()
    }

    @objc private func toggleDictationReview() {
        config.dictationReview.toggle()
        config.save()
        rebuildMenu()
    }

    private var dictionaryPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/ogma/dictionary.txt")
    }

    // Edit the personal dictionary in place. The STT daemon watches the
    // file's mtime, so saved changes apply to the very next dictation.
    @objc private func editDictionary() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Personal Dictionary"
        alert.informativeText = "One word per line, # for comments. Dictation offers these words when it mishears them (matched by sound, not spelling) and never autocorrects them away. Changes apply immediately."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let existing = (try? String(contentsOfFile: dictionaryPath, encoding: .utf8))
            ?? "# One word per line \u{2014} names, jargon, project codenames.\n"

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = existing
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = tv

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let dir = (dictionaryPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        try? tv.string.write(toFile: dictionaryPath, atomically: true, encoding: .utf8)
    }

    @objc private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }
    }

    // Refresh the toggle title + countdown line in place (no full rebuild),
    // called on a timer while the menu is open.
    private func updateModelMenuItems() {
        guard let menu = statusItem.menu else { return }
        menu.item(withTag: 998)?.title = modelToggleTitle()
        if let cd = menu.item(withTag: 997) {
            cd.isHidden = !isModelLoaded
            cd.title = countdownTitle(remainingSeconds(statePath: ttsStatePath, loaded: isModelLoaded))
        }
        menu.item(withTag: 996)?.title = sttModelToggleTitle()
        if let cd = menu.item(withTag: 995) {
            cd.isHidden = !isSTTModelLoaded
            cd.title = countdownTitle(remainingSeconds(statePath: sttStatePath, loaded: isSTTModelLoaded))
        }
    }

    @objc private func editSentencePause() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sentence Pause"
        alert.informativeText = "Milliseconds of silence between sentences (at 1\u{00D7} speed). Set to 0 for no pause."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        field.stringValue = String(config.sentencePause)
        field.placeholderString = "e.g. 400"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let val = Int(text), val >= 0 else { return }
        config.sentencePause = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickStability(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.stability = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickSimilarity(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.similarityBoost = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.style = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func toggleSpeakerBoost() {
        config.useSpeakerBoost.toggle()
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    // MARK: - Credits Display

    private func fetchCredits() {
        guard config.ttsBackend == "auto" || config.ttsBackend == "elevenlabs" else { return }
        guard let key = readAPIKey(), !key.isEmpty else { return }

        // Use cache if fresh (< 60s old)
        if let cached = cachedCredits, Date().timeIntervalSince(cached.fetchedAt) < 60 {
            updateCreditsMenuItem(used: cached.used, limit: cached.limit)
            return
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/user/subscription") else { return }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let used = json["character_count"] as? Int,
                  let limit = json["character_limit"] as? Int else { return }

            self?.cachedCredits = (used: used, limit: limit, fetchedAt: Date())

            DispatchQueue.main.async {
                self?.updateCreditsMenuItem(used: used, limit: limit)
            }
        }.resume()
    }

    private func updateCreditsMenuItem(used: Int, limit: Int) {
        guard let menu = statusItem.menu,
              let creditsItem = menu.item(withTag: 999) else { return }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let remaining = max(limit - used, 0)
        let rStr = fmt.string(from: NSNumber(value: remaining)) ?? "\(remaining)"
        let lStr = fmt.string(from: NSNumber(value: limit)) ?? "\(limit)"
        creditsItem.title = "Credits: \(rStr) / \(lStr)"
        creditsItem.isHidden = false
    }

    // MARK: - API Key Management

    @objc private func manageAPIKey() {
        showAPIKeyDialog(forBackendSwitch: false)
    }

    /// Validate an API key by calling /v1/user/subscription.
    /// Returns nil on success, or an error message on failure.
    private func validateAPIKey(_ key: String) -> String? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user/subscription") else {
            return "Could not build request URL."
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        var result: String? = "Could not reach ElevenLabs. Check your internet connection."
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if error != nil {
                result = "Could not reach ElevenLabs. Check your internet connection."
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = "Unexpected response from ElevenLabs."
                return
            }
            switch http.statusCode {
            case 200:
                result = nil
            case 401:
                result = "Invalid API key. Check that you copied the full key."
            case 403:
                result = "This key is missing required permissions.\nEnable Text-to-Speech and User Read at elevenlabs.io."
            default:
                result = "ElevenLabs returned HTTP \(http.statusCode). Try again later."
            }
        }.resume()
        sem.wait()
        return result
    }

    @discardableResult
    private func showAPIKeyDialog(forBackendSwitch: Bool, optional: Bool = false) -> Bool {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let existingKey = readAPIKey()

        let skipTitle = optional ? "Skip" : "Cancel"
        let baseMessage: String
        let baseInfo: String
        if optional {
            baseMessage = "Add ElevenLabs API Key"
            baseInfo = "Add your API key for cloud TTS.\nThe key needs Text-to-Speech and User Read permissions.\n\nWithout a key, Auto mode will use local TTS only."
        } else if forBackendSwitch {
            baseMessage = "ElevenLabs API Key Required"
            baseInfo = "Enter your ElevenLabs API key to use the cloud backend.\nThe key needs Text-to-Speech and User Read permissions."
        } else {
            baseMessage = "ElevenLabs API Key"
            baseInfo = "Enter or update your ElevenLabs API key.\nThe key needs Text-to-Speech and User Read permissions."
        }

        var errorMessage: String? = nil

        while true {
            let alert = NSAlert()
            alert.messageText = baseMessage
            if let err = errorMessage {
                alert.informativeText = err + "\n\n" + baseInfo
                alert.icon = NSImage(named: NSImage.cautionName)
            } else {
                alert.informativeText = baseInfo
            }
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: skipTitle)
            if !forBackendSwitch && !optional && existingKey != nil && errorMessage == nil {
                alert.addButton(withTitle: "Remove")
            }

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
            if errorMessage == nil, let key = existingKey {
                if key.count > 8 {
                    let start = key.prefix(4)
                    let end = key.suffix(4)
                    field.placeholderString = "\(start)\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(end)"
                } else {
                    field.placeholderString = "Current key set"
                }
            } else {
                field.placeholderString = "Paste your API key here"
            }
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                let val = field.stringValue.trimmingCharacters(in: .whitespaces)
                if val.isEmpty {
                    if existingKey != nil { return true }
                    errorMessage = "No key entered."
                    continue
                }
                if let err = validateAPIKey(val) {
                    errorMessage = err
                    continue
                }
                saveAPIKey(val)
                return true
            } else if response == .alertThirdButtonReturn {
                deleteAPIKey()
                return false
            }
            return false
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Hidden main menu so standard editing key equivalents resolve in any text
// field this app ever shows (accessory apps get none by default).
let mainMenu = NSMenu()
let editHolder = NSMenuItem()
mainMenu.addItem(editHolder)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editHolder.submenu = editMenu
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
