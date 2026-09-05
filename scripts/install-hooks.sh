#!/bin/bash
# asd-governance/process/PROC-007 — repository guard hooks.
#
# Installed at clone time, verified by /ship before it will run. Two guards:
#
#   pre-commit  gitleaks, so a secret is caught while the fix is still free.
#               A blocked commit costs seconds; a pushed secret costs a
#               history rewrite plus credential rotation.
#   pre-push    blocks force-pushes to and deletion of main. Since the 2026
#               migration, GitHub is the only durable copy of app source, and
#               the accident class that threatens it is a history rewrite from
#               this machine. Platform rulesets would need a paid plan; the CEO
#               reviewed and declined that on 2026-07-28, so this hook is the
#               adopted $0 control, not a stopgap.
#   pre-push    (Phase 7 Part C) also runs scripts/fleet-check.py, from the
#               asd-governance checkout, against the exact commit tree being
#               pushed and refuses on a FAIL from the Consistency Contract's
#               static leg (version resolved from asd-app.json's
#               versionDisplay -- object form selects the releaseFamily
#               entry) or the retired-vocabulary denylist. Generalized from
#               Stage 4C's package.json-only check (PROC-001 §5.5), which
#               the three Electron repositories keep as their own special
#               case.
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$(git rev-parse --git-common-dir)/hooks"  # worktree-compatible (Desktop Code)
mkdir -p "$HOOKS"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks is not installed. Install it, then re-run this script:"
  echo "    brew install gitleaks"
  echo
  echo "Hooks NOT installed. /ship will refuse to run until they are."
  exit 1
fi

cat > "$HOOKS/pre-commit" <<'PRECOMMIT'
#!/bin/bash
# asd-governance/process/PROC-007 — secret scan on staged changes. Fails closed.
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "BLOCKED: gitleaks missing. Run scripts/install-hooks.sh." >&2
  exit 1
fi
gitleaks protect --staged --redact --no-banner || {
  echo >&2
  echo "BLOCKED: gitleaks found a potential secret in the staged changes." >&2
  echo "Remove it and re-stage. Do not use --no-verify." >&2
  exit 1
}
PRECOMMIT

cat > "$HOOKS/pre-push" <<'PREPUSH'
#!/bin/bash
# asd-governance/process/PROC-007 — protect main's history from this machine.
# Blocks force-push to and deletion of main. Normal pushes pass untouched.
#
# Phase 7 Part C (generalized from Stage 4C's package.json-only check):
# also runs scripts/fleet-check.py, from the asd-governance checkout at
# $HOME/Development_Local/asd-governance, against the exact commit tree
# being pushed -- extracted with `git archive`, never the working
# directory, so a dirty checkout is judged the same as a clean one -- and
# refuses the push on a FAIL from either the Consistency Contract's static
# leg (the version fleet-check.py resolves from asd-app.json's
# versionDisplay: object form selects the releaseFamily entry, so a
# multi-family repository is checked on its one released family only; a
# repository with no versionDisplay, e.g. a sandbox, passes this leg by
# the same r7 carve-out fleet-check.py itself applies) or the
# retired-vocabulary denylist. Every other fleet-check.py result
# (manifest-schema, required-files, repo-id) is printed for visibility but
# not gated on here -- that is CI's job where a caller exists (R-E/R-F),
# and the Mac generator run's job where one cannot (R-D, R-G, the three
# public sandbox repositories).
ZERO="0000000000000000000000000000000000000000"
ASD_GOVERNANCE_DIR="$HOME/Development_Local/asd-governance"
FLEET_CHECK="$ASD_GOVERNANCE_DIR/scripts/fleet-check.py"
TMPDIR_PUSH=""
cleanup_tmpdir_push() { [ -n "$TMPDIR_PUSH" ] && rm -rf "$TMPDIR_PUSH"; }
trap cleanup_tmpdir_push EXIT

while read -r local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in refs/heads/main|refs/heads/master) ;; *) continue ;; esac

  if [ "$local_sha" = "$ZERO" ]; then
    echo "BLOCKED: refusing to delete $remote_ref." >&2
    exit 1
  fi
  if [ "$remote_sha" != "$ZERO" ] && ! git merge-base --is-ancestor "$remote_sha" "$local_sha"; then
    echo "BLOCKED: this push would rewrite history on $remote_ref." >&2
    echo "GitHub is the only durable copy of this source. Rebase onto origin instead." >&2
    exit 1
  fi

  if [ ! -f "$FLEET_CHECK" ]; then
    echo "BLOCKED: fleet-check.py not found at $FLEET_CHECK." >&2
    echo "Clone asd-governance as a sibling of this repository (PROC-007)." >&2
    exit 1
  fi

  TMPDIR_PUSH="$(mktemp -d)"
  git archive "$local_sha" | tar -x -C "$TMPDIR_PUSH"

  FLEET_JSON="$(python3 "$FLEET_CHECK" --root "$TMPDIR_PUSH" --governance-dir "$ASD_GOVERNANCE_DIR" --json)"
  GATE_OUTPUT="$(printf '%s' "$FLEET_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
gated = ("consistency-contract-static", "denylist")
failed = False
for r in data["results"]:
    if r["name"] in gated:
        print("%-4s %s" % (r["status"], r["name"]))
        for line in r["detail"].splitlines():
            print("     %s" % line)
        if r["status"] == "FAIL":
            failed = True
sys.exit(1 if failed else 0)
')"
  GATE_STATUS=$?
  echo "$GATE_OUTPUT"
  rm -rf "$TMPDIR_PUSH"
  TMPDIR_PUSH=""

  if [ "$GATE_STATUS" -ne 0 ]; then
    echo "BLOCKED: fleet-check.py failed the Consistency Contract and/or denylist check against the pushed tree (above)." >&2
    echo "Fix the cause and re-push; do not bypass with --no-verify." >&2
    exit 1
  fi
done
exit 0
PREPUSH

chmod +x "$HOOKS/pre-commit" "$HOOKS/pre-push"
echo "Hooks installed: pre-commit (gitleaks), pre-push (main history guard + fleet-check.py Consistency Contract/denylist check against the pushed tree)."
