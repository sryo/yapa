# yapa

How yapa is built and how to work on it. Goals and how they are measured are in GOALS.md; fium rules in ~/Documents/fium/RULES.md.

## Target
iPhone SE (1st gen, A9, arm64, not arm64e), iOS 15.8, jailbroken with Dopamine (rootless, semi-untethered).

- **Daemons** are Go binaries built by `./build-ios` into `build/ios` (Go links ios/arm64 only through cgo, so it uses Xcode's iPhoneOS SDK), signed with `ldid`, and run as launchd daemons from `/var/jb/usr/libexec/yapa/`. `yapad` watches the services listed in `/var/jb/etc/yapa/services.json` and answers `/health` on port 8077, to the home network only.
- **The pad** is a native app (Swift, UIKit, iOS 15), installed with TrollStore. It is a Claude Hardware Buddy: a CoreBluetooth peripheral on the Nordic UART Service, speaking newline-delimited JSON as specified in https://github.com/anthropics/claude-desktop-buddy/blob/main/REFERENCE.md. It advertises a name starting with `Claude`, requires encryption on its characteristics, and echoes `prompt.id` exactly in `{"cmd":"permission","id":…,"decision":"once"|"deny"}`. iOS advertises the name only while the app is in the foreground, so the pad stays in front.
- The protocol core (parsing, state, decisions) is a Swift package with no UIKit or CoreBluetooth imports, so `bench/pad` runs it on the Mac.
- The face is procedural (rounded-rect eyes with lids), time-based, easing 120–300 ms between expressions with retargeting, blinking every 3–10 s and glancing every 1–2.25 s; 60 fps while active, lower when idle.
- The Hardware Buddy link carries no text from device to desktop, so push-to-talk needs its own path to the session.

## Test
```bash
go test ./... && bench/test-r2-keepalive && bench/test-r3-health
```
A change is done when `fium done` says so: it measures every How we know row in GOALS.md where the change started and now.
