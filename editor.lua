--[[
function opendebug(ptsnum)
   if debugout then debugout:close() end
   debugout=io.open('/dev/pts/'..tostring(ptsnum), 'w')
   if not debugout then print('debug closed'); return; end
   print('debug set to /dev/pts/'..tostring(ptsnum))
end

function debug(...)
   if not debugout then return end
   for i=1,select('#', ...) do
      if i > 1 then debugout:write '\t' end
      debugout:write(tostring(select(i, ...)))
   end
   debugout:write '\r\n'
end

opendebug(FOO)
--]]

local function make_char_bool(str)
   local booltab = {}
   for ix=1,#str do booltab[str:sub(ix,ix)] = true end
   return booltab
end

local l = require 'ljcurses'
local a = l.attributes
local b = l.boxes
local k = l.keys
local state_signs = { SKP='-', ADD='+', OPT='o', REC=' ' }
local excluded_char = make_char_bool '[]<>/ '
local escapemap = {
   a='M-a', o='M-o', r='M-r', R='M-R', s='M-s',
   l='M-l', L='M-L', x='M-x',
   d='M-d'
}
constrain_state_commands={
   ['M-a']='ADD', ['M-o']='OPT', ['M-r']='REC', ['M-s']='SKP',
   ['M-R']='REQ'
}

local function assert(bool, ...)
   if not bool then l.endwin() end
   return _G.assert(bool, ...)
end

function edit_tagset(tagset, installation)
   local categories_sorted = tagset.categories_sorted
   local category_index = tagset.category_index or {}
   if not tagset.categories_sorted then
      categories_sorted = {}
      for k in pairs(tagset.categories) do
	 table.insert(categories_sorted, k)
      end
      table.sort(categories_sorted)
      tagset.categories_sorted = categories_sorted
      for ix, category in ipairs(categories_sorted) do
	 category_index[category] = ix
      end
      tagset.category_index = category_index
   end
   local package_cursors = {}
   local current_category
   local package_cursor
   local last_package = tagset.last_package
   if last_package then
      current_category = category_index[last_package.category]
      package_cursor = last_package.category_index
   else
      last_package = tagset.categories[categories_sorted[1]]
      current_category = 1
      package_cursor = 1
   end
   local package_list = tagset.categories[categories_sorted[current_category]]
   if not tagset.maxtaglen then
      local maxtaglen = 0
      for tag,_ in pairs(tagset.tags) do
	 if #tag > maxtaglen then maxtaglen = #tag end
      end
      tagset.maxtaglen = maxtaglen
   end
   local maxtaglen = tagset.maxtaglen
   local tagformat = '%-'..maxtaglen..'s'
   local colors = {}
   local viewport_top
   local current_constraint
   local constraint_flags = {}
   local constraint_flags_set = 0
   local only_required = false
   local descr_window
   local package_window
   local special_window
   local rows, cols, subwin_lines, half_subwin
   local installed = installation and installation.tags or {}

   local function open_special()
      if not special_window then
	 special_window = l.newwin(subwin_lines, cols-2, 3, 1)
	 l.bkgd(special_window, colors.special)
	 l.move(special_window, 0, 0)
      end
   end

   local function close_special()
      if special_window then
	 l.delwin(special_window)
	 special_window = nil
      end
   end

   local function print_special_line(...)
      local lineout = ''
      for i=1,select('#', ...) do
	 if i > 1 then
	    lineout = lineout..('        '):sub(1 + #lineout % 8)
	 end
	 lineout = lineout..tostring(select(i, ...))
      end
      local row, _ = l.getyx(special_window)
      l.move(special_window, row, 0)
      l.clrtoeol(special_window)
      l.addnstr(special_window, lineout, cols-2)
      l.noutrefresh(special_window)
      return row
   end

   local function next_line_special(row)
      if row == subwin_lines - 1 then
	 l.move(special_window, 0, 0)
	 l.insdelln(special_window, -1)
	 l.move(special_window, subwin_lines - 1, 0)
      else
	 l.move(special_window, row + 1, 0)
      end
      l.noutrefresh(special_window)
      l.doupdate()
   end

   local function print_special(...)
      open_special()
      local row = print_special_line(...)
      next_line_special(row)
   end

   local function confirm_special(prompt, pattern, default)
      local char, key, _
      open_special()
      repeat
	 local row, col = print_special_line(prompt)
	 l.noutrefresh(special_window)
	 l.doupdate()
	 while true do
	    key = l.getch()
	    if key >= 0 then break end
	    util.usleep(1000)
	 end
	 if key == k.resize then
	    next_line_special(row)
	    return default or ''
	 end
	 char = key >= 0 and key < 128 and string.char(key) or ''
	 local row, _ = l.getyx(special_window)
	 if key > 32 and key < 127 and #prompt < cols-3 then
	    l.addstr(special_window, char)
	 end
	 next_line_special(row)
      until not pattern or char:match(pattern)
      return char == '\n' and default or char
   end

   local get_constraint_flag_string
   do
      local constraint_flag_string = ''
      local last_flag_count = 0
      local last_required = false
      get_constraint_flag_string = function ()
	 if last_flag_count ~= constraint_flags_set
	 or last_required ~= only_required then
	    if constraint_flags_set > 0 or only_required then
	       local newcfs = ' ['
	       for _,flag in ipairs { 'ADD', 'OPT', 'REC', 'SKP' } do
		  if constraint_flags[flag] then
		     newcfs = newcfs..
			({ADD='a',OPT='o',REC='r',SKP='s'})[flag]
		  end
	       end
	       if only_required then
		  constraint_flag_string = newcfs..'R]'
	       else
		  constraint_flag_string = newcfs..']'
	       end
	    else
	       constraint_flag_string = ''
	    end
	    last_flag_count = constraint_flags_set
	    last_required = only_required
	 end
	 return constraint_flag_string
      end
   end
   
   local function show_constraint()
      if current_constraint then
	 local constraint = (#current_constraint > 0 and
				current_constraint or '* EMPTY *')..
	    get_constraint_flag_string()
	 l.move(subwin_lines+4, cols - #constraint-2)
	 local color
	 if #package_list == 0 then
	    color = colors.nomatch
	 else
	    color = colors.highlight
	 end
	 l.attron(color)
	 l.addstr(constraint)
	 l.attroff(color)
	 l.attron(colors.main)
      end
   end

   -- global refs: package_cursor, package_list, package_window
   local function draw_package(tuple, line, selected)
      l.move(package_window, line, 0)
      l.clrtoeol(package_window)
      local outstr = tagformat:format(tuple.tag)
      l.attron(package_window, colors[tuple.state])
      l.addstr(package_window, state_signs[tuple.state])
      l.attroff(package_window, colors[tuple.state])
      if tuple.state == tuple.old_state then
	 l.addstr(package_window, ' ')
      else
	 l.attron(package_window, colors[tuple.old_state])
	 l.addch(package_window, b.diamond)
	 l.attroff(package_window, colors[tuple.old_state])
      end
      local outmax=cols-4
      if installation and not installed[tuple.tag] then
	 outstr = outstr:sub(1,#outstr-1)
	 l.attron(package_window, colors.missing)
	 l.addstr(package_window, '*')
	 l.attroff(package_window, colors.missing)
      end
      if tuple.shortdescr then
	 outstr = outstr..' - '..tuple.shortdescr
      end
      if selected then
	 l.attron(package_window, colors.highlight)
	 l.addnstr(package_window, outstr, outmax)
	 l.attroff(package_window, colors.highlight)
	 l.move(1, 11)
	 local descrs=tagset.category_description[tuple.category]
	 l.addnstr(tuple.category ..
		      (descrs and (' - '..descrs.short) or ''), cols - 10)
	 l.clrtoeol()
	 l.move(1, cols-1)
	 l.addch(b.vline)
	 l.move(1, cols-12)
	 l.addnstr('  '..package_cursor..'/'..#package_list, 13)
	 l.move(subwin_lines+4, 2)
	 local pkgdescr
	 if tuple.version then
	    pkgdescr =
	       string.format('%s-%s-%s-%s  state: %s',
			     tuple.tag,
			     tuple.version,
			     tuple.arch,
			     tuple.build,
			     tuple.state)
	 else
	    pkgdescr =
	       string.format('%s  state: %s',
			     tuple.tag,
			     tuple.state)
	 end
	 if tuple.state ~= tuple.old_state then
	    pkgdescr = pkgdescr..' was: '..tuple.old_state
	 end
	 if tuple.required and tuple.state ~= 'ADD' then
	    l.attron(colors.required)
	    l.addnstr(pkgdescr, outmax)
	    l.attroff(colors.required)
	 else
	    l.addnstr(pkgdescr, outmax)
	 end
	 l.clrtoeol()
	 l.move(subwin_lines+4, cols-1)
	 l.addch(b.vline)
	 if installation then
	    l.move(subwin_lines+5,2)
	    l.clrtoeol()
	    local installed = installed[tuple.tag]
	    if installed then
	       local instdescr =
		  string.format('Installed %s-%s-%s-%s',
				installed.tag,
				installed.version,
				installed.arch,
				installed.build)
	       if tuple.version ~= installed.version
		  or tuple.arch ~= installed.arch
		  or tuple.build ~= installed.build
	       then
		  l.addnstr(instdescr, outmax)
	       else
		  l.attron(colors.same_version)
		  l.addnstr(instdescr, outmax)
		  l.attroff(colors.same_version)
	       end
	    else
	       l.attron(colors.missing)
	       l.addnstr('* NOT INSTALLED *', outmax)
	       l.attroff(colors.missing)
	    end
	    l.move(subwin_lines+5,cols-1)
	    l.addch(b.vline)
	 end
      else
	 if tuple.required and tuple.state ~= 'ADD' then
	    l.attron(package_window, colors.required)
	    l.addnstr(package_window, outstr, outmax)
	    l.attroff(package_window, colors.required)
	 else
	    l.addnstr(package_window, outstr, outmax)
	 end
      end
   end

   -- global refs: package_cursor, package_list, package_window, viewport_top
   local function redraw_package_list()
      if not package_window then
	 package_window = l.newwin(subwin_lines, cols-2, 3, 1)
	 l.bkgd(package_window, colors.main)
      end
      viewport_top = package_cursor - half_subwin
      if viewport_top < 1 then viewport_top = 1 end
      local top = viewport_top
      for i=0,subwin_lines-1 do
	 local selected = top+i
	 local tuple=package_list[selected]
	 if not tuple then break end
	 draw_package(tuple, i, package_cursor == selected)
      end
      if #package_list == 0 then
	 l.move(package_window, half_subwin, cols/2 - 8)
	 l.addstr(package_window, "* NO PACKAGES *")
      end
      show_constraint()
      l.noutrefresh(package_window)
   end

   local function draw_description()
      local descr_lines = show_descr and show_descr() or {}
      if not descr_window then
	 descr_window = l.newwin(subwin_lines, cols-2, 3, 1)
	 l.bkgd(descr_window, colors.description)
      end
      for i = 1,subwin_lines do
	 if i > #descr_lines then break end
	 l.move(descr_window, i-1, 1)
	 l.addnstr(descr_window, descr_lines[i], cols-4)
      end
      l.noutrefresh(descr_window)
   end
   
   local function repaint()
      _,_,rows,cols = l.getdims()
      subwin_lines = rows - (installation and 7 or 6)
      half_subwin = math.floor(subwin_lines/2)
      l.move(0,0)
      l.clrtobot()
      l.box(b.vline,b.hline)
      l.move(2,0)
      l.addch(b.ltee)
      l.hline(b.hline, cols-2)
      l.move(2,cols-1)
      l.addch(b.rtee)
      l.move(1,1)
      l.addstr('Category:')
      l.move(subwin_lines + 3, 0)
      l.addch(b.ltee)
      l.hline(b.hline, cols-2)
      l.move(subwin_lines + 3, cols-1)
      l.addch(b.rtee)
      l.noutrefresh()
      if package_window then
	 l.delwin(package_window)
	 package_window = nil
      end
      if descr_window then
	 l.delwin(descr_window)
	 descr_window = nil
      end
      if show_descr then
	 draw_description()
      elseif special_window then
	 l.resize(special_window, subwin_lines, cols-2)
	 l.redrawwin(special_window)
	 l.refresh(special_window)
      else
	 redraw_package_list()
      end
      -- What else do we need to redraw here?
   end

   -- Constraint stuff
   local function clear_constraint()
      if current_constraint then
	 assert(last_package, "last_package not assigned")
	 current_constraint = nil
	 if #package_list > 0 then
	    last_package = package_list[package_cursor]
	 end
	 current_category = category_index[last_package.category]
	 package_cursor = last_package.category_index
	 package_list = tagset.categories[last_package.category]
	 repaint()
      end
   end

   local function match_constraint(tuple, constraint)
      if only_required and not tuple.required
      or constraint_flags_set > 0 and not constraint_flags[tuple.state] then
	 return
      end
      return tuple.tag:find(constraint)
   end
   
   local function constrain(constraint, old_constraint)
      assert(last_package, "last_package not assigned")
      if not old_constraint then
	 package_cursors[current_category] = package_cursor
      end
      if #package_list > 0 then
	 last_package = package_list[package_cursor]
      end
      current_constraint = constraint
      local new_cursor = 1
      package_list = {}
      if pcall(string.find, '', constraint) then
	 local insert_number=1
	 for _, category in ipairs(categories_sorted) do
	    local cat = tagset.categories[category]
	    for _, tuple in ipairs(cat) do
	       if  match_constraint(tuple,constraint) then
		  table.insert(package_list, tuple)
		  if tuple == last_package then
		     new_cursor = insert_number
		  end
		  insert_number = insert_number+1
	       end
	    end
	 end
      end
      if #package_list > 0 then
	 new_package = package_list[new_cursor]
	 if new_package.category ~= last_package.category then
	    current_category = category_index[new_package.category]
	 end
	 package_cursor = new_cursor
      end
   end

   local function toggle_constrain_by_state(flag)
      if flag == 'REQ' then
	 only_required = not only_required
      else
	 local old_flag = constraint_flags[flag]
	 if old_flag then
	    constraint_flags[flag] = false
	    constraint_flags_set = constraint_flags_set - 1
	 else
	    constraint_flags[flag] = true
	    constraint_flags_set = constraint_flags_set + 1
	 end
      end
      constrain(current_constraint or '', current_constraint)
   end

   local function select_category(new_category)
      if current_constraint then return end
      local save_package = last_package
      if #package_list > 0 then
	 save_package = package_list[package_cursor]
      end
      if current_constraint then clear_constraint() end
      if new_category ~= current_category then
	 package_cursors[current_category] = save_package.category_index
	 package_cursor = package_cursors[new_category] or 1
	 package_list = tagset.categories[categories_sorted[new_category]]
	 current_category = new_category
      end
   end

   local function change_state(tuple, new_state, line)
      if #package_list < 1 then return end
      if not new_state then
	 new_state = tuple.state == 'ADD' and 'SKP' or 'ADD'
      end
      if new_state ~= tuple.state then
	 tuple.state = new_state
	 tagset.dirty = true
	 draw_package(tuple, line, true)
	 l.noutrefresh(package_window)
	 show_constraint()
      end
   end

   local function load_package(overwrite)
      if #package_list > 0 then
	 local conflicts
	 local now = util.realtime()
	 local tuple = package_list[package_cursor]
	 local file = string.format('%s/%s-%s-%s-%s.txz',
				    tuple.category,
				    tuple.tag,
				    tuple.version,
				    tuple.arch,
				    tuple.build)
	 if tuple.arch == 'noarch' then
	    print_special('Skipping NOARCH package '..file)
	 else
	    local filepath=tagset.directory..'/'..file
	    if not tagset.package_cache or overwrite then
	       print_special('Loading package '..file)
	       tagset.packages_loaded = { [tuple] = true }
	       tagset.package_cache =
		  read_archive(filepath, print_special, confirm_special)
	    else
	       print_special('Loading additional package '..file)
	       tagset.packages_loaded[tuple] = true
	       conflicts = tagset.package_cache:extend(filepath, print_special,
						       confirm_special)
	    end
	 end
	 if conflicts then
	    print_special ''
	    print_special 'Hit any key to continue'
	 else
	    local elapsed = util.realtime() - now
	    if elapsed < 1 then util.usleep(1000000 * (1 - elapsed)) end
	    close_special()
	    repaint()
	 end
      end
   end
   
   local function command_loop()
      repaint()
      -- If a timeout isn't given at first, then SIGINT isn't
      -- handled correctly.
      l.timeout(100000)
      while true do
	 ::continue::
	 l.doupdate()
	 local key, suffix
	 while true do
	    key, suffix = l.getch()
	    if key >= 0 then break end
	    util.usleep(1000)
	 end
	 if key == k.resize then
	    -- 1/5 sec
	    l.timeout(200)
	    repeat key = l.getch() until key ~= k.resize
	    l.timeout(0)
	    -- We need to recompute these.
	    repaint()
	    if key == -1 then goto continue end
	 end
	 -- Regardless if ctrl/c is SIGINT, it quits the editor.
	 if key == k.ctrl_c then break end
	 local char = key < 128 and string.char(key) or l.keyname(key)
	 if show_descr then
	    show_descr = nil
	    repaint()
	    goto continue
	 end
	 if special_window then
	    close_special()
	    repaint()
	    goto continue
	 end
	 if key == k.escape and escapemap[suffix] then
	    key = -1
	    char = escapemap[suffix]
	 end
	 if key == k.ctrl_l then
	    if current_constraint then
	       constrain(current_constraint, current_constraint)
	    end
	    repaint()
	 -- Show description
	 elseif key == k.ctrl_d then
	    if #package_list > 0 then
	       show_descr = package_list[package_cursor].description
	       repaint()
	    end
	 elseif char == 'M-d' then
	    -- Does the installation description ever change between releases?
	    if #package_list > 0 and installation then
	       local entry =
		  installation.tags[package_list[package_cursor].tag]
	       if entry then
		  show_descr = entry.description
		  repaint()
	       end
	    end
	 -- Constraint
	 elseif key == k.escape and not suffix then
	    clear_constraint()
	    repaint()
	 elseif constrain_state_commands[char] then
	    toggle_constrain_by_state(constrain_state_commands[char],
				      has_constraint)
	    repaint()
	 elseif key == k.ctrl_u then
	    if current_constraint then
	       constrain('', current_constraint)
	       repaint()
	    end
	 elseif key >= 32 and key < 127 and not excluded_char[char] then
	    local new_constraint = current_constraint
	    if not current_constraint then
	       only_required = false
	       constraint_flags_set = 0
	       constraint_flags = {}
	       new_constraint = ''
	       constraint_state = { }
	    end
	    if #new_constraint < 16 then
	       constrain(new_constraint..char, current_constraint)
	       repaint()
	    end
	 elseif char == 'KEY_BACKSPACE' or key == k.delete then
	    if current_constraint then
	       constrain(current_constraint:sub(1, -2), current_constraint)
	       repaint()
	    end
	 -- Navigation
	 elseif char == 'KEY_RIGHT' then
	    if current_category < #categories_sorted then
	       select_category(current_category+1)
	       repaint()
	    end
	 elseif char == 'KEY_LEFT' then
	    if current_category > 1 then
	       select_category(current_category-1)
	       repaint()
	    end
	 elseif char == '<' then
	    select_category(1)
	    repaint()
	 elseif char == '>' then
	    select_category(#categories_sorted)
	    repaint()
	 elseif char == 'KEY_HOME' then
	    package_cursor = 1
	    repaint()
	 elseif char == 'KEY_END' then
	    package_cursor = #package_list
	    repaint()
	 elseif char == 'KEY_DOWN' then
	    if package_cursor < #package_list then
	       package_cursor = package_cursor+1
	       if package_cursor == viewport_top + subwin_lines then
		  repaint()
	       else
		  draw_package(package_list[package_cursor-1],
			       package_cursor-viewport_top-1, false)
		  draw_package(package_list[package_cursor],
			       package_cursor-viewport_top, true)
		  show_constraint()
		  l.noutrefresh(package_window)
	       end
	    end
	 elseif char == 'KEY_UP' then
	    if #package_list > 0 and package_cursor > 1 then
	       package_cursor = package_cursor - 1
	       if package_cursor < viewport_top then
		  repaint()
	       else
		  draw_package(package_list[package_cursor+1],
			       package_cursor-viewport_top+1, false)
		  draw_package(package_list[package_cursor],
			       package_cursor-viewport_top, true)
		  show_constraint()
		  l.noutrefresh(package_window)
	       end
	    end
	 elseif char == 'KEY_NPAGE' then
	    if #package_list > 0 and package_cursor < #package_list then
	       package_cursor = package_cursor + half_subwin
	       if package_cursor > #package_list then
		  package_cursor = #package_list
	       end
	       repaint()
	    end
	 elseif char == 'KEY_PPAGE' then
	    if package_cursor > 1 then
	       package_cursor = package_cursor - half_subwin
	       if package_cursor < 1 then
		  package_cursor = 1
	       end
	       repaint()
	    end
	 -- Change package state
	 elseif key == k.ctrl_a or char == 'KEY_IC' then
	    change_state(package_list[package_cursor], 'ADD',
			 package_cursor-viewport_top)
	 elseif key == k.ctrl_s or char == 'KEY_DC' then
	    change_state(package_list[package_cursor], 'SKP',
			 package_cursor-viewport_top)
	 elseif key == k.ctrl_o then
	    change_state(package_list[package_cursor], 'OPT',
			 package_cursor-viewport_top)
	 elseif key == k.ctrl_r  then
	    change_state(package_list[package_cursor], 'REC',
			 package_cursor-viewport_top)
	 elseif key == k.ctrl_x  then
	    change_state(package_list[package_cursor],
			 package_list[package_cursor].old_state,
			 package_cursor-viewport_top)
	 elseif char == ' ' then
	    change_state(package_list[package_cursor], nil,
			 package_cursor-viewport_top)
	 -- Archive loading and library resolution
	 elseif char == 'M-l' then
	    load_package()
	 elseif char == 'M-L' then
	    load_package(true)
	 elseif char == 'M-x' then
	    tagset.package_cache = nil
	    tagset.packages_loaded = nil
	 end
      end
   end

   l.init_curses()
   l.start_color()
   l.curs_set(0)
   l.init_pair(1, a.white, a.blue)
   l.init_pair(2, a.cyan, a.blue)
   l.init_pair(3, a.green, a.blue)
   l.init_pair(4, a.red, a.blue)
   l.init_pair(5, a.yellow, a.blue)
   l.init_pair(6, a.yellow, a.black)
   l.init_pair(7, a.green, a.black)
   colors.highlight = bit.bor(l.color_pair(2), a.bold)
   colors.description = bit.bor(l.color_pair(6), a.bold)
   colors.ADD = bit.bor(l.color_pair(3), a.bold)
   colors.SKP = bit.bor(l.color_pair(4), a.bold)
   colors.OPT = bit.bor(l.color_pair(5), a.bold)
   colors.REC = 0
   colors.pattern = colors.highlight
   colors.nomatch = colors.SKP
   colors.required = colors.SKP
   colors.same_version = colors.ADD
   colors.missing = colors.SKP
   colors.main = bit.bor(l.color_pair(1), a.bold)
   colors.special = bit.bor(l.color_pair(7), a.bold)
   l.bkgd(colors.main)
   l.attron(colors.main)
   l.refresh()
   local result={pcall(command_loop)}
   l.endwin()
   clear_constraint()
   if not result[1] then print(unpack(result)) end
   if not current_constraint then
      last_package = package_list[package_cursor]
   end
   tagset.last_package = last_package
   if tagset.package_cache then
      tagset.package_cache:cleanup()
   end
   print 'Editor finished'
end
