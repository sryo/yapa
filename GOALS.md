# yapa: goals

## What yapa is for
For sryo: turn a 2016 iPhone SE that would otherwise sit in a drawer into an always-on home node. It serves sites, git and files to the internet through a tunnel, runs ad-blocking DNS as a backup, and sits on the desk as a pad for Claude Code: approve permission prompts with a tap and talk to an agent with push-to-talk. It has to beat a ~$15 Raspberry Pi Zero 2 W as a server, and alt-tabbing to the terminal as a pad.

## Never traded
- yapa is never the network's only DNS. When it's down, every other device still resolves names.
- Nothing listens on the internet. Public traffic reaches the phone only through the outbound tunnel.
- A prompt the pad didn't answer, or couldn't reach, never counts as approved.
- The pad never takes focus or moves windows on the Mac.

## Goals, in priority order
When two goals conflict, the higher one wins.

1. **Comes back on its own.** After a reboot and one tap on Dopamine's Jailbreak, every service is up again with nothing else to do.
2. **Answering an agent takes one tap.** A permission prompt reaches the pad, buzzes, and the tap gets back to Claude Code fast enough that you never go to the terminal instead.
3. **Talking to an agent works.** Hold, speak, release: the words arrive in the session as text, fast and accurate enough to replace typing short replies.
4. **Light on an old phone.** Every daemon together fits comfortably in 2 GB of RAM and leaves the CPU idle when nothing is happening, so the phone stays cool on the charger.
5. **Small.** Few binaries, a pad page that loads fast on iOS 15 Safari, little code to keep working.

## How we know
| Goal | Metric | Where | Run |
|---|---|---|---|
| 1 | seconds from jailbreak to every health check green; services up | `bench/health` over SSH to the phone | live: `bench/health` |
| 2 | ms from hook fired to pad notified, and from tap to hook answered (p50) | `bench/pad`, a headless pad client on the Mac | `bench/pad` |
| 3 | ms from release to text; word error rate on fixture clips | `bench/ptt` with `bench/clips/` | `bench/ptt` |
| 4 | resident MB of all daemons; idle CPU % over 60 s | `bench/health` over SSH to the phone | live: `bench/health` |
| 5 | bytes of the pad page; bytes of daemon binaries; LOC | `bench/size` | `bench/size` |

Caps: `all=ask quality=hard time=ask+10%`

## Non-goals
- Pi-hole itself: it's Linux-only. AdGuard Home does the same job as one binary.
- Running untethered or surviving a reboot without the tap: no jailbreak for this phone does that.
- Running models on the phone: the A9 is too slow for speech-to-text or an LLM. The heavy work runs on the Mac or the API.
- Any device other than the iPhone SE (1st gen) on iOS 15.
