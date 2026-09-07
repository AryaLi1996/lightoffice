#!/usr/bin/env bash
#
# Static checks for everything in this repository.
#
# Runs the same way locally and in CI, so a green local run means a green CI
# lint job. Every check is skipped-with-a-note rather than failed when its tool
# is missing, so a contributor without shellcheck still gets useful output.
#
# Usage: scripts/lint.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fails=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fails=$((fails+1)); }
skip() { printf '  \033[33m·\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

hdr "shell"
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null && ok "bash -n $f" || bad "bash -n $f"
done < <(find scripts -name '*.sh' | sort)

if command -v shellcheck >/dev/null; then
  while IFS= read -r f; do
    # SC1091: we do not follow sourced files that only exist after a build.
    if out=$(shellcheck -S warning -e SC1091 "$f" 2>&1); then
      ok "shellcheck $f"
    else
      bad "shellcheck $f"
      printf '%s\n' "$out" | sed 's/^/      /' | head -20
    fi
  done < <(find scripts -name '*.sh' | sort)
else
  skip "shellcheck not installed"
fi

hdr "javascript"
while IFS= read -r f; do
  node --check "$f" 2>/dev/null && ok "node --check $f" || bad "node --check $f"
done < <(find tests -name '*.js' | sort)

hdr "python"
while IFS= read -r f; do
  python3 -m py_compile "$f" 2>/dev/null && ok "py_compile $f" || bad "py_compile $f"
done < <(find scripts -name '*.py' | sort)

hdr "json"
while IFS= read -r f; do
  jq -e . "$f" >/dev/null 2>&1 && ok "jq $f" || bad "jq $f"
done < <(find . -name '*.json' -not -path './node_modules/*' -not -path './.git/*' | sort)

hdr "svg"
while IFS= read -r f; do
  python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$f" 2>/dev/null \
    && ok "xml $f" || bad "xml $f"
done < <(find overlay -name '*.svg' | sort)

hdr "docker compose"
if docker compose version >/dev/null 2>&1; then
  if out=$(docker compose -f deploy/docker-compose.nextcloud.yml config 2>&1 >/dev/null); then
    ok "compose config"
  else
    bad "compose config"; printf '%s\n' "$out" | sed 's/^/      /' | head -10
  fi
elif python3 -c "import yaml" 2>/dev/null; then
  python3 -c "import yaml,sys; yaml.safe_load(open('deploy/docker-compose.nextcloud.yml'))" \
    && ok "compose YAML parses (docker unavailable, schema unchecked)" || bad "compose YAML"
else
  skip "neither docker compose nor pyyaml available"
fi

hdr "workflows"
if python3 -c "import yaml" 2>/dev/null; then
  while IFS= read -r f; do
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null \
      && ok "yaml $f" || bad "yaml $f"
  done < <(find .github/workflows -name '*.yml' 2>/dev/null | sort)

  # A workflow can be valid YAML and still hold shell that dies on line one.
  if out=$(python3 scripts/lint_workflows.py 2>&1); then
    ok "$(printf '%s' "$out" | head -1)"
  else
    bad "workflow shell check"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
else
  skip "pyyaml not installed"
fi

hdr "cloudformation"
if [ -d deploy/aws ]; then
  if command -v cfn-lint >/dev/null; then
    while IFS= read -r f; do
      if out=$(cfn-lint "$f" 2>&1); then
        ok "cfn-lint $f"
      else
        bad "cfn-lint $f"
        printf '%s\n' "$out" | sed 's/^/      /' | head -20
      fi
    done < <(find deploy/aws -name '*.yaml' -o -name '*.yml' | sort)
  else
    skip "cfn-lint not installed (pip install cfn-lint)"
  fi
fi

hdr "executable bits"
while IFS= read -r f; do
  [ -x "$f" ] && ok "+x $f" || bad "$f is not executable"
done < <(find scripts -name '*.sh' | sort)

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '\033[32mlint: all checks passed\033[0m\n'
else
  printf '\033[31mlint: %d check(s) failed\033[0m\n' "$fails"
fi
exit $(( fails > 0 ))
