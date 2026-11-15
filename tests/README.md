# Engine tests

Offline checks for the Python engine. No API key, no network, no live model: every provider is a
fake server and every home folder is a throwaway one.

Run them all from the repository root:

```bash
python3 tools/isolated_run.py -- python3 tests/selftest.py
```

`tools/isolated_run.py` gives the run an empty temporary home folder and strips API keys from the
environment, so nothing touches your own Benji folder or keys. The run ends with
`SELFTEST PASSED` or lists each failed check.

| File | What it checks |
|---|---|
| `selftest.py` | The runner, plus the core: tools, the approval gate, skills, memory, provider message formats, the `--serve` protocol |
| `check_any_model.py` | That every tool family works with any provider, not only Claude |
| `check_audit_log.py` | The audit log, log file permissions and `benji --diagnose` |
| `check_browser_acting.py` | Clicking, typing and uploading in the browser, and what each step is classed as |
| `check_drive_mode.py` | Drive mode: who may take over the screen, and how it stops |
| `check_durable_jobs.py` | A job's record kept out of its reach, and jobs that wait out a bad connection |
| `check_evals.py` | The eval harness in `evals/` |
| `check_home_folder.py` | Benji's folder, `~/.benji`, its override, and what the approval gate allows in it |
| `check_jobs.py` | Background jobs: long runs, repeating jobs, steering, stopping |
| `check_model_setup.py` | First-run model configuration |
| `check_policy.py` | The local policy file, the per-turn tool limit, start-up, provider errors in plain words, and keys kept in the Keychain |
| `check_providers.py` | The OpenAI-compatible providers and local models |
| `check_repository.py` | The repository itself: the README's pages, community files and CI |
| `check_shell_and_taint.py` | How shell commands are understood, and what reading outside content makes Benji ask about |

To add a check, put it in the file for its subject, next to the closest existing one, using the
fakes already there.

The maintainer's repository has a few more checks, for parts of the project that are not
published; `selftest.py` runs them only where they exist.
