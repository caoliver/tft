--[[
function opendebug(ptsnum)
   if debugout then debugout:close() end
   debugout=io.open('/dev/pts/'..tostring(ptsnum), 'w')
   if not debugout then print('debug closed'); return; end
   print('debug set to /dev/pts/'..tostring(ptsnum))
end

function debug(...)
   if not debugout then return end
   for i,val in ipairs {...} do
      if i > 1 then debugout:write '\t' end
      debugout:write(tostring(val))
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
local delete_keys = { [k.del]=true, [k.delete]=true, [k.backspace]=true }
local state_signs = { SKP='-', ADD='+', OPT='o', REC=' ' }
local excluded_char = make_char_bool '<>/'

local function assert(bool, ...)
   if not bool then l.endwin() end
   return _G.assert(bool, ...)
end

function edit_tagset(tagset)
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
   local state
   local current_constraint
   local descr_window
   local package_window
   local rows, cols, subwin_lines, half_subwin
   

   local function show_constraint()
      if current_constraint then
	 l.move(rows-2, cols - #current_constraint-2)
	 local color
	 if #package_list == 0 then
	    color = colors.nomatch
	 else
	    color = colors.highlight
	 end
	 l.attron(color)
	 l.addstr(current_constraint)
	 l.attroff(color)
	 l.attron(colors.main)
      end
   end

   -- global refs: package_cursor, package_list, package_window
   local function draw_package(tuple, line, selected)
      l.move(package_window, line, 0)
      l.clrtoeol(package_window)
      local outstr = tagformat:format(tuple.tag)
      if tuple.shortdescr then
	 outstr = outstr..' - '..tuple.shortdescr
      end
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
      if selected then
	 l.attron(package_window, colors.highlight)
	 local outmax=cols-4
	 l.addnstr(package_window, outstr, outmax)
	 l.attroff(package_window, colors.highlight)
	 l.move(1, 11)
	 l.clrtoeol()
	 l.move(1, cols-1)
	 l.addch(b.vline)
	 l.move(1, cols-12)
	 l.addnstr('  '..package_cursor..'/'..#package_list, 13)
	 l.move(rows-2,2)
	 l.clrtoeol()
	 l.move(rows-2, cols-1)
	 l.addch(b.vline)
	 l.move(rows-2,2)
	 if tuple.version then
	    local pkgdescr =
	       string.format('%s-%s-%s-%s  state: %s',
			     tuple.tag,
			     tuple.version,
			     tuple.arch,
			     tuple.build,
			     tuple.state)
	    if tuple.state ~= tuple.old_state then
	       pkgdescr = pkgdescr..' was: '..tuple.old_state
	    end
	    l.addnstr(pkgdescr, cols - 4)
	 end
	 l.move(1, 11)
	 local descrs=tagset.category_description[tuple.category]
	 l.addnstr(tuple.category ..
		      (descrs and (' - '..descrs.short) or ''), cols - 10)
      else
	 l.addnstr(package_window, outstr, cols-4)
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
      subwin_lines = rows - 6
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
      l.move(rows-3,0)
      l.addch(b.ltee)
      l.hline(b.hline, cols-2)
      l.move(rows-3,cols-1)
      l.addch(b.rtee)
      l.noutrefresh()
      if package_window then
	 l.delwin(package_window)
	 package_window = nil
      end
      redraw_package_list()
      if descr_window then
	 l.delwin(descr_window)
	 descr_window = nil
      end
      if show_descr then
	 draw_description()
      end
      -- What else do we need to redraw here?
   end

   -- Constraint stuff
   -- TODO
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

   -- 
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
	       if tuple.tag:find(constraint) then
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
      if not new_state then
	 new_state = tuple.state == 'ADD' and 'SKP' or 'ADD'
      end
      if new_state ~= tuple.state then
	 tuple.state = new_state
	 tagset.dirty = true
	 draw_package(tuple, line, true)
	 l.noutrefresh(package_window)
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
	 local key
	 repeat key = l.getch() until key >= 0
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
	 local char = key < 256 and string.char(key) or 0
	 if state == 'describe' then
	    state = nil
	    show_descr = nil
	    repaint()
	    goto continue
	 end
	 if key == k.ctrl_l then
	    repaint()
	 -- Show description
	 elseif key == k.ctrl_d then
	    state = 'describe'
	    show_descr = package_list[package_cursor].description
	    repaint()
	 -- Constraint
	 elseif key == k.escape then
	    clear_constraint()
	    repaint()
	 elseif key == k.ctrl_u then
	    constrain('', current_constraint)
	    repaint()
	 elseif key >= 32 and key < 127 and not excluded_char[char] then
	    local new_constraint = current_constraint
	    if not current_constraint then new_constraint = '' end
	    if #new_constraint < 16 then
	       constrain(new_constraint..char, current_constraint)
	       repaint()
	    end
	 elseif delete_keys[key] then
	    if current_constraint then
	       constrain(current_constraint:sub(1, -2), current_constraint)
	       repaint()
	    end
	 -- Navigation
	 elseif key == k.right then
	    if current_category < #categories_sorted then
	       select_category(current_category+1)
	       repaint()
	    end
	 elseif key == k.left then
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
	 elseif key == k.home then
	    package_cursor = 1
	    repaint()
	 elseif key == k['end'] then
	    package_cursor = #package_list
	    repaint()
	 elseif key == k.down then
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
	 elseif key == k.up then
	    if package_cursor > 1 then
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
	 elseif key == k.page_down then
	    if package_cursor < #package_list then
	       package_cursor = package_cursor + half_subwin
	       if package_cursor > #package_list then
		  package_cursor = #package_list
	       end
	       repaint()
	    end
	 elseif key == k.page_up then
	    if package_cursor > 1 then
	       package_cursor = package_cursor - half_subwin
	       if package_cursor < 1 then
		  package_cursor = 1
	       end
	       repaint()
	    end
	 -- Change package state
	 elseif key == k.ctrl_a then
	    change_state(package_list[package_cursor], 'ADD',
			 package_cursor-viewport_top)
	 elseif key == k.ctrl_s then
	    change_state(package_list[package_cursor], 'SKP',
			 package_cursor-viewport_top)
	 elseif key == k.ctrl_o then
	    change_state(package_list[package_cursor], 'OPT',
			 package_cursor-viewport_top)
	 elseif key == k.ctrl_r  then
	    change_state(package_list[package_cursor], 'REC',
			 package_cursor-viewport_top)
	 elseif key == k.ctrl_u  then
	    change_state(package_list[package_cursor],
			 package_list[package_cursor].old_state,
			 package_cursor-viewport_top)
	 elseif char == ' ' then
	    change_state(package_list[package_cursor], nil,
			 package_cursor-viewport_top)
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
   colors.highlight = bit.bor(l.color_pair(2), a.bold)
   colors.description = bit.bor(l.color_pair(6), a.bold)
   colors.ADD = bit.bor(l.color_pair(3), a.bold)
   colors.SKP = bit.bor(l.color_pair(4), a.bold)
   colors.OPT = bit.bor(l.color_pair(5), a.bold)
   colors.REC = 0
   colors.pattern = colors.highlight
   colors.nomatch = colors.SKP
   colors.main= bit.bor(l.color_pair(1), a.bold)
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
   print 'Editor finished'
end
