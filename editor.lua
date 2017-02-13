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
   local rows, cols, subwin_lines
   local series_sorted = {}
   local _
   for k in pairs(tagset.categories) do table.insert(series_sorted, k) end
   table.sort(series_sorted)
   local current_series
   local category
   local packages_window
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
   local anchor
   local searchpat=''
   local search_nomatch

   local function show_series()
      l.move(1, 9)
      l.clrtoeol()
      l.move(1, cols-1)
      l.addch(b.vline)
      l.move(1, 9)
      local name = series_sorted[current_series]
      local descrs = tagset.category_description[name]
      l.addnstr(name.. (descrs and (' - '..descrs.short) or ''), cols - 10)
      l.noutrefresh()
   end

   local function draw_package(tuple, line, selected)
      l.move(packages_window, line, 0)
      l.clrtoeol(packages_window)
      local outstr = tagformat:format(tuple.tag)
      if tuple.shortdescr then
	 outstr = outstr..' - '..tuple.shortdescr
      end
      l.attron(packages_window, colors[tuple.state])
      l.addstr(packages_window, state_signs[tuple.state])
      l.attroff(packages_window, colors[tuple.state])
      if tuple.state == tuple.old_state then
	 l.addstr(packages_window, ' ')
      else
	 l.attron(packages_window, colors[tuple.old_state])
	 l.addch(packages_window, b.diamond)
	 l.attroff(packages_window, colors[tuple.old_state])
      end
      if selected then
	 l.attron(packages_window, colors.highlight)
	 local outmax=cols-4
	 if state ~= 'search' or search_nomatch then
	    l.addnstr(packages_window, outstr, outmax)
	 else
	    local first, rest
	    if anchor then
	       first, rest = '',outstr:sub(#searchpat+1)
	    else
	       local start, finish = outstr:find(searchpat, 1, true)
	       first, rest = outstr:sub(1,start-1),outstr:sub(finish+1,-1)
	    end
	    l.addnstr(packages_window, first, outmax)
	    local outmax = outmax - #first
	    if outmax > 0 then
	       l.attron(packages_window, a.standout)
	       l.addnstr(packages_window, searchpat, outmax)
	       l.attroff(packages_window, a.standout)
	       outmax = outmax - #searchpat
	       if outmax > 0 then
		  l.addnstr(packages_window, rest, outmax)
	       end
	    end
	 end
	 l.attroff(packages_window, colors.highlight)
	 l.move(1, cols-10)
	 l.addnstr(''..package_cursor..'/'..#category, 9)
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
	 if #searchpat > 0 then
	    l.move(rows-2, cols - #searchpat - 2)
	    local standout =
	       search_nomatch and colors.nomatch or colors.pattern
	    l.attron(standout)
	    l.addstr(searchpat)
	    l.attroff(standout)
	    l.attron(colors.main)
	 end
      else
	 l.addnstr(packages_window, outstr, cols-4)
      end
   end

   local function redraw_package_list()
      if not packages_window then
	 packages_window = l.newwin(subwin_lines,cols-2,3,1)
	 l.bkgd(packages_window, l.color_pair(1))
      end
      local cursor = package_cursor
      viewport_top = package_cursor - subwin_lines / 2
      if viewport_top < 1 then viewport_top = 1 end
      local top = viewport_top
      for i=1,subwin_lines do
	 local tuple=category[top+i-1]
	 if not tuple then break end
	 draw_package(tuple, i-1, package_cursor == top+i-1)
	 cursor = cursor+1
      end
      l.noutrefresh(packages_window)
   end

   local function draw_description()
      local descr_lines = show_descr and show_descr() or {}
      if not descr_window then
	 descr_window = l.newwin(subwin_lines,cols-2,3,1)
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
      show_series()
      l.move(rows-3,0)
      l.addch(b.ltee)
      l.hline(b.hline, cols-2)
      l.move(rows-3,cols-1)
      l.addch(b.rtee)
      if packages_window then
	 l.delwin(packages_window)
	 packages_window = nil
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

   local function select_series(new_series)
      if new_series ~= current_series then
	 if current_series then
	    package_cursors[current_series] = package_cursor
	 end
	 package_cursor = package_cursors[new_series] or 1
	 category = tagset.categories[series_sorted[new_series]]
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
	 repaint()
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
	 elseif state == 'search' then
	    if key == 27 then
	       state = nil
	       searchpat=''
	       repaint()
	       goto continue
	    elseif char == '^' then
	       anchor = not anchor
	    elseif delete_keys[key] then
	       if #searchpat > 0 then
		  searchpat = searchpat:sub(1,-2)
	       end
	    elseif key == k.down then
	    elseif key == k.up then
	    elseif key == k.home then
	    elseif char and search_char[char] and #searchpat < searchmax then
	       searchpat = searchpat..char
	    end
	    redraw_package_list()
	    -- incremental char
	 end
	 if key == k.ctrl_l then
	    repaint()
	 elseif char == '/' then
	    state = 'search'
	 -- Show description
	 elseif char == 'd' then
	    state = 'describe'
	    show_descr = category[package_cursor].description
	    repaint()
	 -- Navigation
	 elseif key == k.right then
	    if current_series < #series_sorted then
	       select_series(current_series+1)
	    end
	 elseif key == k.left then
	    if current_series > 1 then
	       select_series(current_series-1)
	    end
	 elseif key == k.home then
	    package_cursor = 1
	    repaint()
	 elseif key == k['end'] then
	    package_cursor = #category
	    repaint()
	 elseif key == k.down then
	    if package_cursor < #category then
	       package_cursor = package_cursor+1
	       if package_cursor == viewport_top + subwin_lines then
		  repaint()
	       else
		  draw_package(category[package_cursor-1],
			       package_cursor-viewport_top-1, false)
		  draw_package(category[package_cursor],
			       package_cursor-viewport_top, true)
		  l.noutrefresh(packages_window)
	       end
	    end
	 elseif key == k.up then
	    if package_cursor > 1 then
	       package_cursor = package_cursor - 1
	       if package_cursor < viewport_top then
		  repaint()
	       else
		  draw_package(category[package_cursor+1],
			       package_cursor-viewport_top+1, false)
		  draw_package(category[package_cursor],
			       package_cursor-viewport_top, true)
		  l.noutrefresh(packages_window)
	       end
	    end
	 elseif key == k.page_down then
	    if package_cursor < #category then
	       package_cursor = package_cursor + subwin_lines / 2
	       if package_cursor > #category then
		  package_cursor = #category
	       end
	       repaint()
	    end
	 elseif key == k.page_up then
	    if package_cursor > 1 then
	       package_cursor = package_cursor - subwin_lines / 2
	       if package_cursor < 1 then
		  package_cursor = 1
	       end
	       repaint()
	    end
	 elseif char == '<' then
	    select_series(1)
	 elseif char == '>' then
	    select_series(#series_sorted)
	 elseif char == '+' then
	    change_state(category[package_cursor], 'ADD',
			 package_cursor-viewport_top)
	 elseif char == '-' then
	    change_state(category[package_cursor], 'SKP',
			 package_cursor-viewport_top)
	 elseif char == 'o' then
	    change_state(category[package_cursor], 'OPT',
			 package_cursor-viewport_top)
	 elseif char == 'r' then
	    change_state(category[package_cursor], 'REC',
			 package_cursor-viewport_top)
	 elseif char == '=' then
	    change_state(category[package_cursor],
			 category[package_cursor].old_state,
			 package_cursor-viewport_top)
	 elseif char == ' ' then
	    change_state(category[package_cursor], nil,
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
   colors.pattern = colors.OPT
   colors.nomatch = colors.SKP
   colors.main= bit.bor(l.color_pair(1), a.bold)
   l.bkgd(colors.main)
   l.attron(colors.main)
   l.refresh()
   local result={pcall(do_editor)}
   l.endwin()
   if not result[1] then print(unpack(result)) end
   tagset.current_series = current_series
   package_cursors[current_series] = package_cursor
   print 'Editor finished'
end
