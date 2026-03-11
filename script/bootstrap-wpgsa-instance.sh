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

install_packages() {
  log "installing OS packages"
  retry dnf makecache
  retry dnf install -y \
    git \
    nginx \
    docker \
    ruby \
    ruby-devel \
    rubygems \
    gcc \
    gcc-c++ \
    make \
    patch \
    openssl-devel \
    zlib-devel \
    libffi-devel \
    redhat-rpm-config \
    tar \
    gzip \
    which \
    procps-ng \
    jq \
    findutils \
    shadow-utils
}

create_app_user() {
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /home/"$APP_USER" --shell /bin/bash "$APP_USER"
  fi
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
EOF

  mkdir -p /tmp/wpgsa
  chmod 0777 /tmp/wpgsa
  mkdir -p "$APP_DIR/public/data"
  chown -R "$APP_USER":"$APP_GROUP" /tmp/wpgsa "$APP_DIR/public/data"
}

bundle_install() {
  log "installing Ruby gems"
  su - "$APP_USER" -c "cd '$APP_DIR' && bundle config set --local path vendor/bundle && bundle install"
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
ExecStart=/usr/local/bin/bundle exec rackup --host $APP_HOST --port $APP_PORT
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

configure_nginx() {
  log "writing nginx config"
  cat > /etc/nginx/conf.d/wpgsa.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;

    client_max_body_size 100m;

    location / {
        proxy_pass http://$APP_HOST:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}
EOF

  rm -f /etc/nginx/conf.d/default.conf
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

pull_algorithm_image() {
  log "pulling algorithm container image"
  retry docker pull inutano/wpgsa:0.5.2
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

main() {
  install_packages
  create_app_user
  install_bundler
  checkout_app
  configure_app
  bundle_install
  configure_systemd
  configure_nginx
  pull_algorithm_image
  enable_tls_if_requested
  show_status
  log "bootstrap finished"
}

main "$@"
