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
--]]

local l = require 'ljcurses'
local a = l.attributes
local b = l.boxes
local k = l.keys
local delete_keys = { [k.del]=true, [k.delete]=true, [k.backspace]=true }
local state_signs = { SKP='-', ADD='+', OPT='o', REC=' ' }
local search_char = {}
do
   local valid =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ'..
      'abcdefghijklmnopqrstuvwxyz'..
      '0123456789'..
      '-_'
   for ix=1,#valid do search_char[valid:sub(ix,ix)] = true end
end
local searchmax = 24

function edit_tagset(tagset)
   local rows, cols, subwin_lines, half_subwin
   local series_sorted = {}
   local _
   for k in pairs(tagset.categories) do table.insert(series_sorted, k) end
   table.sort(series_sorted)
   local current_series
   local package_list
   local package_window
   if not tagset.package_cursors then tagset.package_cursors = {} end
   local package_cursors = tagset.package_cursors
   local package_cursor = package_cursors[current_series] or 1
   local colors = {}
   local viewport_top
   if not tagset.maxtaglen then
      local maxtaglen = 0
      for tag,_ in pairs(tagset.tags) do
	 if #tag > maxtaglen then maxtaglen = #tag end
      end
      tagset.maxtaglen = maxtaglen
   end
   local maxtaglen = tagset.maxtaglen
   local tagformat = '%-'..maxtaglen..'s'
   local state
   local descr_window
   local has_restriction
   local all_series

   local function make_restricted_list (restriction, series_number)
      local result = {}
      local series_set =
	 series_number and { series_number } or series_sorted
      if pcall(string.find, '', restriction) then
	 for _, series in ipairs(series_set) do
	    local cat = tagset.categories[series]
	    for _, tuple in ipairs(cat) do
	       if tuple.tag:find(restriction) then
		  table.insert(result, tuple)
	       end
	    end
	 end
      end
      return result
   end

   local function show_restriction()
      if has_restriction then
	 l.move(rows-2, cols - #has_restriction-2)
	 local color
	 if #package_list == 0 then
	    color = colors.nomatch
	 elseif all_series then
	    color = colors.all
	 else
	    color = colors.highlight
	 end
	 l.attron(color)
	 l.addstr(has_restriction)
	 l.attroff(color)
	 l.attron(colors.main)
      end
   end

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
	 l.move(1, 9)
	 l.clrtoeol()
	 l.move(1, cols-1)
	 l.addch(b.vline)
	 l.move(1, cols-10)
	 l.addnstr(''..package_cursor..'/'..#package_list, 9)
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
	 l.move(1, 9)
	 local descrs=tagset.category_description[tuple.category]
	 l.addnstr(tuple.category ..
		      (descrs and (' - '..descrs.short) or ''), cols - 10)
      else
	 l.addnstr(package_window, outstr, cols-4)
      end
   end

   local function redraw_package_list()
      if not package_window then
	 package_window = l.newwin(subwin_lines, cols-2, 3, 1)
	 l.bkgd(package_window, l.color_pair(1))
      end
      local cursor = package_cursor
      viewport_top = package_cursor - half_subwin
      if viewport_top < 1 then viewport_top = 1 end
      local top = viewport_top
      for i=1,subwin_lines do
	 local selected = top+i-1
	 local tuple=package_list[selected]
	 if not tuple then break end
	 draw_package(tuple, i-1, package_cursor == selected)
	 cursor = cursor+1
      end
      if #package_list == 0 then
	 l.move(package_window, half_subwin, cols/2 - 8)
	 l.addstr(package_window, "* NO PACKAGES *")
      end
      show_restriction()
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
      l.addstr('Series:')
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

   local function select_restrict(restriction, all_series)
      if not restriction then
	 if has_restriction then
	    has_restriction = nil
	    package_list = tagset.categories[series_sorted[current_series]]
	    repaint()
	 end
	 return
      end

      package_list = {}
      local series_set =
	 all_series and series_sorted or { series_sorted[current_series] }
      if pcall(string.find, '', restriction) then
	 for _, series in ipairs(series_set) do
	    local cat = tagset.categories[series]
	    for _, tuple in ipairs(cat) do
	       if tuple.tag:find(restriction) then
		  table.insert(package_list, tuple)
	       end
	    end
	 end
      end
      has_restriction = restriction
      repaint()
   end

   local function select_series(new_series)
      if has_restriction then select_restrict(false) end
      if new_series ~= current_series then
	 if current_series then
	    package_cursors[current_series] = package_cursor
	 end
	 package_cursor = package_cursors[new_series] or 1
	 package_list = tagset.categories[series_sorted[new_series]]
	 current_series = new_series
	 repaint()
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

   local function do_editor()
      select_series(tagset.current_series or 1)
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
	    viewport_tops = {}
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
	 -- Restriction
	 elseif key == k.escape then
	    select_restrict()
	 elseif key == k.unitsep then
	    if (has_restriction) then
	       all_series = not all_series
	       select_restrict(has_restriction, all_series)
	    end
	 elseif key >= 32 and key <= 126 then
	    if not has_restriction then
	       has_restriction=''
	       all_series = nil
	    end
	    if #has_restriction < 16 then
	       has_restriction = has_restriction..char
	       select_restrict(has_restriction, all_series)
	    end
	 elseif delete_keys[key] then
	    if has_restriction and #has_restriction > 0 then
	       has_restriction = has_restriction:sub(1, -2)
	       select_restrict(has_restriction, all_series)
	    end
	 -- Navigation
	 elseif key == k.right then
	    if current_series < #series_sorted then
	       select_series(current_series+1)
	    end
	 elseif key == k.left then
	    if current_series > 1 then
	       select_series(current_series-1)
	    end
	 elseif char == '<' then
	    select_series(1)
	 elseif char == '>' then
	    select_series(#series_sorted)
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
		  show_restriction()
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
		  show_restriction()
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
   colors.all = colors.OPT
   colors.main= bit.bor(l.color_pair(1), a.bold)
   l.bkgd(colors.main)
   l.attron(colors.main)
   l.refresh()
   local result={pcall(do_editor)}
   select_restrict(false)
   l.endwin()
   if not result[1] then print(unpack(result)) end
   tagset.current_series = current_series
   package_cursors[current_series] = package_cursor
   print 'Editor finished'
end
