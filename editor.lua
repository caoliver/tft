--[[
-- Simple debug output to other screen when ncurses is active.

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

local l = ljcurses
local a = l.attributes
local b = l.boxes
local k = l.keys
local state_signs = { SKP='-', ADD='+', OPT='o', REC=' ' }
local excluded_char = make_char_bool '[]<>/? '
local escapemap = {
   a='M-a', o='M-o', r='M-r', R='M-R', s='M-s', C='M-C', M='M-M',
   l='M-l', L='M-L', x='M-x', n='M-n', N='M-N', ['\14']='M-^N',
   d='M-d', ['\12']='M-^L', u='M-u'
}
local constrain_state_commands={
   ['M-a']='ADD', ['M-o']='OPT', ['M-r']='REC', ['M-s']='SKP',
   ['M-R']='REQ', ['M-C']='CHG', ['M-M']='MIS'
}
local constraint_special_flags = {}
local constraint_special_flag_names = { 'CHG', 'REQ', 'MIS' }
do
   local power=1
   for _, name in ipairs(constraint_special_flag_names) do
      constraint_special_flags[name] = power
      power = 2 * power
   end
end

local scroll_keys={
   KEY_HOME=true, KEY_END=true,
   KEY_UP=true, KEY_DOWN=true,
   KEY_NPAGE=true, KEY_PPAGE=true
}

local function assert(bool, ...)
   if not bool then l.endwin() end
   return _G.assert(bool, ...)
end

function edit_tagset(tagset, installation)
   assert(tagset.type == 'tagset', 'Self is not a tagset')
   assert(not installation or installation.type == 'installation',
	  'Argument is not an installation')
   if installation == false then
      tagset.installation = nil
   elseif installation then
      tagset.installation = installation
   else
      installation = tagset.installation
   end
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
   local skip_set = tagset.skip_set
   if skip_set and skip_set[categories_sorted[current_category]] then
      current_category = nil
      for i,catname in ipairs(categories_sorted) do
	 if not skip_set[catname] then
	    current_category = i
	    break
	 end
      end
      if not current_category then
	 print 'All categories inhibited.  Goodbye!'
	 return
      end
      last_package = tagset.categories[categories_sorted[current_category]]
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
   local constraint_bits = 0
   local only_required = false
   local package_window
   local reportview_lines
   local reportview_color
   local reportview_head
   local descr_window
   local special_window
   local rows, cols, subwin_lines, half_subwin
   local installed = installation and installation.tags or {}

   local function activate_reportview()
      reportview_lines = { '' }
      reportview_color = colors.report
      reportview_head = 1
   end

   local function redraw_reportview()
      if not reportview_window then
	 reportview_window = l.newwin(subwin_lines, cols-2, 3, 1)
	 l.bkgd(reportview_window, reportview_color)
      end
      l.move(reportview_window, 0, 0)
      l.clrtobot(reportview_window)
      local cursor = reportview_head
      for line = 0, subwin_lines-1 do
	 if not reportview_lines[cursor] then break end
	 l.move(reportview_window, line, 1)
	 l.addnstr(reportview_window, reportview_lines[cursor], cols-4)
	 cursor = cursor+1
      end
      l.noutrefresh(reportview_window)
   end

   local function deactivate_reportview()
      reportview_lines = nil
   end

   local function add_to_reportview(text)
      if not reportview_window then
	 redraw_reportview()
      end
      if text then
	 reportview_lines[#reportview_lines] =
	    reportview_lines[#reportview_lines]..text
      else
	 table.insert(reportview_lines, '')
      end
      local minhead = #reportview_lines - subwin_lines + 1
      if reportview_head >= minhead then
	 local where = #reportview_lines - reportview_head
	 l.move(reportview_window, where, 1)
	 l.clrtoeol(reportview_window)
	 l.addnstr(reportview_window, reportview_lines[#reportview_lines],
		   cols-4)
	 l.noutrefresh(reportview_window)
      elseif minhead == reportview_head + 1 then
	 reportview_head = minhead
	 l.move(reportview_window, 0, 0)
	 l.insdelln(reportview_window, -1)
	 l.move(reportview_window, subwin_lines-1, 0)
	 l.addnstr(reportview_window, reportview_lines[#reportview_lines],
		   cols-4)
	 l.noutrefresh(reportview_window)
      else
	 reportview_head = minhead
	 l.move(reportview_window, 0, 0)
	 l.clrtobot(reportview_window)
	 redraw_reportview()
      end
   end

   local get_constraint_flag_string
   do
      local constraint_flag_string = ''
      local last_flag_count = 0
      local last_constraint_bits = 0
      get_constraint_flag_string = function ()
	 if last_flag_count ~= constraint_flags_set
	 or last_constraint_bits ~= constraint_bits then
	    if constraint_flags_set > 0 or constraint_bits > 0 then
	       local newcfs = ' ['
	       for _,flag in ipairs { 'ADD', 'OPT', 'REC', 'SKP' } do
		  if constraint_flags[flag] then
		     newcfs = newcfs..
			({ADD='a',OPT='o',REC='r',SKP='s'})[flag]
		  end
	       end
	       for _, bitname in ipairs(constraint_special_flag_names) do
		  if not constraint_special_flags[bitname] then
		     l.endwin()
		     print(bitname)
		     os.exit(0)
		  end
		  if bit.band(constraint_bits,
			      constraint_special_flags[bitname]) ~= 0 then
		     newcfs = newcfs..bitname:sub(1,1)
		  end
	       end
	       constraint_flag_string = newcfs..']'
	    else
	       constraint_flag_string = ''
	    end
	    last_flag_count = constraint_flags_set
	    last_constraint_bits = constraint_bits
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

   local function draw_package_line(tuple, line, selected)
      local outstr = tagformat:format(tuple.tag)
      local outmax=cols-4
      l.move(package_window, line, 0)
      l.clrtoeol(package_window)
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
      if installation and not installed[tuple.tag] then
	 outstr = outstr:sub(1,#outstr-1)
	 outmax = outmax - 1
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
   
   local function draw_package_top_win(tuple)
      local outstr
      local outmax=cols-4
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
			  tuple.tag, tuple.version, tuple.arch,
			  tuple.build, tuple.state)
      else
	 pkgdescr =
	    string.format('%s  state: %s', tuple.tag, tuple.state)
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
			     installed.tag, installed.version,
			     installed.arch, installed.build)
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
   end

   local function draw_package(tuple, line, selected)
      draw_package_line(tuple, line, selected)
      if selected then
	 draw_package_top_win(tuple)
      end
   end
   
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
	 local msg = "* NO PACKAGES *"
	 l.move(package_window, half_subwin, cols/2 - #msg/2)
	 l.addstr(package_window, msg)
      end
      show_constraint()
      l.noutrefresh(package_window)
   end

   local function show_description(description)
      local descr_lines = description and description()
      activate_reportview()
      add_to_reportview(tostring(description))
      add_to_reportview()
      if descr_lines then
	 for i, line in ipairs(descr_lines) do
	    if i > 1 then add_to_reportview() end
	    add_to_reportview(line)
	 end
      else
	 add_to_reportview('Sorry!  I can\'t find this description.')
      end
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
      redraw_package_list()
      if reportview_lines then
	 if #package_list then
	    draw_package_top_win(package_list[package_cursor])
	 end
	 if reportview_window then
	    l.delwin(reportview_window)
	    reportview_window = nil
	 end
	 redraw_reportview()
      else
	 if package_window then
	    l.delwin(package_window)
	    package_window = nil
	 end
	 redraw_package_list()
      end
   end

   -- Constraint stuff
   local function clear_constraint()
      if current_constraint then
	 current_constraint = nil
	 constraint_flags = {}
	 constraint_flags_set = 0
	 constraint_bits = 0
	 -- Cached status string may be invalid, so refresh it.
	 get_constraint_flag_string()
	 if #package_list > 0 then
	    last_package = package_list[package_cursor]
	 else
	    assert(last_package, "last_package not assigned")
	 end
	 current_category = category_index[last_package.category]
	 package_cursor = last_package.category_index
	 package_list = tagset.categories[last_package.category]
      end
   end

   local function match_constraint(tuple, constraint)
      if skip_set and skip_set[tuple.category] then return end
      if bit.band(constraint_bits, constraint_special_flags.REQ) ~= 0
      and not tuple.required then return end
      if bit.band(constraint_bits, constraint_special_flags.CHG) ~= 0
      and tuple.state == tuple.old_state then return end
      if bit.band(constraint_bits, constraint_special_flags.MIS) ~= 0
      and installation and installation.tags[tuple.tag] then return end

      if constraint_flags_set > 0 and not constraint_flags[tuple.state] then
	 return
      end
      -- Case insensitive match
      return tuple.tag:lower():find(constraint:lower())
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
      if constraint_special_flags[flag] then
	 constraint_bits = bit.bxor(constraint_bits,
				    constraint_special_flags[flag])
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

   local function find_new_category(start, finish)
      local function select_category(new_category)
	 local save_package = last_package
	 if #package_list > 0 then
	    save_package = package_list[package_cursor]
	 end
	 if new_category ~= current_category then
	    package_cursors[current_category] = save_package.category_index
	    package_cursor = package_cursors[new_category] or 1
	    package_list = tagset.categories[categories_sorted[new_category]]
	    current_category = new_category
	 end
	 repaint()
      end

      if not categories_sorted[start] then return end
      if not skip_set then
	 select_category(start)
      else
	 local bump = start < finish and 1 or -1
	 for new_category=start,finish,bump do
	    if not skip_set[categories_sorted[new_category]] then
	       select_category(new_category)
	       break
	    end
	 end
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

   local function confirm(prompt, pattern, default)
      local char, key, _
      repeat
	 local row, col = add_to_reportview(prompt)
	 l.doupdate()
	 while true do
	    key = l.getch()
	    if key >= 0 then break end
	    util.usleep(1000)
	 end
	 if key == k.resize or key == k.ctrl_c then
	    add_to_reportview()
	    return default or ''
	 end
	 char = key >= 0 and key < 128 and string.char(key) or ''
	 if key > 32 and key < 127 and #prompt < cols-3 then
	    add_to_reportview(char)
	 end
	 add_to_reportview()
      until not pattern or char:match(pattern)
      l.doupdate()
      return char == '\n' and default or char
   end

   local function load_package(overwrite)
      local function print(...)
	 local lineout = ''
	 for i=1,select('#', ...) do
	    if i > 1 then
	       lineout = lineout..('        '):sub(1 + #lineout % 8)
	    end
	    lineout = lineout..tostring(select(i, ...))
	 end
	 add_to_reportview(lineout)
	 add_to_reportview()
      end

      if #package_list > 0 then
	 activate_reportview()
	 repaint()
	 local conflicts
	 local now = util.realtime()
	 local tuple = package_list[package_cursor]
	 local file = string.format('%s/%s-%s-%s-%s',
				    tuple.category,
				    tuple.tag,
				    tuple.version,
				    tuple.arch,
				    tuple.build)
	 if tuple.arch == 'noarch' then
	    add_to_reportview('Skipping NOARCH package '..file)
	    l.doupdate()
	 else
	    local filepath=tagset.directory..'/'..file
	    if not tagset.package_cache or overwrite then
	       add_to_reportview('Loading package '..file)	
	       add_to_reportview()
	       l.doupdate()
	       tagset.packages_loaded = { [tuple] = true }
	       tagset.package_cache =
		  read_archive(filepath, print, confirm)
	    else
	       add_to_reportview('Loading additional package '..file)
	       add_to_reportview()
	       l.doupdate()
	       tagset.packages_loaded[tuple] = true
	       conflicts = tagset.package_cache:extend(filepath, print,
						       confirm)
	    end
	 end
	 if conflicts then
	    add_to_reportview ''
	    add_to_reportview 'Hit any non-scroll key to continue'
	 else
	    local elapsed = util.realtime() - now
	    if elapsed < 1 then util.usleep(1000000 * (1 - elapsed)) end
	    deactivate_reportview()
	    repaint()
	 end
      end
   end

   local function report_sorted_keys(tbl, extractor, printer,
				     singular, plural, rest)
      if not extractor then extractor = function (x) return x end end
      if not printer then printer = add_to_reportview end
      activate_reportview()
      local sorted = {}
      for key in pairs(tbl) do table.insert(sorted, extractor(key)) end
      table.sort(sorted)
      add_to_reportview(''..#sorted..' ')
      add_to_reportview(#sorted == 1 and singular or plural)
      add_to_reportview(rest            )
      add_to_reportview()
      for _,item in ipairs(sorted) do
	 add_to_reportview()
	 add_to_reportview('    ')
	 printer(item)
      end
      repaint()
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
	 if key == k.escape and escapemap[suffix] then
	    key = -1
	    char = escapemap[suffix]
	 end
	 if key == k.ctrl_l then
	    repaint()
	    goto continue
	 end
	 if not scroll_keys[char] and reportview_lines then
	    deactivate_reportview()
	    repaint()
	    goto continue
	 end
	 if char == 'M-u' then
	    tagset.show_uncompressed_size = not tagset.show_uncompressed_size
	    tagset:reset_descriptions()
	 -- Navigation
	 elseif char == 'KEY_RIGHT' then
	    clear_constraint()
	    find_new_category(current_category+1, #categories_sorted)
	 elseif char == 'KEY_LEFT' then
	    clear_constraint()
	    find_new_category(current_category-1, 1)
	 elseif char == '<' then
	    clear_constraint()
	    find_new_category(1,#categories_sorted)
	 elseif char == '>' then
	    clear_constraint()
	    find_new_category(#categories_sorted, 1)
	 elseif char == 'KEY_HOME' then
	    if reportview_lines then
	       reportview_head = 1
	    else
	       package_cursor = 1
	    end
	    repaint()
	 elseif char == 'KEY_END' then
	    if not reportview_lines then
	       package_cursor = #package_list
	    elseif #reportview_lines >= subwin_lines then
	       reportview_head = #reportview_lines - subwin_lines + 1
	    end
	    repaint()
	 elseif char == 'KEY_DOWN' then
	    if reportview_lines then
	       if reportview_head <= #reportview_lines - subwin_lines then
		  l.move(reportview_window, 0, 0)
		  l.insdelln(reportview_window, -1)
		  l.move(reportview_window, subwin_lines - 1, 1)
		  reportview_head = reportview_head + 1
		  l.addnstr(reportview_window,
			    reportview_lines[reportview_head+subwin_lines-1],
			    cols-4)
		  l.noutrefresh(reportview_window)
	       end

	    elseif package_cursor < #package_list then
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
	    if reportview_lines then
	       if reportview_head > 1 then
		  l.move(reportview_window, 0, 1)
		  l.insdelln(reportview_window, 1)
		  reportview_head = reportview_head - 1
		  l.addnstr(reportview_window,
			    reportview_lines[reportview_head],
			    cols-4)
		  l.noutrefresh(reportview_window)
	       end
	    elseif #package_list > 0 and package_cursor > 1 then
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
	    if reportview_lines then
	       local maxhead = #reportview_lines - subwin_lines + 1
	       if maxhead < 1 then maxhead = 1 end
	       reportview_head = reportview_head + half_subwin
	       if reportview_head > maxhead then reportview_head = maxhead end
	       redraw_reportview()
	    elseif #package_list > 0 and package_cursor < #package_list then
	       package_cursor = package_cursor + half_subwin
	       if package_cursor > #package_list then
		  package_cursor = #package_list
	       end
	       repaint()
	    end
	 elseif char == 'KEY_PPAGE' then
	    if reportview_lines then
	       reportview_head = reportview_head - half_subwin
	       if reportview_head < 1 then reportview_head = 1 end
	       redraw_reportview()
	    elseif package_cursor > 1 then
	       package_cursor = package_cursor - half_subwin
	       if package_cursor < 1 then
		  package_cursor = 1
	       end
	       repaint()
	    end
	 -- Show description
	 elseif key == k.ctrl_d then
	    if #package_list > 0 then
	       show_description(package_list[package_cursor].description)
	       repaint()
	    end
	 elseif char == 'M-d' then
	    -- Does the installation description ever change between releases?
	    if #package_list > 0 and installation then
	       local entry =
		  installation.tags[package_list[package_cursor].tag]
	       if entry then
		  show_description(entry.description)
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
	 -- Help
	 elseif char == '?' or char == 'KEY_F(15)' then
	    activate_reportview()
	    for i, line in ipairs {
	       'Key command help','', 'TO BE DONE'
				  }
	    do
	       if i > 1 then add_to_reportview() end
	       add_to_reportview(line)
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
	 elseif char == 'M-^L' then
	    if tagset.package_cache then
	       report_sorted_keys(tagset.packages_loaded,
				  function (p) return p.tag end, nil,
				  'package', 'package', ' loaded:')
	    end
	 elseif char == 'M-x' then
	    tagset.package_cache = nil
	    tagset.packages_loaded = nil
	 elseif char == 'M-n' then
	    local cache = tagset.package_cache
	    if cache then
	       report_sorted_keys(cache.needed, nil, nil,
				  'library', 'libraries', ' needed')
	    end
	 elseif char == 'M-^N' or char == 'M-N' then
	    local cache = tagset.package_cache
	    local function needers(tag)
	       add_to_reportview(tag)
	       add_to_reportview()
	       local sorted={}
	       for key in pairs(cache.needed[tag] or {}) do
		  table.insert(sorted, key.path)
	       end
	       table.sort(sorted)
	       for _,val in ipairs(sorted) do
		  add_to_reportview '       '
		  add_to_reportview(val)
		  add_to_reportview()
	       end
	       repaint()
	    end
	    if cache then
	       activate_reportview()
	       report_sorted_keys(cache.needed, nil,
				  char == 'M-^N' and needers,
				  'library', 'libraries', ' needed')
	       if tagset.directory then
		  add_to_reportview()
		  add_to_reportview()
		  if not tagset.manifest then
		     if confirm('Read manifest for suggestions? (Y/n): ',
				'[YyNn\n]', 'y') == 'y' then
			add_to_reportview 'Reading manifest...'
			l.doupdate()
			tagset.manifest = read_manifest(tagset.directory)
			add_to_reportview 'Done!'
			add_to_reportview()
			add_to_reportview()
		     else
			add_to_reportview 'Skipping suggestions'
			l.doupdate()
			util.usleep(1000000)
			deactivate_reportview()
			repaint()
		     end
		  end
		  if tagset.manifest then
		     add_to_reportview 'Suggestions:'
		     add_to_reportview()
		     add_to_reportview()
		     local format = '  %-24s %-24s %-24s'
		     add_to_reportview('CATEGORY / PACKAGE [-- STATE]')
		     add_to_reportview()		     
		     add_to_reportview(format:format('SONAME','GUESS','STEM'))
		     add_to_reportview()
		     add_to_reportview('  '..('-'):rep(54))
		     add_to_reportview()
		     local suggestions = tagset.manifest:get_suggestions(cache)
		     for _, suggestion in ipairs(suggestions) do
			add_to_reportview()
			local tuple = tagset.tags[suggestion[1]]
			if char == 'M-^N' or tuple.state ~= 'ADD' then
			   add_to_reportview(tuple.category..' / '..
						suggestion[1])
			   if tuple.state ~= 'ADD' then
			      add_to_reportview(' -- '..tuple.state)
			   end
			   add_to_reportview()
			   for _, lib in ipairs(suggestion[2]) do
			      local outstr =
				 format:format(lib[1],lib[2],lib[3])
			      add_to_reportview(outstr)
			      add_to_reportview()
			   end
			end
		     end
		  end
	       end
	    end
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
   colors.report = bit.bor(l.color_pair(6), a.bold)
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
   l.bkgd(colors.main)
   l.attron(colors.main)
   l.refresh()
   local result={pcall(command_loop)}
   l.endwin()
   clear_constraint()
   if not result[1] and not result[2]:match ': interrupted!$' then
      print(result[2])
   end
   if not current_constraint then
      last_package = package_list[package_cursor]
   end
   tagset.last_package = last_package
   if tagset.package_cache then
      tagset.package_cache:cleanup()
   end
   print 'Editor finished'
end
