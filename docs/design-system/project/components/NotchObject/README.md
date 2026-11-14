# NotchObject

The single black object Benji lives in, growing out of the hardware notch in three sizes (closed, peek, open) as one spring-driven shape.

**Consumer provides:** the current size (closed, peek, open), the state for the peek wings, and the open panel's content (transcript, composer). Position it centred on the notch with its top edge at the screen's top; read the notch rect from `NSScreen.auxiliaryTopLeftArea`/`auxiliaryTopRightArea`.

**Use**
- One animatable `Shape`: flat top, concave shoulders flaring into the menu bar (6 / 8 / 12 pt), continuous bottom corners (`radius-notch-closed`, `radius-notch-peek`, `radius-notch-open`). Width, height and radii ride one spring.
- Closed: `notch-closed-width` × `notch-height`, `notch-black`, nothing drawn, no shadow.
- Peek: `notch-peek-width` × `notch-peek-height` (360 × 60): glyph wing left of the hardware notch, state word right, one `peek-line` in the row below.
- Open: `notch-open-width` × `notch-open-height`, `shadow-notch-open` fading in with the height; panel content in the dark appearance.
- Closed ↔ peek with `motion-peek`; anything to or from open with `motion-open`. Content fades in at 65% of a growth and fades out 100 ms before a shrink. A reversed morph keeps its speed. Under Reduce Motion, `motion-reduce` (crossfade). See the Motion section.
- Hover: peek after 100 ms of rest in the hot zone (the notch plus 8 pt) at under 150 pt/s; close 0.7 s after the pointer leaves, only when idle.

**Don't** add a border, a gradient, a face, any bounce or any idle motion. Don't animate the frame and the clip separately. Don't open it without hover, the talk key, the menu-bar item or a real event.
