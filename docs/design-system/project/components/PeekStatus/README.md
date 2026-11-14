# PeekStatus

The contents of the peek: one state glyph, the state word and one line, each tied to a real event, and how they change.

**Consumer provides:** the state (from the companion's state machine), the line (live words, current step, action, first answer line, or error), the smoothed mic or speech level, and word timings from the speech synthesizer.

**Use**
- Glyph in the left wing: the SF Symbol from the States table, coloured with its state token; the mic meter (Listening) or speech meter (Speaking) beside it. The preview draws stand-ins for the symbols.
- State word in the right wing in `peek-status`, at most about 74 pt: Ready, Listening, Transcribing, Working, Approval, Speaking, Looking, Pointing, Done, Error, Permission. The line in `peek-line` in the row below, tail-truncated.
- Glyphs change with `.contentTransition(.symbolEffect(.replace))`; words fade with `motion-fade`; the wing follows with `motion-content`.
- Speaking reveals the line in step with speech (word timings, else 4.5 syllables a second); visuals may lead the audio by 40 ms, never lag.
- Working: one shimmer sweep (1.4 s) then 0.6 s rest, only while the process runs.
- Done: the checkmark bounces once (`motion-done`), holds 0.5 s + 0.25 s per word (1.5–4 s), then the peek closes.
- Under Reduce Motion: crossfades only, static meters, no shimmer, no bounce, lines appear whole.

**Don't** show a state no event produced, move a meter without a real level, colour a state without its glyph and word, use red for anything but errors, or bounce anything but Done.
