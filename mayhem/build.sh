#!/usr/bin/env bash
#
# botan/mayhem/build.sh — build botan's own libFuzzer fuzz targets (instrumented) plus a
# standalone (non-fuzzer) reproducer per declared target.
#
# botan ships a first-class fuzzer build: `python3 configure.py --unsafe-fuzzer-mode
# --build-fuzzers=libfuzzer` emits one binary per src/fuzzer/*.cpp (each defines fuzz();
# the LLVMFuzzer* entry comes from src/fuzzer/fuzzers.h). We thread the base build contract
# through botan's --cc-abi-flags: $SANITIZER_FLAGS + -fsanitize=fuzzer there land on BOTH the
# library compile (so the FUZZED CODE is instrumented, not just the harness) and the fuzzer
# link line (so libFuzzer's runtime is linked in). `make fuzzers` (botan's own target, what
# OSS-Fuzz runs) builds ALL src/fuzzer/*.cpp — we build the full set so the image is at FULL
# OSS-Fuzz parity (42 harnesses), and ship a standalone reproducer per harness.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV (overridable). SANITIZER_FLAGS uses `=` (not `:=`) so an explicit
# empty `--build-arg SANITIZER_FLAGS=` is honored and builds with NO sanitizers (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ---------------------------------------------------------------------------
# asan_options: bake detect_leaks=0 into every fuzz binary.
#
# Under Mayhem's ptrace-based coverage collection, LSan detects the tracer and
# aborts with "LeakSanitizer does not work under ptrace", causing every run to
# exit non-zero → 0 edges → broken run health. __asan_default_options() and
# __lsan_default_options() are STRONG symbols that override the runtime's weak
# versions, disabling LSan while keeping full ASan + UBSan error detection.
# Compile early (before configure.py) so the path is ready when make fuzzers
# runs; injected via --ldflags into the fuzzer Makefile and explicitly on
# each standalone reproducer link line.
ASAN_OBJ=/tmp/botan_asan.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/asan_options.c -o "$ASAN_OBJ"

# ---------------------------------------------------------------------------
# 0) Build botan's OWN test binary (`botan-test`) with the project's NORMAL flags — a separate,
#    clean build dir, NOT the unsafe-fuzzer/sanitized build. This is the honest functional oracle
#    that mayhem/test.sh RUNS (test.sh never compiles). It MUST come first: configure.py writes the
#    top-level Makefile, and the fuzzer configure below overwrites it — but this build uses its own
#    --with-build-dir (test-build/) so its botan-test binary and objects survive the fuzzer rebuild.
#    No sanitizers, no --unsafe-fuzzer-mode: a faithful, deterministic build for PATCH grading.
TEST_BUILD_DIR="$SRC/test-build"
rm -rf "$TEST_BUILD_DIR"
mkdir -p "$TEST_BUILD_DIR"
python3 configure.py \
  --cc=clang --cc-bin="$CXX" \
  --with-build-dir="$TEST_BUILD_DIR" \
  --disable-shared --amalgamation
# With --with-build-dir, configure.py writes the Makefile into that dir ($TEST_BUILD_DIR/Makefile),
# NOT into $SRC — so build it with `make -f`. This keeps the test build fully separate from the
# fuzzer build (which uses the default build/ tree + $SRC/Makefile below).
make -j"$MAYHEM_JOBS" -f "$TEST_BUILD_DIR/Makefile" tests
[ -x "$TEST_BUILD_DIR/botan-test" ] || { echo "test build did not produce botan-test" >&2; exit 1; }
echo "built test binary: $TEST_BUILD_DIR/botan-test"

# Fuzz targets to ship: ALL src/fuzzer/*.cpp — FULL OSS-Fuzz parity (OSS-Fuzz runs `make
# fuzzers`, which builds every harness). Discovered from the source tree so a new upstream
# harness is picked up automatically; each name is a src/fuzzer/<name>.cpp.
TARGETS=()
for f in src/fuzzer/*.cpp; do TARGETS+=("$(basename "$f" .cpp)"); done

# 1) Configure botan's fuzzer build. --cc-abi-flags carries $SANITIZER_FLAGS (so the
#    library — the fuzzed code — is instrumented), $DEBUG_FLAGS (DWARF≤3 symbols for Mayhem
#    triage), AND the libFuzzer engine flag (so each fuzzer links libFuzzer's runtime; with
#    --build-fuzzers=libfuzzer the harness has no main() of its own). --amalgamation keeps the
#    build single-translation-unit and fast. locking_allocator is disabled (its mlock pool is
#    opaque to ASan); getrandom/getentropy are dropped so the fuzzer RNG stays deterministic.
#    This matches botan's documented oss-fuzz recipe.
python3 configure.py \
  --cc=clang --cc-bin="$CXX" \
  --cc-abi-flags="$SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE" \
  --ldflags="$ASAN_OBJ" \
  --disable-shared --disable-modules=locking_allocator \
  --unsafe-fuzzer-mode --build-fuzzers=libfuzzer \
  --without-os-features=getrandom,getentropy \
  --amalgamation

# 2) Build the static library (the instrumented fuzzed code) once, then ALL fuzzers in one shot
#    via botan's own `fuzzers` target — exactly what OSS-Fuzz builds (`make ... fuzzers`).
make -j"$MAYHEM_JOBS" libs
make -j"$MAYHEM_JOBS" fuzzers

LIB="$SRC/libbotan-3.a"
[ -f "$LIB" ] || LIB="$(find "$SRC" -maxdepth 2 -name 'libbotan-*.a' | head -1)"

# 3) Compile LLVM's standalone run-once driver as a C object ONCE (a C++ compile would mangle its
#    LLVMFuzzerTestOneInput reference and miss botan's extern "C" definition). Reused per target.
#    $DEBUG_FLAGS after $SANITIZER_FLAGS so DWARF≤3 symbols are emitted in the standalone too.
SA_OBJ=/tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SA_OBJ"

# 4) Per target: `make fuzzers` already built every build/fuzzer/<t> (the Mayhem libFuzzer
#    binaries); copy each to /mayhem and link a standalone (non-fuzzer) reproducer from the same
#    compiled fuzzer object + LLVM's run-once main + the instrumented lib.
for t in "${TARGETS[@]}"; do
  [ -f "build/fuzzer/$t" ] || { echo "make fuzzers did not produce build/fuzzer/$t" >&2; exit 1; }
  cp "build/fuzzer/$t" "/mayhem/$t"
  # standalone (non-fuzzer) reproducer — repro artifact, not a Mayhem target ($DEBUG_FLAGS after $SANITIZER_FLAGS)
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$ASAN_OBJ" "build/obj/fuzzer/$t.o" "$SA_OBJ" "$LIB" -o "/mayhem/$t-standalone"
done

echo "built ${#TARGETS[@]} fuzz targets: ${TARGETS[*]}"
