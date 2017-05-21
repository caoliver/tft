function cleanuppath(path)
   if not path then error('Invalid path: '..tostring(path)) end
   local stack = {}
   local first,rest=path:match('([^/]*/?)(.*)')
   local anchored = first == '/'
   local backcount = 0
   if first == '..' or first == '../' then backcount = 1 end
   table.insert(stack, first)
   for part in string.gmatch(rest, '([^/]*/?)') do
      if #part > 0 and part ~= '/' and part ~= './' then
	 if part ~= '..' and part ~= '../' then
	    table.insert(stack,part)
	 elseif anchored or #stack > backcount then
	    if #stack > 1 then table.remove(stack, #stack) end
	 else
	    table.insert(stack, '../')
	    backcount = backcount + 1
	 end
      end
   end
   if #stack > 1 or #stack[1] > 1 then
      local first=stack[#stack]:match('^(.*)/')
      if first then stack[#stack] = first end
   end
   return table.concat(stack, '')
end
