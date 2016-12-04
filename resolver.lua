local bad_offers = {
   ['m17n-lib'] = {'libm.so.'},
}

local txzpat = '^||   Package:  '.. 
   '%./([^/]+)/([^/]+)%-([^/-]+)%-([^/-]+)%-([^/-]+).txz'
local eoh = '++========================================'

local function case_insensitive_less_than(a,b)
   return string.lower(a) < string.lower(b)
end

local scanelf=(require 'scanelf').scan_elf

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
	    if dir and (file:sub(-3) == '.so' or
			file:match('%.so%.[.0-9]+$')) then
	       local stem = file:match '^([%a_%-]*[%a])'
	       
	       local assoc = associations[stem]
	       if not assoc then
		  assoc = {}
		  associations[stem] = assoc
	       end
	       table.insert(assoc, {file,package})
	    end
	 end
      end
      ::cont::
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

   local findproc = io.popen('find '..directory..' -type f 2>&-')
   for binfile in findproc:lines() do
      local elfspec = scanelf(binfile)
      if elfspec then
	 if elfspec.soname then
	    table.insert(contents.provided, elfspec.soname)
	 end
	 -- What do we really want to do with these?
	 if elfspec.rpath or elfspec.runpath then
	    for _, path in
	    ipairs(expand_search_path(elfspec.runpath or elfspec.rpath)) do
	       contents.rpaths[path] = true;
	    end
	 end
	 if elfspec.needed then
	    for _, lib in ipairs(elfspec.needed) do
	       if contents.needed[lib] then
		  table.insert(contents.needed[lib], binfile)
	       else
		  contents.needed[lib] = { binfile }
	       end
	    end
	 end
      end
   end
   return contents
end

function expand_archive(archive_file, contents)
   os.execute('s=$(readlink -f '..archive_file..');cd '..tmpdir..
		 ';tar xf $s')
   contents = process_elfs(tmpdir, contents)
   -- Remove internally provided shared objects.
   for _,provided in ipairs(contents.provided) do
      contents.needed[provided] = nil
   end
   os.execute('find $(readlink -f '..tmpdir..') -mindepth 1 -delete')
   return contents
end

function suggest_packages(needed, associations)
   local function bad_offer(needed, offered)
      local offer = bad_offers[offered]
      print("Checking "..offered,needed)
      if offer then
	 for _, bad_match in ipairs(offer) do
	    if needed:sub(1, #bad_match) == bad_match then
	       return true
	    end
	 end
      end
      return false
   end
   local suggestions = {}
   local nomatch = {}
   for needed, needed_by in pairs(needed) do
      local stem = needed:match '^([%a_%-]*[%a])'
      local candidates = associations[stem]
      if not candidates then
	 nomatch[stem] = true;
      else
	 for _, candidate in ipairs(candidates) do
	    if not bad_offer(needed, candidate[2]) then
	       local suggestion = suggestions[candidate[2]]
	       if not suggestion then
		  suggestion = {}
		  suggestions[candidate[2]] = suggestion
	       end
	       table.insert(suggestion,
			    {needed, candidate[1], stem, needed_by})
	       end
	 end
      end
   end
   local sorted = {}
   for k,v in pairs(suggestions) do
      table.sort(v, function(a,b)
		    return case_insensitive_less_than(a[1],b[1]) end)
      table.insert(sorted, {k,v})
   end
   table.sort(sorted, function(a,b)
		 return case_insensitive_less_than(a[1],b[1]) end)
   return sorted
end

function show_suggestions(suggestions, show_needers)
   for _, suggestion in ipairs(suggestions) do
      print(suggestion[1])
      for _, libspec in ipairs(suggestion[2]) do
	 print("    "..libspec[1],libspec[2],libspec[3])
	 if show_needers then
	    for _, needed_by in ipairs(libspec[4]) do
	       print("         "..needed_by:sub(#tmpdir+1))
	    end
	 end
      end
   end
end
