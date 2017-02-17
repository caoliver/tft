// Needed for clock_gettime() and friends.
#define _POSIX_C_SOURCE 199309

#include <signal.h>
#include <unistd.h>
#include <stdint.h>
#include <fcntl.h>
#include <time.h>
#include "lua_head.h"

uint64_t xxhfd(int fd, uint64_t seed);

#if 0
void handler()
{
    dprintf(2, "Ouch!\n");
    return;
}

LUAFN(catch_signals)
{
    signal(SIGINT, handler);
    signal(SIGQUIT, handler);
    signal(SIGHUP, handler);
    return 0;
}
#endif

LUAFN(cputime)
{
    struct timespec result;

    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &result);

    lua_pushnumber(L, (double)result.tv_sec + 1E-9 * (double)result.tv_nsec);
    return 1;
}

LUAFN(xxhsum_file)
{
    int fd;
    uint64_t result;
    char outbuf[24];

    if ((fd = open(luaL_checkstring(L, 1), O_RDONLY)) == -1) {
	lua_pushstring(L, "0");
	return 1;
    }
    result = xxhfd(fd, lua_tointeger(L, 2));
    close(fd);
    sprintf(outbuf, "%llX", (unsigned long long)result);
    lua_pushstring(L, outbuf);
    return 1;
}

LUAFN(lib_exists)
{
    lua_pushboolean(L, access(lua_tostring(L, 1), R_OK|X_OK) == 0);
    return 1;
}

typedef struct { const char *name; int value; } intconst;

LUALIB_API int luaopen_util(lua_State *L)
{
    static const luaL_Reg funcptrs[] = {
//	FN_ENTRY(catch_signals),
	FN_ENTRY(cputime),
	FN_ENTRY(xxhsum_file),
	FN_ENTRY(lib_exists),
	{ NULL, NULL }
    };
    luaL_register(L, "util", funcptrs);
    
    return 1;
}
