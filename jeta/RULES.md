# What the pad must always do

One rule per line, each with what checks it. A rule with no check is marked **unchecked**. Change a rule here first, then
the code and its check.

## Ants

| # | Rule | Checked by |
|---|------|------------|
| A1 | One ant per session not swiped away; with one session or none, a single ant. | `testOneAntPerSession`, `testR2_OneSessionIsTheSingleFace` |
| A2 | Each session has its own spot, in the order sessions started; a session another started stands round that one. | `testEachAntHasItsOwnSpot`, `testFamiliesStandTogether` |
| A3 | Ants walk round each other and round crumb piles, never over them. | `testBusyAntsStayApartAndInPlace`, `bench/jeta-ants` |
| A4 | Busy (thinking or running tools): it walks slowly about its spot in wide curves and never stops, never just turning in place, never in step with the others; thinking (no tool running), its antennae drum and its head shakes. | `testBusyAntsStayApartAndInPlace`, `testBusyAntsNeverSpin`, `testBusyAntsDontTurnInStep`, `testThinkingDrums`, `testEveryWorkingMoodWalks`, `testR2_WhatEachSessionIsDoing`, flow "lone ant walks while its session works" |
| A5 | Needs you (a permission, a question, a failed turn): it pops, comes forward and pulses; the others hold still; a second one pulses at its own spot. | `testNeedsPopsPulsesAndOthersHoldStill`, `testOnlyNeedsDrawsAttention`, `testNeedsComesForwardSleepStays` |
| A6 | Allowed, it hurries home; denied, it walks home slowly. | `testAnsweredItGoesBack` |
| A7 | Done: it turns once on the spot with its antennae up, then it stands. | `testR1_MoodFollowsState`, `testOnlyNeedsDrawsAttention` |
| A8 | It curls up only when nothing of it is left for you: quiet about 95 s after done, and no question or actions waiting, no crumbs beside it, not stale. | `testSleepCurlsUp`, `testR1_NothingLeftForYouBeforeSleep`, `testUnseenDoneKeepsItsCrumbs`, flow "ants stay awake while something waits" |
| A9 | A busy ant drops a crumb a minute into one pile beside its spot, and keeps it until you've seen the finished turn. | `testCrumbsCountTheMinutes`, `testUnseenDoneKeepsItsCrumbs`, `testR2_DoneStaysUnseenUntilLooked` |
| A10 | Gone: it walks off the nearest edge. | flow "session ends" |
| A11 | Held to talk, only the held ant reacts: it steps out from under the finger and faces it. | `testHeldAntStepsOutFromUnderTheFinger`, flow "talk to a session, then stop the Enter" |
| A12 | While a session's text is open, its ant waits beside the text and the others walk off; they come back after. | `testReadingSendsTheTalkerToTheCornerOthersOff`, flows "reply read beside its ant", "lone reply read beside its ant" |
| A13 | While the dial is open every ant walks off. | flows "dial: …" |
| A14 | Every still ant creeps along a slow drift, so nothing burns in. | `testCalmUnlessSessionActsAndDriftWhenStill`, `bench/jeta-ants` |
| A15 | Ants are always full white. | **unchecked** |
| A16 | An ant has a real ant's shape: head with mandibles and elbowed antennae, thorax, a small waist, an abdomen, six legs from the thorax. | **unchecked** |

## Text and gestures

| # | Rule | Checked by |
|---|------|------------|
| T1 | Text comes out of an ant only when its session needs you; a reply opens on a tap, or by itself when it ends on a question. | `testRepliesWaitForATapUnlessTheyAsk` |
| T2 | Every question, permission and action can be answered from the pad, and the answer goes to the session that asked. | flows "permission …", "question answered", "action picked", "two sessions with actions" |
| T3 | Text put away goes back into its ant, and a tap on that ant brings it back; other taps leave it away, so you're never stuck in one session's text. | `testR5_DetailPagesAndCloses`, flow "actions put away and found again" |
| T4 | Answered at the desk, a question leaves the pad. | flow "actions answered at the desk" |
| T5 | A swipe sideways moves between sessions' text; a swipe down on the bare screen opens the session list. While a finger drags sideways the text follows it 1:1; let go short of a fifth of the screen (and not flicked), it springs back; a drag that began as a hold sends nothing. | `testR6_SwipeDownShowsTheSessions`, `testT5_TextFollowsTheFinger`, flows "session list", "two sessions with actions", "text follows the finger", "a drag that began as a hold sends nothing" |
| T6 | A tap on an option is that option, even in the 2 s a tap would stop a pending Enter. | flow "two sessions with actions" |
| T7 | Text left up three minutes untouched folds away; only a permission request stays. | `testUntouchedTextFoldsAway` |
| T8 | All text creeps along a slow drift. | `testTextDriftsSoNoLineSitsStill`, `bench/jeta-text` |
| T9 | Nobody near for three minutes and nothing happening: the backlight dims; anything that needs you brings it back. | `testRestsOnlyWhenNothingNeedsYou` |
| T10 | Only a tap approves; no answer, a timeout or the phone off gives no decision. A request whose hook gave up leaves the pad. | `testR3_NeverApprovedWithoutATap`, flow "a request whose hook gave up leaves" |
