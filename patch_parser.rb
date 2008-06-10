#!/usr/bin/ruby 

=begin

darcs-fast-import: 
  convert a Darcs (Version 1) repository to Git, without invoking Darcs.

Copyright (C) 2008  James Sadler <freshtonic@gmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=end

# Parses Darcs 1 patches.
# Will not handle Darcs 2 repositories.
# NOTE: this class assumes that IO#ungetc can be invoked more than
# once (enough times to push back a line of text).  This is not 
# guaranteed by the Ruby docs, but works for me.
class DarcsPatchParser

  def initialize(instream, handler = PatchHandler.new)
    #@in = PushbackStream.new(instream)
    @in = instream
    @handler = handler
    @hunk_nesting = 0
  end

  def parse
    author, short_message, long_message, timestamp, inverted = parse_header
    @handler.metadata(author, short_message, long_message, timestamp, inverted)
    begin
      parse_body  
    rescue EOFError
      @handler.finished
    end
  end

  private 

  def fix_file_name(file)
    file.gsub(/\\32\\/, " ")
  end

  def parse_body
    # Parse  a   list  of  primitive-patches  (individual   commands  to
    # add/remove/rename files, modify content  etc. After each primitive
    # patch, invoke  the appropriate  handler method.  Primitive patches
    # may be grouped by  '{' and '}'. I think this  is what Darcs refers
    # to as  a 'compound patch'.  Not all  Darcs patches have  the curly
    # braces, and I don't know what the significance is.

    begin
      token = next_token
      if token == "{"
        @in.ungetc('{'[0])
        parse_compound_patch
      elsif token == "}"
        @in.ungetc('}'[0])
        return
      elsif token == "<"
        @in.ungetc('<'[0])
        parse_tag
      elsif token == "addfile"
        @handler.addfile fix_file_name(read_line.strip)
      elsif token == "adddir"
        @handler.adddir fix_file_name(read_line.strip)
      elsif token == "rmfile"
        @handler.rmfile fix_file_name(read_line.strip)
      elsif token == "rmdir"
        @handler.rmdir fix_file_name(read_line.strip)
      elsif token == "hunk"
        filename, line_number = read_line.strip.split(" ")
        filename = fix_file_name(filename)
        line_number = line_number.to_i
        inserted_lines, deleted_lines = parse_hunk(filename, line_number)
        @handler.hunk(filename, line_number, inserted_lines, deleted_lines)
      elsif token == "binary"
        filename = fix_file_name(read_line.strip)
        bytes = parse_binary
        @handler.binary(filename, bytes)
      elsif token == "move"
        from, to = read_line.strip.split(" ")
        from = fix_file_name(from)
        to = fix_file_name(to)
        @handler.move from, to
      elsif token == "merger"
        unread_line("merger")
        parse_merger
        @handler.merger # currently we ignore mergers
      elsif token == "changepref"
        parse_changepref
        @handler.changepref
      elsif token == "replace"
        file, regexp, to_replace, replacement = read_line.strip.split(" ")
        file = fix_file_name file
        @handler.replace(file, regexp, to_replace, replacement)
      else
        raise PatchParseException, "unexpected token '#{token}'"
      end
    end while true
  end

  def parse_compound_patch
    ch = next_token
    expect '{', ch
    @hunk_nesting += 1
    parse_body
    ch = next_token
    expect '}', ch
    @hunk_nesting -= 1
  end

  def parse_tag
    until read_line =~ /^\>/
    end
  end

  def parse_hunk filename, line_number
    line = read_line
    deleted_lines = []
    inserted_lines= []
    until !(line =~ /^([+]|[-])/)
      deleted_lines << line[1..-1] if line =~ /^[-]/
      inserted_lines << line[1..-1] if line =~ /^[+]/
      line = read_line
    end
    unread_line(line)
    return inserted_lines, deleted_lines
  end

  def parse_binary
    line = read_line
    raise PatchParseException unless line =~ /^oldhex/
    until read_line =~ /^newhex/
    end
    data = []

    until (line = read_line) =~ /^[^*]/
      if !@handler.skip_binaries?
        data_line = ""
        line[1..-1].scan(/.{2}/).each { |hex_byte| data_line += hex_byte.hex.chr }
        data << data_line
      end
    end
    unread_line(line)
    data
  end

  def parse_changepref
    # consume it only.  Not interested in the values.
    3.times {|i| read_line}
  end

  def parse_merger
    depth = 0
    begin 
      line = read_line
      if line =~ /^merger/
        depth+=1
      elsif line =~ /^\)/
        depth-=1
      end
    end while depth > 0
  end

  def expect expected_ch, actual_ch
    if expected_ch != actual_ch
      raise PatchParseException, "expected #{expected_ch}, actual '#{actual_ch}'"
    end
  end

  def next_token
    consume_ws
    token = ""
    c = @in.getc
    # why in Ruby does getc return nil if there's nothing
    # left to read, and readline raises EOFError?
    raise EOFError if c.nil?
    token += c.chr
    until c.nil? || c.chr =~ /^[\ |\t|\n]/
      c = @in.getc
      token += c.chr unless c.nil?     
    end 
    @in.ungetc(c) unless c.nil?
    token.strip
  end

  def consume_ws
    c = @in.getc
    raise EOFError if c.nil?
    until c.nil? || !(c.chr =~ /^[\ |\t|\n]/)
      c = @in.getc
    end 
    @in.ungetc(c) unless c.nil?
  end

  def read_line
    @in.readline
  end

  def unread_line line
    line.reverse.each_byte {|ch| @in.ungetc ch}
  end

  def parse_header
    # Sample header: 
    # [This is the short commit message.
    # joe.bloggs@jb.com**20080314065051
    # And this is the optional long commit message]
    #
    # HEADER -> '[' SHORT_MSG '\n' AUTHOR_EMAIL '*' INVERTED_MARKER TSTAMP ( '\n' LONG_MSG )? ']' 
    #
    # INVERTED_MARKER -> '*'|'-'
    
    # And here is the regexp to parse it
    header_regexp = 
    /^\[([^\n]+)\n([^\*]+)\*([-\*])(\d{14})(?:\n((?:^\ [^\n]*\n)+))?\]/     

    lines = read_line
    until match_data = header_regexp.match(lines)
      lines += read_line
    end

    short_message = $1
    author_email = $2
    inverted = $3 == "-" ? true : false
    timestamp = $4
    long_message = $5
    
    start_of_match, end_of_match = match_data.offset(0)
    # push the remaining part of the last 10 lines back onto the stream.
    lines[end_of_match..-1].reverse.each_byte {|b| @in.ungetc b}

    return author_email, short_message, long_message, timestamp, inverted
  end

  def expect_char(expected_ch)
    ch = @in.getc
    raise PatchParseException, "unexpected character '#{ch}' was expecting '#{expected_ch}'"  unless ch == expected_ch
    ch
  end

end

class PatchHandler
  def metadata author, short_msg, long_msg, timestamp, inverted
    puts "METADATA: author: '#{author}', short: '#{short_msg}', long: '#{long_msg}', '#{timestamp}', '#{inverted}'"
  end
  def addfile file
    puts "addfile: '#{file}'"
  end
  def adddir dir
    puts "adddir: '#{dir}'"
  end
  def move file, to
    puts "move: '#{file}' -> '#{to}'"
  end
  def hunk file, line_number, inserted_lines, deleted_lines
    puts "hunk: file: '#{file}' line: #{line_number}"
  end
  def changepref 
    puts "changepref"
  end
  def rmfile file
    puts "rmfile '#{file}'"
  end
  def rmdir dir
    puts "rmdir '#{dir}'"
  end
  def binary file, datastream
    puts "binary '#{binary}'"
  end
  def merger
    puts "merger:"
  end
  def replace file, regexp, to_replace, replacement
    puts "replace: file '#{file}' replace: '#{to_replace}' with '#{replacement}'"
  end
  def skip_binaries?
    false
  end
  def finished
  end
end

class PatchParseException < Exception 
end

