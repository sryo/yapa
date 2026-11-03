# yapa: goals

## What yapa is for
Turn a iPhone that would otherwise sit in a drawer into an always-on home node. It has to beat a ~$15 Raspberry Pi Zero 2 W as a server, and alt-tabbing to the terminal as a pad.

## Never traded
- yapa is never the network's only DNS. When it's down, every other device still resolves names.
- Nothing listens on the internet. Public traffic reaches the phone only through the outbound tunnel.
- A prompt the pad didn't answer, or couldn't reach, never counts as approved.

## Goals, in priority order
When two goals conflict, the higher one wins.

1. **Comes back on its own, keeps itself going.** After a reboot and one tap on Dopamine's Jailbreak, every service is up again with nothing else to do. Between reboots it looks after itself: a crashed daemon restarts, logs and caches don't fill the disk, blocklists and certificates stay fresh, and when something does need a hand, the pad says what and what to do.
2. **Answering an agent takes one tap.** The pad hears every Claude Code session on the Mac through its hooks, straight over Wi-Fi, or pairs with the Claude desktop app over Bluetooth as a Claude Hardware Buddy; it shows what the agents are doing, buzzes on a permission prompt, and the tap gets back fast enough that you never go to the app instead. It feels alive and stays calm: one ant per session that walks like a real one, acts out what its session is doing, moves only as much as its agent does, catches your eye only when an agent needs you, and never burns into the screen or drains the battery.
3. **Talking to an agent works.** Hold, speak, release: the words arrive in the session as text, fast and accurate enough to replace typing short replies.
4. **Light on an old phone.** Every daemon together fits comfortably in 2 GB of RAM and leaves the CPU idle when nothing is happening, so the phone stays cool on the charger.
5. **Small.** Few binaries, a small pad app, little code to keep working.

## How we know
| Goal | Metric | Where | Run |
|---|---|---|---|
| 1 | seconds from jailbreak to every health check green; services up | `bench/yata` over SSH to the phone | live: `bench/yata` |
| 1 | seconds for a killed daemon to come back; disk growth MB/day; days since a hand was needed | `bench/yata` over SSH to the phone | live: `bench/yata` |
| 2 | protocol checks passed against the Hardware Buddy spec | `bench/jeta-buddy`, the pad's protocol core run on the Mac | `bench/jeta-buddy` |
| 2 | µs of CPU per face frame | `bench/jeta-face`, the face model run on the Mac | `bench/jeta-face` |
| 2 | chords misread, and decisions sent that weren't meant, per 1,000 replayed gestures; ms to lock a chord; µs per touch update | `bench/jeta-chord`, seeded gestures replayed through the pad's chord reader on the Mac | `bench/jeta-chord` |
| 2 | frames where text jumps, and where it covers the face, per 1,000 replayed runs of the screen; ms for a change to settle (p50); µs per frame of text | `bench/jeta-text`, seeded screen changes replayed through the pad's text motion with the face on the Mac | `bench/jeta-text` |
| 2 | notices missed, misread and invented per 1,000 replayed streams of the manager's turn events; µs per event | `bench/jeta-notice`, seeded streams replayed through the pad's notice reader on the Mac | `bench/jeta-notice` |
| 2 | ms from a Claude Code permission hook to the buzz, and from a tap to the hook's answer (p50); ms each status hook runs in the background; ms from the manager's `jeta:` line to the pad showing it | `bench/jeta-hook-live`, this Mac sending hooks to the phone over Wi-Fi, someone tapping allow | live: `bench/jeta-hook-live` |
| 2 | frames where a session's face jumps, and where faces overlap, per 1,000 replayed runs; ms from a session's event to its face reacting (p50); µs per frame for every face | `bench/jeta-crowd`, seeded sessions coming, going and changing state, replayed through the faces on the Mac | `bench/jeta-crowd` |
| 2 | frames where a planted foot slides, and where an ant jumps, per 1,000 replayed runs; pt an ant walks a minute while its session does nothing; longest s an ant stays on one spot; µs per frame for every ant | `bench/jeta-ants`, seeded sessions replayed through the colony on the Mac | `bench/jeta-ants` |
| 3 | ms from release to text; word error rate on fixture clips | `bench/che` with `bench/che-clips/` | `bench/che` |
| 4 | resident MB of all daemons; idle CPU % over 60 s | `bench/yata` over SSH to the phone | live: `bench/yata` |
| 5 | bytes of the pad app; bytes of daemon binaries; LOC | `bench/size` | `bench/size` |

Caps: `all=ask quality=hard time=ask+10% loc=ask+1%`
