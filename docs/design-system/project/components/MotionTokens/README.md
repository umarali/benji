# MotionTokens

The seven motion tokens every Benji animation uses, with their curves plotted from the same spring maths the app uses and a demo of each.

**Consumer provides:** nothing; this is a reference card. Motion can't live in `tokens.json`, so the tokens are named here and specified in the Motion section.

**Use**
- `motion-peek` `.smooth(duration: 0.30)` for closed ↔ peek; `motion-open` `.smooth` (0.5 s) for anything to or from open; `motion-content` `.smooth(duration: 0.24)` inside a size.
- `motion-follow` `.spring(duration: 0.35, bounce: 0)` for values retargeted while moving; it keeps velocity.
- `motion-fade` 0.15 s ease-out in, ease-in out, for content entering or leaving.
- `motion-done` only for the Done checkmark: `.symbolEffect(.bounce.up)` or a scale impulse with `.bouncy(duration: 0.45)`.
- `motion-reduce` 0.20 s crossfade stands in for every spatial token under Reduce Motion.

**Don't** add a token for one case, use `motion-done` anywhere else, or give any other token a bounce.
