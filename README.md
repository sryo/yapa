<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/yapa-dark.svg">
    <img alt="yapa" src="docs/logo/yapa-light.svg" width="360">
  </picture>
</h1>

Your agents don’t need faces.

yapa turns the old iPhone in your drawer into a small server. It serves your sites, git or files to the internet without opening ports, and buzzes when an agent needs you, so you approve with a tap or answer by holding a button and talking. It runs on the charger and stays cool.

<img src="docs/statuses.svg" alt="The phone's screen: four ants, one per session, one working, one thinking, one finishing its turn, one curled up asleep; then one comes forward asking to run git push, and Allow is tapped." width="655">

## Install
Jailbreak the phone with [Dopamine](https://github.com/opa334/Dopamine) (through TrollStore), then from your Mac:

```bash
git clone https://github.com/sryo/yapa && cd yapa
./ya root@<phone-ip>
```

## Use
Open the miga app on the phone, and on the Mac:

```bash
jeta/hooks on
```

From then on every Claude Code session on the Mac, in the terminal or the desktop app, reports to the phone over Wi-Fi. `jeta/hooks off` undoes it and leaves your settings as they were. Without the hooks, the Claude desktop app can drive the phone over Bluetooth instead: turn on Help → Troubleshooting → Enable Developer Mode, then Developer → Open Hardware Buddy → Connect, and pick the phone. Either way, the ants on the phone, one per session, show what your agents are doing.

<img src="docs/reply.svg" alt="Tapping an ant opens what its session said, paged with a swipe; then another session asks whether to publish a post, and Publish is tapped." width="655">

 When one asks for permission, the phone buzzes: tap Allow or Deny, or answer in the terminal as usual; whichever you do first counts. Hold the screen to talk, and let go: your words appear in the Claude app (or the terminal in front) and send themselves two seconds later, unless you tap to stop them. English and Spanish both work. Talking also needs che on the Mac; run this once with the phone's address (macOS then asks to let che control the computer):

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
