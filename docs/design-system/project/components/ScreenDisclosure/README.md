# ScreenDisclosure

Says exactly what will happen before Benji looks at the screen, shown while screen context is on for the next message.

**Consumer provides:** the destination name (the model provider, or the custom server's host) and the close action.

**Use**
- `callout` text in `notch-label-secondary` with a `state-looking` viewfinder glyph, on a faint purple tint of `notch-raised`.
- The words name the scope (this message only, this display), what's excluded (Benji's own panel), where it goes, and when it's deleted.
- A close button turns screen context off.

**Don't** capture anything before the user sends, keep screen context on after one message, or soften the destination.
