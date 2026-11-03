# yapa

yapa turns the old iPhone in your drawer into a small server. It serves your sites, git or files to the internet without opening ports, blocks ads as a backup DNS, and buzzes when an agent needs you, so you approve with a tap or answer by holding a button and talking. It runs on the charger and stays cool.

## Install
Jailbreak the phone with [Dopamine](https://github.com/opa334/Dopamine) (through TrollStore), then from your Mac:

```bash
git clone https://github.com/sryo/yapa && cd yapa
./ya root@<phone-ip>
```

## Use
Open the jeta app on the phone, and on the Mac:

```bash
jeta/hooks on
```

From then on every Claude Code session on the Mac, in the terminal or the desktop app, reports to the phone over Wi-Fi. `jeta/hooks off` undoes it and leaves your settings as they were. Without the hooks, the Claude desktop app can drive the phone over Bluetooth instead: turn on Help → Troubleshooting → Enable Developer Mode, then Developer → Open Hardware Buddy → Connect, and pick the phone. Either way, the face on the phone shows what your agents are doing. When one asks for permission, the phone buzzes: tap Allow or Deny, or answer in the terminal as usual; whichever you do first counts. Hold the face to talk, and let go: your words appear in the Claude app (or the terminal in front) and send themselves two seconds later, unless you tap to stop them. English and Spanish both work. Talking also needs che on the Mac; run this once with the phone's address (macOS then asks to let che control the computer):

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
