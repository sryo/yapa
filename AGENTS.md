# yapa

How yapa is built and how to work on it. Goals and how they are measured are in GOALS.md; fium rules in ~/Documents/fium/RULES.md.

## Target
iPhone SE (1st gen, A9, arm64, not arm64e), iOS 15.8, jailbroken with Dopamine (rootless, semi-untethered). Daemons are Go binaries built with `GOOS=ios GOARCH=arm64 CGO_ENABLED=0`, signed with `ldid`, and run as launchd daemons. The pad page targets iOS 15 Safari: no web push, so it holds an open connection and buzzes from the page.

## Test
```bash
bench/size
```
A change is done when `fium done` says so: it measures every How we know row in GOALS.md where the change started and now.
