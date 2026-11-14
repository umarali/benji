# Sound

Benji is silent by default (D-61). It speaks only on voice turns. A user can turn on five quiet cues, short soft sounds for the few moments that matter: the microphone turning on and off, a finished task, a request for a Yes, and a failure. Each cue is redundant: the notch always shows the same thing in glyph, words and colour. If a sound would only say what the screen already makes obvious, or would play on every state, leave it out.

## Principles

1. **Silent by default.** Ship with cues off. Never turn them on for the user, and never nag about them.
2. **Sound only for real events.** A cue plays at the same moment as the event behind it, such as the mic engine starting or the assistant asking for approval, and never for a state the app has guessed.
3. **Never the only signal.** Every cue has a visual twin in the notch, and the visual always comes first. Nothing is ever heard without also being shown.
4. **Not on every state.** There are five cues for eleven states. Working, speaking, looking, pointing, ready and permission make no sound.
5. **Short, soft, still.** Every cue is under 0.6 s and ends when its motion ends. No loops, no repeats, no sound that rises in loudness or urgency.
6. **Calm, even for errors.** An error is lower and duller than Done, never louder. No alarms, buzzers or dissonance.
7. **One voice at a time.** A cue never plays over Benji's speech, and never over another cue.

## The cues

| Cue | Trigger (real event) | Visual twin | Length | Shape | Level | Variants |
|---|---|---|---|---|---|---|
| **Listening on** | Mic engine running (talk key or "Hey Benji") | Glyph `.replace` to `mic.fill`, `state-listening` | 130 ms | One glide up, F♯5 → A5 | −4 dB | 2 (paired with off) |
| **Listening off** | Mic engine stopped | Glyph to `waveform`, meter fades | 130 ms | One glide down, A5 → F♯5 | −6 dB | 2 (same as on) |
| **Done** | Answer delivered, and it was **not** spoken | `checkmark`, `state-done`, `motion-done` | 520 ms | Two notes up a major third, D5 → F♯5 | 0 dB (reference) | 3 |
| **Needs approval** | Assistant waiting for Yes or No | `hand.raised.fill`, `state-approval`, the approval card | 480 ms | Two equal notes, E5 · E5 | +1 dB | 2 |
| **Error** | Assistant, voice or capture error | `exclamationmark.triangle.fill`, `state-error` | 420 ms | Two notes down a minor third, A4 → F♯4, muted | −1 dB | 2 |

Levels are relative loudness (maximum momentary loudness, BS.1770), not peak level.

### Character

- **The family.** The cues share one round, fundamental-led tone, like a soft mallet on felt-covered wood, warmed by a little second harmonic. A faint two-octave overtone on the attack gives them a cool, clean edge. That edge is the mint: cool but warm. All are sine partials with gentle attacks. They are not bells or chimes, and they are not sampled from anything.
- **Contour carries meaning, not pitch.** Up means starting or finishing well. Down means stopping, or something went wrong. Two equal notes mean "your turn". Few people hear absolute pitch, but everyone hears direction.
- **Listening on and off** are a mirrored pair: a quick, small glide, the most discreet sound in the set. They are as frequent as key presses, so they are the quietest cues.
- **Done** is the one moment of character, the sound of the single bounce: a warm rising third whose second note rings out as the checkmark settles.
- **Needs approval** is a light double tap on the same note. It asks for attention without sounding alarmed.
- **Error** sits lower and softer, with no airy overtone and a slower attack, so it sounds like an "oh, no" and not an alarm.

### Timing against motion

Place every note so its attack *peaks* on a motion mark (the attack is 6 ms, or 10 ms for Error, so the note starts that much earlier). Start the cue in the same run-loop turn as the animation that it accompanies.

| Cue | Note 1 lands | Note 2 lands | Motion mark (vocabulary) | Ends |
|---|---|---|---|---|
| Listening on | +6 ms, as the `mic.fill` glyph starts its `.replace` | (glide completes at 60 ms) | `motion-content` | 130 ms, before the glyph settles (285 ms) |
| Listening off | +6 ms, the frame the meter starts to fade | (glide completes at 60 ms) | `motion-fade` out, 150 ms | 130 ms |
| Done | +6 ms, as the bounce starts (after the `.replace` finishes) | **+80 ms, the bounce peak (+14%)** | `motion-done` | 520 ms. About −24 dB by 450 ms, when the bounce is at rest; the last 30 ms fade to silence |
| Needs approval | +6 ms, as the notch starts growing to open | **+177 ms, as the card starts to fade in** (0.353 × 0.50 s) | `motion-open` | 480 ms, before the morph settles (590 ms) |
| Error | +10 ms, as the glyph starts its `.replace` | **+85 ms, the 65% point** (0.353 × 0.24 s) | `motion-content` | 420 ms |

Under Reduce Motion the cue is unchanged and starts with the crossfade. For Done, it starts when the checkmark starts to fade in, since there is no bounce.

### Variants and rotation

- **What varies.** Only the root moves: ±2 semitones for Done, approval and error, and 35 cents for the listening pair. The contour, interval, timing, timbre and loudness stay the same, so the meaning never changes. The twentieth hearing just doesn't sound like a machine gun.
- **How many.** Done gets three variants because it is the one emotional beat and the most likely to be heard in a row. Every other cue gets two. The listening pair is near-identical on purpose: feedback for a key press should be as consistent as a key.
- **Rotation.** Use a shuffle bag per cue: play each variant once in random order, then refill, never repeating the last variant across a refill. Listening off always uses the variant of the Listening on that it closes.
- **Every variant is loudness-matched.** They differ by 0.0 dB in momentary loudness (measured in the table below).

### What gets no sound

| State or event | Why not |
|---|---|
| Ready (hover peek) | It happens constantly and the user caused it. It already has the one light haptic. |
| Transcribing, Working | Work is shown, never sounded: nothing loops under work. |
| Speaking | Benji's voice is the signal. |
| Done after a spoken answer | The user just heard the answer. A cue after it would be noise. |
| Looking (screen) | macOS shows its own purple capture indicator, and Benji shows `viewfinder` in purple. Capture only happens inside a turn the user started, so the user is present. A shutter-like sound would read as surveillance. Revisit only if capture ever starts without the user, which it shouldn't. |
| Pointing | The highlight and the spoken label already point. |
| Needs permission | A window and the system prompt carry it. A sound would scold. |
| Heard nothing | Listening off is enough. Not catching speech isn't a failure that deserves the error sound. |
| Declined, approval timeout | The user said No, or No was assumed. Confirm in words ("Okay, I didn't touch them."), silently. |
| Settings changes, panel open or close | They are direct manipulation with visible results. |

## Loudness

- **One master volume.** In code: `gain = slider² × alertVolume`. The squared slider is an audio taper, so 70% is about −6 dB. The default slider is **70%**.
- **Follow the alert volume.** Scale by the system alert volume (System Settings › Sound › Alert volume), so a user who turned alerts down gets quieter cues too.
- **Follow "Play user interface sound effects".** When it is off, Benji plays no cues, and Settings says why.
- **Master at a fixed ceiling.** The cue files peak at or below **−18 dBFS** (the loudest is −18.5 dBFS). At gain 1, Done reads −30.7 LUFS momentary. That is far below typical macOS alert sounds, which are normalised near full scale (assumed; measure, see Engineering).
- **Default level.** At the default the Done cue should sit about **10 dB below the median macOS alert sound** at the same alert volume: audible in a quiet room, gone under music. Calibrate this once on a Mac and set the default slider from it.
- **Never duck other apps.** Ducking music for a 130 ms cue disturbs more than the cue helps.

### When to stay quiet

| Condition | How it's detected | Behaviour |
|---|---|---|
| Cues off (default) | The setting | Engine never starts, files are never loaded, zero cost |
| macOS UI sound effects off | `com.apple.sound.uiaudio.enabled` in the `com.apple.systemsound` defaults domain. Not public API; **assumed**, verify with `defaults read` | No cues |
| Benji is speaking | Its own synthesiser callbacks (`didStart` to `didFinish`/`didCancel`) | Skip listening and Done cues. Hold an approval or error cue until speech stops (at most 1 s), else drop it |
| VoiceOver announces the same event | Benji posts the announcement itself | No cue on top; one channel per event (see Accessibility) |
| Another app is using the microphone (call, recording, dictation) | Core Audio `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input while Benji's own mic is off. Public API, **assumed** to cover FaceTime, Zoom and Teams; per-process attribution via Core Audio process objects on macOS 14+ is **assumed**, untested | No cues while it is true |
| Screen recording or sharing by another app | **Not detectable** with public API | Nothing. Cues are off by default and quiet when on |
| Focus / Do Not Disturb | `INFocusStatusCenter` needs a separate permission | Not used. Don't ask for a permission just to stay quiet |
| Input and output are the same Bluetooth headset | Device transport type `kAudioDeviceTransportTypeBluetooth` on both | Skip Listening on: opening the headset mic switches the profile and swallows or garbles the cue (**assumed**, test with AirPods) |
| Two cues collide | The cue player | The newer cue wins; the older one fades out over 15 ms. Priority if simultaneous: error > approval > done > listening |
| The same event repeats | The state machine | One cue per event. Approval never re-cues while it waits, and an error never repeats |

## The setting

Put it in **Settings › Voice** in a group called **Sounds**, under the voice picker. If Settings has no Voice pane yet, put it in General. It is not in the notch or the menu-bar menu.

| Element | Copy | Notes |
|---|---|---|
| Group | Sounds | |
| Toggle | Play quiet cues | **Off by default.** Exception: while VoiceOver is running, Listening on and off play unless the user has turned the toggle off themselves (D-67) |
| Help text | A soft sound when I start or stop listening, finish, need your go-ahead, or hit a problem. The notch always shows the same thing. | `callout`, `label-secondary` |
| Slider | Volume | `speaker.fill` … `speaker.wave.3.fill` at the ends. Dimmed while the toggle is off. Plays Done once on release, as the macOS alert slider does |
| Note when macOS UI sounds are off | Your Mac's sound effects are off, so I'll stay quiet too. You can change that in System Settings › Sound. | Replaces the help text; the toggle stays usable |

## Haptics

- **Keep the one rule.** On Force Touch trackpads, play one light `.alignment` haptic (`NSHapticFeedbackManager`) when **hover** opens the peek, and nothing else.
- **At most once per peek.** If the pointer slips out and back within the 0.7 s close grace, don't play it again.
- **Never for events.** A haptic is felt only while a finger is on the trackpad, so it can't announce Done, approval or errors. Don't pair haptics with cues.
- **Independent of the sound setting.** The haptic follows the system's trackpad feedback setting, not "Play quiet cues".

## Engineering

- **A separate engine.** Give cues their own `AVAudioEngine` with one `AVAudioPlayerNode` into `mainMixerNode`. **Never touch `inputNode` on it.** Accessing it configures input, and running input would light the orange microphone indicator. The privacy light must never lie. Keep it apart from the voice engine.
- **Pre-warm at the earliest real signal.** Load every cue into an `AVAudioPCMBuffer` (float32, 48 kHz, mono; about 1 MB total). Call `prepare()` and `start()` on the engine at talk-key down, when "Hey Benji" is detected, when an assistant run starts, or when the Settings toggle or slider is touched. Each of these comes before any cue can fire. Stop the engine 10 s after the notch returns to closed. A running engine keeps the output device awake (power; assumed). Restart on `AVAudioEngineConfigurationChange`.
- **Play.** Call `player.scheduleBuffer(buffer, at: nil, options: .interrupts)` then `player.play()` on the already-running engine. `.interrupts` gives the "newer cue wins" rule. Apply a 15 ms fade on the outgoing buffer if it is still sounding.
- **Format.** Ship 48 kHz, 16-bit, mono **linear PCM** in `.caf` (or `.wav`). Use no AAC or MP3: compressed formats add encoder priming of tens of milliseconds and decode work at play time. 48 kHz because Apple-silicon built-in outputs run at 48 kHz by default (assumed; check the device's nominal rate). A matching rate means no sample-rate conversion. The mixer converts if a device runs at 44.1 kHz.
- **Mastering.** Peak ≤ −18 dBFS. TPDF dither at 16 bit so the quiet tails don't distort. First and last sample exactly 0. A raised-cosine fade over the last 20–30 ms. No leading silence: silence would be pure latency.

### Latency budget

Sound may trail the picture slightly but must never lead it. Motion's own rule allows visuals to lead audio by up to 40 ms. Light also arrives before sound in the physical world, so a small audio lag reads as natural. The **target is cue onset within 0–40 ms after the visual change**, which also keeps the response to a key press well under the 100 ms that feels instant.

| Stage | Budget | Basis |
|---|---|---|
| Event to main thread | Shared with the animation | Same run-loop turn, so it cancels out |
| Schedule on a running player | ≤ 11 ms | Waits at most one I/O buffer: 512 frames at 48 kHz = 10.7 ms (set 256 = 5.3 ms if needed) |
| Buffer in flight and device latency | ≈ 10–20 ms | One buffer plus built-in output latency and safety offset (assumed; read `outputNode.presentationLatency`) |
| **Total audio** | **≈ 21–31 ms** | |
| Picture's own latency | ≈ 8–25 ms | One to two frames, render to photons, at 60–120 Hz (assumed) |
| **Net audio lag** | **≈ 0–23 ms**, within the 40 ms target | |
| Cold engine start (no pre-warm) | Tens to hundreds of ms (assumed) | Why the engine is warmed before any cue can fire |
| Bluetooth output | Often 100–200+ ms (assumed) | Can't be met. Accept it: the visual already led |

Measure on a Mac: log the host time at the event, then the player's render time for the buffer's first frame plus `presentationLatency`.

## Accessibility

- **Sound is redundant.** Every cue's meaning is in the glyph, the words and the colour. A user who never hears a cue misses nothing.
- **One channel per event.** When Benji posts a VoiceOver announcement for an event (Done, an approval, an error), it plays no cue on top. For Listening on and off, prefer the cue to an announcement when cues are on: a spoken "Listening" would talk over the user and land in the recording. When cues are off, announce with low priority.
- **VoiceOver users get the listening pair by default (D-67).** While VoiceOver is running, Listening on and off play even though the toggle starts off, because a cue is the only way to confirm the mic without speech landing in the recording. Done, approval and error stay announced, not cued. Once the user changes the toggle, their choice wins.
- **"Hey Benji" always plays Listening on (D-67).** When the wake phrase (itself off by default) opens the mic, Listening on plays even with cues off: the user may not be looking at the notch, and a microphone that opens on a voice must be heard to open. Listening off follows the normal setting.
- **No loops, no repeats, no rising urgency.** A waiting approval never re-sounds, and nothing flashes or beeps on a timer.
- **Hearing range.** Cues sit between 330 Hz and 3.6 kHz: above the roll-off of small laptop speakers, and below the 4–8 kHz region that age-related hearing loss reaches first. They are mono, so Mono Audio changes nothing.
- **Reduce Motion doesn't change sound.** Only the visual twin changes, to a crossfade.

## How the numbers were derived

- **Lengths** come from the motion they accompany: no cue outlasts its morph. The listening pair (130 ms) also ends before most people start speaking after a key press, which keeps it out of the recording.
- **Note 2 times** are the motion marks: the analytic peak of `motion-done` (impulse response, d 0.45 s, ζ 0.7, v₀ 4.25/s: the peak is at tan(ω_d t) = ω_d/(ζω₀), t = 79.7 ms, +14.0%), and the 65% content point 0.353 × d for `motion-open` and `motion-content`.
- **Pitches.** The register (330–880 Hz fundamentals, partials up to 3.6 kHz) sits above laptop-speaker roll-off and below the ear's harsh 2–5 kHz peak. The notes come from one D-major pentatonic set so consecutive cues never clash.
- **Levels** run quietest for the most frequent cue and loudest for the one that blocks the user. They are measured as K-weighted momentary loudness so short and long cues compare fairly.
- **Variants** are tied to how often each cue is heard and how consistent it needs to be.
- **48 kHz** comes from the output device's native rate, and **LPCM** from latency.
- **D-56.** No other app's sounds, lengths, counts or rates were used, and none of the cue files derive from any existing sound.

## Don't

- Don't turn cues on by default, or prompt the user to turn them on.
- Don't play a cue for a state no event produced, or for Working, Speaking, Looking or Ready.
- Don't loop, repeat or escalate a sound. Don't use alarms, sirens, buzzers or red-alert tones.
- Don't play a cue over Benji's speech, over a VoiceOver announcement of the same event, or while another app is recording.
- Don't let the cue engine open the microphone.
- Don't duck other apps' audio.
- Don't add sounds for hover, clicks or typing.
