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
require 'inventory_parser'
require 'export_to_git_patch_handler'

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
      patch = InventoryParser.read(instream)
      if !patch.nil?
        patches << patch
      else
        break
      end
    rescue EOFError
      break
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


PatchExporter.new(ARGV).export()

