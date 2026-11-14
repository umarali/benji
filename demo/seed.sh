#!/bin/bash
# Creates believable but entirely made-up working files for the demo, in ONE folder inside the demo
# account's own home: ~/BenjiDemo. Run it inside the demo account:
#
#     bash seed.sh
#
# Recording in your own account instead (same-account.md): `bash seed.sh --same-account` drops only
# the administrator check; every other guard below still applies.
#
# `bash seed.sh --in-benji-home` (D-175) puts the folder inside Benji's hidden home instead,
# ~/.benji/demo/BenjiDemo (or $BENJI_WORKDIR/demo/BenjiDemo), so nothing is left loose in the
# home folder. It is an option because the demo asks about "the BenjiDemo folder in my home folder"
# and a viewer should be able to see that folder; the default stays the visible ~/BenjiDemo.
# The two options can be combined.
#
# What it will not do:
#   - run as root, as an administrator, or anywhere but in the home folder the system itself lists
#     for the user running it (it compares $HOME with the account's real home, and stops if they
#     differ, so a changed HOME, someone else's folder or a symlinked path is refused);
#   - write anything outside ~/BenjiDemo (or, with --in-benji-home, ~/.benji/demo/BenjiDemo), read any existing file, delete or overwrite anything
#     (it stops if ~/BenjiDemo already exists: delete that folder yourself if you want a fresh one);
#   - contain a real name, address, number, key or document. Every person, business and figure is
#     invented; the only address is on example.com and the phone numbers are in the 555-01xx range
#     that is reserved for fiction.

set -u

SEED_NAME="BenjiDemo"

benji_folder_has_files() {
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        if [ -e "$entry" ] || [ -L "$entry" ]; then
            [ "${entry##*/}" = .DS_Store ] || return 0
        fi
    done
    return 1
}
# The older folder Benji will move into ~/.benji at its next start, if any: benji/home.py's _is_store, in shell.
benji_store_waiting() {
    if [ -d "$HOME/.chilly" ] && benji_folder_has_files "$HOME/.chilly"; then echo .chilly; return; fi
    for name in chilly pal; do
        [ -d "$HOME/$name" ] || continue
        for clone in .git __main__.py chilly/__main__.py benji/__main__.py pal/__main__.py; do
            [ ! -e "$HOME/$name/$clone" ] || continue 2
        done
        for sign in answers.jsonl policy.json events.jsonl engine.log memory.jsonl voice.log latency.jsonl usage.jsonl; do
            if [ -e "$HOME/$name/$sign" ]; then echo "$name"; return; fi
        done
    done
}
benji_home_is_empty() { ! benji_folder_has_files "$1"; }

die() { echo "seed.sh: $*" >&2; exit 1; }

# ---- files -----------------------------------------------------------------------------------------

# make_pdf <file> <title> <line>...: a one-page PDF with plain text, ASCII only, built by hand so it
# needs no tool beyond the shell. Offsets in the cross-reference table are computed, not guessed.
make_pdf() {
    out="$1"; shift
    title="$1"; shift
    text="BT /F1 18 Tf 72 740 Td ($title) Tj ET"
    y=700
    for line in "$@"; do
        text="$text BT /F1 11 Tf 72 $y Td ($line) Tj ET"
        y=$((y - 18))
    done
    o1="1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
"
    o2="2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
"
    o3="3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
endobj
"
    o4="4 0 obj
<< /Length ${#text} >>
stream
$text
endstream
endobj
"
    o5="5 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
"
    head="%PDF-1.4
"
    off1=${#head}
    off2=$((off1 + ${#o1}))
    off3=$((off2 + ${#o2}))
    off4=$((off3 + ${#o3}))
    off5=$((off4 + ${#o4}))
    xref=$((off5 + ${#o5}))
    {
        printf '%s' "$head" "$o1" "$o2" "$o3" "$o4" "$o5"
        printf 'xref\n0 6\n0000000000 65535 f \n'
        for off in $off1 $off2 $off3 $off4 $off5; do printf '%010d 00000 n \n' "$off"; done
        printf 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%s\n%%%%EOF\n' "$xref"
    } > "$out"
}

# write_files <dir>: the whole fictional content. <dir> must not exist yet.
write_files() {
    d="$1"
    mkdir "$d" "$d/bakery-site" "$d/receipts" "$d/notes" || return 1

    cat > "$d/README-first.txt" <<'TXT'
Pelican Row Bakery: working folder (all of this is made up)

Everything in here is invented for a demo: the bakery, the people, the amounts and the supplier.
Nothing is real, and nothing here is connected to any real business or person.

  budget.csv        monthly budget against what was actually spent
  sales-q3.csv      three months of daily sales by item
  notes/            meeting notes and a to-do list
  receipts/         three small PDFs (invoice, lease summary, price list)
  bakery-site/      a tiny website for the shop
TXT

    cat > "$d/budget.csv" <<'CSV'
month,category,planned,actual
2026-07,Flour and dry goods,1800,1925
2026-07,Dairy and eggs,950,880
2026-07,Packaging,300,342
2026-07,Staff,6200,6200
2026-07,Rent,2400,2400
2026-07,Utilities,420,465
2026-08,Flour and dry goods,1800,1760
2026-08,Dairy and eggs,950,1010
2026-08,Packaging,300,288
2026-08,Staff,6200,6410
2026-08,Rent,2400,2400
2026-08,Utilities,420,451
2026-09,Flour and dry goods,1900,2050
2026-09,Dairy and eggs,1000,985
2026-09,Packaging,320,330
2026-09,Staff,6200,6200
2026-09,Rent,2400,2400
2026-09,Utilities,430,418
CSV

    {
        echo "date,item,units_sold,unit_price,total"
        day=1
        while [ $day -le 14 ]; do
            dd=$(printf '%02d' "$day")
            sourdough=$((38 + (day * 7) % 11)); croissant=$((52 + (day * 5) % 17)); cinnamon=$((24 + (day * 3) % 9))
            echo "2026-09-$dd,Sourdough loaf,$sourdough,6.50,$((sourdough * 13 / 2)).$(( (sourdough * 13 % 2) * 5 ))0"
            echo "2026-09-$dd,Butter croissant,$croissant,3.20,$((croissant * 32 / 10)).$(( croissant * 32 % 10 ))0"
            echo "2026-09-$dd,Cinnamon roll,$cinnamon,3.80,$((cinnamon * 38 / 10)).$(( cinnamon * 38 % 10 ))0"
            day=$((day + 1))
        done
    } > "$d/sales-q3.csv"

    cat > "$d/notes/meeting-2026-09-18.txt" <<'TXT'
Pelican Row Bakery: Thursday planning (invented)

Present: Marta (owner), Idris (head baker), Joanne (front of house)

- Croissant demand is up on weekends; Idris wants a second proofing rack.
- Packaging cost crept up again; Joanne to ask Brightwell Packaging for a quote on 5,000 bags.
- Marta will decide on the Saturday market stall after the budget review on the 25th.
- Rent review letter arrived; lease summary is in receipts/.

Actions
  Idris   price two proofing racks, report next Thursday
  Joanne  packaging quote by Friday
  Marta   budget review, 25 September
TXT

    cat > "$d/notes/todo.txt" <<'TXT'
[ ] Reorder oat flour (low on the 20th)
[ ] Fix the typo in the menu: "croisant"
[x] Book the oven service
[ ] Reply to the market organiser (hello@example.com, 555-0142)
[ ] Look at the August staff overtime line in budget.csv
TXT

    cat > "$d/bakery-site/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Pelican Row Bakery</title>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <h1>Pelican Row Bakery</h1>
  <p>Bread, croissants and cinnamon rolls, baked every morning. (An invented shop for a demo.)</p>
  <ul id="menu"></ul>
  <script>
    // TODO: load menu.json and fill the list above
  </script>
</body>
</html>
HTML

    cat > "$d/bakery-site/styles.css" <<'CSS'
body { font-family: Georgia, serif; max-width: 34em; margin: 3em auto; color: #2b2118; background: #fbf6ee; }
h1 { font-size: 2em; border-bottom: 2px solid #c9a56a; }
#menu li { margin: .4em 0; }
CSS

    cat > "$d/bakery-site/menu.json" <<'JSON'
[
  {"name": "Sourdough loaf", "price": 6.50},
  {"name": "Butter croissant", "price": 3.20},
  {"name": "Cinnamon roll", "price": 3.80},
  {"name": "Oat cookie", "price": 2.10}
]
JSON

    cat > "$d/bakery-site/README.md" <<'MD'
# Pelican Row Bakery site

A tiny made-up site. `index.html` should show the items in `menu.json`; the script in it is not
written yet.
MD

    make_pdf "$d/receipts/invoice-1042.pdf" "Invoice 1042 - Brightwell Packaging (invented)" \
        "Bill to: Pelican Row Bakery" \
        "Paper bags, 2,000 x 0.11 = 220.00" \
        "Kraft boxes, 300 x 0.64 = 192.00" \
        "Delivery: 18.00" \
        "Total due: 430.00" \
        "Pay within 30 days. Questions: 555-0107."
    make_pdf "$d/receipts/lease-summary.pdf" "Lease summary - 14 Pelican Row (invented)" \
        "Monthly rent: 2,400.00" \
        "Term: 5 years from 1 March 2024" \
        "Review: rent may rise by up to 4 percent each March" \
        "Notice to leave: 6 months in writing"
    make_pdf "$d/receipts/price-list-oct.pdf" "Millhouse Flour price list (invented)" \
        "Strong white, 16 kg: 21.40" \
        "Wholemeal, 16 kg: 23.10" \
        "Rye, 16 kg: 25.60" \
        "Oat flour, 10 kg: 19.90" \
        "Prices valid until 31 October."

    printf 'Made-up demo data from demo/seed.sh. Safe to delete this whole folder.\n' > "$d/.benji-demo-seed"
}

# ---- guards ----------------------------------------------------------------------------------------

check_account() {
    me="$(id -un)"
    case "$me" in
        ""|*[!A-Za-z0-9._-]*) die "cannot work out which account this is" ;;
    esac
    [ "$(id -u)" != 0 ] || die "refusing to run as root. Run it as the demo account."
    real_home="$(eval "printf '%s' ~$me")"
    [ -n "$real_home" ] && [ "$real_home" != "~$me" ] || die "cannot find this account's home folder"
    [ -n "${HOME:-}" ] || die "HOME is not set"
    [ "$HOME" = "$real_home" ] || die "HOME is not this account's own home folder: refusing to write anywhere else."
    case "$HOME" in
        /|/var/root|/private/var/root|/Users|/Users/Shared|/tmp|/private/tmp) die "that is not a personal home folder: refusing." ;;
    esac
    [ -d "$HOME" ] || die "the home folder does not exist"
    [ ! -L "$HOME" ] || die "the home folder is a symbolic link: refusing."
    [ -w "$HOME" ] || die "cannot write to your own home folder"
    [ "$same_account" = 1 ] && return 0
    case " $(id -Gn) " in
        *" admin "*) die "this account is an administrator. The demo account must be a standard user: refusing (recording in your own account? see same-account.md)." ;;
    esac
}

main() {
    same_account=0
    in_home=0
    for arg in "$@"; do
        case "$arg" in
            --same-account) same_account=1 ;;
            --in-benji-home) in_home=1 ;;
            *) die "unknown option: $arg (the options are --same-account and --in-benji-home)" ;;
        esac
    done
    check_account
    target="$HOME/$SEED_NAME"
    if [ "$in_home" = 1 ]; then
        benji_home="${BENJI_WORKDIR:-${CHILLY_WORKDIR:-${PAL_WORKDIR:-$HOME/.benji}}}"
        # Never make ~/.benji before Benji has moved an older folder into it: a new ~/.benji with
        # something in it would leave that folder stranded (start Benji once first).
        if [ "$benji_home" = "$HOME/.benji" ] && benji_home_is_empty "$benji_home"; then
            waiting="$(benji_store_waiting)"
            [ -z "$waiting" ] || die "$HOME/$waiting is still Benji's folder: start Benji once so it moves into $benji_home, then run this again."
        fi
        target="$benji_home/demo/$SEED_NAME"
    fi
    [ ! -e "$target" ] && [ ! -L "$target" ] || die "$target already exists. Delete it yourself first if you want a fresh copy; this script never deletes or overwrites."
    umask 077
    if [ "$in_home" = 1 ]; then
        mkdir -p "${target%/*}" || die "could not create ${target%/*}"
    fi
    write_files "$target" || die "could not create the files (nothing outside $target was touched)"
    echo "Created $target with made-up files:"
    echo "  README-first.txt, budget.csv, sales-q3.csv, notes/, receipts/ (3 PDFs), bakery-site/"
    echo "Everything in it is invented."
}

# Run main only when executed, not when a test sources the file to call write_files on a scratch folder.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
