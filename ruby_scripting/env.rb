#!/usr/bin/env ruby
# ruby_scripting/env.rb — layer 2: identity, tree, config, runtime scripts (ruby wrapper)
# Delegates to scripts/env.sh which renders templates/ with @VAR@ substitution.
#
#   ruby ruby_scripting/env.rb <orchestrator|router|worker|client> [ORCHESTRATOR_IP]

require 'fileutils'

module BeautEnv
  HERE = File.expand_path(File.dirname(__FILE__) + '/..')

  def self.log(msg);   $stdout.puts "\e[1;36m==>\e[0m #{msg}"; end
  def self.die(msg);   $stderr.puts "\e[1;31mxx\e[0m #{msg}"; exit 1; end

  def self.run(role, orch_ip = '')
    die "usage: ruby_scripting/env.rb <orchestrator|router|worker|client> [ORCHESTRATOR_IP]" \
      unless %w[orchestrator router worker client].include?(role)
    log "layer 2: env + runtime (#{role} -> #{orch_ip})"

    # layer 1: build
    require_relative 'build'
    BeautBuild.run(false)

    # layer 2: env/runtime (renders templates/ with sed @VAR@ replacement)
    system('bash', "#{HERE}/scripts/env.sh", role, orch_ip.to_s) or die "env.sh failed"
    log "env configured: role=#{role} orch_ip=#{orch_ip}"
  end
end

role = ARGV[0] || 'orchestrator'
ip = ARGV[1] || '127.0.0.1'
BeautEnv.run(role, ip)
