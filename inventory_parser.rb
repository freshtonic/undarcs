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
    line = f.gets
    return nil if line.nil?
    if line[0..0] != '['
      raise "Invalid inventory entry (starts with \"#{line[0..-2]}\")"
    end

    name = line[1..-2]
    line = f.readline
    raise "Invalid inventory entry '#{line}'" if !line[/^(.*)\*(\*|\-)([0-9]{14})\]?\s*$/]
    author = $1
    date = $3
    log = nil
    if !line[/\]\s*$/]
      log = ""
      log += line[1..-1] while !((line = f.readline) =~ /^\]/)
    end

    return self.new(date, name, author, log)
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

