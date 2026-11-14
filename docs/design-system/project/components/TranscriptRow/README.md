# TranscriptRow

One line of the conversation in the open panel: what you said, what Benji did, and what it answered.

**Consumer provides:** the role (you, Benji, step, approval outcome, error, screen attached), the text, and for screen attachments the thumbnail of exactly what was sent.

**Use**
- You: `body` in `notch-label`, led by a small chevron in `notch-label-secondary`.
- Benji: `body` in `notch-label`, led by a `benji-mint` dot.
- Step: `callout` in `notch-label-secondary`, tool name and target in `mono`.
- Approved / Declined: `callout`; the glyph carries `state-done` or `notch-label-secondary`.
- Error: `body` in `state-error` with the triangle glyph.
- Screen attached: `caption` with `state-looking` viewfinder glyph and the real thumbnail.
- Live partial words while listening: `body`, italic, `notch-label-secondary`, replaced by the sent line.

**Don't** fade rows out, truncate answers, or render markdown symbols literally.
