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

# TODO: handle conflict, tag and undo patches.

# TODO: handler merger patches. These are the patches that darcs creates
# when you  pull a patch that  conflicts with one already  in your local
# repository. A merger is a piece  of darcs book keeping that identifies
# the conflicts.  The conflict  is resolved  by the  next patch  that is
# commited.

# TODO: verify handling of changes to binaries actually works
#
# TODO: obtain  patch  order  by extracting  timestamps  in order  from
# inventory file.

require 'enumerator'
require 'optparse'
require 'open3'

class PatchExporter

  def initialize(args)
    @line_buf = []      # holds lines that we have unread.
    @line_number = 1    # the number of the line in the Darcs patch
                        # that we are currently parsing (starting at 1)
    @added_files = []   
    @deleted_files = []
    @renamed_files = {}
    @changed_files = []
    @in = nil           # input stream for the currently parsed patch

    parse_command_line(args)
    begin
      @authors = AuthorFile.new @authorsfile
    rescue
      log "could not find authors file #{@authorsfile}"
      exit 1
    end
  end

  # Generates a list  of all patches in the repo  that are referenced by
  # the inventory. (Darcs  keeps patch files around after  an unpull but
  # it does this merely by removing  the reference to the patch from the
  # inventory).
  #
  # NOTE: this  method is probably not  very robust. We should  sort the
  # list of patches  so that they are  in the same order as  they are in
  # the inventory. I  don't think the timestamp is enough,  as Darcs may
  # have commuted some patches into a non-temporal order.
  def generate_patch_list
    @patches = []
    Dir.new("#{@darcsrepo}/_darcs/patches").entries.each do |entry|
      if entry =~ /\.gz$/
        @patches << entry
      end
    end
    inventory = open("#{@darcsrepo}/_darcs/inventory") {|f| f.read}
    to_remove = []
    @patches.each do |p|
      tstamp = p[0..13]
      if !inventory.include?(tstamp)
        to_remove << p
      end
    end
    @patches = (@patches - to_remove).sort
  end

  def export
    generate_patch_list
    @patches.each do |patch|
      log "converting patch #{patch}"
      readline
      @in = IO.popen("gunzip -c #{@darcsrepo}/_darcs/patches/#{patch}")
      export_patch
    end
  end

  def export_patch
    first  = nextline
    second = nextline
    short_message = first[1..-1].rstrip
    author = second[0..second.index("**") - 1]
    git_message = short_message

    if !(second =~ /\{$/)
      line = nextline 
      begin
        unless line =~ /^\]/
          git_message = "#{git_message}#{line}"
        end
        line = nextline
      end while !(line =~ /^\]/)
    end

    git_message.gsub! /\\n/, "\\n"

    log "author: '#{author}'"
    log "message: '#{git_message}'"


    begin
      line = nextline
      until line =~ /^\}$/
        if line =~ /^adddir/
          dir = fix_file_name(line.gsub(/^adddir /, "").rstrip)
          add_dir(dir)
        elsif line =~ /^addfile/
          file = fix_file_name(line.gsub(/^addfile /, "").rstrip)
          add_file(file)
        elsif line =~ /^rmfile/
          file = fix_file_name(line.gsub(/^rmfile /, "").rstrip)
          rm_file(file)
        elsif line =~ /^hunk/
          file, line_number = line.gsub(/^hunk /, "").rstrip.split(" ")
          file = fix_file_name(file)
          line_number = line_number.to_i
          apply_hunk(file, line_number)
        elsif line =~ /^binary/
          file = fix_file_name(line.gsub(/^binary /, "").rstrip)
          write_binary(file)
        elsif line =~ /^move /
          before, after = line.gsub(/^move /, "").split(" ")
          after = fix_file_name(after)
          log "renaming '#{before}' -> '#{after}'"
          File.rename "#{@gitrepo}/#{before}", "#{@gitrepo}/#{after}"
          @renamed_files[before] = after
        elsif line =~ /^merger/
          # I think we can just *consume* the 'merger' as the next
          # patch file we parse will contain the complete patch resolution.
          unread(line)
          consume_merger(0)
        elsif line =~ /^changepref/
          # we don't do any thing with changepref (meaningless in Git)
          # but we do need to consume it.
          # changepref is of the format:
          # changepref pref_name <newline> <newline> value
          nextline
          nextline
        else
          log err_unexpected(line, 
            "/^(adddir|addfile|rmfile|hunk|move|binary|merger|changepref)/") 
          exit 1
        end
        line = nextline
      end
    rescue EOFError
      log "unexpected end of patch file detected"
      exit 1
    ensure
      @lin_buf = []
      @in = nil
    end
    log "changes to working tree complete; updating GIT repository"

    @renamed_files.each_key {|k| run_git "add -u '#{k}'"}
    @renamed_files.each_value {|v| run_git "add '#{v}'"}
    @added_files = @added_files - @deleted_files
    @added_files.each_slice(40) {|files| run_git "add #{(files.map {|file| "'#{file}'"}).join(" ")}"}
    # Darcs deletes a file by creating a hunk that removes all the lines
    # then deletes the file.  In that case we want no files in the changed list
    # that are in the deleted list, or we will break Git.
    @changed_files = @changed_files - @deleted_files
    @changed_files.each_slice(40) {|files| run_git "add #{(files.map {|file| "'#{file}'"}).join(" ")}"}
    @deleted_files.each_slice(40) {|files| run_git "rm #{(files.map {|file| "'#{file}'"}).join(" ")}"}
    run_git "commit -m '#{git_message}' --author \"#{@authors.get_email(author)}\""
    @added_files = []
    @changed_files = []
    @renamed_files = {}
    @deleted_files = []
    log "finished importing patch"
  end

  def consume_merger(depth)
    begin 
      line = readline
      if line =~ /^merger/
        depth+=1
      elsif line =~ /^\)/
        depth-=1
      end
    end while count > 0
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


  def run_git(command)
    Open3.popen3("(cd #{@gitrepo} && git #{command})") do |sin,sout,serr|
      log "executing command '#{command}'"
      sinlines = sout.readlines
      serrlines = serr.readlines
      if serrlines.size > 0
        serrlines.each {|line| $stderr.puts line }
        exit 1
      end
    end
  end

  def fix_file_name(file)
    file.gsub(/\\32\\/, " ")
  end

  def read_hunk file
    log "processing hunk for file '#{file}'"
    line = nextline
    deleted_lines = []
    inserted_lines= []
    until !(line =~ /^([+]|[-])/)
      deleted_lines << line[1..-1] if line =~ /^[-]/
      inserted_lines << line[1..-1] if line =~ /^[+]/
      line = nextline
    end
    unreadline(line)
    return deleted_lines, inserted_lines
  end

  def read_original_file(file)
    in_file = open_file_for_reading(file)
    origin_lines = nil
    begin
      orig_lines = in_file.readlines
    ensure
      in_file.close
    end
    orig_lines
  end

  def open_file_for_reading(file)
      File.new("#{@gitrepo}/#{file}", "r")
  end

  def apply_hunk(file, line_number)
    @changed_files << file unless @changed_files.include? file
    log "processing hunk for file '#{file}'"
    if @added_files.include? file
      # optimisation: avoid reading the entire hunk into 
      # RAM when it's a new file that we are creating
      out_file = File.new("#{@gitrepo}/#{file}", "w")
      begin
        line = nextline 
        until !(line =~ /^([+]|[-])/) # for some reason, even on a new file, we can have '-' lines....??
          out_file.write(line[1..-1]) if line =~ /^[+]/
          line = nextline
        end
        unreadline(line)
      ensure
        out_file.close
      end
    else
      # this hunk is a change to an existing file, so consume
      # the original, perform the merge in RAM and write out the result
      deleted_lines, inserted_lines = read_hunk file
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
    end
  end

  def nextline
    @line_number = @line_number + 1
    if @line_buf.size > 0
      @line_buf.pop
    else
      @in.readline
    end
  end

  def unreadline(line)
    raise "nil line!" unless line
    @line_number = @line_number - 1
    @line_buf.push line
  end

  def add_file(file)
    @added_files << file
    log "adding file #{file}"
    out_file = File.new("#{@gitrepo}/#{file}", "w")
    out_file.close
  end

  def write_binary(file)
    @changed_files << file
    if @skip_binaries
      log "NOT writing binary file #{file}, skipping"
    else
      log "writing binary file #{file}"
    end

    out_file = File.new("#{@gitrepo}/#{file}", "w") unless @skip_binaries
    begin
      consume_line(/^oldhex/)
      until nextline =~ /^newhex/
      end
      until (line = nextline) =~ /^[^*]/
        unpack_binary(line[1..-1], out_file) unless @skip_binaries
      end
      ensure
      out_file.close unless @skip_binaries
    end
    unreadline(line)
  end

  def add_dir(dir)
    @added_files << dir
    log "adding dir '#{dir}'"
    Dir.mkdir "#{@gitrepo}/#{dir}"
  end

  def rm_file(file)
    @deleted_files << file
    log "removing file '#{file}'"
    File.delete "#{@gitrepo}/#{file}"
  end

  def consume_line(regex)
    line = nextline
    raise err_unexpected(line, regex) unless line =~ regex
    line
  end

  def err_unexpected(line, regex)
    "unexpected token(s) '#{line.strip}' at line #{@line_number} " + 
      "(expecting match against regex #{regex})"
  end

  def log(msg)
    STDERR.puts "darcs-fast-export: #{msg}"
  end

  # Converts a string of pairs of hex digits to bytes.
  # I doubt this is quick, but it's so ingenious (not my own
  # ingenuity, I must confess - found it on the web!).
  def unpack_binary(line, file)
    line.scan(/.{2}/).each { |hex_byte| file.putc(hex_byte.hex.chr) }
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

PatchExporter.new(ARGV).export()

