---
name: music
description: See what's playing and control playback in the macOS Music app via AppleScript.
when_to_use: The user asks what's playing, or to play, pause or skip music, or about their playlists in Apple Music.
---

# Music

Use the Music app through AppleScript with `run_applescript`, never by faking clicks.
macOS asks the user for automation permission the first time.

## Read (these only get data)
What's playing:
```applescript
tell application "Music"
    if player state is playing then
        return (name of current track) & " by " & (artist of current track)
    end if
    return "Nothing is playing."
end tell
```
Playlists:
```applescript
tell application "Music" to get name of user playlists
```

## Control (these change state, so Benji may ask the user to approve)
```applescript
tell application "Music" to pause
```
Others: `playpause`, `next track`, `previous track`, `play user playlist "Road trip"`.

## Care
- Use the exact playlist name from the list above.
- Never delete tracks or playlists, and never buy anything.
- Don't change the volume unless the user asks.
