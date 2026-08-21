#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${APP_DIR:-/opt/wpgsa.org}"
APP_USER="${APP_USER:-wpgsa}"
APP_GROUP="${APP_GROUP:-wpgsa}"
APP_BRANCH="${APP_BRANCH:-master}"
APP_REPO="${APP_REPO:-https://github.com/inutano/wpgsa.org.git}"
DOMAIN_NAME="${DOMAIN_NAME:-wpgsa.org}"
APP_PORT="${APP_PORT:-9292}"
APP_HOST="${APP_HOST:-127.0.0.1}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
ENABLE_TLS="${ENABLE_TLS:-false}"

log() {
  printf '[bootstrap] %s\n' "$1"
}

retry() {
  local n=0
  local max=10
  local delay=15
  while true; do
    if "$@"; then
      return 0
    fi
    n=$((n + 1))
    if [ "$n" -ge "$max" ]; then
      return 1
    fi
    sleep "$delay"
  done
}

version_ge() {
  # True if dotted numeric version $1 >= $2 (e.g. "3.2.7" >= "3.1.21").
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

dependency_version() {
  local gem="$1"
  su - "$APP_USER" -c "cd '$APP_DIR' && bundle list" 2>/dev/null \
    | grep -E "^[[:space:]]*\* ${gem} \(" \
    | sed -E 's/.*\(([0-9.]+)\).*/\1/'
}

RUBY_PKG="${RUBY_PKG:-}"

detect_ruby_package() {
  local candidate
  for candidate in ruby3.4 ruby3.3 ruby3.2; do
    if dnf list --available "$candidate" >/dev/null 2>&1 || dnf list --installed "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

install_packages() {
  log "installing OS packages"
  retry dnf makecache

  if [ -z "$RUBY_PKG" ]; then
    RUBY_PKG="$(detect_ruby_package)" || {
      log "no ruby3.2 or newer package is available on this AMI"
      exit 1
    }
  fi
  log "using ruby package: $RUBY_PKG"

  retry dnf install -y \
    git nginx docker "$RUBY_PKG" "${RUBY_PKG}-devel" \
    gcc gcc-c++ make patch openssl-devel zlib-devel libffi-devel \
    redhat-rpm-config tar gzip which procps-ng jq findutils shadow-utils

  local version
  version="$(ruby -e 'print RUBY_VERSION')"
  case "$version" in
    3.2*|3.3*|3.4*|3.5*|4.*) log "ruby $version accepted" ;;
    *) log "ruby $version is below the 3.2 floor required by haml"; exit 1 ;;
  esac
}

create_app_user() {
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /home/"$APP_USER" --shell /bin/bash "$APP_USER"
  fi
  usermod -aG docker "$APP_USER"
}

start_docker() {
  log "starting Docker daemon"
  systemctl enable --now docker
}

configure_swap() {
  if swapon --show | grep -q '/swapfile'; then
    log "swap already active"
    return 0
  fi

  log "creating 2 GiB swap file"
  dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
}

install_bundler() {
  log "installing bundler"

  # AL2023's ruby3.x RPMs ship only versioned binaries (ruby3.4-gem, etc).
  # The alternatives system links `ruby` alone -- it never creates a bare
  # `gem` link -- so a plain `gem install` fails with "command not found"
  # even though the version check in install_packages already passed.
  local gem_bin=""
  if [ -n "$RUBY_PKG" ] && [ -x "/usr/bin/${RUBY_PKG}-gem" ]; then
    gem_bin="/usr/bin/${RUBY_PKG}-gem"
  elif command -v gem >/dev/null 2>&1; then
    gem_bin="$(command -v gem)"
  else
    log "no gem executable found (looked for /usr/bin/${RUBY_PKG}-gem and a bare 'gem' on PATH)"
    exit 1
  fi
  log "using gem binary: $gem_bin"

  "$gem_bin" install bundler -N

  local bundle_path
  bundle_path="$(su - "$APP_USER" -c 'command -v bundle')" || {
    log "bundle is not available in $APP_USER's login shell; bundle_install will fail"
    exit 1
  }
  log "bundler $(su - "$APP_USER" -c 'bundle --version') installed; bundle resolved to $bundle_path in $APP_USER's login shell"
}

checkout_app() {
  log "checking out app code"
  mkdir -p "$APP_DIR"
  chown "$APP_USER":"$APP_GROUP" "$APP_DIR"

  if [ ! -d "$APP_DIR/.git" ]; then
    su - "$APP_USER" -c "git clone '$APP_REPO' '$APP_DIR'"
  fi

  # Run every git operation as the app user, and chown the checkout to the
  # app user before touching it. checkout_app must be idempotent -- a
  # second bootstrap run against a repo already chowned to $APP_USER would
  # otherwise be operated on as root, which git refuses ("detected dubious
  # ownership") and aborts the whole script under set -e.
  su - "$APP_USER" -c "git -C '$APP_DIR' fetch --all --tags"
  su - "$APP_USER" -c "git -C '$APP_DIR' checkout '$APP_BRANCH'"
  su - "$APP_USER" -c "git -C '$APP_DIR' pull --ff-only origin '$APP_BRANCH'"
  chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"
}

configure_app() {
  log "configuring app"
  cat > "$APP_DIR/config.yaml" <<EOF
workdir: "/tmp/wpgsa"
network_file_path: "$APP_DIR/data/merged_mouse_150904_trim.network"
max_concurrent_jobs: ${MAX_CONCURRENT_JOBS:-2}
EOF

  if [ ! -f "$APP_DIR/data/merged_mouse_150904_trim.network" ]; then
    log "reference network file is missing from the checkout"
    exit 1
  fi

  if [ ! -f "$APP_DIR/public/data/example/data.hclust.js" ]; then
    log "example dataset is missing from the checkout"
    exit 1
  fi

  mkdir -p /tmp/wpgsa "$APP_DIR/public/data" "$APP_DIR/tmp/sockets" "$APP_DIR/tmp/pids" "$APP_DIR/tmp/slots"
  chmod 0777 /tmp/wpgsa
  chown -R "$APP_USER":"$APP_GROUP" /tmp/wpgsa "$APP_DIR/public/data" "$APP_DIR/tmp"
}

bundle_install() {
  log "installing Ruby gems"
  # frozen true forbids Bundler from re-resolving Gemfile.lock. Without it,
  # an unfrozen install on a different Ruby/Bundler than the lockfile was
  # resolved on can silently drift to different gem versions, and leaves
  # the checkout dirty, which breaks a later `git pull --ff-only`.
  su - "$APP_USER" -c "cd '$APP_DIR' && \
    bundle config set --local path vendor/bundle && \
    bundle config set --local without 'test' && \
    bundle config set --local frozen true && \
    bundle install"

  log "verifying bundle is satisfied"
  su - "$APP_USER" -c "cd '$APP_DIR' && bundle check" || {
    log "bundle check failed after bundle install"
    exit 1
  }
}

configure_systemd() {
  log "writing systemd unit"
  cat > /etc/systemd/system/wpgsa.service <<EOF
[Unit]
Description=wPGSA Sinatra application
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment=RACK_ENV=production
ExecStart=/usr/bin/env bundle exec puma -C $APP_DIR/config/puma.rb
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=always
RestartSec=5
# lib/wpgsa/job.rb#spawn! detaches an analysis runner as a child of this
# Puma process, so it lives inside this unit's cgroup. The default
# KillMode (control-group) makes systemd kill every process in that
# cgroup on stop/restart -- so deploying an unrelated fix with
# `systemctl restart wpgsa` also kills any in-flight analysis, leaving
# job.json stuck at "running" with a dead pid forever. Do not remove
# this: KillMode=process signals only the main (Puma) process and lets
# detached runners finish undisturbed.
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wpgsa
  systemctl restart wpgsa
}

configure_cleanup_timer() {
  log "installing cleanup timer"
  cat > /etc/systemd/system/wpgsa-cleanup.service <<EOF
[Unit]
Description=Remove wPGSA job output past its retention window

[Service]
Type=oneshot
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment=WPGSA_WORKDIR=/tmp/wpgsa
Environment=WPGSA_RETENTION_DAYS=${RETENTION_DAYS:-30}
ExecStart=$APP_DIR/script/cleanup-jobs
EOF

  cat > /etc/systemd/system/wpgsa-cleanup.timer <<EOF
[Unit]
Description=Daily wPGSA job cleanup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now wpgsa-cleanup.timer
}

configure_nginx() {
  log "writing nginx config"
  cat > /etc/nginx/conf.d/wpgsa.conf <<EOF
upstream wpgsa_app {
    server unix:$APP_DIR/tmp/sockets/puma.sock fail_timeout=0;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME _;

    root $APP_DIR/public;
    client_max_body_size 100m;

    add_header Strict-Transport-Security "max-age=${HSTS_MAX_AGE:-300}" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        try_files \$uri @app;
    }

    location @app {
        proxy_pass http://wpgsa_app;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_redirect off;
    }
}
EOF

  chmod o+x "$APP_DIR"
  chmod -R o+rX "$APP_DIR/public"

  # nginx runs as its own system user; it needs write access to the Puma
  # unix socket (config/puma.rb creates it at mode 0660 via ?umask=0117)
  # and execute access on every directory between $APP_DIR and the socket
  # to traverse into it. Group membership must be granted before nginx is
  # (re)started below, because it only takes effect for a freshly started
  # process, not one already running.
  usermod -aG "$APP_GROUP" nginx
  chmod g+rx "$APP_DIR" "$APP_DIR/tmp" "$APP_DIR/tmp/sockets"

  rm -f /etc/nginx/conf.d/default.conf
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

pull_algorithm_image() {
  log "pulling algorithm container image"
  retry docker pull inutano/wpgsa:0.5.2
}

configure_cloudwatch_agent() {
  log "installing CloudWatch agent"
  if ! retry dnf install -y amazon-cloudwatch-agent; then
    log "CloudWatch agent package unavailable; skipping"
    return 0
  fi

  cat > /opt/aws/amazon-cloudwatch-agent/etc/wpgsa-metrics.json <<'EOF'
{
  "agent": { "metrics_collection_interval": 300 },
  "metrics": {
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "disk": {
        "resources": ["/"],
        "measurement": ["disk_used_percent"],
        "metrics_collection_interval": 300
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 300
      }
    }
  }
}
EOF

  if ! /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/wpgsa-metrics.json; then
    log "CloudWatch agent config apply failed; continuing without it"
    return 0
  fi
}

enable_tls_if_requested() {
  if [ "$ENABLE_TLS" != "true" ]; then
    log "TLS bootstrap skipped"
    return 0
  fi

  if [ -z "$LETSENCRYPT_EMAIL" ]; then
    log "ENABLE_TLS=true but LETSENCRYPT_EMAIL is empty; skipping TLS"
    return 0
  fi

  if ! dnf install -y certbot python3-certbot-nginx; then
    log "certbot packages unavailable; skipping TLS"
    return 0
  fi

  log "requesting Let's Encrypt certificate"
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email "$LETSENCRYPT_EMAIL" \
    -d "$DOMAIN_NAME" \
    --redirect || log "certbot failed; app remains on HTTP"
}

show_status() {
  log "systemd status summary"
  systemctl --no-pager --full status wpgsa || true
  systemctl --no-pager --full status nginx || true
  systemctl --no-pager --full status docker || true
}

verify() {
  log "verifying local endpoints"
  local failed=0
  local curl_opts=(-s --connect-timeout 5 --max-time 10)

  systemctl is-active --quiet wpgsa || { log "wpgsa.service is not active"; failed=1; }
  systemctl is-active --quiet nginx  || { log "nginx is not active"; failed=1; }
  systemctl is-active --quiet docker || { log "docker is not active"; failed=1; }

  local code
  for path in / /download "/result?uuid=example"; do
    code="$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' "http://127.0.0.1${path}" || echo 000)"
    log "GET ${path} -> ${code}"
    [ "$code" = "200" ] || failed=1
  done

  code="$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' 'http://127.0.0.1/wpgsa/result?uuid=example&type=t-score&format=filepath' || echo 000)"
  log "GET /wpgsa/result (example t-score) -> ${code}"
  [ "$code" = "200" ] || failed=1

  # The checks above send Host: 127.0.0.1, which Sinatra's development-mode
  # permitted_hosts already allows -- they would pass even if
  # RACK_ENV=production were missing or misspelled in the systemd unit.
  # Send the production vhost's Host header explicitly so this actually
  # exercises host_authorization the way the ALB will.
  code="$(curl "${curl_opts[@]}" -H "Host: $DOMAIN_NAME" -o /dev/null -w '%{http_code}' 'http://127.0.0.1/' || echo 000)"
  log "GET / with Host: ${DOMAIN_NAME} -> ${code}"
  [ "$code" = "200" ] || failed=1

  # Belt and braces on top of `bundle config set --local frozen true` in
  # bundle_install: `bundle check` only asserts that the installed gems
  # satisfy the lockfile, not that the lockfile's versions clear the
  # security floors this branch exists to establish. The lockfile was
  # resolved on a Ruby/Bundler newer than AL2023 ships; assert the actual
  # installed versions directly so a silent re-resolution to older gems
  # fails the bootstrap instead of shipping quietly.
  local dep gem_name floor version
  for dep in "rack 3.1.21" "rack-session 2.1.2" "sinatra 4.2.0"; do
    gem_name="${dep% *}"
    floor="${dep#* }"
    version="$(dependency_version "$gem_name")"
    if [ -z "$version" ]; then
      log "could not determine installed version of ${gem_name}"
      failed=1
    elif version_ge "$version" "$floor"; then
      log "${gem_name} ${version} satisfies floor ${floor}"
    else
      log "${gem_name} ${version} is BELOW the required floor ${floor}"
      failed=1
    fi
  done

  if [ "$failed" -ne 0 ]; then
    log "verification FAILED"
    exit 1
  fi
  log "verification passed"
}

main() {
  install_packages
  configure_swap
  create_app_user
  start_docker
  install_bundler
  checkout_app
  configure_app
  bundle_install
  pull_algorithm_image
  configure_systemd
  configure_cleanup_timer
  configure_nginx
  configure_cloudwatch_agent
  show_status
  verify
  log "bootstrap finished"
}

main "$@"
