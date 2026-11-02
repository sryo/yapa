# yapa

How yapa is built and how to work on it. Goals and how they are measured are in GOALS.md; fium rules in ~/Documents/fium/RULES.md.

## Target
iPhone SE (1st gen, A9, arm64, not arm64e), iOS 15.8, jailbroken with Dopamine (rootless, semi-untethered).

- **Daemons** are Go binaries built by `./build-ios` into `build/ios` (Go links ios/arm64 only through cgo, so it uses Xcode's iPhoneOS SDK), signed with `ldid`, and run as launchd daemons from `/var/jb/usr/libexec/yapa/`. `yata` watches the services listed in `/var/jb/etc/yapa/services.json` and answers `/health` on port 8077, to the home network only.
- **jeta**, the pad, is a native app (Swift, UIKit, iOS 15), installed with TrollStore. It is a Claude Hardware Buddy: a CoreBluetooth peripheral on the Nordic UART Service, speaking newline-delimited JSON as specified in https://github.com/anthropics/claude-desktop-buddy/blob/main/REFERENCE.md. It advertises a name starting with `Claude`, requires encryption on its characteristics, and echoes `prompt.id` exactly in `{"cmd":"permission","id":…,"decision":"once"|"deny"}`. iOS advertises the name only while the app is in the foreground, so jeta stays in front.
- The protocol core (parsing, state, decisions) is a Swift package with no UIKit or CoreBluetooth imports, so `bench/pad` runs it on the Mac.
- `jeta/` holds JetaKit (the face model, no UIKit) and `App/` (UIKit). `jeta/build-app sim` builds `build/jeta/sim/jeta.app` for the Simulator; `jeta/build-app device` builds `build/jeta/jeta.ipa` for TrollStore. There is no Xcode project: swiftc compiles both straight from source. iOS 27 Simulators refuse apps without a scene delegate, so the app uses one.
- The face is two small white ovals, close together, drawn from `Stroke.outline()`. Every value is a spring (no jumps); mood changes overshoot, squash and hop; the face roams the screen, steps closer when curious (with a dog-like head tilt) and back when busy. It blinks every 3–10 s and glances every 1–2.25 s; 60 fps while awake, 30 asleep. White only, no mouth, no angry eyes.
- A tap calls `face.poke`: it wakes the face and draws its eyes to the finger.
- Two or more fingers are a chord, read by JetaKit's `Chord` (after Krenn's car UI): the finger count picks the control, spacing is read once at touch-down, and dragging up or down steps it. One finger never acts; a finger landing late voids the chord. Two close fingers with a prompt up decide: drag up past 120 pt and let go for once, down for deny, short of it sends nothing. Each step clicks and pokes the face, since the SE has no Taptic Engine. Until the Buddy link lands, the attention mood stands in for a prompt. `bench/chord` replays seeded gestures through it.
- The Hardware Buddy link carries no text from device to desktop, so push-to-talk has its own path. `jeta/App/Talk.swift`: hold the face (≥150 ms) to record 16 kHz mono WAV, release to POST it to `yapa-talk` on the Mac, found over Bonjour (`_yapa-talk._tcp`, port 8078); a tap in the next 2 s POSTs `/cancel`.
- `mac/` is the Mac side (SwiftPM, macOS 26+). `TalkKit` holds what tests can reach: WER, language pick, HTTP parsing, routing, the pending Enter, and `Transcriber` (Apple's on-device SpeechTranscriber, en_US and es_ES run in parallel, the more confident wins). `yapa-talk` types the text with CGEvents into Claude or a terminal in front, else keys it into the Claude app behind without raising it, else leaves it on the clipboard; Enter follows after `YAPA_TALK_ENTER` s (2). It accepts only this Mac and `YAPA_TALK_FROM` hosts, IPv4 only. Nothing in the desktop app or `claude` accepts text from outside, short of `claude --channels` with a dev flag, so typing is the one path that reaches both. `mac/install` runs it as a LaunchAgent.

## Test
```bash
go test ./... && bench/test-r2-keepalive && bench/test-r3-health && bench/test-r4-talk && swift test --package-path jeta && swift test --package-path mac
```
A change is done when `fium done` says so: it measures every How we know row in GOALS.md where the change started and now.
