# Motion

Benji moves like part of macOS: calm, quick to answer, and still when nothing is happening. Motion only ever reports a real event: the pointer reached the notch, the microphone is on, the assistant is working, an answer arrived. There is exactly one moment of character, a single gentle bounce when a task is done (D-61). Everything else is critically damped and never overshoots.

This section is the motion specification. The tokens are in the first table; the rest says where each one is used and why its numbers are what they are.

## Principles

1. **Nothing moves when nothing happens.** Closed is still and invisible. A held peek (Ready, Done, Needs approval) is still. No breathing, no idle glow, no attention-seeking. The display link stops when the last spring settles.
2. **Motion follows the event, never leads it.** The mic meter moves only with the real input level, the speaking waveform only with the real output level, the working shimmer only while the assistant process is running.
3. **One object, one spring.** The notch object morphs as a single shape. Width, height and corner radii share one spring per transition; content never animates on a different clock from its container.
4. **Interruptible everywhere.** Any morph can be reversed mid-flight. It continues from its current size and speed; it never jumps or restarts.
5. **Fast to answer, slow to leave.** Responses to the user start within one frame. Leaving is unhurried: a grace period before closing, content fading before the shape shrinks.
6. **Every animation has a still alternative.** Under Reduce Motion, nothing grows, travels, scales or bounces; sizes change behind a short crossfade and live meters become static.

## Tokens

Each spring is given as Apple's two numbers: **perceptual duration `d`** and **bounce `b`**. With mass 1, stiffness `k = (2π / d)²` and damping `c = 4π(1 − b) / d`, so the damping ratio is `ζ = 1 − b`. Every spring except `motion-done` has `b = 0` (critically damped).

| Token | Use it for | SwiftUI | Core Animation | Settles (within 0.5%) |
|---|---|---|---|---|
| `motion-peek` | Closed ↔ peek | `.smooth(duration: 0.30)` | `CASpringAnimation(perceptualDuration: 0.30, bounce: 0)` (k 438.6, c 41.89) | ≈ 355 ms |
| `motion-open` | Any morph that starts or ends at open | `.smooth` (duration 0.5, bounce 0) | `CASpringAnimation(perceptualDuration: 0.50, bounce: 0)` (k 157.9, c 25.13) | ≈ 590 ms |
| `motion-content` | Changes inside one size: rows, the approval card, status words, button release | `.smooth(duration: 0.24)` | `CASpringAnimation(perceptualDuration: 0.24, bounce: 0)` (k 685.4, c 52.36) | ≈ 285 ms |
| `motion-follow` | Values retargeted while moving (the pointer ring between nearby targets) | `.spring(duration: 0.35, bounce: 0)` on a value that keeps changing | A stepped spring (k 322.3, c 35.90) on a display link that runs only while moving; `CASpringAnimation` can't retarget with velocity | ≈ 415 ms |
| `motion-fade` | Opacity of content entering or leaving a size | in `.easeOut(duration: 0.15)`, out `.easeIn(duration: 0.15)` | `CABasicAnimation` 0.15 s, ease-out (0, 0, 0.58, 1) / ease-in (0.42, 0, 1, 1) | 150 ms |
| `motion-done` | **Only** the checkmark when Done arrives | `.symbolEffect(.bounce.up, options: .nonRepeating, value: doneCount)`; custom views: a scale impulse with `.bouncy(duration: 0.45)` | `CAKeyframeAnimation` on `transform.scale` sampled from the impulse response (d 0.45, b 0.3, start velocity 4.25/s) | peak +14% at 80 ms, rest by ≈ 450 ms |
| `motion-reduce` | The Reduce Motion stand-in for every spatial token | `.easeInOut(duration: 0.20)` on opacity, geometry changed instantly underneath | `CATransition` `.fade`, 0.20 s | 200 ms |

The settle time of a critically damped spring to within 0.5% is `1.18 × d`: `(1 + u)e^(−u) = 0.005` at `u = 7.43`, and `u = 2πt / d`.

### Why these numbers

- **`motion-open` = Apple's `.smooth`.** The open panel is a large change (185 × 32 to 460 × 380 pt). Apple's default spring for large, non-playful changes is `.smooth` at 0.5 s; using it unchanged keeps Benji beside the system's own sheets and popovers.
- **`motion-peek` = 0.30 s.** The peek is small (175 pt wider, 28 pt deeper) and usually answers a hover, so it must feel immediate. People perceive a response under about 100 ms as instantaneous. With `d = 0.30`, the shape is 65% of the way there, where content starts to fade in, at 106 ms (`0.353 × d`). Shorter than 0.25 s started to look like a snap rather than a growth; longer than 0.35 s let the content arrive noticeably after the hover.
- **`motion-content` = 0.24 s.** Inside a fixed size, things travel at most a row or two (≤ 40 pt). Slightly faster than the peek keeps content changes subordinate to shape changes.
- **`motion-follow` = 0.35 s.** A follower needs to be soft enough that a retarget mid-flight doesn't look like a jerk, and quick enough that a 200 pt hop doesn't trail. Peak speed of a critically damped spring for a hop of distance `D` is `D × ω / e` with `ω = 2π / d`; at 0.35 s and 220 pt that is about 1,450 pt/s, the fastest we let anything Benji draws cross the screen.
- **`motion-fade` = 0.15 s.** Fades must finish inside the shortest morph so text is never seen half-transparent at rest. 150 ms is under half of `motion-peek`.
- **`motion-done`.** An impulse (a kick of velocity from rest) rather than a step, so the checkmark returns exactly to its size. `b = 0.3` (ζ 0.7) gives one visible rise and a return with an undershoot of under 1%, which reads as a single nod, not a wobble. The start velocity was chosen so the peak is +14%: large enough to see at 13 pt, small enough to stay inside the wing.
- **`motion-reduce` = 0.20 s.** A crossfade long enough to read as a change of state rather than a flicker, short enough to keep up with the full-motion timings.

## Rules that come with the tokens

- **One token per transition: the largest size involved wins.** Closed ↔ peek uses `motion-peek`. Anything that starts or ends at open uses `motion-open`.
- **Growing: content fades in at 65% of the morph.** For a critically damped spring that is `0.353 × d`: 106 ms into `motion-peek`, 177 ms into `motion-open`. Content fades in with `motion-fade` (in).
- **Shrinking: content fades out first.** `motion-fade` (out) starts at once; the shape starts 100 ms later, when the content is at most a third visible. The 100 ms wait applies only when starting from rest: a retarget mid-flight never waits.
- **Retargeting keeps velocity.** A reversed morph continues from its current size and speed. Use SwiftUI's springs (which keep velocity on retarget) or `motion-follow`'s stepped spring, never a fresh `CASpringAnimation` from the model value.
- **`motion-follow` glides only short hops**, up to about 220 pt. Further than that, fade out at the old target and fade in at the new one.
- **Never stack bounces.** `motion-done` runs once per Done event, on the checkmark only. A second Done within its 450 ms restarts it; it never queues.
- **Symbols change with the system's effect.** Glyph changes use `.contentTransition(.symbolEffect(.replace))` with the system's default timing.

## The notch object's shape

The notch object is one path: a flat top flush with the top of the screen, a concave **shoulder** at each top corner where it meets the menu bar (like the hardware notch's own corners, curving outward), straight sides, and **continuous** bottom corners. The shoulders and bottom corners grow with the size.

| Size | Width × height (pt) | Bottom corner radius | Shoulder radius | Shadow |
|---|---|---|---|---|
| Closed | 185 × 32 | 10 (`radius-notch-closed`) | 6 (assumed; measure the hardware) | none |
| Peek | 360 × 60 (was 40) | 18 (`radius-notch-peek`) | 8 | none |
| Open | 460 × 380 | 26 (`radius-notch-open`) | 12 | `shadow-notch-open`, opacity following the height |

- **Continuous corners.** The bottom curve starts `1.4 × r` from the corner, not `r`, so the curvature eases in like `RoundedRectangle(style: .continuous)`.
- **Shoulders flare outward** by their radius on each side of the top edge, so the object looks poured from the menu bar rather than pasted under it.
- **The morph grows from the notch's corners.** The top edge never moves; width grows symmetrically about the notch's centre and height grows downward. Because the closed shape is exactly the hardware, the notch itself appears to stretch.
- **One animatable shape.** In SwiftUI, a `Shape` whose `animatableData` carries width, height, bottom radius and shoulder radius, all driven by one spring. Don't animate a frame and a clip separately.
- **Peek height (D-63).** The peek promises "one line below the notch". The hardware notch is 32 pt deep and holds nothing (the camera sits there), so the line needs its own row: 32 pt for the wings, then 6 + 16 (`peek-line`) + 6 pt. That makes the peek 60 pt deep, not 40. The wings either side of the hardware notch are 87.5 pt wide at 360 pt.
- **Displays without a notch.** The object sits at the top centre. Closed is invisible: it grows from the closed size at opacity 0, and its body fades in with `motion-fade` while the morph runs. It shrinks and fades out the same way.

## Peek layout

```
          ┌──────────── 360 pt ────────────┐
 shoulder ╲ glyph wing │  hardware  │ word wing ╱
          │  ● ▮▮▮▮    │   notch    │  Listening │  32 pt
          │    rename the screenshots on my…    │  28 pt (line row)
          ╰─────────────────────────────────────╯
```

- **Left wing:** the state glyph, plus the mic meter (Listening) or the speech meter (Speaking).
- **Right wing:** the state word in `peek-status`, at most about 74 pt wide; it truncates, it never wraps. The words: Ready, Listening, Transcribing, Working, Approval, Speaking, Looking, Pointing, Done, Error, Permission. ("Needs approval" and "Needs permission" are too wide for the wing; the line row carries the detail.)
- **Line row:** one `peek-line`, tail-truncated; the open panel holds the full text.

## Transitions

Every change of size or state, with its token and its Reduce Motion version. "Fade in at 65%" and "fade out first" are the rules above.

### Size changes

| From → to | Trigger (real event) | Token | Content | Reduce Motion |
|---|---|---|---|---|
| Closed → peek | Hover rest (see Timing), talk key down, menu-bar item, or an event while closed (answer, approval, listening) | `motion-peek` | Wings and line fade in at 106 ms | Crossfade 0.20 s to the peek |
| Peek → closed | Idle, pointer left, close grace passed; or Done hold ended | `motion-peek` | Fade out first, shape 100 ms later | Crossfade |
| Peek → open | Click the peek, start typing, approval arrives, a turn needs room | `motion-open` | Peek wings stay; line fades out at once; panel content fades in at 177 ms | Crossfade |
| Open → peek | Collapse (`chevron.up`), Escape while busy | `motion-open` | Panel content fades out first; line fades in at 65% | Crossfade |
| Open → closed | Escape when idle, pointer left after the grace with nothing pending | `motion-open` | All content fades out first, shape 100 ms later | Crossfade |
| Closed → open | Typing shortcut while closed, approval while closed | `motion-open` | Panel content fades in at 177 ms | Crossfade |

The shadow (`shadow-notch-open`) fades in with the height: its opacity is `(h − 60) / (380 − 60)`, clamped to 0…1, so closed and peek never have one.

### State changes inside the peek

The size stays; only the content changes.

| Change | Animation | Reduce Motion |
|---|---|---|
| Glyph | `.contentTransition(.symbolEffect(.replace))` | Crossfade 0.20 s |
| State word | Old word fades out, new fades in (`motion-fade`), the wing's width follows with `motion-content` | Instant swap |
| Line | New text replaces old with `.contentTransition(.opacity)`; live words stream (below) | Instant swap |
| Colour (glyph, word) | Follows the glyph's transition; never animated on its own | Instant |

### Per state

| State | Enters with | While in it | Leaves with | Reduce Motion |
|---|---|---|---|---|
| Ready | Peek morph; mint dot fades in | Still | Peek closes after the grace | No change needed |
| Listening | Glyph `.replace` to `mic.fill`; meter fades in | Mic meter follows the real input level | Meter fades out over 150 ms when the mic stops, the same frame the engine stops | Meter shows a static level (updated at most 4 times a second, no easing) |
| Transcribing | Glyph `.replace` to `waveform`, orange at 0.6 opacity | Still; the line shows "…" | Next state | Same |
| Working | Glyph `.replace` to `circle.dotted` | One shimmer across the step words (1.4 s sweep, 0.6 s rest), only while the process runs | Shimmer stops at its next rest; never cut mid-sweep unless the state ends | No shimmer; the step words stay, still |
| Needs approval | Grows to open (`motion-open`); the approval card rises 8 pt and fades in with `motion-content` | Still; nothing pulses | Card fades out first; then the next state | Card fades in only |
| Speaking | Glyph `.replace` to `waveform` in mint; speech meter fades in | Bars follow the synthesiser's real output level; the line reveals in step with speech | Meter fades out when the utterance finishes | Static glyph; the line appears whole |
| Looking | Glyph `.replace` to `viewfinder` in purple | Still for the whole capture | Next state | Same |
| Pointing | Glyph `.replace` to `scope`; the on-screen highlight (Overlay) | Still in the notch | With the highlight | Fade only |
| Done | Glyph `.replace` to `checkmark`, then **`motion-done` once**, starting when the replace finishes | Held still for the Done hold | Peek closes (`motion-peek`), unless hovered | No bounce; the glyph crossfades in |
| Error | Glyph `.replace` to `exclamationmark.triangle.fill` in red | Still; held until dismissed or the next message; never flashes | Next state | Same |
| Needs permission | Glyph `.replace` to `lock.fill` | Still | When the permission is granted or dismissed | Same |

### Inside the open panel

| Change | Animation | Reduce Motion |
|---|---|---|
| New transcript row | Fades in and rises from 6 pt below with `motion-content`; the list scrolls with `motion-content` only if already at the bottom | Fade only |
| Streaming answer text | Each new glyph fades in over 0.12 s, staggered by up to 8 ms per glyph within a chunk (`TextRenderer`, macOS 15+); fallback `.contentTransition(.opacity)` per chunk | Chunks appear whole |
| Approval card in / out | Rises 8 pt + fades in (`motion-content`); out: fades (`motion-fade`) then the rows close the gap (`motion-content`) | Fade only |
| Screen disclosure strip | Height and opacity with `motion-content` | Fade only |
| Buttons | System press states; release with `motion-content` | System |

## Timing constants

| Constant | Value | Why |
|---|---|---|
| Hover rest before peek | Pointer inside the hot zone (the notch plus 8 pt), moving slower than 150 pt/s, for 100 ms | 100 ms is the limit for feeling immediate. The speed gate ignores pointers passing through the menu bar on the way to a menu (they move far faster than 150 pt/s) |
| Close grace | 0.7 s after the pointer leaves, idle states only | Long enough to return after slipping out; short enough that Benji doesn't linger |
| Never closes while | Listening, transcribing, working, speaking, awaiting approval, or hovered | Those are real ongoing events |
| Done hold | 0.5 s + 0.25 s per word of the Done line, clamped to 1.5–4 s | About half a second to move the eyes there plus about 240 words a minute of reading |
| Working shimmer | 1.4 s sweep, 0.6 s rest (2.0 s cycle, 0.5 Hz) | Slow enough to read as "ongoing", far below the 3 Hz flash limit |
| Level smoothing (mic and speech) | Attack time constant 35 ms, release 140 ms | Follows syllable onsets (about 4–5 a second) without flicker; falls back gently between words |
| Meter frame rate | At most 48 fps, and only while the smoothed level changes by more than 1% | Audio buffers arrive about 47 times a second; drawing faster adds nothing |
| Speech-paced reveal | Word timings from `AVSpeechSynthesizerDelegate` `willSpeakRangeOfSpeechString`; without them, an estimate of 4.5 syllables a second (a comma counts as 1 syllable, a sentence end as 2). Visuals may lead the audio by up to 40 ms, never lag | Seeing a word slightly before hearing it feels natural; hearing it first feels broken |
| Streaming text | Each glyph fades in over 0.12 s, staggered by up to 8 ms per glyph within a chunk | Chunks ripple in rather than pop |

## Meters

- **Mic meter (Listening).** Four bars in `state-listening`, 3 pt wide, 2 pt apart, 3–14 pt tall, fixed profile 0.55 / 1.0 / 0.8 / 0.5 × the smoothed level. One real level, no invented variation: the bars never move independently.
- **Speech meter (Speaking).** The same four bars in `benji-mint`, driven by the synthesiser's output level (render speech through an `AVAudioEngine` tap, or `AVSpeechSynthesizer.write` buffers). If no output level is available, show the static `waveform` glyph rather than a fake animation.
- **Level scale.** RMS of each buffer mapped from −50…0 dBFS to 0…1.

## Frame pacing and battery

- **Closed, Ready, Done held, Needs approval, Error:** zero frames. The display link is stopped.
- **Morphs:** the display link runs at the display's rate (up to 120 Hz on ProMotion) only until the spring settles, then stops.
- **Working shimmer:** a gradient mask on a `CALayer`, installed once when Working starts and removed when it ends; it runs in the render server, not on the main thread.
- **Meters:** updated from the audio callback's smoothed level, redrawn only when the level changes by more than 1%, at most 48 fps.
- **Budget (target, not yet measured):** under 1% CPU on Apple silicon while closed or in a held peek; under 5% while listening or speaking. Measure with Instruments when built.

## Reduce Motion and other settings

| Setting | What changes |
|---|---|
| Reduce Motion | Every size change becomes `motion-reduce` (crossfade, geometry instant underneath). No bounce on Done, no shimmer, no streaming ripple, no rising rows. Meters show a static level updated at most 4 times a second. Symbol effects off |
| Reduce Transparency | Liquid Glass controls inside the panel become solid `notch-raised`. The notch body is already opaque |
| Increase Contrast | `notch-hairline` rises to 0.25 opacity; secondary labels use `notch-label`. Motion is unchanged |
| Differentiate Without Color | Unchanged: every state already has its own glyph and word |
| Prefers cross-fade transitions (Accessibility › Display) | Treated like Reduce Motion for size changes |

## VoiceOver

Announce state changes, not animations. One announcement per real event, with `.announcement` priority low for progress and high for approval and errors:

| Event | Announcement |
|---|---|
| Listening starts | "Listening" |
| Approval needed | "Benji needs approval: Move 12 files to Archive" |
| Done | the Done line ("Done. 12 files moved to Archive.") |
| Error | the error line |
| Pointing | "Pointing at Share button" |

Peek and open sizes are announced as the panel appearing ("Benji, expanded"); the morph itself is never announced.

## Don't

- Don't add overshoot anywhere except the Done checkmark, and don't use `motion-done` for anything else.
- Don't animate while closed, and don't run any loop that isn't driven by a real, ongoing event.
- Don't animate frame and clip separately, or content on a different clock from its shape.
- Don't restart a morph on retarget; continue from the current size and speed.
- Don't flash, cycle or pulse a colour, or animate red. (The pointer's single halo pulse grows and fades in one colour; see the Overlay section.)
- Don't let a meter move without a real level behind it.
