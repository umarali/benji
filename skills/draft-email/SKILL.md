---
name: draft-email
description: Draft an email in the user's voice. Draft only — never send.
when_to_use: The user asks you to write or reply to an email, or to draft a message to someone.
---

# Draft an email

Goal: produce a ready-to-send draft. You do **not** send anything — Benji has no send
capability, and sending is the user's call anyway.

## Steps
1. Pin down: recipient, purpose, key points, desired tone, and any deadline/ask.
   If the user gave a thread to reply to, read it first (via a file they point to).
2. If something essential is missing (who it's to, the core ask), ask one bundled set
   of specific questions before writing — don't invent facts, names, or commitments.
3. Write the draft: clear subject line, a greeting, tight body, a single clear ask,
   and a sign-off. Match the user's voice, not a generic assistant tone.

## Output
- Write the draft to `output/email-<short-slug>.md` with `write_file`, and also show
  it in your reply.
- Label it clearly as a **draft**. Tell the user it's ready to copy into their mail
  client; Benji will not send it.
- If you had to assume anything, list those assumptions in one line under the draft.
