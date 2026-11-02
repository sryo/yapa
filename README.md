# yapa

yapa turns the old iPhone SE in your drawer into a small server and a desk pad for Claude Code. It serves your sites, git and files to the internet without opening ports, blocks ads as a backup DNS, and buzzes when an agent needs you, so you approve with a tap or answer by holding a button and talking. It runs on the charger and stays cool.

## Install
Jailbreak the phone with [Dopamine](https://github.com/opa334/Dopamine) (through TrollStore), then from your Mac:

```bash
git clone https://github.com/sryo/yapa && cd yapa
./install root@<phone-ip>
```

## Use
Open the pad in Safari on the phone and add it to the home screen. When Claude Code asks for permission, the phone buzzes: tap Allow or Deny. Hold the big button to talk to the session, and let go to send.

```bash
yapa status        # each service, up or down, and since when
yapa logs gitea    # one service's recent log
```

## Known gaps
- After the phone restarts, open Dopamine and tap Jailbreak. Until you do, nothing runs.
- Keep a second DNS server set on your router: when the phone is off, that one answers.
