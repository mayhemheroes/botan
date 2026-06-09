#!/usr/bin/env bash
#
# botan/mayhem/test.sh — RUN botan's own unit-test suite (botan-test, built by build.sh with the
# project's NORMAL flags) → CTRF. PATCH-grade oracle. build.sh compiled test-build/botan-test in a
# separate clean (non-sanitized, non-fuzzer) build dir; this only RUNS it and reports counts.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

BIN="$SRC/test-build/botan-test"
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; exit 2; }

# Run the full suite. botan-test self-locates its data dir (src/tests/data) from CWD=$SRC.
# Long-running / online / memory-intensive tests are left OFF (the defaults) so the run stays a few
# minutes and stays deterministic & hermetic (no network). botan-test exits non-zero on failure.
"$BIN" 2>&1 | tee /tmp/botan-test.out
rc=${PIPESTATUS[0]}
out="$(cat /tmp/botan-test.out)"

# botan's StdoutReporter summary line:  "Tests complete ran <N> tests in <t> ..." followed by either
#   "<M> tests failed (in <suites>)"   or   "all tests ok".
# botan-test has no notion of "skipped" in its summary, so skipped=0.
total=$( printf '%s\n' "$out" | sed -n 's/.*complete ran \([0-9][0-9]*\) tests* in .*/\1/p'  | tail -1)
failed=$(printf '%s\n' "$out" | sed -n 's/.*ran [0-9][0-9]* tests* in [^ ]* \([0-9][0-9]*\) tests* failed.*/\1/p' | tail -1)
: "${total:=0}" "${failed:=0}"

# Anti-sabotage: if total==0 the suite didn't run (sabotaged binary, missing data, crash before
# any test) — always a failure regardless of exit code. A no-op exit(0) patch MUST fail here.
if [ "$total" -eq 0 ]; then
  echo "botan-test ran 0 tests — binary is sabotaged, crashed before any test, or data is missing" >&2
  emit_ctrf "botan-test" 0 1 0
  exit 1
fi

# Fallback: if rc!=0 but we got a count, trust the count (non-zero failed already captured).
passed=$(( total - failed )); [ "$passed" -lt 0 ] && passed=0

emit_ctrf "botan-test" "$passed" "$failed" 0
