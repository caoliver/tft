#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>
#include <limits.h>
#include <err.h>
#include "lua_head.h"

// Process files in 16MB clumps.
#define FILE_CLUMP (16 * 1024 * 1024)

typedef unsigned int UINT;

/*
 * Original work by Jeff Garzik
 *
 * External file lists, symlink, pipe and fifo support by Thayne Harbaugh
 * Hard link support by Luciano Rocha
 */

static unsigned int offset;
static unsigned int ino = 721;
static luaL_Buffer outbuf;

struct file_handler {
    const char *type;
    int (*handler)(const char *line);
};

static void emit_pad (void)
{
    while (offset & 3) {
	luaL_addchar(&outbuf, 0);
	offset++;
    }
}

static void emit_rest(const char *name)
{
    unsigned int name_len = strlen(name) + 1;
    unsigned int tmp_ofs;

    luaL_addstring(&outbuf, name);
    luaL_addchar(&outbuf, 0);
    offset += name_len;

    tmp_ofs = name_len + 110;
    while (tmp_ofs & 3) {
	luaL_addchar(&outbuf, 0);
	offset++;
	tmp_ofs++;
    }
}

static void emit_hdr(const char *s)
{
    luaL_addstring(&outbuf, s);
    offset += 110;
}

LUAFN(emit_trailer)
{
    char s[256];
    const char name[] = "TRAILER!!!";

    luaL_buffinit(L, &outbuf);

    sprintf(s, "%s%08X%08X%08lX%08lX%08X%08lX"
	    "%08X%08X%08X%08X%08X%08X%08X",
	    "070701",		/* magic */
	    0,			/* ino */
	    0,			/* mode */
	    (long) 0,		/* uid */
	    (long) 0,		/* gid */
	    1,			/* nlink */
	    (long) 0,		/* mtime */
	    0,			/* filesize */
	    0,			/* major */
	    0,			/* minor */
	    0,			/* rmajor */
	    0,			/* rminor */
	    (unsigned)strlen(name)+1, /* namesize */
	    0);			/* chksum */
    emit_hdr(s);
    emit_rest(name);

    while (offset % 512) {
	luaL_addchar(&outbuf, 0);
	offset++;
    }

    luaL_pushresult(&outbuf);
    return 1;
}

LUAFN(emit_directory)
{
    const char *name = luaL_checkstring(L, 1);
    char s[256];

    luaL_buffinit(L, &outbuf);

    if (name[0] == '/')
	name++;
    sprintf(s,"%s%08X%08X%08lX%08lX%08X%08lX"
	    "%08X%08X%08X%08X%08X%08X%08X",
	    "070701",		    /* magic */
	    ino++,		    /* ino */
	    0700 | S_IFDIR,	    /* mode */
	    (long) 0,		    /* uid */
	    (long) 0,		    /* gid */
	    2,			    /* nlink */
	    (long) time(NULL),	    /* mtime */
	    0,			    /* filesize */
	    3,			    /* major */
	    1,			    /* minor */
	    0,			    /* rmajor */
	    0,			    /* rminor */
	    (UINT)strlen(name) + 1, /* namesize */
	    0);			    /* chksum */
    emit_hdr(s);
    emit_rest(name);

    luaL_pushresult(&outbuf);
    return 1;
}

LUAFN(emit_file)
{
    const char *name = luaL_checkstring(L, 1);
    const char *data = luaL_checkstring(L, 2);
    char s[256];
    size_t size = lua_objlen(L, 2);

    luaL_buffinit(L, &outbuf);

    if (name[0] == '/')
	name++;
    sprintf(s,"%s%08X%08X%08lX%08lX%08X%08lX"
	    "%08lX%08X%08X%08X%08X%08X%08X",
	    "070701",		/* magic */
	    ino,		/* ino */
	    0600 | S_IFREG,	/* mode */
	    (long) 0,		/* uid */
	    (long) 0,		/* gid */
	    1,			/* nlink */
	    (long) time(NULL),  /* mtime */
	    size,		/* filesize */
	    3,			/* major */
	    1,			/* minor */
	    0,			/* rmajor */
	    0,			/* rminor */
	    (UINT)strlen(name)+1,	/* namesize */
	    0);			/* chksum */
    emit_hdr(s);
    luaL_addstring(&outbuf, name);
    luaL_addchar(&outbuf, 0);
    offset += strlen(name) + 1;
    emit_pad();

    offset += size;
    luaL_addlstring(&outbuf, data, size);
    emit_pad();
    ino++;
	
    luaL_pushresult(&outbuf);
    return 1;
}

LUALIB_API int luaopen_cpiofns(lua_State *L)
{
    static const luaL_Reg funcptrs[] = {
	FN_ENTRY(emit_directory),
	FN_ENTRY(emit_file),
	FN_ENTRY(emit_trailer),
	{ NULL, NULL }
    };
    luaL_register(L, "cpiofns", funcptrs);
    
    return 1;
};
