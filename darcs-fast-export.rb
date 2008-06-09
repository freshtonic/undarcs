#!/usr/bin/ruby

# Copyright (C) 2007 James Sadler <freshtonic@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

# Reads a Darcs repository one patch file at a time and 'replays' those
# patches in the order that they were applied, and capturing the changes
# after each patch application using git.
#
# At the end of the process, there should be a new git repository whose
# head is the same as the darcs pristine tree,
#
# How it works
# ------------
#
# darcs-fast-export takes each darcs  patch and follows the instructions
# contained within the patch to modify  the working tree. Once the patch
# has been successfully applied, darcs-fast-import invokes the necessary
# git commands in  order for git to  commit a patch that  makes the same
# changes to the working copy as the darcs patch.
#
# darcs-fast-export is  pretty dumb.  It doesn't understand  darcs patch
# dependencies and assumes that the patch timestamps accurately reflect
# the order the patches were created.
#
# When should you use darcs-fast-export?  When tailor or darcs2git.py do
# not work because  your repository is too big. tailor  and friends work
# by invoking darcs to pull the patches  one at a time. While this works
# for most  darcs repositories,  it doesn't  work on  large repositories
# that seem  to bring out the  worst in darcs time/space  performance. I
# found my  own repository  was unexportable  using those  tools because
# darcs would  die due to  an out  of memory error  after over a  day of
# processing time.
#

# TODO: assert that there are no untracked files after applying changes to
# the git repo.
#
# TODO: Git doesn't like empty directories, so insert a hidden 
# .darcs-fast-export file in each new dir (and add it to git).
#
# TODO: Resumability.

require 'enumerator'
require 'optparse'
require 'open3'
require 'fileutils'
require 'sha1'
require 'patch_parser'

class PatchExporter

  def initialize(args)
    @line_buf = []      # holds lines that we have unread.
    @line_number = 1    # the number of the line in the Darcs patch
                        # that we are currently parsing (starting at 1)
    @added_files = []   
    @deleted_files = []
    @renamed_files = {}
    @in = nil           # input stream for the currently parsed patch

    parse_command_line(args)
    begin
      @authors = AuthorFile.new @authorsfile
    rescue
      log "could not find authors file #{@authorsfile}"
      exit 1
    end
  end

  def generate_patch_list
    patches = []
    instream = IO.popen("cat #{@darcsrepo}/_darcs/inventory")
    begin
      log "reading patch"
      patch = PatchInfo.read(instream)
      if !patch.nil?
        patches << patch
      else
        break
      end
    rescue
      log $!.message
      exit 1
    end while true
    instream.close
    patches
  end

  def export
    patches = generate_patch_list
    log "read #{patches.size} patches from the Darcs inventory"
    patches.each do |patch|
      log "converting patch #{patch.filename}"
      @current_patch = patch.filename
      instream = IO.popen("gunzip -c #{@darcsrepo}/_darcs/patches/#{patch.filename}")
      DarcsPatchParser.new(instream, 
        ExportToGitPatchHandler.new(
          @gitrepo, @current_patch, self, @skip_binaries, @authors)).parse
    end
  end

  def parse_command_line(args)
    OptionParser.new do |options|
      options.banner = "Usage #{$0} [options]"

      options.on(
        '-a [authorfile]',
        '--authorfile [authorfile]',
        'File of DARCS_USER_NAME=Joe Blogs <joeb@somecompany.com> , one entry per line'
      ) do |authorfile|
        @authorsfile = authorfile
      end

      options.on(
        '-s [darcsrepo]',
        '--source-repo [darcsrepo]',
        'The source darcs repository'
      ) do |darcsrepo|
        @darcsrepo = darcsrepo
      end

      options.on(
        '-t [gittrepo]',
        '--target-repo [gitrepo]',
        'The target GIT repository (must already be initialised)'
      ) do |gitrepo|
        @gitrepo = gitrepo
      end

      options.on(
        '-b [skip]',
        '--skip-binaries [skip]',
        'Skips binary files (i.e. will not include them in the generated Git repo)'
      ) do |skip|
        @skip_binaries = (skip =~ /^true$/)
      end

      begin
        @skip_binaries = false
        options.parse! args
      rescue OptionParser::InvalidOption
        log "Failed to parse options(#{$!})"
        exit 1
      end

      check_arg(options, "authorfile", @authorsfile)
      check_arg(options, "source-repo", @darcsrepo)
      check_arg(options, "target-repo", @gitrepo)
    end

  end

  def check_arg(options, arg, value)
    unless value
      warn "#{arg} required"
      warn options
      exit(1)
    end
  end
  
  def log(msg)
    STDERR.puts "darcs-fast-export: #{msg}"
  end

end

class AuthorFile
  def initialize(file)
    f = File.new(file)
    lines = f.readlines
    @authors = {}
    lines.each do |line|
      key, value = line.split("=")
      @authors[key] = value.rstrip      
    end
    f.close
  end

  def get_email(author)
    email = @authors[author]
    email unless email
    "James Sadler <freshtonic@gmail.com>"
  end
end

# This class was taken from the darcs-ruby project.
# This class holds the patch's name, log, author, date, and other
# meta-info.
class PatchInfo
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
    @git_message = "#{short_msg}\n#{@long_msg}\n\n" + 
      "Exported from Darcs patch: #{@patch_name}".gsub("[']", '["]')
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
    if @added.include? file
      @added.delete(file)
      @added<< to
    else
      File.rename "#{@gitrepo}/#{file}", "#{@gitrepo}/#{to}"
    end
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
        log "lines were supposed to be inserted - something bad has happened"
        exit 1
      end
    end
  end

  def changepref pref, value
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

  def replace file, to_replace, replacement
    command = "sed -i 's/#{oldtext}/#{newtext}/g' #{@gitrepo}/#{file}"
    Open3.popen3("(#{command})") do |sin,sout,serr|
      log "executing command '#{command}'"
      sinlines = sout.readlines
      serrlines = serr.readlines
      if serrlines.size > 0
        serrlines.each {|line| $stderr.puts line }
        exit 1
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
        exit 1
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


PatchExporter.new(ARGV).export()

