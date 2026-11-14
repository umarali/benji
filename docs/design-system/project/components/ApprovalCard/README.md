# ApprovalCard

Asks before Benji changes, sends or deletes anything: the exact action and target, with No, Adjust and Yes.

**Consumer provides:** the action ("Move 12 files"), the target (path, recipient, app), and the three handlers. Adjust returns the request to the composer with the action pre-filled.

**Use**
- Card on `notch-raised`, `radius-card`, `space-4` padding, a `state-approval` hand glyph and a thin `state-approval` top edge.
- Action in `headline`, target in `mono` on its own line.
- Capsule buttons (`radius-pill`): No and Adjust neutral, Yes in `accent` (the user's accent colour). Return and Escape mean No; Yes needs a click or ⌘Return.
- Times out after 60 s as No, saying so ("Timed out, so I didn't do it.").
- Works when the panel isn't focused: it brings the panel forward and takes the keyboard.

**Don't** make Yes the default button, hide the target, or approve on timeout.
