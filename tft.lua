local origin=(arg and (arg[0]:match '^(.*)/') or '.')
print(origin)
util=package.loadlib(origin..'/util.so', 'luaopen_util')()
elfutil=package.loadlib(origin..'/elfutil.so', 'luaopen_elfutil')()
local marshal=package.loadlib(origin..'/lmarshal.so', 'luaopen_marshal')()
dofile(origin..'/resolver.lua')
dofile(origin..'/tagfile.lua')
dofile(origin..'/editor.lua')
bad_offers = dofile(origin..'/bad_offers.lua')
