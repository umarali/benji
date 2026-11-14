#!/bin/bash
# Run this INSIDE the demo account (a standard, non-admin macOS user), before you record anything.
#
#     bash check-isolation.sh <owner-username>
#
# <owner-username> is the short name of the account that owns this Mac's real data (the one you
# normally use). The script asks one question about each thing that account owns: "can this account
# get to it?" Every answer must be NO. It only checks whether access would be allowed (test -r,
# test -x, ls -ld for the permission bits, and exit codes). It never opens, lists, reads or prints
# the contents of any file or folder, it writes nothing (not even a log), and it prints the owner's
# and other users' names as OWNER / OTHER-n so a recording of this screen does not show them.
#
# PASS = access was denied (or there is nothing there). FAIL = this account could get in.
# Any FAIL: stop. Do not record. Fix it on the owner's account (hardening-checklist.md) and run again.
# Exit status: 0 all PASS, 1 at least one FAIL, 2 wrong use.
#
# BENJI_DEMO_USERS_DIR is for this repository's own tests (a fake /Users); leave it unset.

set -u

USERS_DIR="${BENJI_DEMO_USERS_DIR:-/Users}"
ME="$(id -un)"
FAILS=0
N=0

usage() {
    echo "usage: bash check-isolation.sh <owner-username>" >&2
    echo "  Run it inside the demo account. <owner-username> is the account whose data must stay out of reach." >&2
    exit 2
}

[ $# -eq 1 ] || usage
OWNER="$1"
case "$OWNER" in
    ""|*[!A-Za-z0-9._-]*|.*|-*) echo "That does not look like a macOS short user name: letters, digits, dot, dash, underscore only." >&2; usage ;;
esac

pass() { N=$((N + 1)); echo "  PASS  $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL  $1"; }

# The permission bits of a path, e.g. drwx------ (ls -ld shows the entry itself, never its contents).
mode_of() { ls -ld "$1" 2>/dev/null | cut -c1-11; }

# deny_dir <label shown> <path>: PASS when this account can neither list nor enter the folder.
deny_dir() {
    label="$1"; p="$2"
    r=no; x=no
    test -r "$p" && r=yes
    test -x "$p" && x=yes
    if [ "$r" = no ] && [ "$x" = no ]; then
        pass "$label: denied"
    else
        fail "$label: this account can get in (read=$r, enter=$x, mode $(mode_of "$p"))"
    fi
}

echo "Benji demo isolation check (read-only)"
echo

# 0. Is this the right account, and does the check mean anything?
echo "Setup"
if [ "$ME" = "$OWNER" ]; then
    fail "you are logged in as the owner account: run this inside the demo account instead"
    echo
    echo "RESULT: FAIL. STOP THE DEMO. Nothing was checked."
    exit 1
else
    pass "running as a different account from the owner"
fi
if [ -d "$USERS_DIR/$OWNER" ]; then
    pass "the owner's home folder exists (so the checks below are meaningful)"
else
    fail "no home folder for OWNER at the usual place: wrong name? Nothing below can be trusted"
    echo
    echo "RESULT: FAIL. STOP THE DEMO. Check the name you typed."
    exit 1
fi
if test -r "$HOME" && test -x "$HOME"; then
    pass "control: this account can read and enter its own home (the tests work)"
else
    fail "control: this account cannot read its own home, so the other results mean nothing"
fi
case " $(id -Gn) " in
    *" admin "*) fail "this account is an administrator: the demo account must be a standard user" ;;
    *) pass "this account is not in the admin group" ;;
esac
echo

# 1. The owner's home folder and the things people keep in it.
echo "The owner's files"
OH="$USERS_DIR/$OWNER"
deny_dir "OWNER's home folder" "$OH"
deny_dir "OWNER's .ssh" "$OH/.ssh"
deny_dir "OWNER's .aws" "$OH/.aws"
deny_dir "OWNER's .config" "$OH/.config"
deny_dir "OWNER's Documents" "$OH/Documents"
deny_dir "OWNER's Desktop" "$OH/Desktop"
deny_dir "OWNER's Benji folder" "$OH/.benji"
deny_dir "OWNER's older Benji folder" "$OH/.chilly"
deny_dir "OWNER's older visible folder" "$OH/chilly"
deny_dir "OWNER's Benji key file" "$OH/.benji.env"
deny_dir "OWNER's older key file" "$OH/.chilly.env"
echo

# 2. Keychains and browser profiles.
echo "Keychains and browsers"
deny_dir "OWNER's keychain folder" "$OH/Library/Keychains"
deny_dir "OWNER's Chrome profile folder" "$OH/Library/Application Support/Google/Chrome"
deny_dir "OWNER's Brave profile folder" "$OH/Library/Application Support/BraveSoftware"
deny_dir "OWNER's Edge profile folder" "$OH/Library/Application Support/Microsoft Edge"
deny_dir "OWNER's Arc profile folder" "$OH/Library/Application Support/Arc"
deny_dir "OWNER's Firefox profile folder" "$OH/Library/Application Support/Firefox"
deny_dir "OWNER's Safari data" "$OH/Library/Safari"
deny_dir "OWNER's cookies" "$OH/Library/Cookies"
deny_dir "OWNER's Mail data" "$OH/Library/Mail"
deny_dir "OWNER's Messages data" "$OH/Library/Messages"
echo

# 3. Every other account's home folder (names are not printed).
echo "Other accounts"
i=0
for d in "$USERS_DIR"/*; do
    [ -d "$d" ] || continue
    b="${d##*/}"
    case "$b" in
        "$ME"|"$OWNER"|Shared|Guest) continue ;;
    esac
    i=$((i + 1))
    deny_dir "another user's home folder (OTHER-$i)" "$d"
done
if [ "$i" -eq 0 ]; then
    pass "no other user home folders besides the owner's and this account's"
fi
echo

# 4. Privilege and the system's user records.
echo "Privilege"
if sudo -n true >/dev/null 2>&1; then
    fail "sudo works without a password for this account: it can act as an administrator"
else
    pass "sudo -n true: refused"
fi
DSLOCAL="${BENJI_DEMO_DSLOCAL:-/private/var/db/dslocal}"
if test -r "$DSLOCAL/nodes/Default/users" || test -r "$DSLOCAL/nodes/Default/users/root.plist"; then
    fail "this account can read the system's user records (dslocal)"
else
    pass "the system's user records (dslocal): denied"
fi
echo

if [ "$FAILS" -eq 0 ]; then
    echo "RESULT: PASS. All $N checks passed. This reduces the risk of recording here; it does not remove it (see demo/README.md)."
    exit 0
fi
echo "RESULT: FAIL. $FAILS of $N checks failed."
echo "STOP THE DEMO. Do not record. Fix the failures on the OWNER account (demo/hardening-checklist.md), then run this again."
exit 1
