#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="diff"
LINT_ONLY=false

usage() {
  cat <<'EOF'
Usage: scripts/check.sh [--diff | --staged | --all] [--lint-only]

  --diff       Check changed files + run build and tests (default)
  --staged     Fast pre-commit check on staged files only (skips build/tests)
  --all        Check all production files + run build and tests
  --lint-only  Skip Swift build/tests and Node alignment tests
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff) MODE="diff"; shift ;;
    --staged) MODE="staged"; LINT_ONLY=true; shift ;;
    --all) MODE="all"; shift ;;
    --lint-only) LINT_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

IS_CI=false
if [[ "${CI:-}" == "true" || "${CI:-}" == "1" ]]; then
  IS_CI=true
fi

OS="$(uname -s)"

collect_changed_files() {
  local ext="$1"
  if [[ "$MODE" == "staged" ]]; then
    git diff --cached --name-only --diff-filter=ACMR | grep -E "^Sources/.*\\.${ext}$" || true
    return
  fi

  {
    git diff --name-only --diff-filter=ACMR || true
    git diff --cached --name-only --diff-filter=ACMR || true
    git ls-files --others --exclude-standard || true
    local base=""
    for ref in origin/main main; do
      if base="$(git merge-base HEAD "$ref" 2>/dev/null)"; then
        git diff --name-only --diff-filter=ACMR "${base}...HEAD" || true
        break
      fi
    done
  } | sort -u | grep -E "^Sources/.*\\.${ext}$" | while IFS= read -r f; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done || true
}

echo "==> [check] slop-check.py (--${MODE})"
python3 scripts/slop-check.py "--${MODE}"

if [[ "$LINT_ONLY" == "false" ]]; then
  if [[ "$OS" == "Darwin" ]]; then
    echo "==> [check] swift build"
    swift build
    echo "==> [check] swift run MarginsSelfTest"
    swift run MarginsSelfTest
  else
    echo "==> [check] skipping Swift build/tests on ${OS} (macOS required)"
  fi

  if command -v node >/dev/null 2>&1; then
    echo "==> [check] node scripts/test-annotation-alignment.js"
    node scripts/test-annotation-alignment.js
    echo "==> [check] node scripts/test-formatting.js"
    node scripts/test-formatting.js
    echo "==> [check] node scripts/test-zen.js"
    node scripts/test-zen.js
  elif [[ "$IS_CI" == "true" ]]; then
    echo "error: node is required in CI" >&2
    exit 1
  else
    echo "==> [check] skipping JS alignment tests (node not installed)"
  fi
fi

# SwiftLint (optional locally, required on macOS in CI)
if command -v swiftlint >/dev/null 2>&1; then
  if [[ "$MODE" == "all" ]]; then
    echo "==> [check] swiftlint (all Sources)"
    swiftlint lint --config .swiftlint.yml --quiet
  else
    SWIFT_FILES=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && SWIFT_FILES+=("$f")
    done < <(collect_changed_files swift)
    if [[ ${#SWIFT_FILES[@]} -gt 0 ]]; then
      echo "==> [check] swiftlint (${#SWIFT_FILES[@]} Swift file(s))"
      swiftlint lint --config .swiftlint.yml --quiet -- "${SWIFT_FILES[@]}"
    fi
  fi
elif [[ "$IS_CI" == "true" && "$OS" == "Darwin" ]]; then
  echo "error: swiftlint is required when CI=true on macOS" >&2
  exit 1
else
  echo "==> [check] skipping swiftlint (not installed)"
fi

# ESLint (optional locally if not installed, required in CI via eslint or pinned npx eslint@9)
ESLINT_CMD=()
if command -v eslint >/dev/null 2>&1; then
  ESLINT_CMD=(eslint)
elif [[ "$IS_CI" == "true" ]]; then
  if command -v npx >/dev/null 2>&1; then
    ESLINT_CMD=(npx --yes eslint@9)
  else
    echo "error: eslint (or npx) is required when CI=true" >&2
    exit 1
  fi
fi

if [[ ${#ESLINT_CMD[@]} -gt 0 ]]; then
  JS_FILES=()
  if [[ "$MODE" == "all" ]]; then
    for f in Sources/Margins/Resources/Editor/*.js; do
      [[ -f "$f" ]] && JS_FILES+=("$f")
    done
  else
    while IFS= read -r f; do
      [[ -n "$f" ]] && [[ "$f" == Sources/Margins/Resources/Editor/* ]] && JS_FILES+=("$f")
    done < <(collect_changed_files js)
  fi
  if [[ ${#JS_FILES[@]} -gt 0 ]]; then
    echo "==> [check] eslint (${#JS_FILES[@]} JS file(s))"
    "${ESLINT_CMD[@]}" --config eslint.config.mjs "${JS_FILES[@]}"
  fi
else
  echo "==> [check] skipping eslint (not installed)"
fi

echo "==> [check] all checks passed"
