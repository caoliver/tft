local function case_insensitive_less_than(a,b)
   return string.lower(a) < string.lower(b)
end

local make_tmpdir, rm_tmpdir
do
   local tmpdir, tmpdirlen
   function make_tmpdir()
      if not tmpdir then
	 local pipe = io.popen 'mktemp -d 2>&-'
	 local dirname
	 if pipe then
	    tmpdir = pipe:read '*l'
	    tmpdirlen = #tmpdir
	    pipe:close()
	 end
      end
      return tmpdir, tmpdirlen
   end
   function rm_tmpdir()
      if tmpdir then
	 os.execute('rm -rf '..tmpdir)
	 tmpdir = nil
      end
   end
end

function _G.read_archive(archive_file, myprint, mygetch)
   local print = myprint or print
   local getch = mygetch or getch
   local function satisfy(self, root, myprint, mygetch)
      print = myprint or print
      getch = mygetch or getch
      local root = root or ''
      local paths, seen = {}, {}
      for _, line in ipairs { '/lib', '/lib64', '/usr/lib', '/usr/lib64' } do
	 local pathname = util.realpath(root..line)
	 if pathname then
	    seen[pathname] = true
	    table.insert(paths, pathname)
	 end
      end
      local ldsoconf = io.open(root..'/etc/ld.so.conf')
      if ldsoconf then
	 for line in ldsoconf:lines() do
	    local pathname = util.realpath(root..line)
	    if pathname and not seen[pathname] then
	       seen[pathname] = true
	       table.insert(paths, pathname)
	    end
	 end
	 ldsoconf:close()
      end
      seen = nil
      local remove = {}
      local removes
      for needed in pairs(self.needed) do
	 local satisfied = {}
	 for _, path in ipairs(paths) do
	    if util.lib_exists(path..'/'..needed) then
	       table.insert(satisfied, path);
	       remove[needed] = true
	       removes = true;
	    end
	 end
	 if #satisfied == 1 then
	    print('DT_NEEDED '..needed..
		     ' satisfied in directory: '..satisfied[1])
	 elseif #satisfied == 0 then
	    print('DT_NEEDED '..needed..' remains unsatisfied')
	 else
	    print('DT_NEEDED '..needed..' satified in directories: ')
	    for _, v in ipairs(satisfied) do print('  '..v) end
	 end
      end
      if not removes then return end
      local confirm =
	 getch('Remove satisfied needs? (y/N):',  '[YyNn\n\4]', 'n')
      if confirm == '\4' or confirm:upper() == 'N' then return end
      for needed in pairs(remove) do
	 self.needed[needed] = nil
      end
   end

   local function clone(self)
      local new = create()
      for sum in pairs(self.archivesums) do
	 new.archivesums[sum] = true
      end
      for path, name in pairs(self.elfpaths) do
	 new.elfpaths[path] = name
      end
      for soname in pairs(self.sonames) do
	 new.sonames[soname] = true
      end
      for _, elf in ipairs(self.elfs) do
	 table.insert(new.elfs, elf)
      end
      for name, elftable in pairs(self.needed) do
	 local newelfs = {}
	 for elf in pairs(elftable) do newelfs[elf] = true end
	 new.needed[name] = newelfs
      end
      return new
   end

   local function extend(self, archive_file, myprint, mygetch)
      local print = myprint or print
      local getch = mygetch or getch
      local std_search = {
	 ['/lib']=true, ['/lib64']=true,
	 ['/usr/lib']=true, ['/usr/lib64']=true
      }
      do
	 local matches=util.glob(archive_file..'.t?z')
	 if not matches or #matches ~= 1 then
	    print('Can\'t find archive for '..archive_file)
	    return
	 end
	 archive_file = matches[1]
      end
      local decompose_archive_name =
	 '([^/]+)/([^/]+)%-[^/-]+%-[^/-]+%-[^/-]+%.t.z$'

      local archivesum = util.xxhsum_file(archive_file)
      if self.archivesums[archivesum] then
	 local shortname = archive_file:match '([^/]*)$'
	 print('Copy of archive '..shortname..' is already loaded.')
	 local confirm = getch('Are you sure? (y/N): ', '[YyNn\n\4]', 'n')
	 if confirm == '\4' or confirm:upper() == 'N' then return end
      end
   
      local elfs = self.elfs
      local sonames = self.sonames
      local needed = self.needed
      local elfpaths = self.elfpaths
      local tmpdir, len = make_tmpdir()
      tmpdir=tmpdir..'/'
      local conflicts

      local inodes_read = {}
      os.execute('ROOT=$(readlink -f '..tmpdir..') installpkg 2>&- 1>&-'..
		    archive_file)
      local findproc = io.popen('find -L '..tmpdir..
				   ' ! -type d -printf "%D,%i %p\n" 2>&-')
      for line in findproc:lines() do
	 local inode, name = line:match('^([^%s]+) (.*)$')
	 local elf =
	    inodes_read[inode] == nil and (elfutil.scan_elf(name) or false)
	 if elf then
	    inodes_read[inode] = elf
	    elf.path = name:sub(len+1)
	    elf.category, elf.package =
	       archive_file:match(decompose_archive_name)
	    if elfpaths[elf.path] then
	       print('Potential conflict for '..elf.path..' in '..elf.package)
	       local path=elfpaths[elf.path]
	       if tmpdir == path:sub(1,#tmpdir) then
		  path="$WORKDIR/"..path:sub(#tmpdir+1)
	       end
	       print('Exists already as '..path)
	       conflicts = true
	    end
	    elfpaths[elf.path] = name
	    table.insert(elfs, elf)
	    if elf.soname and std_search[elf.path:match('^(.*)/[^/]*$')] then
	       sonames[elf.soname] = true
	    end
	    for _,name in ipairs(elf.needed) do
	       if not needed[name] then needed[name] = {} end
	       needed[name][elf] = true
	    end
	 end
      end
      os.execute('find $(readlink -f '..tmpdir..') -mindepth 1 -delete')
      -- resolve internal needed.  (Assumes architecture matches.)
      for soname in pairs(sonames) do needed[soname] = nil end
      local found = {}
      for name,elfs in pairs(needed) do
	 local unresolved = 0
	 for elf in pairs(elfs) do
	    unresolved = unresolved + 1
	    for _, path in ipairs(elf.runpath or elf.rpath or {}) do
	       if path == '$ORIGIN' then
		  path = elf.path:match '^(.*)/[^/]*$'
	       elseif path:sub(1, 8) == '$ORIGIN/' then
		  path = elf.path:match '^(.*)/[^/]*$'..'/'..altpath:sub(9)
	       end
	       if elfpaths[path..'/'..name] then
		  unresolved = unresolved - 1
	       end
	    end
	    if unresolved == 0 then table.insert(found, name) end
	 end
      end
      for _, found in pairs(found) do needed[found] = nil end
      self.archivesums[archivesum] = true
      return conflicts
   end

   function create()
      return make_object('archive_set', {
	 archivesums = {}, elfs = {}, sonames = {}, needed = {},
	 elfpaths = {},
	 clone = clone, satisfy = satisfy, extend = extend,
	 cleanup=rm_tmpdir })
   end

   local new = create()
   if archive_file then extend(new, archive_file, myprint, myprint) end
   return new
end


-- Assumes architecture matches.  When is this a bad thing?


function _G.read_manifest(archive_directory)
   local archpat = '^||   Package:  '..
      '%./([^/]+)/([^/]+)%-([^/-]+)%-([^/-]+)%-([^/-]+)%.t.z'
   local eoh = '++========================================'
   local associations = {}
   local input = io.popen('bzcat '..archive_directory..'/MANIFEST.bz2')
   local state = 0
   local category, tag, version, arch, build
   for line in input:lines() do
      if state == 0 then
	 category, tag, version, arch, build = line:match(archpat)
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
	       table.insert(assoc, {file,tag})
	    end
	 end
      end
      ::cont::
   end
   
   local function get_suggestions (self, archiveset)
      if object_type[archiveset] ~= 'archive_set' then
	 print 'Argument must be an archive set'
	 return
      end
      local associations = self.associations
      local function bad_offer(needed, offered)
	 local offer = bad_offers[offered]
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
      for needed, neededby in pairs(archiveset.needed) do
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
			       {needed, candidate[1], stem, neededby})
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
   
   local function suggest(self, archiveset, verbose, pattern)
      if object_type[archiveset] ~= 'archive_set' then
	 print 'First argument must be an archive set'
	 return
      end
      local suggestions = get_suggestions(self, archiveset)
      for _, suggestion in ipairs(suggestions) do
	 if not pattern or suggestion[1]:match(pattern) then
	    print(suggestion[1])
	    if verbose then
	       for _, libspec in ipairs(suggestion[2]) do
		  print("    "..libspec[1],libspec[2],libspec[3])
		  if verbose==2 then
		     for neededby in pairs(libspec[4]) do
			print("         "..neededby.path)
		     end
		  end
	       end
	    end
	 end
      end
   end
   
   return make_object('manifest',
		      { suggest = suggest, get_suggestions = get_suggestions,
			associations = associations })
end
