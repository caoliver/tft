/*
*  xxHash - Fast Hash algorithm
*  Copyright (C) 2012-2016, Yann Collet
*
*  BSD 2-Clause License (http://www.opensource.org/licenses/bsd-license.php)
*
*  Redistribution and use in source and binary forms, with or without
*  modification, are permitted provided that the following conditions are
*  met:
*
*  * Redistributions of source code must retain the above copyright
*  notice, this list of conditions and the following disclaimer.
*  * Redistributions in binary form must reproduce the above
*  copyright notice, this list of conditions and the following disclaimer
*  in the documentation and/or other materials provided with the
*  distribution.
*
*  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
*  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
*  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
*  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
*  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
*  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
*  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
*  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
*  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*
*  You can contact the author at :
*  - xxHash homepage: http://www.xxhash.com
*  - xxHash source repository : https://github.com/Cyan4973/xxHash
*/


#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

static const uint64_t PRIME64_1 = 11400714785074694791ULL;
static const uint64_t PRIME64_2 = 14029467366897019727ULL;
static const uint64_t PRIME64_3 =  1609587929392839161ULL;
static const uint64_t PRIME64_4 =  9650029242287828579ULL;
static const uint64_t PRIME64_5 =  2870177450012600261ULL;

static inline uint64_t rot64(uint64_t x, int8_t r)
{
    return (x << r) | (x >> (64 - r));
}

#define round(ACC, INPUT) \
    rot64(ACC + INPUT * PRIME64_2, 31) * PRIME64_1
#define mergeRound(ACC, VAL) \
    PRIME64_1 * (ACC ^ (rot64(VAL * PRIME64_2, 31) * PRIME64_1)) + PRIME64_4

/* Input is assumed to be aligned to an eight byte boundary. */
uint64_t xxh(const void* input, size_t len, uint64_t seed)
{
    const uint8_t* p = (const uint8_t*)input;
    const uint8_t* const bEnd = p + len;
    uint64_t h64;

    if (len>=32) {
        const uint8_t* const limit = bEnd - 32;
        uint64_t v1 = seed + PRIME64_1 + PRIME64_2;
        uint64_t v2 = seed + PRIME64_2;
        uint64_t v3 = seed + 0;
        uint64_t v4 = seed - PRIME64_1;

        do {
            v1 = round(v1, *(const uint64_t *)p); p+=8;
            v2 = round(v2, *(const uint64_t *)p); p+=8;
            v3 = round(v3, *(const uint64_t *)p); p+=8;
            v4 = round(v4, *(const uint64_t *)p); p+=8;
        } while (p<=limit);

        h64 = rot64(v1, 1) + rot64(v2, 7) + rot64(v3, 12) + rot64(v4, 18);
        h64 = mergeRound(h64, v1);
        h64 = mergeRound(h64, v2);
        h64 = mergeRound(h64, v3);
        h64 = mergeRound(h64, v4);

    } else {
        h64  = seed + PRIME64_5;
    }

    h64 += (uint64_t) len;

    while (p+8<=bEnd) {
        h64 ^= round(0, *(const uint64_t *)p);
        h64  = rot64(h64,27) * PRIME64_1 + PRIME64_4;
        p+=8;
    }

    if (p+4<=bEnd) {
        h64 ^= (uint64_t)(*(const uint32_t*)p) * PRIME64_1;
        h64 = rot64(h64, 23) * PRIME64_2 + PRIME64_3;
        p+=4;
    }

    while (p<bEnd) {
        h64 ^= (*p) * PRIME64_5;
        h64 = rot64(h64, 11) * PRIME64_1;
        p++;
    }

    h64 ^= h64 >> 33;
    h64 *= PRIME64_2;
    h64 ^= h64 >> 29;
    h64 *= PRIME64_3;
    h64 ^= h64 >> 32;

    return h64;
}

uint64_t xxhfd(int fd, uint64_t seed)
{
    struct stat sb;
    if (fstat(fd, &sb) < 0 || !S_ISREG(sb.st_mode))
	return 0;
    
    uint64_t result = 0 ;
    void *map = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map != MAP_FAILED) {
	result = xxh(map, sb.st_size, seed);
	munmap(map, sb.st_size);
    }
    
    return result;
}
