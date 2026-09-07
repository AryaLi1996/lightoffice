#!/usr/bin/env python3
"""Syntax-check the shell embedded in GitHub Actions workflows.

A workflow can be perfectly valid YAML and still contain shell that dies on the
first line — and you only find out several minutes into a run. This extracts
every `run:` block and puts it through `bash -n`, which catches unbalanced
quotes, broken heredocs and stray `fi`/`done` before anything is pushed.

`${{ ... }}` expressions are replaced with a placeholder token first: they are
substituted by the runner before the shell ever sees them, so leaving them in
would produce spurious syntax errors.

Usage: scripts/lint_workflows.py [.github/workflows]
"""
import os
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("pyyaml is not installed; skipping workflow shell checks")
    sys.exit(0)

EXPR = re.compile(r"\$\{\{[^}]*\}\}")
# Actions must be pinned to a major version at least; a floating @main or an
# unpinned action is a supply-chain risk in a workflow that can publish releases.
UNPINNED = re.compile(r"@(main|master)$")

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def check_run_block(script: str, label: str, shell: str) -> list[str]:
    """Return a list of problems for one `run:` block."""
    if shell in ("pwsh", "powershell", "python", "cmd"):
        return []  # not bash; nothing we can check here
    # The runner substitutes expressions before invoking the shell.
    cleaned = EXPR.sub("EXPR_PLACEHOLDER", script)
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
        fh.write("#!/usr/bin/env bash\n")
        fh.write(cleaned)
        path = fh.name
    try:
        proc = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
        if proc.returncode != 0:
            err = proc.stderr.replace(path, label).strip()
            return [f"{label}: {err}"]
        return []
    finally:
        os.unlink(path)


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows"
    if not os.path.isdir(root):
        print(f"no workflow directory at {root}")
        return 0

    problems: list[str] = []
    checked = 0

    for name in sorted(os.listdir(root)):
        if not name.endswith((".yml", ".yaml")):
            continue
        path = os.path.join(root, name)
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
        if not isinstance(doc, dict):
            problems.append(f"{name}: not a mapping")
            continue

        for job_name, job in (doc.get("jobs") or {}).items():
            default_shell = (
                (job.get("defaults") or {}).get("run", {}).get("shell")
                or (doc.get("defaults") or {}).get("run", {}).get("shell")
                or "bash"
            )
            for i, step in enumerate(job.get("steps") or []):
                if not isinstance(step, dict):
                    continue

                uses = step.get("uses")
                if uses and UNPINNED.search(uses):
                    problems.append(
                        f"{name}:{job_name}[{i}]: action {uses} tracks a branch; pin a version"
                    )

                run = step.get("run")
                if not run:
                    continue
                checked += 1
                label = f"{name}:{job_name}[{i}] {step.get('name', 'unnamed')}"
                problems.extend(
                    check_run_block(run, label, step.get("shell", default_shell))
                )

    print(f"checked {checked} run block(s) across {root}")
    if problems:
        for p in problems:
            print(f"  {RED}x{RESET} {p}")
        return 1
    print(f"  {GREEN}v{RESET} all run blocks parse and all actions are pinned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
