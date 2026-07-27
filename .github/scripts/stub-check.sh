#!/usr/bin/env bash
# stub-check: fail CI if source files contain stub markers (in comments) or
# runtime not-implemented signals (in code). A dependency-free mirror of the
# autonoma stub-lint rules 1A/2A, scoped to this plugin's language.
set -euo pipefail

# High-confidence "this code isn't real" signals. Deliberately NOT bare
# TODO/FIXME (too noisy) — only phrases that state the path is unfinished.
PATTERN='stub implementation|stub method|placeholder data|will be (fully )?implemented later|for (proof of concept|demonstration)|FIXME:? *real|raise +NotImplementedError|this would +(use|query|call|fetch|compute|analyze|apply|invoke|perform|retrieve|integrate|connect|trigger|generate|scan|evaluate)|error[ (]+["'"'"'][^"'"'"']*not[ _-]?implemented'

FILES=$(git ls-files '*.el' '*.py' '*.lua' 2>/dev/null | grep -vE '/(\.cask|elpa|__pycache__|tests?|spec)/|_test\.|_spec\.' || true)
[ -z "$FILES" ] && { echo "stub-check: no source files"; exit 0; }

if echo "$FILES" | xargs grep -EniH "$PATTERN" 2>/dev/null; then
  echo ""
  echo "::error::stub-check: stub markers / not-implemented signals found above — implement or remove before merge."
  exit 1
fi
echo "stub-check: clean ($(echo "$FILES" | wc -l | tr -d ' ') files)"
