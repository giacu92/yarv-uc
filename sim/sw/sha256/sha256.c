#include <stdint.h>
#include "uart.h"

/*
 * Minimal freestanding SHA-256 monitor for YARV32-UC.
 *
 * UART:
 *   - reads characters until '\r' or '\n'
 *   - backspace is supported
 *   - Enter computes SHA-256
 *
 * Example:
 *
 *   > hello
 *   2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
 *
 * No libc required.
 */

#define INPUT_MAX 128

static uint32_t rotr32(uint32_t x, uint32_t n)
{
    return (x >> n) | (x << (32 - n));
}

static uint32_t ch(uint32_t x, uint32_t y, uint32_t z)
{
    return (x & y) ^ (~x & z);
}

static uint32_t maj(uint32_t x, uint32_t y, uint32_t z)
{
    return (x & y) ^ (x & z) ^ (y & z);
}

static uint32_t big_sigma0(uint32_t x)
{
    return rotr32(x, 2) ^
           rotr32(x, 13) ^
           rotr32(x, 22);
}

static uint32_t big_sigma1(uint32_t x)
{
    return rotr32(x, 6) ^
           rotr32(x, 11) ^
           rotr32(x, 25);
}

static uint32_t small_sigma0(uint32_t x)
{
    return rotr32(x, 7) ^
           rotr32(x, 18) ^
           (x >> 3);
}

static uint32_t small_sigma1(uint32_t x)
{
    return rotr32(x, 17) ^
           rotr32(x, 19) ^
           (x >> 10);
}


/*
 * SHA-256 constants.
 */
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};


/*
 * SHA-256 initial hash values.
 */
static const uint32_t H_INIT[8] = {
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19
};


/*
 * Process one 512-bit block.
 */
static void sha256_transform(uint32_t H[8], const uint8_t block[64])
{
    uint32_t W[64];

    uint32_t a, b, c, d;
    uint32_t e, f, g, h;

    uint32_t T1, T2;

    int i;

    /*
     * First 16 words: big endian.
     */
    for (i = 0; i < 16; i++) {
        W[i] =
            ((uint32_t)block[i * 4 + 0] << 24) |
            ((uint32_t)block[i * 4 + 1] << 16) |
            ((uint32_t)block[i * 4 + 2] << 8)  |
            ((uint32_t)block[i * 4 + 3]);
    }

    /*
     * Message schedule.
     */
    for (i = 16; i < 64; i++) {
        W[i] =
            small_sigma1(W[i - 2]) +
            W[i - 7] +
            small_sigma0(W[i - 15]) +
            W[i - 16];
    }

    a = H[0];
    b = H[1];
    c = H[2];
    d = H[3];

    e = H[4];
    f = H[5];
    g = H[6];
    h = H[7];

    /*
     * 64 SHA-256 rounds.
     */
    for (i = 0; i < 64; i++) {

        T1 =
            h +
            big_sigma1(e) +
            ch(e, f, g) +
            K[i] +
            W[i];

        T2 =
            big_sigma0(a) +
            maj(a, b, c);

        h = g;
        g = f;
        f = e;
        e = d + T1;

        d = c;
        c = b;
        b = a;
        a = T1 + T2;
    }

    H[0] += a;
    H[1] += b;
    H[2] += c;
    H[3] += d;

    H[4] += e;
    H[5] += f;
    H[6] += g;
    H[7] += h;
}


/*
 * SHA-256 arbitrary-length message.
 *
 * Output:
 *   digest[0..7]
 */
static void sha256(
    const uint8_t *data,
    uint32_t len,
    uint32_t digest[8])
{
    uint32_t H[8];

    uint8_t block[64];

    uint32_t full_blocks;
    uint32_t remainder;

    uint32_t i;
    uint32_t j;

    for (i = 0; i < 8; i++)
        H[i] = H_INIT[i];

    /*
     * Process complete 64-byte blocks.
     */
    full_blocks = len / 64;

    for (i = 0; i < full_blocks; i++)
        sha256_transform(H, data + i * 64);

    /*
     * Remaining bytes.
     */
    remainder = len & 63;

    for (j = 0; j < 64; j++)
        block[j] = 0;

    for (j = 0; j < remainder; j++)
        block[j] = data[full_blocks * 64 + j];

    /*
     * SHA-256 padding.
     */
    block[remainder] = 0x80;

    /*
     * If there isn't room for the 64-bit length,
     * process this block and use another one.
     */
    if (remainder >= 56) {

        sha256_transform(H, block);

        for (j = 0; j < 64; j++)
            block[j] = 0;
    }

    /*
     * Length in bits, big endian.
     */
    {
        uint64_t bit_len = (uint64_t)len * 8;

        block[56] = (uint8_t)(bit_len >> 56);
        block[57] = (uint8_t)(bit_len >> 48);
        block[58] = (uint8_t)(bit_len >> 40);
        block[59] = (uint8_t)(bit_len >> 32);

        block[60] = (uint8_t)(bit_len >> 24);
        block[61] = (uint8_t)(bit_len >> 16);
        block[62] = (uint8_t)(bit_len >> 8);
        block[63] = (uint8_t)(bit_len);
    }

    sha256_transform(H, block);

    for (i = 0; i < 8; i++)
        digest[i] = H[i];
}


/*
 * Print SHA-256 digest.
 */
static void print_digest(const uint32_t digest[8])
{
    static const char hex[] = "0123456789abcdef";
    int i;

    for (i = 0; i < 8; i++) {
        int s;

        for (s = 28; s >= 0; s -= 4)
            uart_putc(hex[(digest[i] >> s) & 0xF]);
    }

    uart_putc('\r');
    uart_putc('\n');
}


/*
 * Main UART SHA-256 shell.
 */
int main(void)
{
    char input[INPUT_MAX];

    uint32_t digest[8];

    uint32_t len = 0;

    uart_puts("\r\n");
    uart_puts("YARV32 SHA-256 monitor\r\n");
    uart_puts("> ");

    while (1) {

        /*
         * Wait for a character.
         */
        char c = uart_getc();

        /*
         * Enter.
         */
        if (c == '\r' || c == '\n') {

            uart_puts("\r\n");

            /*
             * Don't hash an empty line.
             */
            if (len != 0) {

                sha256(
                    (const uint8_t *)input,
                    len,
                    digest
                );

                uart_puts("SHA256: ");
                print_digest(digest);
            }

            len = 0;

            uart_puts("> ");

            continue;
        }

        /*
         * Backspace / DEL.
         */
        if (c == '\b' || c == 127) {

            if (len > 0) {
                len--;

                /*
                 * Erase character on terminal.
                 */
                uart_putc('\b');
                uart_putc(' ');
                uart_putc('\b');
            }

            continue;
        }

        /*
         * Store printable character.
         */
        if (c >= 32 && c <= 126) {

            if (len < INPUT_MAX - 1) {

                input[len++] = c;

                /*
                 * Echo.
                 */
                uart_putc(c);
            }
        }
    }

    return 0;
}