# Composer

The bottom of the open panel: screen-context toggle, the message field, and send.

**Consumer provides:** the text binding, whether screen context is armed, whether Benji is busy (send disabled), and the send and toggle actions.

**Use**
- Field on `notch-raised` with a `notch-hairline` outline, `radius-field`, `body` text, placeholder "Ask Benji…" in `notch-label-secondary`; grows to four lines.
- Screen toggle: `viewfinder` glyph, `notch-label-secondary` off, `state-looking` on.
- Send: `arrow.up.circle.fill` in `benji-mint`; dimmed while empty or busy.
- Return sends; ⌘V/C/X/A/Z work in the field.
- On macOS 26 the two buttons use Liquid Glass; on 14–15 plain glyph buttons.

**Don't** add a separate mic button here; the talk key and the header mic cover voice.
