Benji is the calm assistant in your notch: call it, it sorts things out, then it leaves you in peace. It should feel like it shipped with macOS. Build every Benji surface from Apple's system values first and spend Benji's own identity in a few deliberate places: the name and voice, the notch behaviour, `benji-mint`, the app icon and the wordmark.

## Principles

1. **Native first.** Use system colours, SF Pro, SF Symbols, system materials and SwiftUI's standard springs. They track light and dark, Increase Contrast, Reduce Transparency, Reduce Motion and the user's accent colour without extra work, and stay current when macOS changes. The hex values in this system are references for previews; in code use the system colour each token's note names.
2. **Invisible until called.** Benji lives in the notch. Closed, it is the notch. It opens only for the user (hover, talk key, the menu-bar item) or for a real event (an answer arrives, an approval is needed).
3. **Every state is a real event.** Never animate work that isn't happening. Each state in the table below names the signal behind it.
4. **Privacy you can see.** Orange (`state-listening`) means the microphone is on, purple (`state-looking`) means the screen is being used, exactly as the macOS menu-bar indicators mean.
5. **Ask before acting.** Anything that changes, sends or deletes waits for an explicit Yes. Return, Escape, dismissal and the 60-second timeout all mean No.

## Content fundamentals

Write as a capable friend at the next desk: calm, brief, warm, honest, lightly dry.

- **Name:** "Benji" in sentences, "Hey Benji" as the call phrase, lowercase "benji" only in the wordmark, URLs and handles. Pronoun: it. Never translate the name. No "AI" suffix in product copy.
- **Casing:** sentence case for everything, including buttons ("Open Settings", "Go ahead"). macOS menu items use title case ("Show Benji", "Download Better Voices…").
- **Person:** Benji says "I", the user is "you".
- **Shape of an answer:** lead with the result, then one next step. One sentence beats three.
- **Spoken answers:** the first one or two sentences, written for the ear. No lists, markdown or URLs read aloud; the panel keeps the full answer.
- **Honesty:** say what happened and what didn't. Only claim an action a tool confirmed ("Done. 12 files moved"), never one it merely ran.
- **No:** exclamation marks in strings, emoji, slang, surveillance phrasing ("I noticed you…"), check-ins ("Still there?"), icy puns, pepper jokes.

| Moment | Copy |
|---|---|
| First run | Hey, I'm Benji. Tap Right Option when you need me; otherwise I'll stay out of the way. |
| Woken | Hey. What are we sorting? |
| Listening | Go on. |
| Heard nothing | Didn't catch that. Tap and try again. |
| Approval | I'll move 12 files to Archive. Go ahead? |
| Done | Done. 12 files moved to Archive. |
| Declined | Okay, I didn't touch them. |
| Error | That didn't work: the file is locked by another app. Try again once it's closed? |
| Unsure | Not sure. Two ways to read this. Which did you mean? |
| Screen context | I'll look at this screen once, for this message only. |
| Permission | I need Accessibility to hear the Right Option key. Open Settings? |
| Idle tooltip | Here if you need me. |
| Going quiet | All set. |

## Visual foundations

### Where Benji lives

One continuous object that grows out of the hardware notch, top edge flush with the top of the screen, in three sizes (see the NotchObject component):

- **Closed** (`notch-closed-width` × `notch-height`): pure `notch-black`, nothing drawn. It is the notch.
- **Peek** (`notch-peek-width` × `notch-peek-height`): a glyph wing left of the notch, a state word right of it, and one `peek-line` in a row below the notch.
- **Open** (`notch-open-width` × `notch-open-height`): the full panel.

Hover opens the peek after 100 ms of rest at the notch (the pointer moving slower than 150 pt/s), so passing through the menu bar doesn't. It stays open while listening, working, speaking, awaiting approval or hovered, and closes 0.7 s after the cursor leaves when idle. Displays without a notch show the same object at the top centre. Never trail the cursor and never draw a character beside it.

### Colour

- Paint the notch object `notch-black` in both appearances and render its contents in the dark appearance: text `notch-label` and `notch-label-secondary`, fields `notch-raised`, dividers `notch-hairline`.
- Use `benji-mint` for Benji itself on the notch: the ready dot, the speaking waveform, the pointer ring, the send button. It is the only identity colour.
- Use the state colours only for their state: `state-listening` (mic), `state-looking` (screen), `state-approval`, `state-done`, `state-error`. Working has no colour; it uses `notch-label-secondary`.
- In windows (Settings, onboarding) follow the system appearance: `window-bg`, `surface`, `label`, `label-secondary`, `separator`, and `accent` for primary actions (always the user's accent colour in code).
- Never use `system-mint` or `system-orange` as text or as a lone icon on light grounds (about 2:1); pair a status glyph with words. Essential text in light windows uses `label`, not `label-secondary` (3.8:1).
- Never tell states apart by colour alone: each has its SF Symbol and its words.
- Focus rings are the system's (accent-coloured, drawn by AppKit). Don't draw custom ones.

### Type

- Set all UI in SF Pro through the macOS text styles: `body` for answers, `callout` for tool steps and disclosures, `headline` for the approval action, `caption` for attachment details, `title-1` and `large-title` in windows.
- Set Benji's own short lines in SF Pro Rounded: `peek-line` in the peek, `peek-status` for state words, `greeting` for Benji speaking as itself.
- Set paths, commands and code in `mono`.
- Never bundle or embed SF fonts and never use them in the wordmark or logo (Apple's licence covers UI only).

### Spacing, corners and shape

- Space on the 4 pt steps `space-1` to `space-5`; windows use `space-5` margins.
- Use continuous corners everywhere (`RoundedRectangle(cornerRadius:style: .continuous)`), and keep them concentric: an inner radius is the outer radius minus the padding (`radius-field` inside `radius-notch-open`).
- The notch object has a flat top flush with the screen, concave shoulders where it meets the menu bar, and bottom corners that grow with its size: `radius-notch-closed`, `radius-notch-peek`, `radius-notch-open`.
- Capsule buttons and level bars use `radius-pill`.

### Materials and depth

- The notch object is solid `notch-black`; give only the open size `shadow-notch-open`.
- Controls inside the open object use Liquid Glass on macOS 26 (`.buttonStyle(.glass)`, `.glassEffect`) and fall back to plain `notch-raised` fills on macOS 14–15 and under Reduce Transparency.
- Settings and onboarding are standard windows with standard materials.

### Motion

Calm and system-like, with exactly one gentle bounce, on Done (D-61). Every animation uses one of seven tokens; the Motion section has the full specification and the MotionTokens, NotchObject and PeekStatus cards show them running.

| Token | Use | SwiftUI |
|---|---|---|
| `motion-peek` | Closed ↔ peek | `.smooth(duration: 0.30)` |
| `motion-open` | Anything to or from open | `.smooth` (0.5 s) |
| `motion-content` | Changes inside one size | `.smooth(duration: 0.24)` |
| `motion-follow` | Values retargeted while moving | `.spring(duration: 0.35, bounce: 0)` |
| `motion-fade` | Content entering or leaving | `.easeOut` / `.easeIn`, 0.15 s |
| `motion-done` | Only the Done checkmark | `.symbolEffect(.bounce.up)` |
| `motion-reduce` | Every spatial change under Reduce Motion | `.easeInOut(duration: 0.20)` crossfade |

- Nothing moves when nothing happens: closed, Ready, Done held and Needs approval are still, and the display link stops.
- Content fades in at 65% of a growth and fades out 100 ms before a shrink. A reversed morph keeps its speed.
- Meters move only with the real mic or speech level; the working shimmer runs only while the assistant does.
- Nothing flashes, nothing loops for attention, nothing but the Done checkmark overshoots.
- Pointing on screen (ring or region, reveal, label placement, lifetime, capture privacy) is specified in the Overlay section; the sound cues in the Sound section.

### States

| State | Real signal | Glyph | Colour | Peek line |
|---|---|---|---|---|
| Ready | hovered while idle | `circle.fill` (small) | `benji-mint` | Here if you need me. |
| Listening | microphone engine running | `mic.fill` + level bars | `state-listening` | live words as heard |
| Transcribing | audio ended, final text pending | `waveform` | `state-listening`, dimmed | … |
| Working | assistant process running, tool events | `circle.dotted` | `notch-label-secondary` | the current step |
| Needs approval | assistant waiting for Yes or No | `hand.raised.fill` | `state-approval` | the action and its target |
| Speaking | speech synthesizer started | `waveform` | `benji-mint` | the first line of the answer |
| Looking | screenshot attached to this message | `viewfinder` | `state-looking` | Looking at this screen once |
| Pointing | answer carried a point on screen | `scope` | `benji-mint` | the target's label |
| Done | answer delivered | `checkmark` | `state-done` | All set. |
| Error | assistant, voice or capture error | `exclamationmark.triangle.fill` | `state-error` | what failed, briefly |
| Needs permission | a macOS permission is missing | `lock.fill` | `notch-label-secondary` | which one and why |

### Sound and haptics

Silent by default (D-61); Benji speaks only on voice turns, in the best installed Apple voice. A few quiet cues exist as an option; the Sound section lists them. On Force Touch trackpads, play one light `.alignment` haptic when hover opens the peek, and nothing else.

## Iconography

- Use SF Symbols only, in hierarchical or palette rendering, at the text style's size. The state glyphs are listed in the States table; controls use `mic`, `mic.fill`, `viewfinder`, `arrow.up.circle.fill`, `stop.circle.fill`. The open panel's band uses `house` (Home), `chevron.backward` (Back, same weight and long side as Collapse), `square.and.pencil` (New conversation), `stop.fill` (Stop), `gearshape` (Settings, drawn selected while Settings is open), `sidebar.left` (one toggle for Show and Hide recent conversations) and `chevron.up` (Collapse), all semibold at one optical size (D-138). `bubble.left` is for conversation rows only.
- Animate symbols with symbol effects (`.replace`, `.bounce`, `.pulse`, `.variableColor`) and switch them off under Reduce Motion.
- No emoji, no custom pictograms where a symbol exists, no faces or eyes, no snowflakes, ice, peppers or sunglasses.
- The menu-bar item is the monochrome template `benji-menubar-glyph.svg` (Logos): the two Exchange elbows, one ink, macOS tints it. While Benji is busy with a turn (listening, transcribing, working, speaking, awaiting approval) it swaps to `benji-menubar-glyph-working.svg`, the halves closed into one rounded square (D-137). A swap, not an animation.
- The app icon is Exchange (D-137): two thick rounded elbows on opposite corners with equal gaps, the light mint half you and the deep mint half Benji, on a gradient black tile, in default, dark, tinted and clear appearances (Logos), built as a macOS 26 layered icon with one layer per elbow.
- The wordmark is lowercase "benji" (`benji-wordmark.svg`), custom-drawn from circles and straight strokes, never set in a font; "Hey Benji" has its own lockup. Clear space and minimum sizes are in the Logos group's notes.

## Accessibility

Respect Reduce Motion, Reduce Transparency, Increase Contrast and Differentiate Without Color. Everything is reachable without a mouse: the talk key and the menu-bar item open Benji, Tab moves through the open panel, Escape closes it or says No. Give every control a VoiceOver label, announce state changes and pointing ("Pointing at Share button"), and keep answers in a readable, scrollable transcript; never auto-fade text the user needs.

## Don't

- Don't trail the cursor, add a mascot, or give Benji a face or eyes.
- Don't resemble existing assistant apps: no blue triangle cursor, lavender blob, ^ ω ^ face, ⌃⌥ logo, kaomoji, glossy blue or peach bubbles, cream graph-paper sketches.
- Don't introduce a custom colour, font or easing where a system one exists.
- Don't open the notch object, animate it, or make a sound without a real event.
- Don't use red flashing, alarms, or colour as the only signal.
