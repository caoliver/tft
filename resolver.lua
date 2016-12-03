local txzpat = '^||   Package:  '..
   '%./([^/]+)/([^/]+)%-([^/-]+)%-([^/-]+)%-([^/-]+).txz'
local eoh = '++========================================'

local util=require 'util'

function get_load_path(root)
   local path = {}
   if not root then root = '' end
   local ldsoconf = io.open(root..'/etc/ld.so.conf')
   for line in ldsoconf:lines() do
      path[root..line] = true
   end
   ldsoconf:close()
   return path
end

function read_manifest(archive_directory)
   local associations = {}
   local input = io.popen('bzcat '..archive_directory..'/MANIFEST.bz2')
   local state = 0
   local category, package, version, arch, build
   for line in input:lines() do
      if state == 0 then
	 category, package, version, arch, build = line:match(txzpat)
	 if category then state = 1 end
      elseif state == 1 then
	 state = 2
      elseif state == 2 then
	 if line ~= eoh then
	    print('I got lost reading the manifest.  Line was: '..line)
	    return
	 end
	 state = 3
      elseif state == 3 then
	 if line == '' then
	    state = 0
	 else
	    local dir,file = line:match('(.+)/([^/]+)$',49)
	    if dir and (file:find('.so.',1,true) or
			file:sub(-3) == '.so') then
	       local assoc = associations[file]
	       if not assoc then
		  assoc = {}
		  associations[file] = assoc
	       end
	       assoc[package] = file
	    end
	 end
      end
   end
   return associations
end


function add_libraries(resolution_roots, libraries)
   local libraries = libraries or {}
   for k, _ in pairs(resolution_roots) do
      libdir = io.popen('find 2>&- '..k..' -maxdepth 1 '..
			   '-name \\*.so -o -name \\*.so.\\* '..
			   '-printf \'%f\\n\'')
      for line in libdir:lines() do libraries[line]=true end
      libdir:close()
   end
   return libraries
end

-- This should be a C fn in util!
function make_tmpdir()
   local pipe = io.popen 'mktemp -d 2>&-'
   local dirname
   if pipe then
      dirname = pipe:read '*l'
      pipe:close()
   end
   return dirname
end		   

function process_elfs(directory, contents)
   local pushback
   local elftype
   local interp
   local proc = io.popen('readelf -dl / '..
			    '$(find '..directory..' -type f) 2>&-')
   local function getline()
      local old = pushback
      pushback = nil
      return old or proc:read()
   end
   
   local function ungetline(line)
      pushback = line
   end
   
   local function expand_search_path(pathlist, origin)
      local result = {}
      pathlist = pathlist:match '%s*(.*[^%s])%s*'
      while pathlist do
	 local path, rest = pathlist:match '^([^:]*):(.*)$'
	 if not path then
	    path = pathlist
	 end
	 if (path:match '^%$ORIGIN/') or (path:match '^%$ORIGIN$') then
	    -- FIGURE ORIGIN STUFF HERE
	 end
	 table.insert(result, path)
	 pathlist = rest
      end
      return result
   end

   contents = contents or { needed = {}, provided = {}, rpaths = {} }
   
   repeat
      local state = 'start'
      local scanners = {
	 start = function(line)
	    return line and 'file' or nil
	 end,

	 file = function(line)
	    local file = line:match '^File: .*/(.*)'
	    return 'elftype'
	 end,

	 elftype = function(line)
	    if not line then return nil end
	    if line == '' then return 'elftype' end
	    elftype = line:match 'Elf file type is ([^ ]*)'
	    if elftype then return 'interp' end
	    if line == 'There are no program headers in this file.' then
	       return 'start'
	    end
	    ungetline(line)
	    return 'file'
	 end,
	 
	 interp = function(line)
	    if line == 'There is no dynamic section in this file.' then
	       return 'start'
	    end
	    if line:match '^Dynamic section' then return 'dyns' end
	    interp = line:match '%[Requesting program interpreter: (.*)%]'
	    return 'interp'
	 end,

	 dyns = function(line)
	    if line == '' or line == nil then
	       ungetline(line)
	       return false;
	    end
	    local dyntype, value = line:match '%((.*)%).*%[(.*)%]'
	    if dyntype == 'SONAME' then
	       insert.table(contents.provided, value)
	    elseif dyntype == 'RPATH' or dyntype == 'RUNPATH' then
	       for path in ipairs(expand_search_path(value)) do
		  contents.rpaths[value] = true
	       end
	    elseif dyntype == 'NEEDED' then
	       contents.needed[value] = true
	    end
	    return 'dyns'
	 end
      }
      repeat
	 local line = getline()
	 state = scanners[state](line)
      until not state
   until state == nil
   proc:close()
   return contents
end

function expand_archive(archive_file, contents)
   os.execute('s=$(readlink -f '..archive_file..');cd '..tmpdir..
		 ';tar xf $s')
   contents = process_elfs(tmpdir, contents)
   os.execute('find $(readlink -f '..tmpdir..') -mindepth 1 -delete')
   return contents
end
