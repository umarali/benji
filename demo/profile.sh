#!/bin/bash
# Starts Benji with an empty, throwaway folder before you record a demo in your own account.
# Your real Benji folder (~/.benji: memory, saved conversations, jobs, logs) is not moved, copied,
# read or changed: the demo run uses a scratch folder of its own through BENJI_WORKDIR, the one
# switch that tells the engine and the app where Benji's folder is (D-175).
#
#     bash profile.sh start     # before recording; Benji must be quit. Opens Benji on the scratch folder.
#     bash profile.sh finish    # after recording; Benji must be quit. Tells you where the scratch folder is.
#
# `start` makes ~/.benji/demo/run-<time> (mode 700), links the on-device voice into it (voice-venv and
# voices hold nothing personal; only the links are made) and opens Benji with BENJI_WORKDIR set to it
# (`open --env`). Benji then starts as if new: no memory, no recent conversations, no jobs. Nothing is
# deleted by this script: `finish` only names the folder, and you delete it yourself when you have
# looked. (Before D-175 this script moved your real ~/benji aside and back; that is gone.)
# Your key stays where it is (the Keychain or ~/.benji.env): the demo run uses it like any other run.

set -u

BENJI_HOME="$HOME/.benji"
RUNS="$BENJI_HOME/demo"
KEEP="voice-venv voices"

die() { echo "profile.sh: $*" >&2; exit 1; }

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set"
if pgrep -x Benji >/dev/null 2>&1; then die "quit Benji first (its menu-bar icon, then Quit)"; fi

case "${1:-}" in
    start)
        # Never make ~/.benji before Benji has moved an old ~/benji into it: a new, empty ~/.benji
        # would leave that folder stranded.
        if [ -d "$HOME/benji" ] && [ ! -e "$BENJI_HOME" ]; then
            die "$HOME/benji is still Benji's folder: open Benji once so it moves into $BENJI_HOME, quit it, then run this again."
        fi
        run="$RUNS/run-$(date +%Y%m%d-%H%M%S)"
        [ ! -e "$run" ] && [ ! -L "$run" ] || die "$run already exists: wait a second and run it again"
        mkdir -p -m 700 "$RUNS" || die "cannot create $RUNS"
        mkdir -m 700 "$run" || die "cannot create $run"
        for n in $KEEP; do
            if [ -d "$BENJI_HOME/$n" ] && [ ! -L "$BENJI_HOME/$n" ]; then
                ln -s "$BENJI_HOME/$n" "$run/$n" || die "could not link $n"
            fi
        done
        echo "Demo folder: $run"
        open -n --env "BENJI_WORKDIR=$run" -a Benji || die "could not open Benji; start it yourself with BENJI_WORKDIR=$run"
        echo "Benji is open on an empty folder. Record, quit Benji, then run: bash profile.sh finish" ;;
    finish)
        [ -d "$RUNS" ] || die "no demo run was started ($RUNS does not exist)"
        echo "Your own files in $BENJI_HOME were never touched."
        echo "The demo's files are in the run-<time> folders under $RUNS: look, then delete that folder yourself." ;;
    *)
        die "usage: bash profile.sh start | finish" ;;
esac
