CFLAGS+=-fPIC -I /usr/local/include/luajit-2.0/
CFLAGS+=-Wall -Wno-parentheses -O2 -mtune=generic -fomit-frame-pointer -std=c99
LDFLAGS+=-lluajit-5.1 -lncurses 
OBJS=ljcurses.so ljcurses.o

.PHONY: all clean

ljcurses.so: ljcurses.o
	gcc -shared $(LDFLAGS) -o $@ $^

clean:
	rm -f $(OBJS)
