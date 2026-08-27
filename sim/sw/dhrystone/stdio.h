/*
 * Freestanding stand-in for <stdio.h>, shadowing the toolchain's.
 *
 * sifive/dhry.h ends with `#include <stdio.h>` and the comment "for strcpy,
 * strcmp" -- 1988 C, where the string prototypes came in with the I/O ones.
 * The default toolchain here is a *linux glibc* cross-compiler, so that
 * include resolves against a full hosted glibc header set: it drags in
 * feature-test machinery, __builtin declarations and a `printf` attributed
 * for a hosted library, none of which belongs in a -nostdlib image that
 * supplies its own printf over a UART.
 *
 * `-I.` puts this directory ahead of the system paths for <> includes too,
 * so this file answers dhry.h's include instead. It declares exactly the
 * three functions the benchmark calls through it. The declarations matter:
 * gcc 14 makes an implicit function declaration an error, not a warning, so
 * without them the vendored sources do not compile at all.
 *
 * printf, strcpy and malloc are defined in ../common/ee_printf.c and
 * dhry_portme.c; strcmp comes from sifive/strcmp.S.
 */

#ifndef DHRY_FREESTANDING_STDIO_H
#define DHRY_FREESTANDING_STDIO_H

int   printf(const char *fmt, ...);
char *strcpy(char *dst, const char *src);
int   strcmp(const char *a, const char *b);

/* malloc is deliberately NOT declared here. dhry_1.c declares it itself,
 * K&R style -- `extern char *malloc ();` -- and a real prototype in scope
 * before that line is a conflicting declaration, not a redundant one
 * (`char *()` against `void *(unsigned long)`), which gcc rejects. The
 * port's definition is in dhry_portme.c; C linkage does not care that the
 * two spellings differ. */

#endif /* DHRY_FREESTANDING_STDIO_H */
