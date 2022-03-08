function getch(prompt, pattern, default)
   local ch
   repeat
      io.write(prompt)
      io.flush()
      ch = util.getchar()
      local outch = '...'
      if #ch == 1 then
	 local byte = string.byte(ch)
	 if byte >= 32 and byte < 127 then outch = ch
	 elseif ch == '\n' or ch == '\4' then outch = ''
	 end
      end
      print(outch)
   until not pattern or ch:match(pattern)
   return ch == '\n' and default or ch
end
