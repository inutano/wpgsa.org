app_root = File.expand_path("..", __dir__)

directory app_root
environment ENV.fetch("RACK_ENV", "production")

threads_count = Integer(ENV.fetch("PUMA_THREADS", "5"))
threads threads_count, threads_count

workers Integer(ENV.fetch("PUMA_WORKERS", "2"))
preload_app!

bind ENV.fetch("PUMA_BIND", "unix://#{app_root}/tmp/sockets/puma.sock?umask=0117")

pidfile "#{app_root}/tmp/pids/puma.pid"
state_path "#{app_root}/tmp/pids/puma.state"

on_restart do
  require "fileutils"
  FileUtils.mkdir_p("#{app_root}/tmp/sockets")
  FileUtils.mkdir_p("#{app_root}/tmp/pids")
end
