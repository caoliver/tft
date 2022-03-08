// Needed for clock_gettime() and friends.
#define _POSIX_C_SOURCE 199309

#include <signal.h>
#include <unistd.h>
#include <stdint.h>
#include <fcntl.h>
#include <time.h>
#include "lua_head.h"
#include <errno.h>
#include <glob.h>
#include <termios.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <xxhash.h>
#include <fcntl.h>
#include <sys/mman.h>

uint64_t xxhfd(int fd, uint64_t seed);

LUAFN(getchar)
{
    struct termios new, old;
    char inbuf[16];
    char *ptr=inbuf;
    if (tcgetattr(0, &old) < 0)
	return 0;
    new=old;
    tcflush(0, TCIFLUSH);
    new.c_lflag &= ~(ECHO | ICANON);
    tcsetattr(0, TCSANOW, &new);
    for (int i=0; ++i <= sizeof(inbuf); ++ptr) {
	struct timeval timeout = {0,50000};
	fd_set infds;
	FD_ZERO(&infds);
	FD_SET(0, &infds);
	if (select(1, &infds, NULL, NULL, i == 1 ? NULL : &timeout) != 1 ||
	    read(0, ptr, 1) < 1)
	    break;
    }
    tcsetattr(0, TCSANOW, &old);
    tcflush(0, TCIFLUSH);
    lua_pushlstring(L, inbuf, ptr - inbuf);
    return 1;
}

LUAFN(readable)
{
    const char *filename = lua_tostring(L, 1);
    if (access(filename, R_OK) == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushnil(L);
    lua_pushinteger(L, errno);
    return 2;
}

LUAFN(cputime)
{
    struct timespec result;

    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &result);

    lua_pushnumber(L, (double)result.tv_sec + 1E-9 * (double)result.tv_nsec);
    return 1;
}

LUAFN(realtime)
{
    struct timespec result;

    clock_gettime(CLOCK_REALTIME, &result);

    lua_pushnumber(L, (double)result.tv_sec + 1E-9 * (double)result.tv_nsec);
    return 1;
}

LUAFN(usleep)
{
    usleep(luaL_checkinteger(L, 1));
    return 0;
}

LUAFN(glob)
{
    glob_t resultglob;
    const char *pattern = lua_tostring(L, 1);
    int rc;


    rc = glob(pattern, GLOB_ERR, NULL, &resultglob);
    if (rc != 0 && rc != GLOB_NOMATCH) {
        lua_pushnil(L);
        lua_pushinteger(L, rc == GLOB_NOSPACE ? ENOMEM : errno);
        return 2;
    }

    lua_newtable(L);
    if (rc == 0)
    {
	int i = 0;
	while (i < resultglob.gl_pathc) {
	    lua_pushstring(L, resultglob.gl_pathv[i++]);
	    lua_rawseti(L, -2, i);
	}
	globfree(&resultglob);
    }
    return 1;
}


LUAFN(xxhsum_file)
{
    int fd;
    struct stat sb;
    if ((fd = open(luaL_checkstring(L, 1), O_RDONLY)) == -1 ||
	fstat(fd, &sb) == -1) {
	lua_pushstring(L, "X");
	return 1;
    }
    
    void *map = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
	close(fd);
	lua_pushstring(L, "X");
	return 1;
    }
    close(fd);
    uint64_t result = XXH64(map, sb.st_size, 0);
    munmap(map, sb.st_size);
    char outbuf[24];
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
	FN_ENTRY(getchar),
	FN_ENTRY(readable),
	FN_ENTRY(realtime),
	FN_ENTRY(cputime),
	FN_ENTRY(usleep),
	FN_ENTRY(glob),
	FN_ENTRY(xxhsum_file),
	FN_ENTRY(lib_exists),
	{ NULL, NULL }
    };
    luaL_register(L, "util", funcptrs);
    
    return 1;
}
