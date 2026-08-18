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
  gem install bundler -N
}

checkout_app() {
  log "checking out app code"
  mkdir -p "$APP_DIR"
  if [ ! -d "$APP_DIR/.git" ]; then
    git clone "$APP_REPO" "$APP_DIR"
  fi
  git -C "$APP_DIR" fetch --all --tags
  git -C "$APP_DIR" checkout "$APP_BRANCH"
  git -C "$APP_DIR" pull --ff-only origin "$APP_BRANCH"
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
  su - "$APP_USER" -c "cd '$APP_DIR' && \
    bundle config set --local path vendor/bundle && \
    bundle config set --local without 'test' && \
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
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable docker
  systemctl restart docker
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

  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/wpgsa-metrics.json
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

  systemctl is-active --quiet wpgsa || { log "wpgsa.service is not active"; failed=1; }
  systemctl is-active --quiet nginx  || { log "nginx is not active"; failed=1; }
  systemctl is-active --quiet docker || { log "docker is not active"; failed=1; }

  local code
  for path in / /download "/result?uuid=example"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1${path}" || echo 000)"
    log "GET ${path} -> ${code}"
    [ "$code" = "200" ] || failed=1
  done

  code="$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1/wpgsa/result?uuid=example&type=t-score&format=filepath' || echo 000)"
  log "GET /wpgsa/result (example t-score) -> ${code}"
  [ "$code" = "200" ] || failed=1

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
  install_bundler
  checkout_app
  configure_app
  bundle_install
  configure_systemd
  configure_cleanup_timer
  configure_nginx
  configure_cloudwatch_agent
  pull_algorithm_image
  show_status
  verify
  log "bootstrap finished"
}

main "$@"
