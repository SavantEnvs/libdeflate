#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS libdeflate's own CTest suite (built by mayhem/build.sh) plus known-answer
# gzip interop checks against the system gzip. The interop checks assert actual output bytes, so a
# neutered/no-op libdeflate-gzip fails them (the CTest binaries alone could not show that).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/build-tests"
GZ="$B/programs/libdeflate-gzip"
for f in "$GZ" "$B/programs/test_checksums"; do
  [ -x "$f" ] || { echo "missing $f (mayhem/build.sh should have built it)" >&2; emit_ctrf cmake-ctest+gzip-interop 0 1 0; exit 1; }
done

passed=0; failed=0
ok()  { passed=$((passed + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; }

# 1) upstream CTest suite
ct_out="$(cd "$B" && ctest -j "$MAYHEM_JOBS" --output-on-failure 2>&1)"; echo "$ct_out"
ct_re="([0-9]+)% tests passed, ([0-9]+) tests failed out of ([0-9]+)"
if [[ "$ct_out" =~ $ct_re ]]; then
  ct_failed="${BASH_REMATCH[2]}"
  passed=$((passed + BASH_REMATCH[3] - ct_failed)); failed=$((failed + ct_failed))
else
  bad "ctest produced no summary"
fi

# 2) known-answer interop with system gzip (deterministic input, hardcoded digest)
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
seq 1 5000 > "$WORK/in"
want="$(sha256sum < "$WORK/in" | cut -d' ' -f1)"
[ "$want" = "23f90f8b2c3a4b5f3b5e156339994afd5c2718b378aca6f0e17111f80a70d4ec" ] || bad "test input digest mismatch ($want)"

for lvl in 1 3 6 9 12; do
  cp "$WORK/in" "$WORK/c"
  if "$GZ" "-$lvl" -c "$WORK/c" > "$WORK/c.gz" 2>/dev/null \
     && [ "$(gzip -dc "$WORK/c.gz" 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$want" ] \
     && [ "$(stat -c %s "$WORK/c.gz")" -lt "$(stat -c %s "$WORK/in")" ]; then
    ok "libdeflate-gzip -$lvl output decodes with system gzip to the original"
  else bad "libdeflate-gzip -$lvl output"; fi
done

for lvl in 1 6 9; do
  gzip "-$lvl" -c "$WORK/in" > "$WORK/s.gz"
  if [ "$("$GZ" -d -c "$WORK/s.gz" 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$want" ]; then
    ok "libdeflate-gzip -d decodes system gzip -$lvl stream to the original"
  else bad "libdeflate-gzip -d of system gzip -$lvl stream"; fi
done

# corrupt stream must be rejected with a non-zero exit and no good output
head -c 200 "$WORK/s.gz" > "$WORK/trunc.gz"
if "$GZ" -d -c "$WORK/trunc.gz" > "$WORK/trunc.out" 2>/dev/null; then bad "truncated gzip accepted"; else ok "truncated gzip rejected"; fi

emit_ctrf cmake-ctest+gzip-interop "$passed" "$failed" 0
