# PermissionChecklist

The one place to grant everything Benji needs, each with why it's needed and its live status; used in onboarding and the menu-bar item's Setup section.

**Consumer provides:** each permission's live status (read from the system each time it's shown) and the request action (system prompt once per launch, then the right System Settings pane).

**Use**
- A standard macOS grouped form on `surface` in a `window-bg` window; rows: name in `body`, purpose in `callout` in `label` (not `label-secondary`, which is 3.95:1 on `surface` in light).
- Status: `system-green` checkmark plus "Allowed", or an `accent` "Allow…" button. Status glyphs always sit beside words.
- The four rows, in order: Microphone (to hear you when you talk), Speech Recognition (to turn your voice into text on this Mac), Accessibility (for the Right Option talk key), Screen Recording (only when you include your screen with a message).

**Don't** ask for everything on launch, or show a permission as granted that the system doesn't confirm.
