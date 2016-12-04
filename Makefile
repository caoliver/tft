CFLAGS+=-fPIC -I /usr/local/include/luajit-2.0/ -I /usr/include/libelf
CFLAGS+=-Wall -Wno-parentheses -O2 -mtune=generic -fomit-frame-pointer -std=c99
LDFLAGS+=-lluajit-5.1

.PHONY: all clean

all: ljcurses.so scanelf.so

ljcurses.so: ljcurses.o
	gcc -shared $(LDFLAGS) -lncurses -o $@ $<

scanelf.so: scanelf.o
	gcc -shared $(LDFLAGS) -lelf -o $@ $<

%.so: %.o
	gcc -shared $(LDFLAGS) -o $@ $<

clean:
	find -name \*.o -delete -o -name \*.so -delete