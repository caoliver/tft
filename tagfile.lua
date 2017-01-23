#!/usr/local/bin/lua

local function case_insensitive_less_than(a,b)
   return string.lower(a) < string.lower(b)
end

function first_field(a, b) return case_insensitive_less_than(a[1], b[1]) end

local indent='  '
local line_start = #indent

local show_matches, show_tuples, describe
do
   local function sort_matches(set)
      local sorted={}
      for _,v in ipairs(set) do table.insert(sorted, v) end
      table.sort(sorted)
      return sorted
   end

   show_matches = function (set)
      local sorted = sort_matches(set.set)
      local i=0
      for _,v in ipairs(sorted) do
	 if #v > 25 then io.write(' '..v:sub(1,24)..'*')
	 else io.write((' %-25s'):format(v))
	 end
	 if i==2 then i = 0; io.write '\n'
	 else i = i + 1
	 end
      end
      if i > 0 then io.write '\n' end
   end

   describe = function (thingie, taglist)
      if type(taglist) ~= 'table' then
	 taglist = sort_matches(thingie:like(taglist).set)
      end
      if #taglist == 0 then return end
      for _,tag in ipairs(taglist) do
	 local item = thingie.tags[tag]
	 if not item or not item.description then
	    print('Can\'t find description for tag '..tag)
	    return
	 end
	 print('Description for tag '..tag..'\n')
	 for _,line in ipairs(item.description()) do print(indent..line) end
	 print ''
      end
   end
end

local function cleanuppath(path)
   if not path then error('Invalid path: '..tostring(path)) end
   -- Elide superfluous '/'.
   path = path:gsub('/+', '/')
   -- Remove backtracks.
   local newpath
   while true do
      local newpath = path:gsub('^/%.%./', '/')
      if newpath == path then break end
      path = newpath
   end
   while true do
      local newpath = path:gsub('/[^/]+/%.%./', '/')
      if newpath == path then break end
      path = newpath
   end
   -- Remove trailing slash if present.
   return path[#path] == '/'  and path:sub(1,-2) or path
end

function read_installation(prefix)
   local directory = cleanuppath((prefix or '')..'/var/log/packages')

   local function check_other(arg)
      if not arg.type ~= 'tagset' then
	 print 'Argument must be a tagset'
	 return false
      end
      return true
   end

   local function make_description(package, tag)
      local descr_lines
      return function()
	 if not descr_lines then
	    local descr_file = io.open(package)
	    if descr_file then
	       local reading_descr
	       local descr_match = '^'..tag..':(.*)'
	       for line in descr_file:lines() do
		  if line == 'FILE LIST:' then break end
		  if descr_lines then
		     local text = line:match(descr_match)
		     if text then
			table.insert(descr_lines, text)
		     end
		  elseif line == 'PACKAGE DESCRIPTION:' then
		     descr_lines = {}
		  end
	       end
	       descr_file:close()
	       -- trim trailer
	       while #descr_lines > 0 and descr_lines[#descr_lines] == '' do
		  table.remove(descr_lines)
	       end
	    end
	 end
	 return descr_lines
      end
   end

   local function compare(self, tagset, ...)
      if check_other(tagset) then tagset:compare(self, ...) end
   end

   local function missing(self, tagset)
      if check_other(tagset) then tagset:missing(self) end
   end

   local function like(self, pattern)
      local set = {}
      for tag, _ in pairs(self.tags) do
	 if tag:match(pattern) then table.insert(set, tag) end
      end
      return { set=set, show=show_matches, describe=describe }
   end

   local function show_like(self, pattern)
      local matches = {}
      for tag, tuple in pairs(self.tags) do
	 if not pattern or tag:match(pattern) then
	    table.insert(matches, tuple)
	 end
      end
      if #matches == 0 then return end
      table.sort(matches, function (a,b) return a.tag < b.tag end)
      local maxpkglen, maxverlen = 7, 7
      for _,tuple in ipairs(matches) do
	 if maxpkglen < #tuple.tag then maxpkglen = #tuple.tag end
	 if maxverlen < #tuple.version then maxverlen = #tuple.version end
      end
      local format =
	 indent..'%-'..maxpkglen..'s  %-'..maxverlen..'s  %-6s  %s'
      io.write(format:format('PACKAGE', 'VERSION', 'ARCH',
			     'BUILD'..'\n'..indent))
      for _=1,maxverlen+maxpkglen+16 do io.write '-' end
      io.write '\n'
      for _,tuple in ipairs(matches) do
	 print(format:format(tuple.tag, tuple.version,
			     tuple.arch, tuple.build))
      end
   end

    local installed = { type = 'installation',
		       show=show_like, like = like, tags={},
		       describe = describe, compare=compare,
		       missing=missing }
   local find = io.popen('find '..directory..' -type f')
   for package in find:lines() do
      local tag,version,arch,build =
	 package:match '/([^/]+)%-([^-]+)%-([^-]+)%-([^-]+)$'
      if tag then
	 local descr_lines

	 installed.tags[tag] = { tag=tag,
				 version = version,
				 arch = arch,
				 build = build,
				 description = make_description(package, tag) }
      end
   end
   find:close()
   return installed
end

local tagset_list = {}
local tagset_next_instance = {}
setmetatable(tagset_list, {__mode = 'k'})

function read_tagset(tagset_directory, skip_kde)
   local allowed_states = {ADD=true, REC=true, OPT=true, SKP=true}

   tagset_directory = cleanuppath(tagset_directory)

   local function forget_changes(self, uncache)
      self.dirty = false
      for tag,tuple in pairs(self.tags) do
	 if tuple.state ~= tuple.old_state then
	    tuple.state = tuple.old_state
	 end
      end
      if uncache then
	 tagset_list[self] = nil
	 tagset_list_changed = true
      end
   end

   local function like(self, pattern)
      local set = {}
      for tag, _ in pairs(self.tags) do
	 if tag:match(pattern) then table.insert(set, tag) end
      end
      return { set=set, show=show_matches }
   end

   local function set_state(self, taglist, state)
      if not state then
	 state = 'ADD'
      else
	 state = state:upper()
	 if not allowed_states[state] then
	    print('Invalid state: '..state)
	    return
	 end
      end
      if type(taglist) ~= 'table' then taglist = like(self, taglist).set end
      for _, tag in ipairs(taglist) do
	 local tuple = self.tags[tag]
	 if not tuple then
	    print('Can\'t find tag '..tag..' in set.  Skipping!')
	 else
	    if tuple.state ~= state  then
	       tuple.state = state;
	       self.dirty = true
	    end
	 end
      end
   end

   local function show_like(self, pattern, category, state)
      local matches = {}
      for tag, tuple in pairs(self.tags) do
	 if (not pattern or tag:match(pattern)) and
	    (not category or category == tuple.category) and
	    (not state or state == tuple.state)
	 then
	    table.insert(matches, tuple)
	 end
      end
      if #matches == 0 then return end
      table.sort(matches,
		 function (a, b) return
		       a.category < b.category or
		       a.category == b.category and
		    case_insensitive_less_than(a.tag,b.tag) end)
      local maxpkglen, maxverlen = 7, 7
      if matches[1].version then
	 for _,tuple in ipairs(matches) do
	    if maxpkglen < #tuple.tag then maxpkglen = #tuple.tag end
	    if maxverlen < #tuple.version then maxverlen = #tuple.version end
	 end
	 format =
	    indent..'%-8s  %-'..maxpkglen..'s  %-5s  %-'..
	    maxverlen..'s  %-6s  %s'
	 io.write(format:format('CATEGORY', 'PACKAGE', 'STATE', 'VERSION',
				'ARCH', 'BUILD\n'..indent))
	 for i=1,maxverlen+maxpkglen+34 do io.write '-' end
	 io.write '\n'
	 for _,match in ipairs(matches) do
	    print(format:format(match.category, match.tag,
				match.state..
				   (match.state ~= match.old_state and '*' or ''),
				match.version, match.arch, match.build))
	 end
      else
	 for _,tuple in ipairs(matches) do
	    if maxpkglen < #tuple.tag then maxpkglen = #tuple.tag end
	 end
	 format =
	    indent..'%-8s  %-'..maxpkglen..'s  %-5s'
	 io.write(format:format('CATEGORY', 'PACKAGE', 'STATE\n'..indent))
	 for i=1,maxpkglen+17 do io.write '-' end
	 io.write '\n'
	 for _,match in ipairs(matches) do
	    print(format:format(match.category, match.tag, match.state))
	 end
      end
   end

   local function write_tagset(self, directory, NonADD_to_SKP)
      if not directory then print 'No directory given'; return; end
      for category, tags in pairs(self.categories) do
	 local tagdir = directory..'/'..category
	 os.execute('rm -rf '..tagdir)
	 if os.execute('mkdir -p '..directory..'/'..category) ~= 0 then
	    print('Can\'t make directory '..tagdir)
	    return
	 end
	 local tagfilename = tagdir..'/tagfile'
	 local tagfile = io.open(tagfilename, 'w')
	 if not tagfile then
	    print('Can\'t create tagfile '..tagfilename)
	    return
	 end
	 for _, tuple in ipairs(tags) do
	    if NonADD_to_SKP and tuple.state ~= 'ADD' then
	       tagfile:write(tuple.tag..':SKP\n')
	    else
	       tagfile:write(tuple.tag..':'..tuple.state..'\n')
	    end
	 end
	 tagfile:close()
	 for _,tuple in pairs(self.tags) do tuple.old_state = tuple.state end
	 self.dirty = false
	 self.directory = directory
      end
   end

   local function missing(self, installation)
      if installation.type ~= 'installation' then
	 print 'Argument must be an installation'
	 return
      end
      local missing_required={}
      for tag,tuple in pairs(self.tags) do
	 if not installation.tags[tag] and tuple.state == 'ADD' then
	    table.insert(missing_required, tag)
	 end
      end
      if #missing_required > 0 then
	 print('  Missing reqirements from installation:')
	 show_matches {set=missing_required}
      else
	 print '  No missing requirements!'
      end
   end

   local function compare(self, thingie, options)
      options = options or {}
      local show_version_changes = options.show_changes
      local show_optional = options.show_opts
      local inhibit_recommended = options.no_recs
      local category = options.category
      local pattern = options.pattern

      local function intersection_difference(a, b)
	 local function check_states(a,b)
	    if pattern then
	       if a and not a.tag:match(pattern) then return false end
	       if b and not b.tag:match(pattern) then return false end
	    end
	    if category then
	       if a and a.category and a.category ~= category then
		  return false
	       end
	       if b and b.category and b.category ~= category then
		  return false
	       end
	    end
	    if skip_kde and (a and a.category and a.category:match '^kde' or
			     b and b.category and b.category:match '^kde') then
	       return false
	    end
	    if show_optional then return true end
	    if inhibit_recommended and
	       ((a and a.state == 'REC') or (b and b.state == 'REC'))
	    then
	       return false
	    end
	    return a and a.state ~= 'OPT' or b and b.state ~= 'OPT'
	 end

	 local only_a = {}
	 local only_b = {}
	 local common = {}
	 for tag, tuple in pairs(a.tags) do
	    if check_states(tuple, b.tags[tag]) then
	       table.insert(b.tags[tag] and common or only_a, tag)
	    end
	 end
	 for tag, tuple in pairs(b.tags) do
	    if check_states(a.tags[tag], tuple) then
	       if not a.tags[tag] then table.insert(only_b, tag) end
	    end
	 end
	 return common, only_a, only_b
      end

      other_thing =
	 thingie.type == 'tagset' and 'second tagset' or 'installation'
      print('Comparing tagset to '..other_thing)
      local common, not_in_other, not_in_self =
	 intersection_difference(self, thingie)
      local different_version = {}
      if show_version_changes then
	 for _,tag in ipairs(common) do
	    local tuple=self.tags[tag]
	    local other_tuple=thingie.tags[tag]
	    if (tuple.version and other_tuple.version and
		   (tuple.version ~= other_tuple.version or
		    tuple.build ~= other_tuple.build)) then
	       table.insert(different_version,
			    { tag=tag ,
			      tagset_version =
				 tuple.version..' / '..tuple.build,
			      installed_version
				 = other_tuple.version..' / '..
				 other_tuple.build })
	    end
	 end
      end
      if #not_in_other > 0 then
	 print('Missing from '..other_thing..':')
	 show_matches {set=not_in_other}
      else
	 print('Nothing missing from '..other_thing..'!')
      end
      if #not_in_self > 0 then
	 print('Missing from tagset:')
	 show_matches {set=not_in_self}
      else
	 print 'Nothing missing from tagset!'
      end
      if not show_version_changes or #different_version == 0 then return end
      print('\n  Differing versions')
      table.sort(different_version,
		 function(a,b)
		    return case_insensitive_less_than(a.tag, b.tag) end)
      for _, tuple in ipairs(different_version) do
	 print(indent..'tag: '..tuple.tag..
		  '  tagset: '..tuple.tagset_version..
		  '  installed: '..tuple.installed_version)
      end
   end

   local function make_description(descr_file)
      local descr_lines
      return function ()
	 if not descr_lines then
	    local descr_file = io.open(descr_file)
	    if (descr_file) then
	       descr_lines = {}
	       for line in descr_file:lines() do
		  line = line:match '^[^:]*:( .*)$'
		  table.insert(descr_lines, line)
	       end
	       descr_file:close()
	       while #descr_lines > 0 and descr_lines[#descr_lines] == '' do
		  table.remove(descr_lines)
	       end
	    end
	 end
	 return descr_lines
      end
   end

   local function get_instance(directory)
      local new_instance = 1 + (tagset_next_instance[directory] or 0)
      tagset_next_instance[directory] = new_instance
      return new_instance
   end

   local function clone(self)
      local newset = {
      tags = {}, categories = {}, directory = tagset_directory,
      write = write_tagset, show=show_like, change_archive=change_archive,
      forget=forget_changes, set=set_state, like=like, describe=describe,
      compare=compare, missing=missing, clone=clone }
      for category,tags in ipairs(self.categories) do
	 local taglist = {}
	 newset.categories[category] = taglist
	 for _, tuple in ipairs(tags) do
	    local newtuple = {}
	    for k,v in pairs(tuple) do newtuple[k] = v end
	    newtuple.old_state = newtuple.state
	    table.insert(taglist, newtuple)
	    newset.tags[newtuple.tag] = newtuple
	 end
      end
      tagset_list[newset] = true
      tagset_list_changed = true
      newset.instance = get_instance(self.directory)
      return newset
   end

   local function change_archive(self, directory)
      directory = cleanuppath(directory)
      for _,tuple in pairs(self.tags) do
	 tuple.version = nil
	 tuple.arch = nil
	 tuple.build = nil
	 tuple.description = nil
	 tuple.shortdescr = nil
      end
      local txtfiles_pipe =
	 io.popen('find '..directory..' -name \\*.txt')
      for descr_file in txtfiles_pipe:lines() do
	 local tag,version,arch,build =
	    descr_file:match '/([^/]+)%-([^/-]+)%-([^/-]+)%-([^/-]+).txt$'
	 if not self.tags[tag] then
	    print('No tagfile record for '..tag..'.  Skipping!')
	 else
	    self.tags[tag].version = version
	    self.tags[tag].arch = arch
	    self.tags[tag].build = build
	    self.tags[tag].description = make_description(descr_file)
	 end
      end
      txtfiles_pipe:close()

      local maketags = io.popen('ls '..directory..'/*/maketag 2>/dev/null')
      for line in maketags:lines() do
	 local maketag = io.open(line)
	 if maketag then
	    local gotdata
	    for line in maketag:lines() do
	       local quoted = line:sub(1,1) == '"'
	       if gotdata and not quoted then break end
	       if quoted then
		  gotdata = true
		  local tag, descr =
		     line:match '"([^"]*)" "([^"]*)" "[^"]*" \\'
		  if not tag then
		     print('Skipping strange line: '..line)
		  else
		     local entry = self.tags[tag]
		     if entry then entry.shortdescr = descr end
		  end
	       end
	    end
	    maketag:close()
	 end
      end
   end

   local tagset = {
      type = 'tagset',
      tags = {}, categories = {}, directory = tagset_directory,
      write = write_tagset, show=show_like, change_archive=change_archive,
      forget=forget_changes, set=set_state, like=like, describe=describe,
      compare=compare, missing=missing, clone=clone }
   local category_pipe = io.popen('find '..tagset_directory..
				     ' -mindepth 1 -maxdepth 1 -type d')
   for category_directory in category_pipe:lines() do
      local category = category_directory:match '([^/]*)$'
      local tagfile = io.open(category_directory..'/tagfile')
      if not tagfile then
	 print('No tagfile found in '..category_directory..' Skipping!')
	 goto next_directory
      end
      for line in tagfile:lines() do
	 local tag,state = line:match '(.*):([^:]+)$'
	 if not allowed_states[state] then
	    print('Bad state for tag '..tag..' in category '..category)
	 else
	    local tuple = {
	       tag=tag, category=category, state=state, old_state=state }
	    tagset.tags[tag] = tuple
	    if not tagset.categories[category] then
	       tagset.categories[category] = {}
	    end
	    table.insert(tagset.categories[category], tuple)
	 end
      end
      tagfile:close()
      ::next_directory::
   end
   -- Now try to enumerate txt files for packages.  If this is
   -- just a tagset directory, then there will be none.
   change_archive(tagset, tagset_directory)
   category_pipe:close()
   tagset_list_changed= true
   tagset_list[tagset] = true
   tagset.instance = get_instance(tagset_directory)
   return tagset
end


do
   local tagset_list_last_size=0
   function tagsets(ix)
      local format = indent..'%d: %3s %s%s'
      local sets = {}
      for tagset,_ in pairs(tagset_list) do table.insert(sets, tagset) end
      table.sort(sets, function(a, b) return a.directory < b.directory end)
      if #sets ~= tagset_list_last_size then
	 tagset_list_last_size = #sets
	 tagset_list_changed = true
      end
      if tagset_list_changed then
	 io.write 'The set of loaded tagsets may have changed.  '
	 if #sets > 0 then print 'Here\'s new the list.' end
	 tagset_list_changed = nil
      end
      if #sets == 0 then print 'The list is empty.' end
      for i,set in ipairs(sets) do
	 print(format:format(i, '<'..set.instance..'>',
			     (set.dirty and '* ' or '  '), set.directory))
      end
      if ix then return sets[ix] end
   end
end
