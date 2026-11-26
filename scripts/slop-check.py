#!/usr/bin/env python3
"""Zero-dependency structural and hygiene guardrail check for Margins.

Usage:
  scripts/slop-check.py [--diff | --staged | --all | FILE ...]

Exits non-zero with `file:line: [rule] message` diagnostics on violations.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

MAX_FILE_LINES = 500
MAX_FUNCTION_LINES = 80

# Existing files/functions grandfathered at their current size so they cannot grow further.
LEGACY_FILE_LINE_LIMITS = {
    "Sources/Margins/AppState+Agent.swift": 562,
    "Sources/Margins/Resources/Editor/annotations.js": 614,
    "Sources/Margins/Resources/Editor/editor.js": 1547,
}

LEGACY_FUNCTION_LINE_LIMITS = {
    ("Sources/Margins/AppState+Agent.swift", "discuss"): 84,
    ("Sources/Margins/AppState+Files.swift", "handle"): 88,
    ("Sources/MarginsCore/PromptBuilder.swift", "system"): 96,
}

SWIFT_FUNC_RE = re.compile(
    r"^[ \t]*(?:(?:public|private|internal|fileprivate|open|static|class|override|"
    r"mutating|nonmutating|final|@MainActor|@discardableResult|nonisolated)\s+)*"
    r"func\s+([A-Za-z0-9_]+)[^{;\n]*\{",
    re.MULTILINE,
)

JS_FUNC_RE = re.compile(
    r"(?:^[ \t]*(?:async\s+)?function\s+([A-Za-z0-9_$]+)\s*\([^)]*\)\s*\{|"
    r"^[ \t]*(?:const|let|var)\s+([A-Za-z0-9_$]+)\s*=\s*(?:async\s*)?"
    r"(?:\([^)]*\)|[A-Za-z0-9_$]+)\s*=>\s*\{)",
    re.MULTILINE,
)

JS_EMPTY_CATCH_RE = re.compile(r"\bcatch\s*(?:\([^)]*\))?\s*\{\s*\}")
JS_DEBUG_RE = re.compile(r"\b(?:console\.log\s*\(|debugger\b)")
SWIFT_DEBUG_RE = re.compile(r"(?<![.\w])(?:print|debugPrint)\s*\(")


def run_git(args: list[str]) -> list[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def is_checked_path(rel_path: str) -> bool:
    if rel_path.startswith("Sources/") and rel_path.endswith(".swift"):
        return True
    if rel_path.startswith("Sources/Margins/Resources/Editor/") and rel_path.endswith(".js"):
        return True
    return False


def collect_diff_files() -> list[str]:
    files: set[str] = set()
    # Unstaged, staged, and untracked changes in the working tree.
    files.update(run_git(["diff", "--name-only", "--diff-filter=ACMR"]))
    files.update(run_git(["diff", "--cached", "--name-only", "--diff-filter=ACMR"]))
    files.update(run_git(["ls-files", "--others", "--exclude-standard"]))

    # Also include commits on the current branch since diverging from main, if available.
    for base_ref in ("origin/main", "main"):
        merge_base = run_git(["merge-base", "HEAD", base_ref])
        if merge_base:
            files.update(run_git(["diff", "--name-only", "--diff-filter=ACMR", f"{merge_base[0]}...HEAD"]))
            break

    return sorted(p for p in files if is_checked_path(p) and (REPO_ROOT / p).is_file())


def collect_staged_files() -> list[str]:
    files = run_git(["diff", "--cached", "--name-only", "--diff-filter=ACMR"])
    return sorted(p for p in files if is_checked_path(p) and (REPO_ROOT / p).is_file())


def collect_all_files() -> list[str]:
    swift_files = [
        p.relative_to(REPO_ROOT).as_posix()
        for p in sorted((REPO_ROOT / "Sources").rglob("*.swift"))
    ]
    js_files = [
        p.relative_to(REPO_ROOT).as_posix()
        for p in sorted((REPO_ROOT / "Sources/Margins/Resources/Editor").glob("*.js"))
    ]
    return sorted(swift_files + js_files)


def strip_comments_and_strings(text: str, *, is_swift: bool) -> str:
    """Replace comment and string interiors with spaces while preserving newlines."""
    out: list[str] = []
    i = 0
    n = len(text)
    in_line_comment = False
    block_comment_depth = 0
    in_str: str | None = None
    in_triple = False

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if in_line_comment:
            if c == "\n":
                in_line_comment = False
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue

        if block_comment_depth > 0:
            if is_swift and c == "/" and nxt == "*":
                block_comment_depth += 1
                out.extend((" ", " "))
                i += 2
            elif c == "*" and nxt == "/":
                block_comment_depth -= 1
                out.extend((" ", " "))
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
            continue

        if in_triple:
            if text[i : i + 3] == '"""':
                in_triple = False
                out.extend(('"', '"', '"'))
                i += 3
            elif c == "\\" and i + 1 < n:
                out.extend((" ", "\n" if nxt == "\n" else " "))
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
            continue

        if in_str is not None:
            if c == "\\" and i + 1 < n:
                out.extend((" ", "\n" if nxt == "\n" else " "))
                i += 2
            elif c == in_str:
                in_str = None
                out.append(c)
                i += 1
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
            continue

        if c == "/" and nxt == "/":
            in_line_comment = True
            out.extend((" ", " "))
            i += 2
        elif c == "/" and nxt == "*":
            block_comment_depth = 1
            out.extend((" ", " "))
            i += 2
        elif is_swift and text[i : i + 3] == '"""':
            in_triple = True
            out.extend(('"', '"', '"'))
            i += 3
        elif (is_swift and c == '"') or (not is_swift and c in ('"', "'", "`")):
            in_str = c
            out.append(c)
            i += 1
        else:
            out.append(c)
            i += 1

    return "".join(out)


def find_matching_brace(masked: str, open_idx: int) -> int:
    depth = 0
    for i in range(open_idx, len(masked)):
        ch = masked[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def check_file(rel_path: str) -> list[str]:
    path = REPO_ROOT / rel_path
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    is_swift = rel_path.endswith(".swift")
    masked = strip_comments_and_strings(text, is_swift=is_swift)
    violations: list[str] = []

    file_limit = LEGACY_FILE_LINE_LIMITS.get(rel_path, MAX_FILE_LINES)
    if len(lines) > file_limit:
        violations.append(
            f"{rel_path}:{file_limit + 1}: [file-length] {len(lines)} lines exceeds limit of {file_limit}"
        )

    func_re = SWIFT_FUNC_RE if is_swift else JS_FUNC_RE
    for match in func_re.finditer(masked):
        name = match.group(1) if is_swift else (match.group(1) or match.group(2))
        open_brace = match.end() - 1
        close_brace = find_matching_brace(masked, open_brace)
        if close_brace == -1:
            continue
        start_line = masked.count("\n", 0, match.start()) + 1
        end_line = masked.count("\n", 0, close_brace) + 1
        length = end_line - start_line + 1
        limit = LEGACY_FUNCTION_LINE_LIMITS.get((rel_path, name), MAX_FUNCTION_LINES)
        if length > limit:
            violations.append(
                f"{rel_path}:{start_line}: [function-length] `{name}` is {length} lines (limit {limit})"
            )

    if not is_swift:
        for match in JS_EMPTY_CATCH_RE.finditer(masked):
            line = masked.count("\n", 0, match.start()) + 1
            violations.append(
                f"{rel_path}:{line}: [no-empty-catch] empty catch block swallows errors silently"
            )
        for idx, line in enumerate(masked.splitlines(), 1):
            if JS_DEBUG_RE.search(line):
                violations.append(
                    f"{rel_path}:{idx}: [no-debug-log] remove console.log/debugger from editor script"
                )
    elif not rel_path.startswith("Sources/MarginsCLI/"):
        for idx, line in enumerate(masked.splitlines(), 1):
            if SWIFT_DEBUG_RE.search(line):
                violations.append(
                    f"{rel_path}:{idx}: [no-debug-log] remove print/debugPrint from app/core Swift code"
                )

    return violations


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Margins structural/hygiene slop checks.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--diff", action="store_true", help="Check changed files (default)")
    group.add_argument("--staged", action="store_true", help="Check staged files only")
    group.add_argument("--all", action="store_true", help="Check all production Swift and editor JS files")
    parser.add_argument("files", nargs="*", help="Explicit repo-relative or absolute file paths to check")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.files:
        targets = []
        for raw in args.files:
            p = pathlib.Path(raw)
            rel = p.resolve().relative_to(REPO_ROOT).as_posix() if p.is_absolute() else p.as_posix()
            if is_checked_path(rel) and (REPO_ROOT / rel).is_file():
                targets.append(rel)
    elif args.all:
        targets = collect_all_files()
    elif args.staged:
        targets = collect_staged_files()
    else:
        targets = collect_diff_files()

    if not targets:
        print("slop-check: no matching production files to check")
        return 0

    all_violations: list[str] = []
    for rel_path in targets:
        all_violations.extend(check_file(rel_path))

    if all_violations:
        for item in all_violations:
            print(item, file=sys.stderr)
        print(f"slop-check: {len(all_violations)} violation(s) in {len(targets)} file(s)", file=sys.stderr)
        return 1

    print(f"slop-check: ok ({len(targets)} file(s) checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
