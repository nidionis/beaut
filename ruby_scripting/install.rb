#!/usr/bin/env ruby
# ruby_scripting/install.rb — beaut single entry point (ruby)
# The only user-facing ruby script besides config.env.
#
#   ruby ruby_scripting/install.rb                  install (reads config.env)
#   ruby ruby_scripting/install.rb --role ROLE [IP] quick non-interactive install
#   ruby ruby_scripting/install.rb --serve [PORT]   publish bootstrap tarball
#   ruby ruby_scripting/install.rb --status         show systemd status
#   ruby ruby_scripting/install.rb --uninstall      remove systemd units
#
# Uses templates/ with @VAR@ substitution (sed) via scripts/env.sh.

require 'fileutils'

module Beaut
  HERE = File.expand_path(File.dirname(__FILE__) + '/..')
  PREFIX = ENV['PREFIX'] || '/usr/local'
  BIN_DIR = "#{PREFIX}/bin"
  ENV_DIR = ENV['ENV_DIR'] || '/etc/beaut'
  STATE_DIR = ENV['STATE_DIR'] || '/var/lib/beaut'
  SU = ENV['SERVICE_USER'] || 'beaut'
  SG = ENV['SERVICE_GROUP'] || 'beaut'
  CONF = "#{ENV_DIR}/beaut.conf"

  def self.log(msg);   $stdout.puts "\e[1;36m==>\e[0m #{msg}"; end
  def self.info(msg);  $stdout.puts "     #{msg}"; end
  def self.die(msg);   $stderr.puts "\e[1;31mxx\e[0m #{msg}"; exit 1; end
  def self.root?;      Process.uid == 0; end
  def self.sh(*args);  system(*args) or die "command failed: #{args.join(' ')}"; end

  def self.load_config(f = "#{HERE}/config.env")
    die "config file not found: #{f} (copy config.env.example to config.env and edit)" unless File.file?(f)
    # simple KEY="VALUE" shell-style parser
    File.readlines(f).each do |line|
      next if line.strip.start_with?('#') || line.strip.empty?
      if line =~ /^([A-Z_]+)="?(.*?)"?\s*$/
        ENV[$1] = $2
      end
    end
    die 'config.env must define BEAUT_PASSWORD' unless ENV['BEAUT_PASSWORD']
    die 'config.env must define ROLE' unless ENV['ROLE']
    log "config loaded from #{f} (role=#{ENV['ROLE']})"
  end

  def self.do_install(role, orch_ip = '')
    die 'run as root: sudo ruby ruby_scripting/install.rb' unless root?
    log "layers 1 + 2"
    sh('bash', "#{HERE}/scripts/env.sh", role, orch_ip.to_s)
    sh('bash', "#{HERE}/scripts/build.sh") unless File.exist?("#{HERE}/bin/beaut")

    # read deploy state written by scripts/env.sh
    state = {}
    File.readlines("#{HERE}/.deploy-state").each do |line|
      k, v = line.strip.split('=', 2); state[k] = v if k
    end

    bin_dir = state['BEAUT_BIN'] || "#{HERE}/bin"
    log "installing binaries to #{BIN_DIR}"
    FileUtils.mkdir_p(BIN_DIR, mode: 0755)
    %w[beaut-tool beaut-router].each do |b|
      src = File.join(bin_dir, b)
      next unless File.exist?(src)
      FileUtils.install(src, File.join(BIN_DIR, b), mode: 0755)
      FileUtils.chown('root', 'root', File.join(BIN_DIR, b))
    end

    FileUtils.mkdir_p(ENV_DIR, mode: 0750)
    FileUtils.chown('root', SG, ENV_DIR)
    if File.file?("#{HERE}/config.env")
      FileUtils.install("#{HERE}/config.env", CONF, mode: 0640)
      FileUtils.chown('root', SG, CONF)
    end

    # bootstrap admin identity
    priv = "#{ENV_DIR}/priv.tsv"
    unless File.size?(priv) && ENV['BEAUT_PASSWORD']
      log "bootstrapping admin identity"
      FileUtils.install('/dev/null', "#{ENV_DIR}/pending.tsv", mode: 0660, owner: 'root', group: SG)
      id = `#{"#{BIN_DIR}/beaut-tool"} join "#{ENV_DIR}/pending.tsv" "#{ENV['BEAUT_PASSWORD']}"`.match(/id=(\S+)/)[1]
      sh("#{BIN_DIR}/beaut-tool", "approve", "#{ENV_DIR}/pending.tsv", priv, id, '3')
      FileUtils.install(priv, priv, mode: 0640, owner: 'root', group: SG)
      log "admin id=#{id} level=3"
    end

    log "done — role=#{ENV['ROLE']}"
  end

  def self.do_serve(port = 8080)
    d = Dir.mktmpdir
    %w[install.sh config.env scripts templates].each do |name|
      src = File.join(HERE, name)
      FileUtils.cp_r(src, d) if File.exist?(src)
    end
    sh('tar', 'czf', "#{d}/beaut.tgz", '-C', d, 'install.sh', 'config.env', 'scripts', 'templates')
    ip = `hostname -I 2>/dev/null | awk '{print $1}'`.strip
    ip = '127.0.0.1' if ip.empty?
    File.write("#{d}/orch.host", ip)
    sh('tar', 'czf', "#{d}/beaut.tgz", '-C', d, 'install.sh', 'config.env', 'scripts', 'templates', 'orch.host')
    sha = `sha256sum #{d}/beaut.tgz | awk '{print $1}'`.strip[0..15]
    log "serving on :#{port} — sha256 #{sha}…"
    puts <<~EOT

      on the new node (verify before running):
        curl -fsSLO http://#{ip}:#{port}/beaut.tgz
        curl -fsSL  http://#{ip}:#{port}/beaut.tgz.sha256 | sha256sum -c -
        tar xzf beaut.tgz && sudo BEAUT_PASSWORD='...' ruby ruby_scripting/install.rb

    EOT
    require 'webrick'
    srv = WEBrick::HTTPServer.new(Port: port.to_i, DocumentRoot: d, Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN))
    trap('INT') { srv.shutdown }
    srv.start
  end

  def self.do_status
    sh('systemctl', 'status', 'beaut-orchestrator', 'beaut-heartbeat.timer', 'beaut-router', '--no-pager', err: File::NULL, out: File::NULL)
  end

  def self.do_uninstall
    die 'run as root' unless root?
    sh('systemctl', 'disable', '--now', 'beaut-orchestrator', 'beaut-heartbeat.timer', 'beaut-router', err: File::NULL, out: File::NULL)
    Dir.glob('/etc/systemd/system/beaut-worker@*.service').each do |u|
      sh('systemctl', 'disable', '--now', File.basename(u), err: File::NULL, out: File::NULL)
    end
    sh('rm', '-f', '/etc/systemd/system/beaut-*.service', '/etc/systemd/system/beaut-*.timer', '/etc/sudoers.d/beaut', err: File::NULL, out: File::NULL)
    sh('systemctl', 'daemon-reload', err: File::NULL, out: File::NULL)
    log "units removed — state kept in #{STATE_DIR}"
  end
end

case ARGV.first
when '--serve'   then ARGV.shift; Beaut.do_serve(ARGV.first || 8080)
when '--status'  then Beaut.do_status
when '--uninstall' then Beaut.do_uninstall
when '--role'
  ARGV.shift
  die 'usage: ruby_scripting/install.rb --role ROLE [ORCH_IP]' if ARGV.empty?
  role = ARGV.shift; ip = ARGV.first || '127.0.0.1'
  role = 'orchestrator' if role == 'orchestrator' && ip.nil?
  ENV['ROLE'] = role; ENV['ORCHESTRATOR_IP'] = ip
  ENV['IP_ORCHESTRATOR'] = ip
  Beaut.do_install(role, ip)
when nil, '--help', '-h'
  puts File.readlines(__FILE__)[1..10].join
  exit 0
else
  Beaut.load_config
  Beaut.do_install(ENV['ROLE'] || 'orchestrator', ENV['IP_ORCHESTRATOR'] || '')
end
