
class ExportToGitPatchHandler < PatchHandler

  def initialize(gitrepo, patch_name, logger, skip_binaries, authors)
    @added = []
    @renamed = {}
    @deleted = []
    @logger = logger
    @gitrepo = gitrepo
    @patch_name = patch_name
    @skip_binaries = skip_binaries
    @authors = authors
  end

  def metadata author, short_msg, long_msg, timestamp, inverted
    @author = author
    @git_message = ("#{short_msg}\n#{long_msg}\n\n" + 
      "Exported from Darcs patch: #{@patch_name}").gsub(/[']/, '"')
    @timestamp = timestamp
    @inverted = inverted
  end

  def addfile file
    @added << file
    log "adding file #{file}"
    FileUtils.touch("#{@gitrepo}/#{file}")
  end

  def adddir dir
    @added << dir
    log "adding dir '#{dir}'"
    Dir.mkdir "#{@gitrepo}/#{dir}"
  end

  def move file, to
    # Apparently darcs thinks is a good idea to add and then
    # move a file in the same patch. Before we attempt to move
    # a file that's not yet on disk, let's just simply remove
    # the name from 'added_files' if it's there, and replace
    # it with the new name.
    File.rename "#{@gitrepo}/#{file}", "#{@gitrepo}/#{to}"
    if @added.include? file
      @added.delete(file)
    end
    @added << to
    @renamed[file] = to
  end

  def hunk file, line_number, inserted_lines, deleted_lines
    if File.exists?("#{@gitrepo}/#{file}")
      orig_lines = read_original_file(file)
      orig_lines_index = line_number - 1

      deleted_lines.size.times {|i| orig_lines.delete_at orig_lines_index}
      orig_lines.insert(orig_lines_index, inserted_lines)
      orig_lines.flatten!
      
      out_file = File.new("#{@gitrepo}/#{file}", "w")
      begin
        orig_lines.each do |orig_line|
          out_file.write orig_line
        end
      ensure
        out_file.close
      end
    else
      log "WARN: attempt to apply hunk to non-existing file #{file}"
      if inserted_lines.size == 0
        log "No lines were inserted"
      else
        raise "lines were supposed to be inserted - something bad has happened"
      end
    end
  end

  def changepref 
    # do nothing.  No equivalent exists in Git
  end

  def rmfile file
    @deleted << file
    log "removing file '#{file}'"
    if File.exists? "#{@gitrepo}/#{file}"
      File.delete "#{@gitrepo}/#{file}"
    else
      log "file did not exist, this may be an error but its valid for " +
        "two patches to remove the same file and not conflict"
    end
    # weird, I know but darcs will happily create, edit, move and then
    # destroy a file all in the same patch.  So we need to remove the file
    # from the 'add' list.
    @added.delete(file)
    @renamed.delete(@renamed.invert[file])
  end

  def rmdir dir
    FileUtils.rm_rf "#{@gitrepo}/#{dir}"
  end

  def binary file, datastream
    if @skip_binaries
      log "NOT writing binary file #{file}, skipping"
    else
      log "writing binary file #{file}"
    end
  end

  def merger
    # do nothing (the parser currently skips over them)
  end

  def replace file, regexp, oldtext, newtext
    command = "sed -i 's/#{oldtext}/#{newtext}/g' #{@gitrepo}/#{file}"
    Open3.popen3("(#{command})") do |sin,sout,serr|
      log "executing command '#{command}'"
      sinlines = sout.readlines
      serrlines = serr.readlines
      if serrlines.size > 0
        serrlines.each {|line| $stderr.puts line }
        raise  "error executing command '#{command}'"
      end
    end
  end

  def skip_binaries?
    @skip_binaries
  end

  def finished
    @renamed.keys.each_slice(80) {|files| run_git "add -u #{(files.map{|file| "'#{file}'"}).join(" ")}"}
    @renamed.values.each_slice(80) {|files| run_git "add #{(files.map{|file| "'#{file}'"}).join(" ")}"}
    @added = @added - @deleted
    @added.each_slice(80) {|files| run_git "add #{(files.map {|file| "'#{file}'"}).join(" ")}"}
    # Darcs deletes a file by creating a hunk that removes all the lines
    # then deletes the file.  In that case we want no files in the changed list
    # that are in the deleted list, or we will break Git.
    run_git "add -u"  # take care of changed and deleted files
    run_git "commit -m '#{@git_message}' --author \"#{@authors.get_email(@author)}\""
  end

  private
  def run_git(command)
    Open3.popen3("(cd #{@gitrepo} && git #{command})") do |sin,sout,serr|
      log "executing command '#{command}'"
      sinlines = sout.readlines
      serrlines = serr.readlines
      if serrlines.size > 0
        serrlines.each {|line| $stderr.puts line }
        log "in patch #{@current_patch}"
        raise "executing command '#{command}'"
      end
    end
  end

  def log(msg)
    @logger.log(msg)
  end

  def read_original_file(file)
    in_file = File.new("#{@gitrepo}/#{file}", "r")
    origin_lines = nil
    begin
      orig_lines = in_file.readlines
    ensure
      in_file.close
    end
    orig_lines
  end
end

