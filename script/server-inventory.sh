#!/usr/bin/env bash

set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

cmd() {
  local label="$1"
  shift

  printf '\n$ %s\n' "$label"
  if "$@"; then
    :
  else
    printf '[command failed]\n'
  fi
}

section "Timestamp"
cmd "date -Is" date -Is

section "Host"
cmd "hostnamectl" hostnamectl
cmd "uname -a" uname -a
cmd "cat /etc/os-release" cat /etc/os-release

section "Runtime"
cmd "ruby -v" ruby -v
cmd "bundle -v" bundle -v
cmd "gem env home" gem env home
cmd "which ruby" which ruby
cmd "which bundle" which bundle

section "App Process"
cmd "ps -ef | grep -E 'ruby|rackup|puma|unicorn|passenger|sinatra' | grep -v grep" sh -c "ps -ef | grep -E 'ruby|rackup|puma|unicorn|passenger|sinatra' | grep -v grep"
cmd "systemctl list-units --type=service --all | grep -Ei 'wpgsa|ruby|rack|puma|unicorn|nginx|httpd|apache|docker'" sh -c "systemctl list-units --type=service --all | grep -Ei 'wpgsa|ruby|rack|puma|unicorn|nginx|httpd|apache|docker' || true"
cmd "systemctl list-unit-files | grep -Ei 'wpgsa|ruby|rack|puma|unicorn|nginx|httpd|apache|docker'" sh -c "systemctl list-unit-files | grep -Ei 'wpgsa|ruby|rack|puma|unicorn|nginx|httpd|apache|docker' || true"

section "Web Proxy"
cmd "nginx -v" nginx -v
cmd "httpd -v" httpd -v
cmd "apachectl -v" apachectl -v
cmd "ls /etc/nginx" ls -la /etc/nginx
cmd "find /etc/nginx -maxdepth 2 -type f" find /etc/nginx -maxdepth 2 -type f
cmd "find /etc/httpd -maxdepth 3 -type f" find /etc/httpd -maxdepth 3 -type f

section "TLS"
cmd "certbot --version" certbot --version
cmd "find /etc/letsencrypt -maxdepth 3 -type f" find /etc/letsencrypt -maxdepth 3 -type f

section "Docker"
cmd "docker --version" docker --version
cmd "docker info --format '{{json .}}'" docker info --format "{{json .}}"
cmd "docker images" docker images
cmd "docker ps -a" docker ps -a

section "Filesystem"
cmd "df -h" df -h
cmd "lsblk" lsblk
cmd "mount" mount
cmd "ls -la /tmp" ls -la /tmp

section "Application Files"
cmd "pwd" pwd
cmd "find /home -maxdepth 3 -type d \\( -name 'wpgsa.org' -o -name 'wpgsa' \\)" sh -c "find /home -maxdepth 3 -type d \\( -name 'wpgsa.org' -o -name 'wpgsa' \\) 2>/dev/null || true"
cmd "find /opt -maxdepth 3 -type d \\( -name 'wpgsa.org' -o -name 'wpgsa' \\)" sh -c "find /opt -maxdepth 3 -type d \\( -name 'wpgsa.org' -o -name 'wpgsa' \\) 2>/dev/null || true"
cmd "find /srv -maxdepth 3 -type d \\( -name 'wpgsa.org' -o -name 'wpgsa' \\)" sh -c "find /srv -maxdepth 3 -type d \\( -name 'wpgsa.org' -o -name 'wpgsa' \\) 2>/dev/null || true"

section "Scheduled Jobs"
cmd "crontab -l" crontab -l
cmd "find /etc/cron* -maxdepth 2 -type f" find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly -maxdepth 2 -type f

section "Networking"
cmd "ss -ltnp" ss -ltnp
cmd "ip addr" ip addr
cmd "ip route" ip route

section "Recent Logs"
cmd "journalctl -n 200 --no-pager" journalctl -n 200 --no-pager
cmd "journalctl -u docker -n 100 --no-pager" journalctl -u docker -n 100 --no-pager

