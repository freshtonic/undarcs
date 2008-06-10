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

