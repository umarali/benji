# PointerHighlight

Shows where something is on screen after a screen-context answer: a mint ring at a point, or a rounded region around a box, with a short label, revealed as the speech names it, then gone. The full rules are in Overlay.md.

**Consumer provides:** the target from the answer in screenshot pixels (a point, or a box once the backend can send one), its label (1 to 3 words), the capture's display ID, frame and sent image size for mapping, the spoken text and word timings (or text-only), and the window the target was in at capture time.

**Use**
- Ring for a point or a box up to 44 × 44 pt: `pointer-ring` outer diameter, 3 pt `benji-mint` stroke between 1 pt black-60% keylines, `shadow-pointer` halo over a HUD-material band; interior clear. Region for larger boxes: 2 pt stroke outset 4 pt, `radius-field` at the mint edge, same keylines and halo. No mark for boxes over a third of the display.
- Label in a dark HUD-material `radius-pill` capsule, `callout` semibold white, `space-2` from the halo. Try below, above, trailing, leading; keep it inside the visible frame inset `space-3`, clear of the target and the notch object, on the same display; no side fits, no label.
- Reveal at the anchor word (up to 40 ms early): stroke draws with `motion-content` (ring) or `motion-open` (region), halo fades in with `motion-fade`, label at 65%, then one pulse of the halo's copy, then still. Steps within 220 pt glide with `motion-follow`. Under Reduce Motion the whole mark fades in with `motion-reduce`.
- Gone 8 s after rest (at least 3 s after speech ends), or on the next message, Escape, a click on the target, scroll, the target window moving, closing or being covered, a Space change, an app switch, a display change or sleep. Erase with `motion-fade`.
- One click-through, never-key `NSPanel` per display at `.popUpMenu`, below the notch panel, `sharingType = .none` unless the user turns on "Show Benji in screen recordings". VoiceOver hears "Pointing at <label>."
- Increase Contrast: thicker stroke, opaque black keylines, opaque label. Reduce Transparency: no halo or material, opaque `notch-raised` keylines and label.

**Don't** move or draw a cursor, draw freehand (underlines, arrows, highlighter), fill or dim the target, cover it with the label, loop the pulse, take focus, or point at anything the model couldn't clearly see.
