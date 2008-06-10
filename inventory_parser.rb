# This class was taken from the darcs-ruby project.
# This class holds the patch's name, log, author, date, and other
# meta-info.
class InventoryParser 
  def initialize(date, name, author, log = nil, inverted = false)
    if date.kind_of?(String)
      @date = parse_date(date)
    else
      @date = date
    end
    @name = name
    @author = author
    @log = log
    @inverted = inverted
  end

  attr_reader :date, :name, :author, :log
  def inverted?
    @inverted
  end

  # Reads a patch from a stream using the inventory format
  def self.read(f)
    header_regexp = 
    /^\[([^\n]+)\n([^\*]+)\*([-\*])(\d{14})(?:\n((?:^\ [^\n]*\n)+))?\]/     

    lines = f.readline
    until match_data = header_regexp.match(lines)
      lines += f.readline
    end

    short_message = $1
    author_email = $2
    inverted = $3 == "-" ? true : false
    date = $4
    long_message = $5
    if long_message
      stripped = ""
      long_message.each_line {|l| stripped += l[1..-1] }
      long_message = stripped
    end
    length_of_match = match_data[0].size
    # push the remaining part of the last 10 lines back onto the stream.
    lines[length_of_match..-1].reverse.each_byte {|b| f.ungetc b}

      puts "author: '#{author_email}'\nshort: '#{short_message}'\n" + 
        "date: '#{date}'\nlong: '#{long_message}'\ninverted: '#{inverted}'"

    return self.new(date, short_message, author_email, long_message)
  end

  # Retrieve the patch's date in string timestamp format
  def timestamp
    date.strftime("%Y%m%d%H%M%S") 
  end

  # Retrieve the patch's name
  def filename
    author_hash = SHA1.new(author).to_s[0..4]
    hash = SHA1.new(name + author + timestamp +
                    (log.nil? ? '' : log.gsub(/\n/, '')) +
                    (inverted? ? 't' : 'f'))
    "#{timestamp}-#{author_hash}-#{hash}.gz"
  end

  def to_s
    if log
      the_log = log.gsub(/[\n\s]+$/, '').gsub(/\n/, "\n ")
    end
    "[#{name}\n#{author}**#{timestamp}" +
    (log.nil? ? '' : "\n " + the_log + "\n") + "]"
  end

protected
  def parse_date(str)
    # Format is YYYYMMDDHHMMSS
    Time.gm(str[0..3].to_i, str[4..5].to_i, str[6..7].to_i, str[8..9].to_i,
            str[10..11].to_i, str[12..13].to_i)
  end
end

