# macOS review — September 6, 2026

Scope: the macOS application, speech services, normalization pipeline, audio
helper, installers/uninstaller, packaging/release scripts, documentation, and
tests. The existing platform-directory migration and Android work were preserved.
This is a source review and hardening pass, not a certification of all runtime
behavior. During the review, no installed application, credentials, models, or release was updated.

## Findings addressed

| Area | Failure or exposure | Change |
|---|---|---|
| Read-aloud input | Writing a large selection into a pipe before launching its reader could deadlock. | Start the child before writing; handle cancellation during input delivery. |
| Playback lifecycle | Old completions could clear a newer process handle; delayed respeak could restart after Cancel. | Guard process and UI updates by generation; serialize hotkey dispatch and validate delayed restarts. |
| Clipboard privacy | Copy failure could send unrelated clipboard contents to TTS, including cloud TTS. | Require a new clipboard change from the same foreground application. |
| Dictation sockets | Connection errors and daemon EOF were ignored; blocked writes delayed cancellation and audio queues could grow without bounds. | Explicit failure callbacks, immediate shutdown, serialized descriptor disposal, write timeout, and bounded backlog. |
| Dictation recovery | Timeout silently discarded available transcription. | Recover available partials into an explicit review card without LLM processing or automatic insertion. |
| Insertion | Cancel did not stop paced typing; late delivery could target another application or observable field. | Invalidate pending delivery and typing, check captured focus for automatic insertion, and monitor observable focus during typing. |
| Daemon lifetime | Idle watchdogs could terminate active recognition or speech generation. | Track active requests and measure idle time with a monotonic clock from request completion. |
| Local IPC | Runtime permissions inherited the launching process's umask; request headers and audio frames were unbounded. | Private data directories and sockets; bounded headers and frames; validate sample rates and finite samples. |
| Daemon state | Concurrent writers reused the same temporary state filename. | Serialize atomic state publication. |
| Cancelled recognition | Parakeet attempted to flush and finalize after the client disconnected. | Return without finalization on disconnect or incomplete audio. |
| Audio queue | Missing files and playback failures could omit the completion protocol, leaving Bash waiting. | Complete the protocol on failure and handle decoder errors. |
| Configuration | Invalid floating-point values, zero speeds, extreme timers, and pasted multiline values could break behavior or inject settings. | Validate and bound values; flatten embedded newlines; use private config permissions; refresh all changed menu settings. |
| LLM response parsing | An unlabelled code fence could lose a short first line; IPv6 loopback handling was inconsistent. | Strip only recognized fence labels and normalize IPv6 host brackets. |
| Process termination | PID files could identify unrelated reused processes or invalid process-group IDs. | Require valid positive PIDs and matching helper commands. |
| Helper updates | Deleting a working helper before copying its replacement left a failure window. | Atomically replace helper contents. |
| Installation | Failed dependency repairs destroyed the prior environment; download failures could leave permanent partial dictionary files; background errors were discarded. | Restore previous environments on repair failure, publish dictionary downloads after success, and retain installation logs. |
| Test reliability | Tests wrote into installed runtime directories and fast mode ran an unrelated installed audio binary. | Isolate runtime/config files and keep fast mode independent of installed audio playback. |

The uninstaller also removes `normalize.py`; cancelling the source installer's
welcome dialog now exits; installer lock names are user-specific.

## Remaining priorities

1. **Reproducible installation and readiness checks.** `install-local.sh` still
   installs several unconstrained dependencies and treats some STT/model
   download failures as nonfatal. Cache checks based on a model's `config.json`
   do not establish that all weights are present. Introduce a tested dependency
   manifest and explicit per-engine readiness checks before announcing success.
2. **Credential transport.** The macOS app and source installer still use the
   `security` command for Keychain access; writes put the key in command-line
   arguments, as do some `curl` headers. Move credential operations into native
   APIs and pass request material through private streams, while preserving
   compatibility with standalone `speak.sh` and existing Keychain access rules.
3. **UI and concurrency separation.** `Ogma.swift` still combines AppKit views,
   process management, audio capture, provider clients, settings, and insertion
   in one large file. Extract these behind testable interfaces, particularly
   focus/clipboard operations and the dictation state machine. Some synchronous
   Keychain/subprocess work still runs from menu actions.
4. **Focus limitations.** Accessibility checks cannot identify an editor field
   when an application exposes no focused element, or reliably detect every
   caret move within the same element. Manual insertion/review remains the most
   controllable option for those applications.
5. **Distribution validation.** Release preparation now checks for committed
   macOS sources, associates the release with the exact build revision, and
   includes the license in the source archive. Signing/notarization and
   installation on clean machines still need separate work.
6. **Text and speech quality.** Normalization has substantial regression
   coverage, but aggressive mathematical/chemical cleanup and speaker isolation
   need corpus-based quality evaluation. The target-speaker extraction plan is
   still research/design work, not an implemented feature.

## Validation

- Existing fast shell suite: 1,143 passed, 0 failed, including normalization and lifecycle regressions.
- Fourteen added model-free tests passed. They exercise actual Swift config/parser/socket code,
  rejected audio-file behavior, daemon lifetime and permissions, request bounds,
  shell numeric validation, unrelated PID protection, and failed-install rollback.
- The complete application was compiled for Apple Silicon and Intel with a macOS 13 deployment target;
  shell scripts were syntax-checked.
- Temporary socket integration tests require execution outside restrictive
  network sandboxes. They use disposable fixtures and do not call providers.
- Microphone capture, real Parakeet/Voxtral/Kokoro inference, cloud requests,
  Accessibility behavior across applications/Spaces, fresh installation,
  uninstall, Intel execution, and signed distribution were not exercised.

Before release, manually check long dictation, disconnecting a microphone,
switching fields during rewrite/typing, Cancel during cold loading and playback,
and recovery from an interrupted model download.
