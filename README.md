# yapa

yapa turns the old iPhone SE in your drawer into a small server and a desk pad for Claude Code. It serves your sites, git and files to the internet without opening ports, blocks ads as a backup DNS, and buzzes when an agent needs you, so you approve with a tap or answer by holding a button and talking. It runs on the charger and stays cool.

## Install
Jailbreak the phone with [Dopamine](https://github.com/opa334/Dopamine) (through TrollStore), then from your Mac:

```bash
git clone https://github.com/sryo/yapa && cd yapa
./ya root@<phone-ip>
```

## Use
Open the yapa app on the phone. In the Claude desktop app, turn on Help → Troubleshooting → Enable Developer Mode, then Developer → Open Hardware Buddy → Connect, and pick the phone. From then on the face on the phone shows what your agents are doing. When one asks for permission, the phone buzzes: tap Allow or Deny. Hold the face to talk, and let go: your words appear in the Claude app (or the terminal in front) and send themselves two seconds later, unless you tap to stop them. English and Spanish both work. For talking, run this once on the Mac with the phone's address:

```bash
CHE_FROM=<phone-ip> mac/install
```

Put things on it from the Mac, one command each:

```bash
./ya add site ~/Sites/blog        # https://yapa.yadarola.com.ar/blog/
./ya add site ~/Sites/blog blog   # https://blog.yadarola.com.ar/
./ya add service hello api        # builds cmd/hello, runs it, https://api.yadarola.com.ar/
./ya parts                        # what's on the phone, on or off, and where
./ya off hello                    # stop it, keep it; ./ya on hello brings it back
```

Each of these is a part, kept in `~/.config/yapa/parts`. A service is a Go main package in `cmd/<name>` that listens on `127.0.0.1:$PORT`. Add it again to update it.

```bash
yapa status        # each service, up or down, and since when
yapa logs gitea    # one service's recent log
```

## Known gaps
- After the phone restarts, open Dopamine and tap Jailbreak. Until you do, nothing runs.
- The first time you talk, macOS asks to let che control the computer (Accessibility). Until you allow it, your words land on the clipboard instead.
- Keep a second DNS server set on your router: when the phone is off, that one answers.
