# Overlay

When an answer that used screen context refers to something on screen, Benji can show where it is: a calm mark at the target and a short label, timed to the words that name it, then gone. The overlay is a highlight, not a drawing. Nothing follows the cursor, nothing is drawn freehand, and nothing appears without a real event (D-54).

## When it appears

- Only after an answer to a message that carried a screenshot (the `state-looking` turn), and only when the answer names a target (today the `[POINT:x,y:label]` tag).
- Only on the display that was captured, and only for something the model could clearly see.
- One mark at a time. An answer may name up to three targets in order ("Tick Sync files, then Include photos"); each appears when the speech reaches it and replaces the one before.
- While a mark is up, the peek shows the Pointing state: `scope` glyph in `benji-mint` and the label.

## Marks

Two kinds. The model sends geometry and intent; Benji picks the mark and draws it locally.

| Mark | Use it for | Geometry | Needs from the model |
|---|---|---|---|
| **Ring** | Anything about the size of a control: a button, an icon, a checkbox, a menu-bar item, a Dock icon | A circle around the point, outer diameter `pointer-ring` (26 pt), interior left clear | A point (exists today) |
| **Region** | Things larger than a control: a field, a paragraph, a photo, a sidebar section, a group of settings | A rounded rectangle around the box, outset 4 pt from the target, corner radius `radius-field` at the mint edge | A box: `[BOX:x1,y1,x2,y2:label]` (D-67: added to the backend together with ordered multi-target answers; the ring ships first, the region follows in the same overlay rework) |

Choosing between them:

- A point always gets a ring.
- A box no bigger than 44 × 44 pt gets a ring at its centre. A ring is easier to find than a small rectangle and survives a few points of error in the model's coordinates.
- A box covering more than a third of the display, or more than 80% of its width or height, gets no mark. It's the whole window; say it in words.

Not included, on purpose:

- **Underline or text range.** A region around the words does the same job with one shape. An underline needs line geometry that a downscaled screenshot doesn't give reliably, and an underline 2 pt off reads as a mistake where a region's 4 pt outset absorbs it. It's also a pen gesture, and Benji doesn't draw.
- **Arrows, callout lines, numbers, circles drawn by hand, highlighter fills.** They are drawings and add a second thing to look at. Steps are shown one at a time, so they need no numbers.

## Anatomy

Every mark is the same stack of layers, drawn from the inside out. Interiors are never filled, tinted or blurred: the target stays exactly as the user sees it.

| Layer | Ring (radii from the point) | Region (outsets from the target box) | Value |
|---|---|---|---|
| Clear interior | 0–9 pt | inside 3 pt | nothing drawn |
| Inner keyline | 9–10 pt | 3–4 pt | 1 pt, black at 60% |
| Mint stroke | 10–13 pt (3 pt) | 4–6 pt (2 pt) | `benji-mint` |
| Outer keyline | 13–14 pt | 6–7 pt | 1 pt, black at 60% |
| Halo | 14–20 pt | 7–13 pt | `shadow-pointer`: `benji-mint` at 28%, 6 pt wide |
| Material band | under the halo | under the halo | HUD material (`.hudWindow`), dark appearance, behind-window blending |

- Keep every layer concentric: region corner radius = outset + 4 pt, so the mint edge (outset 6) has `radius-field` (10 pt) and the halo's outer edge 17 pt. Use continuous corners.
- The region's stroke is thinner than the ring's because it's longer: at equal weight a rectangle reads much heavier than a 26 pt circle.
- `benji-mint` is fixed (the dark-appearance `systemMint`) in both appearances. The overlay floats over other apps, so the system appearance says nothing about what's underneath; the keylines handle light grounds.
- Align strokes to the backing pixel grid of the display they're on.

**Why keylines.** Mint alone is 11.9:1 on black but 1.8:1 on white and falls to 1.0:1 on a mint-coloured background. A 1 pt black keyline at 60% on each side of the mint fixes this: over every background on a 16-level RGB grid (4,096 colours), the ring always has at least one edge of **4.7:1** or more (mint against the ground on dark content, the keyline against the ground on light content, mint against its own keyline everywhere), above the 3:1 WCAG asks of graphics. 60% is the lightest keyline that clears 4.5:1 (50% gives 3.5:1, 40% only 2.6:1), so it stays quiet on dark content. The mint halo doesn't add contrast on light grounds; it's there to soften busy content around the mark. (Computed, not measured on a display.)

## Variants

| Setting | Ring and region | Label |
|---|---|---|
| Default | As in Anatomy | Dark HUD material capsule, white text |
| Increase Contrast | Mint stroke +1 pt (ring 4 pt, region 3 pt), growing inward; keylines opaque black, 1.5 pt; halo kept. Worst edge rises to 11.9:1 | Opaque `notch-raised`, 1 pt `notch-label-secondary` border |
| Reduce Transparency | No halo and no material. Keylines become opaque `notch-raised`, 2 pt: a mint ring set in the notch's own black. Worst edge 9.6:1 | Opaque `notch-raised`, no blur |
| Differentiate Without Color | No change: the mark never relied on colour. Its meaning is its shape plus the label's words, and the peek's `scope` glyph and words | No change |
| Reduce Motion | Same look; see Reveal | Same look |

## Label

- The target's name from the answer, 1 to 3 words, sentence case as written by the model. Single line, at most 240 pt wide, truncated at the end.
- `callout` (12 pt) semibold, white, in a `radius-pill` capsule, padding 4 × 10 pt.
- Capsule: HUD material in the dark appearance with a `notch-hairline` inner edge. White text on it stays at least 6.7:1 over every background on the grid above (white is the worst case, before blur).
- The label is part of the mark: it appears with it, never moves by itself and goes with it.

## Placement

Place the label on the first side that fits, in this order:

| Order | Side | Position |
|---|---|---|
| 1 | Below | `space-2` (8 pt) below the mark's halo, centred on the target |
| 2 | Above | `space-2` above the halo, centred |
| 3 | Trailing (right in left-to-right languages) | `space-2` beside the halo, vertically centred |
| 4 | Leading | the same on the other side |
| — | No side fits | No label. The words are in the answer and the peek |

A side fits when the label:

- lies inside the display's **safe area**: `NSScreen.visibleFrame` (which already excludes the menu bar and the Dock) inset by `space-3` (12 pt);
- doesn't touch the mark's keep-out (its outer halo edge; the outer keyline under Reduce Transparency), so it never covers the target;
- stays clear, by `space-3`, of the notch object at its current size and of any other Benji panel;
- stays on the target's display.

Above and below may slide sideways to stay in the safe area, but only while the label still spans the target's centre; past that, try the next side. Trailing and leading slide vertically by the same rule.

Edges and the notch:

- The mark itself never moves off the target. Near a display edge it may be cut by the edge; only the label moves.
- A target in the menu bar or the Dock is fine: the ring sits on it and the label goes into the safe area below or above it.
- If the open panel covers the target, collapse the panel to peek when the reveal starts (`motion-open`, content fading out first). The screenshot left Benji's panel out, so the model saw what the user can't. Hovering the peek opens it again as usual.

## Reveal

The reveal is tied to speech. The anchor is the first spoken word of the label ("Share" in "It's the Share button, top right"); if the label's words aren't in the spoken text, the end of the first sentence. Use the speech-paced reveal rule:

- Word times come from `AVSpeechSynthesizerDelegate.speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`, or the estimated fallback of 4.5 syllables per second, a comma counting as 1 syllable and a sentence end as 2.
- Start the reveal at the anchor word, up to 40 ms early when its time is known ahead. Never after the word is heard.
- Text-only answers (no speech): start when the answer has finished arriving in the panel or peek.

With motion (times from the start of the reveal):

| Time | Ring | Region |
|---|---|---|
| 0 ms | Stroke and keylines draw clockwise from 12 o'clock (`strokeEnd` 0 → 1) with `motion-content`. Halo and material fade in with `motion-fade` (in) | The same, from the top centre, with `motion-open` |
| 85 ms / 177 ms | Label fades in with `motion-fade` (the 65% point: 0.353 × d) | Same rule, at 177 ms |
| ≈ 285 ms / ≈ 590 ms | Stroke settles. **The one pulse:** a copy of the halo grows 10 pt outward with `motion-open` while its opacity goes from 28% to 0 along the same progress | The same |
| ≈ 875 ms / ≈ 1.2 s | At rest. Nothing moves until the mark is erased | At rest |

- Only the halo's copy pulses, once per target. The ring itself never scales, nothing loops, nothing flashes.
- Steps: when the next target is within 220 pt, the ring glides there with `motion-follow` (it keeps its velocity if retargeted), the old label fades out at once with `motion-fade`, the new label fades in when 35% of the hop remains, and the ring pulses once on arrival. Peak speed is about 6.6 × the hop per second: 475 pt/s for 72 pt, 1,450 pt/s for 220 pt. Further than 220 pt, or between a ring and a region, the old mark fades out and the new one reveals as above.
- Erase with `motion-fade` (out), then order the overlay window out when no marks remain.

Under Reduce Motion: at the same moment, the whole mark (stroke, halo and label) fades in at once with `motion-reduce` (200 ms). No stroke drawing, no pulse, no glide; steps crossfade with `motion-reduce`. Erasing is already a fade and doesn't change.

In Core Animation: `CAShapeLayer.strokeEnd` with a `CASpringAnimation` built from the token (mass 1, stiffness and damping from the motion table), opacity with `CABasicAnimation`. Run a display link only for a glide, and only while it moves. At rest nothing is scheduled.

## Lifetime and erase

A mark stays **8 s after it comes to rest**, and at least until 3 s after Benji stops speaking. It goes earlier on any of these:

| Event | How Benji knows (public API) | Permission | Status |
|---|---|---|---|
| Next message, talk key, New conversation | Benji's own events | none | Detected |
| Escape | In Benji's panel: its own key handling. Elsewhere: `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`. Observed only, never consumed, so the front app also gets it | Accessibility (already granted for the talk key) | Detected when granted |
| Click inside the target (plus its outset) | Global monitor for `.leftMouseDown` | none expected; verify | Detected |
| Scroll | Global monitor for `.scrollWheel`, while the pointer is over the target's window | none expected; verify | Detected for trackpad and mouse; **keyboard and programmatic scrolling are not** |
| Target window moves, resizes or closes | The window is identified at capture time from the `SCShareableContent` the capture already fetched (topmost window containing the target: `windowID`, `frame`, owning app). Then `AXObserver` (`kAXMovedNotification`, `kAXResizedNotification`, `kAXUIElementDestroyedNotification`); without Accessibility, poll `CGWindowListCopyWindowInfo` bounds at 4 Hz, only while a mark is up | Accessibility, or none for polling | Detected |
| Another window covers the target | Same poll: z-order of the window list | none | Detected |
| Space change | `NSWorkspace.activeSpaceDidChangeNotification` | none | Detected |
| App switch | `NSWorkspace.didActivateApplicationNotification`, when the new app is neither the target's app nor Benji | none | Detected |
| Displays change | `NSApplication.didChangeScreenParametersNotification` | none | Detected |
| Sleep | `NSWorkspace.screensDidSleepNotification`, `willSleepNotification` | none | Detected |
| Screen lock | `com.apple.screenIsLocked` distributed notification | none | Works widely but undocumented; assumed |
| Content changes inside a still window (a page navigates, a tab switches, a list re-sorts) | Not observable without reading pixels or deep AX | — | **Not detected**; the time-out covers it |
| Mission Control | No public notification. `.transient` collection behaviour hides the window there | none | Assumed from the documented behaviour; verify |

Nothing else erases a mark: hovering it or moving the pointer near it does nothing.

## Coordinates and displays

The model answers in pixels of the screenshot it was sent; the mark is drawn in points on one display.

1. Keep, with each capture, the display's ID (`CGDirectDisplayID`), its frame in AppKit global coordinates and the pixel size of the image actually sent.
2. Reject a point or box outside the image.
3. Scale by the display's size in points over the image's size in pixels (separately for x and y). This also absorbs the Retina backing scale and the downscaling.
4. Flip y: screenshot pixels start at the top-left; AppKit's global space starts at the bottom-left of the primary display. Global x = display min x + x × scale; global y = display max y − y × scale. For a box, map both corners.
5. Find the display again by its ID, never by its index in `NSScreen.screens` (the order changes). If it's gone or its frame changed since the capture, show no mark and keep the words.
6. Convert to the overlay window of that display and draw there. Marks and labels never cross to another display.

## Windows

One overlay window per display, created when a mark is first needed there and ordered out when its last mark goes.

| Property | Setting | Why |
|---|---|---|
| Class | `NSPanel` subclass, `[.borderless, .nonactivatingPanel]`, `canBecomeKey` and `canBecomeMain` return false | Never takes focus or activates Benji |
| Frame | The display's whole `frame` | Marks can sit on the menu bar or the Dock |
| Input | `ignoresMouseEvents = true` | Click-through: every click, scroll and hover reaches the app underneath |
| Look | `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `animationBehavior = .none` | Only the mark is visible |
| Spaces | `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]` | Present on whichever Space is active, including full-screen apps; hidden in Mission Control; left out of window cycling |
| Level | `.popUpMenu`, ordered front when shown, and always below Benji's notch panel | Above normal and floating windows, the menu bar and menus, so menu-bar and menu targets can be marked; the notch always wins. Never use the screen-saver level |
| Lists | `isExcludedFromWindowsMenu = true`; the content view is hidden from accessibility | It isn't a window the user works with |
| Capture | `sharingType = .none` by default (see below) | |

Interactive parts never go in the overlay. If one is ever needed, it gets its own small panel.

## Capture privacy

- **By default, keep Benji out of screen captures and recordings.** Set `sharingType = .none` on the overlay windows and the notch panel. Settings › Privacy: "Show Benji in screen recordings", off by default; on sets `.readOnly`.
- **Verify before promising it in copy.** `sharingType = .none` reliably hides a window from the legacy window-list capture; whether ScreenCaptureKit-based recorders (the system screenshot tools, QuickTime, conferencing apps) honour it on macOS 15 and 26 is not verified, and there are reports that they don't. Until checked, the setting's footnote says "where macOS allows".
- **Benji's own screenshots never include Benji.** The capture filter already excludes every window Benji owns (`SCContentFilter(display:excludingApplications:…)`), marks included.
- **Step aside** (erase every mark, `motion-fade`) when:

| Situation | Detectable? |
|---|---|
| Secure text entry is on anywhere (password fields, purchase and login sheets) | Yes: `IsSecureEventInputEnabled()`. Also never point into a secure field |
| Screenshot shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5) | Yes, when the defaults are in use, through the same global key monitor as Escape (Accessibility). Remapped shortcuts aren't seen |
| Screenshot app launched another way | Partly: `NSWorkspace.didLaunchApplicationNotification` for the Screenshot app; the capture UI itself runs in a system process with no public notification. Assumed, best effort |
| The system window/screen-sharing picker | **No** public signal for apps that didn't present it. Click-through plus capture exclusion keep it harmless |
| Mission Control | Handled by `.transient` (assumed, verify) |

- The purple `state-looking` indicator belongs to the notch, not the overlay. The overlay never shows a capture indicator and never appears during a capture.

## Accessibility

- **VoiceOver.** When the reveal starts, post `NSAccessibility.Notification.announcementRequested` with priority medium (so it queues after VoiceOver's current speech instead of cutting it): "Pointing at Share button." For steps: "Step 2 of 2: Include photos." With no label: "Pointing at something on screen." Nothing is announced on erase. The overlay's views are hidden from accessibility; the announcement is the whole interface.
- **Reduce Motion.** Fade only: the whole mark fades in with `motion-reduce`; no stroke drawing, pulse or glide.
- **Increase Contrast, Reduce Transparency, Differentiate Without Color.** See Variants.
- **Keyboard.** Escape dismisses every mark: in Benji's panel it also closes the panel (one press means "go away"); elsewhere it's observed, not taken (see Lifetime).
- **Readable.** The label repeats the answer, which stays in the transcript; nothing the user needs exists only in the overlay.

## Never

- Never trail, move, warp, hide or replace the cursor. Never draw a cursor, a character, a face or a pointing hand.
- Never draw freehand: no wobble, taper, handwriting, scribbles, highlighter, arrows or watercolour.
- Never fill, tint, dim or blur the target, and never let the label cover it.
- Never loop. One pulse per target, then still. No flashing, no attention-seeking idle motion.
- Never take focus, activate Benji, or swallow a click, scroll or key.
- Never show more than one mark at a time, or a mark on a display other than the captured one.
- Never keep a mark after its window moved, closed or was covered, after a scroll, a Space change or an app switch.
- Never point at something the model couldn't clearly see, or into a password field.
- Never use the state colours for the mark: it's `benji-mint`; orange and purple keep their privacy meanings.
- Never appear in screen recordings by default, and never in Benji's own screenshots.
