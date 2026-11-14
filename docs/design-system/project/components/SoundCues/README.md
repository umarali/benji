# SoundCues

The five optional quiet cues (Listening on, Listening off, Done, Needs approval and Error), each tied to a real event and to the motion it lines up with. They are off by default (D-61).

**Consumer provides:** the event from the companion's state machine, whether Benji is speaking or VoiceOver will announce the event, the user's setting (on/off and volume), and the system alert volume and UI-sound-effects flag.

**Use**
- Play a cue only when "Play quiet cues" is on and macOS UI sound effects are on. The gain is `volume² × alert volume`, and the default volume is 70%.
- Use a separate pre-warmed `AVAudioEngine` with one `AVAudioPlayerNode`, and never touch its `inputNode`. Start it at talk-key down, "Hey Benji", or when an assistant run starts. Stop it 10 s after the notch closes.
- Start the cue in the same run-loop turn as its animation. Done starts with the checkmark's bounce, so its second note lands on the bounce peak at 80 ms.
- Rotate variants with a shuffle bag. Listening off reuses the variant of the Listening on it closes.
- Skip the cue when the answer was spoken, while Benji speaks, when VoiceOver announces the same event, or while another app is using the microphone.
- Ship 48 kHz, 16-bit, mono LPCM files that peak at −18 dBFS or below.

**Don't** turn cues on by default, play one for Working, Speaking, Looking or Ready, loop or repeat a cue, play over speech, or duck other apps.
