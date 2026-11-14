---
name: summarize-folder
description: Make sense of a folder — what's in it and what matters.
when_to_use: The user asks what's in a directory, to summarize a pile of files, or to find the important ones.
---

# Summarize a folder

Goal: give the user a quick, honest map of a folder so they know what's there and
what to look at first.

## Steps
1. `list_dir` the target folder (default to the working folder if none given).
2. Group entries by type/purpose (code, docs, data, media, archives, junk).
3. For the handful of files that look most important (largest, a README, configs,
   recently relevant), `read_file` the first ~40 lines to learn what they are.
4. Use `search_files` if the user asked about a specific topic ("where is X?").

## Reporting
- Lead with a one-line verdict ("~40 files; mostly a Python project plus two PDFs").
- Then a short grouped list, each group a line or two.
- Call out anything notable: duplicates, very large files, obvious junk, secrets in
  plain sight (warn, do not print their values).
- Do not delete or move anything — this skill only reads. Suggest cleanups; let the
  user decide.
