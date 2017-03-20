CFLAGS+=-fPIC -I /usr/local/include/luajit-2.0/ -I /usr/include/libelf
CFLAGS+=-Wall -Wno-parentheses -O3 -mtune=generic -fomit-frame-pointer -std=c99
LDFLAGS+=-lluajit-5.1

.PHONY: all clean

all: ljcurses.so elfutil.so lmarshal.so util.so cpiofns.so

ljcurses.so: ljcurses.o
	gcc -shared $(LDFLAGS) -lncurses -o $@ $<

elfutil.so: elfutil.o
	gcc -shared $(LDFLAGS) -lelf -o $@ $<

util.so: util.o xxhash.o
	gcc -shared $(LDFLAGS) xxhash.o -o $@ $<

cpiofns.o: cpiofns.c
	gcc $(CFLAGS) -c -D_POSIX_C_SOURCE=200809L -o $@ $<

cpiofns.so: cpiofns.o
	gcc -shared $(LDFLAGS) -o $@ $<

%.so: %.o
	gcc -shared $(LDFLAGS) -o $@ $<

clean:
	find -name \*.o -delete -o -name \*.so -delete
