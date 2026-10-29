#!/usr/bin/env bash
#
# mayhem/build.sh — builds the sanitized libFuzzer harnesses (upstream's own scripts/libFuzzer/*/fuzz.c),
# their -standalone reproducers, and the project's test suite (normal flags, for mayhem/test.sh).
# Idempotent and offline: only the in-tree sources, zlib (apt, in the image) and cmake are used.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

TARGETS="deflate_compress deflate_decompress gzip_decompress zlib_decompress"

# 1) The library, sanitized + SanCov-instrumented (fuzzer-no-link) + DWARF 3, with libdeflate's own
#    assertions on (as upstream's scripts/libFuzzer/fuzz.sh does).
FUZZ_BUILD="$SRC/build-fuzz"
rm -rf "$FUZZ_BUILD"
mkdir -p "$FUZZ_BUILD/obj"
compile_one() {
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 \
      -DLIBDEFLATE_ENABLE_ASSERTIONS=1 -I"$SRC" -I"$SRC/lib" \
      -c "$1" -o "$FUZZ_BUILD/obj/$(echo "${1%.c}" | tr / _).o"
}
export -f compile_one
export FUZZ_BUILD
printf '%s\n' lib/*.c lib/*/*.c | xargs -P "$MAYHEM_JOBS" -I{} bash -c 'compile_one {}'
${AR:-ar} rcs "$FUZZ_BUILD/libdeflate-fuzz.a" "$FUZZ_BUILD"/obj/*.o

# 2) Leak detection off at build time (ASan/UBSan stay on).
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"

# 3) Each harness twice: libFuzzer binary + run-once standalone reproducer.
for t in $TARGETS; do
  h="$SRC/scripts/libFuzzer/$t/fuzz.c"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -O1 -I"$SRC" \
      "$h" "$FUZZ_BUILD/libdeflate-fuzz.a" "$FUZZ_BUILD/lsan_off.o" -o "/mayhem/$t"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I"$SRC" \
      "$h" "$FUZZ_BUILD/standalone_main.o" "$FUZZ_BUILD/libdeflate-fuzz.a" "$FUZZ_BUILD/lsan_off.o" \
      -o "/mayhem/$t-standalone"
done

# 4) The project's own test suite and the gzip CLI, NORMAL flags, for mayhem/test.sh. build-tests is
#    covered by upstream's /build* gitignore.
rm -rf "$SRC/build-tests"
# shellcheck disable=SC2086
env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake -S "$SRC" -B "$SRC/build-tests" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC" \
    -DLIBDEFLATE_BUILD_TESTS=ON -DLIBDEFLATE_BUILD_SHARED_LIB=OFF \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS"
