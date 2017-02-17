#include "lua_head.h"
#include <ncurses.h>
#include <ctype.h>
#include <termios.h>
#include <unistd.h>

// Milliseconds
#define ESC_DELAY 50 

static WINDOW *curwin;

static int curtimeout;

static int which_window(lua_State *L, WINDOW **w)
{
    if (lua_islightuserdata(L, 1)) {
	*w = (WINDOW *)lua_topointer(L, 1);
	return 1;
    }
    if (!lua_isnone(L,1) && lua_isnil(L, 1)) {
	*w = stdscr;
	return 1;
    }
    *w = curwin;
    return 0;	
}


LUAFN(init_curses)
{
    initscr();
    set_escdelay(ESC_DELAY);
    curwin = stdscr;
    noecho();
    raw();
    keypad(stdscr,TRUE);
    lua_getglobal(L, "ljcurses");
    lua_getfield(L, -1, "boxes");
    // These aren't constants at compile time.  :-(
    AT_NAME_PUT_INT(vline,    ACS_VLINE);
    AT_NAME_PUT_INT(hline,    ACS_HLINE);
    AT_NAME_PUT_INT(urcorner, ACS_URCORNER);
    AT_NAME_PUT_INT(ulcorner, ACS_ULCORNER);
    AT_NAME_PUT_INT(lrcorner, ACS_LRCORNER);
    AT_NAME_PUT_INT(llcorner, ACS_LLCORNER);
    AT_NAME_PUT_INT(ltee,     ACS_LTEE);
    AT_NAME_PUT_INT(rtee,     ACS_RTEE);
    AT_NAME_PUT_INT(ttee,     ACS_TTEE);
    AT_NAME_PUT_INT(btee,     ACS_BTEE);
    AT_NAME_PUT_INT(plus,     ACS_PLUS);
    AT_NAME_PUT_INT(diamond,  ACS_DIAMOND);
    return 0;
}

LUAFN(endwin)
{
    endwin();
    return 0;
}


LUAFN(getch)
{
    int k;
    enum { DONE, ESC1, ESC2 } state = DONE;

    // Skip escape sequences.
    for (;;) {
	k=getch();
	if (k < 0 && state == ESC1) {
	    k = 27;
	    goto done;
	}
	switch(state) {
	case DONE:
	    if (k != 27)
		goto done;
	    state = ESC1;
	    timeout(ESC_DELAY);
	    break;
	case ESC1:
	    if (k != 'O' && k != '[')
		goto done;
	    state = ESC2;
	    break;
	case ESC2:
	    if (!isdigit(k) && k != ';')
		state = DONE;
	}
    }

done:
    timeout(curtimeout);
    lua_pushinteger(L, k);
    return 1;
}

LUAFN(timeout)
{
    curtimeout = luaL_checkinteger(L, 1);
    timeout(curtimeout);
    return 0;
}

LUAFN(curs_set)
{
    lua_pushinteger(L, curs_set(luaL_checkinteger(L, 1)));
    return 1;
}


LUAFN(doupdate)
{
    doupdate();
    return 0;
}

LUAFN(refresh)
{
    WINDOW *w;
    which_window(L, &w);
    
    wrefresh(w);
    return 0;
}

LUAFN(noutrefresh)
{
    WINDOW *w;
    which_window(L, &w);
    
    wnoutrefresh(w);
    return 0;
}

LUAFN(redrawwin)
{
    WINDOW *w;
    which_window(L, &w);
    
    redrawwin(w);
    return 0;
}


LUAFN(newwin)
{
    WINDOW *w = newwin(luaL_checkinteger(L,1),
		       luaL_checkinteger(L,2),
		       luaL_checkinteger(L,3),
		       luaL_checkinteger(L,4));

    lua_pushlightuserdata(L, w);
    return 1;
}

LUAFN(delwin)
{
    WINDOW *w = (WINDOW *)lua_topointer(L, 1);

    if (w != stdscr) {
	if (w == curwin)
	    curwin = stdscr;
	delwin(w);
    }
    return 0;
}

LUAFN(setwin)
{
    lua_pushlightuserdata(L, curwin);
    
    if (!lua_isnone(L, 1) && lua_isnil(L, 1))
	curwin = stdscr;
    else if (lua_islightuserdata(L,1)) {
	WINDOW *w = (WINDOW *)lua_topointer(L, 1);
	
	if (w != curwin)
	    curwin = w;
    }
    return 1;
}

LUAFN(getdims)
{
    WINDOW *w;
    which_window(L, &w);
    
    int r = 0,c = 0;
    getbegyx(w,r,c);
    lua_pushinteger(L, r);
    lua_pushinteger(L, c);
    getmaxyx(w,r,c);
    lua_pushinteger(L, r);
    lua_pushinteger(L, c);
    return 4;
}

LUAFN(getyx)
{
    WINDOW *w;
    which_window(L, &w);
    
    int r = 0,c = 0;
    getyx(w,r,c);
    lua_pushinteger(L, r);
    lua_pushinteger(L, c);
    return 2;
}

LUAFN(mvwin)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    mvwin(w, luaL_checkinteger(L, 1 + i), luaL_checkinteger(L, 2 + i));
    return 0;
}


LUAFN(start_color)
{
    int flag;
	
    if ((flag = has_colors()))
	start_color();
    lua_pushboolean(L, flag);
    return 1;
}

LUAFN(init_pair)
{
    init_pair(luaL_checkinteger(L, 1),
	      luaL_checkinteger(L, 2),
	      luaL_checkinteger(L, 3));
    return 0;
}

LUAFN(color_pair)
{
    lua_pushinteger(L, COLOR_PAIR(luaL_checkinteger(L,1)));
    return 1;
}

LUAFN(attron)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    wattron(w, luaL_checkinteger(L, 1 + i));
    return 0;
}

LUAFN(attroff)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    wattroff(w, luaL_checkinteger(L, 1 + i));
    return 0;
}

LUAFN(bkgd)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    wbkgd(w, luaL_checkinteger(L, 1 + i));
    return 0;
}


LUAFN(move)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    wmove(w, luaL_checkinteger(L, 1 + i), luaL_checkinteger(L, 2 + i));
    return 0;
}


LUAFN(addch)
{
    WINDOW *w;
    int i = which_window(L, &w);

    waddch(w, luaL_checkinteger(L, i + 1));
    return 0;
}

LUAFN(addstr)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    waddstr(w, luaL_checkstring(L, i + 1));
    return 0;
}

LUAFN(addnstr)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    waddnstr(w, luaL_checkstring(L, 1 + i), luaL_checkinteger(L, 2 + i));
    return 0;
}

LUAFN(insstr)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    winsstr(w, luaL_checkstring(L, i + 1));
    return 0;
}

LUAFN(insnstr)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    winsnstr(w, luaL_checkstring(L, 1 + i), luaL_checkinteger(L, 2 + i));
    return 0;
}


LUAFN(insdelln)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    winsdelln(w, luaL_checkinteger(L, 1 + i));
    return 0;
}

LUAFN(clrtoeol)
{
    WINDOW *w;
    which_window(L, &w);
    
    wclrtoeol(w);
    return 0;
}

LUAFN(clrtobot)
{
    WINDOW *w;
    which_window(L, &w);
    
    wclrtobot(w);
    return 0;
}

LUAFN(delch)
{
    WINDOW *w;
    which_window(L, &w);
    
    wdelch(w);
    return 0;
}


LUAFN(vline)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    wvline(w, luaL_checkinteger(L, 1 + i), luaL_checkinteger(L, 2 + i));
    return 0;
}

LUAFN(hline)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    whline(w, luaL_checkinteger(L, 1 + i), luaL_checkinteger(L, 2 + i));
    return 0;
}

LUAFN(box)
{
    WINDOW *w;
    int i = which_window(L, &w);
    
    box(w, luaL_checkinteger(L, 1 + i), luaL_checkinteger(L, 2 + i));
    return 0;
}


typedef struct { const char *name; int value; } intconst;

LUALIB_API int luaopen_ljcurses(lua_State *L)
{
    static const luaL_Reg funcptrs[] = {
	FN_ENTRY(init_curses),
	FN_ENTRY(endwin),
	FN_ENTRY(getch),
	FN_ENTRY(timeout),
	FN_ENTRY(curs_set),
	
	FN_ENTRY(doupdate),
	FN_ENTRY(refresh),
	FN_ENTRY(noutrefresh),
	FN_ENTRY(redrawwin),
	
	FN_ENTRY(newwin),
	FN_ENTRY(delwin),
	FN_ENTRY(setwin),
	FN_ENTRY(getdims),
	FN_ENTRY(getyx),
	FN_ENTRY(mvwin),
	
	FN_ENTRY(start_color),
	FN_ENTRY(init_pair),
	FN_ENTRY(color_pair),
	FN_ENTRY(attron),	
	FN_ENTRY(attroff),
	FN_ENTRY(bkgd),
	
	FN_ENTRY(move),
	
	FN_ENTRY(addch),
	FN_ENTRY(addstr),
	FN_ENTRY(addnstr),
	FN_ENTRY(insstr),
	FN_ENTRY(insnstr),
	
	FN_ENTRY(insdelln),
	FN_ENTRY(clrtoeol),
	FN_ENTRY(clrtobot),
	FN_ENTRY(delch),
	
	FN_ENTRY(vline),
	FN_ENTRY(hline),
	FN_ENTRY(box),
	{ NULL, NULL }
    };

    static intconst attribute_const[] = {
	{"black",	COLOR_BLACK},
	{"white",	COLOR_WHITE},
	{"red",		COLOR_RED},
	{"blue",	COLOR_BLUE},
	{"green",	COLOR_GREEN},
	{"cyan",	COLOR_CYAN},
	{"magenta",	COLOR_MAGENTA},
	{"yellow",	COLOR_YELLOW},
	
	{"normal",	A_NORMAL},
	{"standout",	A_STANDOUT},
	{"underline",	A_UNDERLINE},
	{"reverse",	A_REVERSE},
	{"blink",	A_BLINK},
	{"dim",		A_DIM},
	{"bold",	A_BOLD},
	{"protect",	A_PROTECT},
	{"invis",	A_INVIS},
	{"altcharset",	A_ALTCHARSET},
	{"chartext",	A_CHARTEXT},
	
	{NULL, 0}
    };

    static intconst keys_const[] = {
	{"ctrl_space",	0},
	{"delete",	127},
	{"escape",	27},	/*  Ctrl [  */
	{"grpsep",	28},	/*  Ctrl \  */
	{"fldsep",	29},	/*  Ctrl ]  */
	{"recsep",	30},	/*  Ctrl ^  */
	{"unitsep",	31},	/*  Ctrl -  */
	{"insert",	KEY_IC},
	{"del",		KEY_DC},
	{"home",	KEY_HOME},
	{"page_down",	KEY_NPAGE},
	{"page_up",	KEY_PPAGE},
	{"end",		KEY_END},
	{"down",	KEY_DOWN},
	{"up",		KEY_UP},
	{"left",	KEY_LEFT},
	{"right",	KEY_RIGHT},
	{"backtab",	KEY_BTAB},
	{"backspace",	KEY_BACKSPACE},
	{"resize",	KEY_RESIZE},
	
	{NULL, 0}
    };
    
    luaL_register(L, "ljcurses", funcptrs);

    lua_pushstring(L, "attributes");
    lua_newtable(L);
    for (int i = 0; attribute_const[i].name; i++) {
	lua_pushstring(L, attribute_const[i].name);
	lua_pushinteger(L, attribute_const[i].value);
	lua_rawset(L, -3);
    }
    lua_rawset(L, -3);

    lua_pushstring(L, "boxes");
    lua_newtable(L);
    lua_rawset(L, -3);

    lua_pushstring(L, "keys");
    lua_newtable(L);
    for (int i = 0; i < 26; i++) {
	char name[7] = "ctrl_?";
	name[5] = i+'a';
	lua_pushstring(L, name);
	lua_pushinteger(L, i+1);
	lua_rawset(L, -3);
    }
    for (int i = 0; keys_const[i].name; i++) {
	lua_pushstring(L, keys_const[i].name);
	lua_pushinteger(L, keys_const[i].value);
	lua_rawset(L, -3);
    }
    lua_rawset(L, -3);
    
    return 1;
}
