#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="$SCRIPT_DIR/bootstrap-wpgsa-instance.sh"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
ARCH="${ARCH:-x86_64}"
AMI_PARAM="${AMI_PARAM:-al2023-ami-kernel-default-${ARCH}}"
KEY_NAME="${KEY_NAME:-}"
DOMAIN_NAME="${DOMAIN_NAME:-wpgsa.org}"
HOSTNAME_TAG="${HOSTNAME_TAG:-wpgsa-org}"
APP_BRANCH="${APP_BRANCH:-stage1-rebuild}"  # TEMP: revert to master before merging this branch
APP_REPO="${APP_REPO:-https://github.com/inutano/wpgsa.org.git}"
EIP_ALLOCATION_ID="${EIP_ALLOCATION_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
VPC_ID="${VPC_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"
SSH_CIDR="${SSH_CIDR:-}"
ROOT_VOLUME_SIZE="${ROOT_VOLUME_SIZE:-30}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
ENABLE_TLS="${ENABLE_TLS:-false}"
TAG_SPEC="ResourceType=instance,Tags=[{Key=Name,Value=${HOSTNAME_TAG}},{Key=Project,Value=wpgsa.org}]"

USER_DATA_FILE=""

cleanup() {
  # USER_DATA_FILE is a script-scope variable, initialised empty above, so
  # this is safe to run on every exit path -- including a die() before
  # render_user_data has ever run -- without tripping `set -u`.
  if [ -n "$USER_DATA_FILE" ]; then
    rm -f "$USER_DATA_FILE"
  fi
}
trap cleanup EXIT INT TERM

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_env() {
  [ -n "${!1:-}" ] || die "missing required variable: $1"
}

ensure_aws_auth() {
  aws sts get-caller-identity --region "$REGION" >/dev/null
}

default_vpc() {
  aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text
}

default_subnet() {
  local vpc_id="$1"
  aws ec2 describe-subnets \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$vpc_id" Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' \
    --output text
}

render_user_data() {
  local tmpfile
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<EOF
#!/bin/bash
set -euo pipefail

export APP_BRANCH='${APP_BRANCH}'
export APP_REPO='${APP_REPO}'
export DOMAIN_NAME='${DOMAIN_NAME}'
export ENABLE_TLS='${ENABLE_TLS}'
export LETSENCRYPT_EMAIL='${LETSENCRYPT_EMAIL}'

cat >/root/bootstrap-wpgsa-instance.sh <<'BOOTSTRAP'
$(cat "$BOOTSTRAP_SCRIPT")
BOOTSTRAP

chmod +x /root/bootstrap-wpgsa-instance.sh
/root/bootstrap-wpgsa-instance.sh > /var/log/wpgsa-bootstrap.log 2>&1
EOF
  printf '%s\n' "$tmpfile"
}

launch_instance() {
  local subnet_id="$1"
  local sg_id="$2"
  local user_data_file="$3"
  local iam_args=()

  if [ -n "$INSTANCE_PROFILE_NAME" ]; then
    iam_args=(--iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}")
  fi

  local cmd=(
    aws ec2 run-instances
    --region "$REGION"
    --image-id "resolve:ssm:/aws/service/ami-amazon-linux-latest/${AMI_PARAM}"
    --instance-type "$INSTANCE_TYPE"
    --subnet-id "$subnet_id"
    --security-group-ids "$sg_id"
    --key-name "$KEY_NAME"
    --associate-public-ip-address
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_SIZE},\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]"
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled"
    --tag-specifications "$TAG_SPEC"
    --user-data "file://${user_data_file}"
  )

  if [ "${#iam_args[@]}" -gt 0 ]; then
    cmd+=("${iam_args[@]}")
  fi

  cmd+=(
    --query 'Instances[0].InstanceId'
    --output text
  )

  "${cmd[@]}"
}

associate_eip() {
  local instance_id="$1"
  [ -n "$EIP_ALLOCATION_ID" ] || return 0

  aws ec2 associate-address \
    --region "$REGION" \
    --instance-id "$instance_id" \
    --allocation-id "$EIP_ALLOCATION_ID" \
    --allow-reassociation >/dev/null
}

instance_public_ip() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text
}

instance_public_dns() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicDnsName' \
    --output text
}

print_summary() {
  local instance_id="$1"
  local sg_id="$2"
  local ip dns

  ip="$(instance_public_ip "$instance_id")"
  dns="$(instance_public_dns "$instance_id")"

  cat <<EOF

Launch complete.

Region:          $REGION
Instance ID:     $instance_id
Security Group:  $sg_id
Public IP:       $ip
Public DNS:      $dns
Domain target:   $DOMAIN_NAME
Branch:          $APP_BRANCH

Next checks:
  1. Wait a few minutes for cloud-init to finish.
  2. SSH in and inspect: sudo tail -f /var/log/wpgsa-bootstrap.log
  3. Inspect services: sudo systemctl status wpgsa nginx docker
  4. If you used an Elastic IP, point wpgsa.org DNS to it if not already attached.
  5. If ENABLE_TLS=true, verify certbot succeeded after DNS resolves to this host.

EOF
}

main() {
  need_cmd aws
  require_env KEY_NAME
  require_env SSH_CIDR
  require_env SECURITY_GROUP_ID
  [ "$SSH_CIDR" != "0.0.0.0/0" ] || die "refusing to open SSH to the whole internet; set SSH_CIDR"
  [ -f "$BOOTSTRAP_SCRIPT" ] || die "bootstrap script not found: $BOOTSTRAP_SCRIPT"
  ensure_aws_auth

  if [ -z "$VPC_ID" ]; then
    VPC_ID="$(default_vpc)"
  fi
  [ "$VPC_ID" != "None" ] || die "could not resolve a VPC_ID; set VPC_ID explicitly"

  if [ -z "$SUBNET_ID" ]; then
    SUBNET_ID="$(default_subnet "$VPC_ID")"
  fi
  [ "$SUBNET_ID" != "None" ] || die "could not resolve a SUBNET_ID; set SUBNET_ID explicitly"

  local instance_id
  USER_DATA_FILE="$(render_user_data)"

  instance_id="$(launch_instance "$SUBNET_ID" "$SECURITY_GROUP_ID" "$USER_DATA_FILE")"

  aws ec2 wait instance-running --region "$REGION" --instance-ids "$instance_id"
  associate_eip "$instance_id"
  aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$instance_id"

  print_summary "$instance_id" "$SECURITY_GROUP_ID"
}

main "$@"
