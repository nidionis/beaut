#!/usr/bin/env ruby
# ruby_scripting/build.rb — layer 1: arch + deps + compile src/ (ruby wrapper)
# Delegates to scripts/build.sh which performs the actual build.
#
#   ruby ruby_scripting/build.rb        build (cached)
#   ruby ruby_scripting/build.rb --force  force rebuild

require 'fileutils'

module BeautBuild
  HERE = File.expand_path(File.dirname(__FILE__) + '/..')

  def self.log(msg);   $stdout.puts "\e[1;36m==>\e[0m #{msg}"; end
  def self.die(msg);   $stderr.puts "\e[1;31mxx\e[0m #{msg}"; exit 1; end

  def self.run(force = false)
    log "layer 1: build — arch + deps + compile src/ (single source of truth)"
    args = ['bash', "#{HERE}/scripts/build.sh"]
    args << '--force' if force
    system(*args, chdir: HERE) or die "build failed"
    unless File.executable?("#{HERE}/bin/beaut")
      die "bin/beaut was not produced — check src/ and Makefile"
    end
    log "bin/beaut built"
  end
end

force = ARGV.include?('--force')
BeautBuild.run(force)
