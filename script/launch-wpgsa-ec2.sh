#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="$SCRIPT_DIR/bootstrap-wpgsa-instance.sh"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
ARCH="${ARCH:-x86_64}"
AMI_PARAM="${AMI_PARAM:-al2023-ami-kernel-default-${ARCH}}"
KEY_NAME="${KEY_NAME:-}"
DOMAIN_NAME="${DOMAIN_NAME:-wpgsa.org}"
HOSTNAME_TAG="${HOSTNAME_TAG:-wpgsa-org}"
APP_BRANCH="${APP_BRANCH:-master}"
APP_REPO="${APP_REPO:-https://github.com/inutano/wpgsa.org.git}"
EIP_ALLOCATION_ID="${EIP_ALLOCATION_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
VPC_ID="${VPC_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-wpgsa-web}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"
ROOT_VOLUME_SIZE="${ROOT_VOLUME_SIZE:-30}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
ENABLE_TLS="${ENABLE_TLS:-false}"
TAG_SPEC="ResourceType=instance,Tags=[{Key=Name,Value=${HOSTNAME_TAG}},{Key=Project,Value=wpgsa.org}]"

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

ensure_security_group() {
  local vpc_id="$1"
  local sg_id

  sg_id="$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$vpc_id" Name=group-name,Values="$SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)"

  if [ "$sg_id" = "None" ] || [ -z "$sg_id" ]; then
    sg_id="$(aws ec2 create-security-group \
      --region "$REGION" \
      --group-name "$SECURITY_GROUP_NAME" \
      --description "wpgsa.org web access" \
      --vpc-id "$vpc_id" \
      --query 'GroupId' \
      --output text)"

    aws ec2 authorize-security-group-ingress \
      --region "$REGION" \
      --group-id "$sg_id" \
      --ip-permissions \
      "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${SSH_CIDR},Description=SSH}]" \
      "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP}]" \
      "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTPS}]"
  fi

  printf '%s\n' "$sg_id"
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

  aws ec2 run-instances \
    --region "$REGION" \
    --image-id "resolve:ssm:/aws/service/ami-amazon-linux-latest/${AMI_PARAM}" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$subnet_id" \
    --security-group-ids "$sg_id" \
    --key-name "$KEY_NAME" \
    --associate-public-ip-address \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --tag-specifications "$TAG_SPEC" \
    --user-data "file://${user_data_file}" \
    "${iam_args[@]}" \
    --query 'Instances[0].InstanceId' \
    --output text
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

  if [ -z "$SECURITY_GROUP_ID" ]; then
    SECURITY_GROUP_ID="$(ensure_security_group "$VPC_ID")"
  fi

  local user_data_file instance_id
  user_data_file="$(render_user_data)"
  trap 'rm -f "$user_data_file"' EXIT

  instance_id="$(launch_instance "$SUBNET_ID" "$SECURITY_GROUP_ID" "$user_data_file")"

  aws ec2 wait instance-running --region "$REGION" --instance-ids "$instance_id"
  associate_eip "$instance_id"
  aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$instance_id"

  print_summary "$instance_id" "$SECURITY_GROUP_ID"
}

main "$@"
