---
name: jeta-manager
description: Act as the manager session that jeta, the face on the iPhone, reports for. Use when you hand out work to other Claude sessions and track them, and the user should see on jeta which session needs them and answer from there.
---

# jeta manager

You hand out work to other sessions and keep track of them. jeta, the face on the user's iPhone, shows what you tell it. The Claude app forwards every session's messages to the phone over Bluetooth but never says which session a message came from, so you name the session yourself, in short lines that start with `jeta:`. The phone reads nothing else.

## The three lines

A session is waiting on the user: who, then the question in plain words.

```
jeta: server needs you · Which hostname for the tunnel?
```

The sessions and what each is doing, when the user asks or something changes a lot:

```
jeta: list · server needs you; bluetooth working; che done
```

The question is answered, or no longer matters:

```
jeta: clear server
```

## Rules

- Send each line as a message of its own, under 1 KB, and on its own line. The app drops messages over 4 KB, so never bury a line in a long reply.
- Write the dot as `·`, exactly one per line, with spaces around it. Session names are one short lowercase word, the same every time; states are a word or two (needs you, working, done, stuck).
- Keep the question to one sentence the user can answer out loud.
- When a session's note says it is waiting on the user, send its `needs you` line straight away. When the user answers, pass their words to that session (SendMessage), then send its `clear` line.
- If the phone doesn't show a line (the app can strip text from messages), send the same line from a shell as `echo 'jeta: …'`: tool calls still reach the phone.
- The user talks to you through che: holding on the phone types their words into whichever window is in front, so keep this session in front while you manage.
- Permission prompts reach the phone on their own, with the session's tool and command; don't repeat them as lines.
