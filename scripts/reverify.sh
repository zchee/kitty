#!/bin/bash
# Re-verify a commit against the golden matrix from a clean, throwaway
# worktree. Generalized in W3h from the W3f review's wave-specific original
# (archived at .omc/verify/w3f-verify-assets/reverify.sh) per ADR-0032 §4/§8:
#   - repo root derived, never hardcoded
#   - config list read from CONFIG_MATRIX by AST, never a hand copy
#   - outputs to a fresh mktemp dir; NEVER deletes prior evidence (F9)
#   - the worktree is removed on exit (F9's leftover)
#   - a terminal PASS/FAIL verdict line (the original could fail pass-shaped)
# Usage: reverify.sh <sha> [baseline-dir]
#   baseline-dir defaults to the newest .omc/verify/*/baseline-final.
# Gate cost: ~45 s measured (W3g VP-F4).
set -u
SHA="${1:?usage: reverify.sh <sha> [baseline-dir]}"
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1
BASE="${2:-$(ls -td "$ROOT"/.omc/verify/*/baseline-final 2>/dev/null | head -1)}"
[ -d "$BASE" ] || { echo "VERDICT: FAIL (no baseline dir: $BASE)"; exit 1; }
OUT="$(mktemp -d "${TMPDIR:-/tmp}/reverify-XXXXXX")"
WT="$OUT/wt"
FAILED=0
fail() { echo "  FAIL: $*"; FAILED=1; }
cleanup() { git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1; }
trap cleanup EXIT

echo "== output dir (kept): $OUT"
echo "== baseline: $BASE"
git -C "$ROOT" worktree add --detach "$WT" "$SHA" >/dev/null 2>&1 || { echo "VERDICT: FAIL (worktree)"; exit 1; }
echo "== worktree at $(git -C "$WT" rev-parse HEAD)"

export PATH="$HOME/sdk/go1.26.6/bin:/opt/local/slang/bin:$PATH"
export PKG_CONFIG_PATH="$(printf %s: /opt/homebrew/opt/*/lib/pkgconfig)${PKG_CONFIG_PATH:-}"
( cd "$WT" && python3.14 setup.py build > "$OUT/build.log" 2>&1 )
BUILD_EXIT=$?
WARNINGS=$(grep -ciE 'warning' "$OUT/build.log")
echo "== BUILD EXIT=$BUILD_EXIT warnings=$WARNINGS"
echo "== $(grep -E 'Linking Metal shader library' "$OUT/build.log" | tail -1)"
[ "$BUILD_EXIT" = 0 ] || fail "build exit $BUILD_EXIT"
[ "$WARNINGS" = 0 ] || fail "$WARNINGS build warnings"
DIRTY=$(git -C "$WT" status --short | grep -v 'kitty/glsl-uniforms.h')
[ -z "$DIRTY" ] || fail "worktree dirty beyond glsl-uniforms.h: $DIRTY"

echo "== goldens vs baseline (threshold 0)"
( cd "$WT" && ./scripts/metal-golden.py capture --output-dir "$OUT/goldens" >/dev/null 2>&1 )
( cd "$WT" && ./scripts/metal-golden.py compare "$BASE" "$OUT/goldens" --threshold 0 > "$OUT/compare.json" 2>/dev/null )
python3.14 - "$OUT/compare.json" <<'PY' || FAILED=1
import json, re, sys
raw = open(sys.argv[1]).read()
d = json.loads(re.search(r'\{.*\}', raw, re.S).group(0))["results"]
bad = {k: v.get("max_diff", v.get("error", "?")) for k, v in sorted(d.items())
       if v.get("max_diff", 1) != 0}
n = len(d)
if bad:
    print(f"  FAIL: {len(bad)}/{n} configs nonzero/error: {bad}")
    raise SystemExit(1)
print(f"  {n}/{n} configs at max_diff=0")
PY
echo "== matrix size from source: $(cd "$WT" && python3.14 -c '
import ast
src = open("scripts/metal-golden.py").read()
for n in ast.parse(src).body:
    if isinstance(n, ast.AnnAssign) and getattr(n.target, "id", "") == "CONFIG_MATRIX":
        print(len(n.value.keys))')"

echo "== starvation probe (nudge disabled -> expect NO thumbnail + the F5 string)"
python3.14 - "$WT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "scripts/_golden_content_helper.py"
t = p.read_text()
cand = '    if os.environ.get("KITTY_METAL_TEST_THUMBNAIL"):'
if t.count(cand) == 1:
    p.write_text(t.replace(cand, "    if False:  # REVERIFY: nudge disabled")); print("  nudge disabled")
else:
    print("  COULD NOT DISABLE NUDGE -- helper shape changed, inspect by hand")
PY
STARVE=$( (cd "$WT" && ./scripts/metal-golden.py capture --output-dir "$OUT/starve" --configs screenshot-thumb 2>&1) | grep -c 'no thumbnail produced' )
git -C "$WT" checkout -- scripts/_golden_content_helper.py
if [ "$STARVE" -ge 1 ]; then echo "  starved as expected, F5 string fired"; else fail "starvation probe did not starve (lever self-serving?)"; fi

if [ "$FAILED" = 0 ]; then echo "VERDICT: PASS ($SHA)"; else echo "VERDICT: FAIL ($SHA) -- see $OUT"; exit 1; fi
