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
require 'author_file'

class PatchExporter

  def initialize(args)
    parse_command_line(args)
    begin
      @authors = AuthorFile.new @authorsfile
    rescue
      log "could not find authors file #{@authorsfile}"
      exit 1
    end
  end

  def export
    generate_patch_list.each do |patch|
      log "converting patch #{patch.filename}"
      instream = IO.popen("gunzip -c #{@darcsrepo}/_darcs/patches/#{patch.filename}")
      DarcsPatchParser.new(instream, 
        ExportToGitPatchHandler.new(
          @gitrepo, patch.filename, self, @skip_binaries, @authors)).parse
    end
  end

  def log(msg)
    STDERR.puts "darcs-fast-export: #{msg}"
  end

  private

  def generate_patch_list
    patches = []
    File.open("#{@darcsrepo}/_darcs/inventory") do |f|
      begin
        patch = InventoryParser.read(f)
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
    end
    patches
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

end

PatchExporter.new(ARGV).export() if __FILE__ == $0

