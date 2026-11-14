#!/usr/bin/env python3
"""Benji's eval harness (D-155). See evals/README.md.

    python3 -I tools/eval.py list
    python3 -I tools/eval.py check                    # offline: recorded replies through the code checks
    python3 -I tools/eval.py record --plan            # what a new run would ask; no call
    python3 -I tools/eval.py record --live --model claude-haiku-5-5 --effort low   # the user's call
    python3 -I tools/eval.py compare evals/fixtures evals/runs/<run>
    python3 -I tools/eval.py judge --plan             # the split rubric; --live calls the judge
    python3 -I tools/eval.py label                    # your own answers, to measure the judge
    python3 -I tools/eval.py agree evals/runs/judge-<stamp>.json
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from evals.harness import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
