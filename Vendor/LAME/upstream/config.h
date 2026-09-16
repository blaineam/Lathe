/* Written by refresh-upstream.sh — not from upstream, and not autoconf's.
 *
 * LAME's build normally generates this. This package does not run autoconf, so
 * the handful of facts LAME needs about the platform are stated directly. They
 * are facts about Apple platforms rather than probes: darwin has all of these
 * headers and functions, on every architecture this package targets.
 */
#ifndef LATHE_LAME_CONFIG_H
#define LATHE_LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_UNISTD_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_MEMCPY 1
#define HAVE_STRCHR 1

/* HAVE_XMMINTRIN_H is deliberately ABSENT rather than defined to 0. LAME tests
 * it with #ifdef, so defining it as zero still selects the SSE intrinsics path
 * and pulls in libmp3lame/vector/, which is x86-only and is not vendored. This
 * package targets Apple silicon, where the C paths are what get used anyway. */

/* LAME's own version strings, which lame.c reports through the API. */
#define PACKAGE "lame"
#define VERSION "3.100"

/* FLOAT and FLOAT8 are deliberately NOT defined here.
 *
 * machine.h defines them, and defines FLOAT_MAX and FLOAT8_MAX alongside — but
 * only inside the `#ifndef FLOAT` branch it takes when config.h has said
 * nothing. Defining FLOAT here skips that branch, leaves FLOAT_MAX undefined,
 * and the build fails several files later complaining about a constant rather
 * than about the type. Leaving both alone gives exactly what a plain
 * ./configure produces: FLOAT is float, FLOAT8 is double.
 */

/* autoconf APPENDS these typedefs to config.h when the platform does not
 * already declare them, which darwin does not — they come from glibc's
 * <ieee754.h>. Without them util.h does not compile, and the error names the
 * type rather than the missing step, which is why this is written down.
 * ieee854_float80_t is omitted along with HAVE_IEEE854_FLOAT80: long double on
 * arm64 is not the 80-bit format the name refers to. */
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

/* The IEEE-754 bit trick LAME uses to round floats quickly. Valid on every
 * architecture this package targets, all of which are little-endian IEEE-754. */
#define TAKEHIRO_IEEE754_HACK 1

#endif /* LATHE_LAME_CONFIG_H */
