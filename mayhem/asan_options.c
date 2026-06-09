/*
 * asan_options.c — disable LeakSanitizer in all botan fuzz binaries.
 *
 * WHY: ASan enables LSan (leak detection) by default on Linux. Under Mayhem's
 * ptrace-based coverage collection, LSan detects the tracer process and aborts
 * with the message "LeakSanitizer has encountered a fatal error" /
 * "LeakSanitizer does not work under ptrace (strace, gdb, etc)". Mayhem treats
 * this non-zero exit as a broken run and records 0 edges, even though the
 * target code executed correctly and coverage counters were incremented.
 *
 * HOW: __asan_default_options() and __lsan_default_options() are defined here
 * WITHOUT __attribute__((weak)) — strong symbols always override the ASan/LSan
 * runtime's weak definitions, regardless of link order or --whole-archive.
 * detect_leaks=0 is supplied in both hooks to cover whichever sanitizer's flag
 * parser initializes first. This completely disables LSan while leaving full
 * ASan + UBSan memory/UB error detection in place.
 *
 * INJECTION: compiled to /tmp/botan_asan.o then passed via --ldflags to botan's
 * configure.py so the Makefile includes it as a direct object in every fuzzer
 * and test link command, and added explicitly to each standalone reproducer
 * link in build.sh. Same detect_leaks=0 pattern as mayhemheroes/simdutf,
 * mayhemheroes/my_basic, and mayhemheroes/VC4C.
 */

const char *__asan_default_options(void) {
    return "detect_leaks=0";
}

const char *__lsan_default_options(void) {
    return "detect_leaks=0";
}
