# Hardening checklist: for the owner, on the owner's OWN account

Do this before you create or use the demo account. Every command is for **you** to run in **your own
Terminal**, on **your own account**, and every one only looks or tightens permissions. None of it is run
by Benji, and none assumes anything is installed: each command is written so that it does nothing
when the thing it names does not exist. Read a command before you paste it. Nothing here is a
guarantee; it makes the demo account less able to reach your things (see [README.md](README.md)).

Steps marked **(admin)** need an administrator's password on this Mac. Do not type that password while
recording.

## 1. Tighten your home folder to owner-only

macOS creates home folders that other accounts can open and list. Close that:

```bash
ls -ld ~            # before: look at the first column, e.g. drwxr-xr-x
chmod 700 ~         # only you can enter or list your home folder
ls -ld ~            # after: drwx------
```

If something of yours must be reachable by another account (a shared folder), put it somewhere else on
purpose (step 4), not in your home.

## 2. Tighten the places people keep secrets

Each line only acts if the folder exists:

```bash
for d in ~/.ssh ~/.aws ~/.config ~/.gnupg ~/.kube ~/.docker; do [ -d "$d" ] && chmod 700 "$d" && ls -ld "$d"; done
for f in ~/.benji.env ~/.netrc ~/.npmrc ~/.pypirc; do [ -f "$f" ] && chmod 600 "$f" && ls -l "$f"; done
[ -d ~/Library/Keychains ] && ls -ld ~/Library/Keychains
```

## 3. Review what is group- or world-readable under your home

This prints **names** of files others could read; it opens none of them. Adjust the depth if you like:

```bash
find ~ -maxdepth 3 \( -path ~/Library -o -path ~/.Trash \) -prune -o -type f \( -perm -040 -o -perm -004 \) -print 2>/dev/null | head -50
```

For anything on the list you do not want shared: `chmod go-rwx <file>`. With your home at 700 these are
not reachable through the home folder anyway; this is the second lock.

## 4. Review the places every account can read

Another account can read world-readable files **outside** your home. Look at what you left there:

```bash
ls -la /Users/Shared 2>/dev/null
ls -la /private/tmp 2>/dev/null | head -30
ls -l /usr/local/etc /opt/homebrew/etc 2>/dev/null | head -40     # tool configs; some hold tokens
ls -ld /Volumes/* 2>/dev/null                                     # drives and network shares that are mounted
```

Remove or move anything of yours that does not belong there. Unmount shares and eject external drives
before the demo.

## 5. Make a demo-only API key with a spending cap

The demo uses a real model, so it needs a key. Make that key harmless:

1. In your model provider's console, create a **new** key used for nothing else. Name it so you remember
   (for example "benji-demo").
2. Set the lowest **monthly spend limit** the console allows, or fund the account with a small amount
   only. If the console has no cap, use a prepaid balance of a few dollars.
3. Do not reuse your everyday key, and do not copy it from your account. You will type the new key by hand
   into the demo account's own `~/.benji.env` (mode 600), once, and nowhere else.
4. After the demo, **revoke the key** in the console.

## 6. Do not bring your real keys or files in

- Do not AirDrop, drag, email, sync or copy any of your real files, keys, `.benji.env`, browser profile or
  notes to the demo account. `seed.sh` creates invented files there.
- Do not sign the demo account in to iCloud, an Apple ID, Chrome or any website with a real login.
- Do not use `/Users/Shared`, a shared folder or a USB stick as a bridge for anything private. If you use
  `/Users/Shared` to hand over the public repository (a copy of the exported tree, nothing else), remove it
  afterwards: `rm -r /Users/Shared/<that folder>` **(you run this; check the name first)**.
- Clipboards are per login session. Do not copy your key from your account and paste it in the demo
  account; type it.

## 7. Turn off network-connected agents and sharing while the demo account is on screen

Anything running in **your** account keeps running after you switch to the demo account (fast user
switching leaves your session alive). So:

- Prefer to **log out** of your own account completely (Apple menu › Log Out) before the demo account is
  logged in, so nothing of yours is running: chat apps, sync clients, notification popups, AI coding
  agents or assistants with access to your files or screen, remote-control tools, VPN clients that expose
  your files.
- If you cannot log out, quit those apps by name first. Check what is still running:

```bash
ps -axo comm= | sort -u | head -80      # names of running programs; look for agents, sync and remote tools
```

- Check the sharing services **(admin)**: System Settings › General › Sharing. Turn off Screen Sharing,
  File Sharing, Remote Login, Remote Management, Remote Apple Events, Content Caching and Internet Sharing
  for the demo. To read the state of remote login from Terminal: `sudo systemsetup -getremotelogin`.
- Turn off notification previews and Do Not Disturb-bypassing apps for the demo: System Settings ›
  Notifications.

## 8. Check the demo account is what you think **(admin)**

After you create it (see [README.md](README.md)):

- System Settings › Users & Groups: the demo user's type is **Standard**, not Administrator.
- It is not set to "Allow user to administer this computer" and is not in the admin group:
  `id -Gn <demo-username>` should not list `admin`. (This command lists group names for the named
  account.)

## 9. Run the isolation check inside the demo account

Log in as the demo user and run `bash check-isolation.sh <your-username>` (the script is in this folder;
see the README for how to get it there). Every line must say PASS. If any says FAIL, fix it here, on
your own account, and run it again. Do not record on a FAIL.

## 10. After the demo

- Revoke the demo API key.
- Delete the demo account **(admin)**: System Settings › Users & Groups › the "i" next to it › Delete User,
  and choose to delete the home folder. Or keep it, log out, and clear its files yourself.
- Remove anything you put in `/Users/Shared`.
- Review the recording before you share it for anything private that appeared on screen.
