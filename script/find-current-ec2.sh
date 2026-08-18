#!/usr/bin/env bash

set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
DOMAIN_NAME="${DOMAIN_NAME:-wpgsa.org}"
PUBLIC_IP="${PUBLIC_IP:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

log() {
  printf '[find-current-ec2] %s\n' "$1" >&2
}

resolve_domain_ip() {
  local domain="$1"
  local ip

  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short A "$domain" | tail -n 1)"
  elif command -v host >/dev/null 2>&1; then
    ip="$(host "$domain" | awk '/has address/ {print $4}' | tail -n 1)"
  else
    printf ''
    return 0
  fi

  printf '%s\n' "$ip"
}

resolve_domain_cname() {
  local domain="$1"

  if command -v dig >/dev/null 2>&1; then
    dig +short CNAME "$domain" | tail -n 1
  elif command -v host >/dev/null 2>&1; then
    host "$domain" | awk '/is an alias for/ {print $NF}' | tail -n 1
  else
    printf ''
  fi
}

describe_eip_by_ip() {
  local ip="$1"
  aws ec2 describe-addresses \
    --region "$REGION" \
    --public-ips "$ip" \
    --query 'Addresses[0]' \
    --output json 2>/dev/null || true
}

instance_id_from_public_ip() {
  local ip="$1"
  aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=ip-address,Values=${ip}" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true
}

describe_instance() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0]' \
    --output json
}

describe_network_interfaces() {
  local instance_id="$1"
  aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters "Name=attachment.instance-id,Values=${instance_id}" \
    --query 'NetworkInterfaces[*].{NetworkInterfaceId:NetworkInterfaceId,Status:Status,Description:Description,PrivateIp:PrivateIpAddress,PrivateIps:PrivateIpAddresses[*].PrivateIpAddress,PublicAssociation:Association.PublicIp,SubnetId:SubnetId,VpcId:VpcId,SecurityGroups:Groups[*].GroupId,AttachmentDeviceIndex:Attachment.DeviceIndex,DeleteOnTermination:Attachment.DeleteOnTermination}' \
    --output json
}

describe_security_groups() {
  local group_ids_csv="$1"
  [ -n "$group_ids_csv" ] || return 0

  aws ec2 describe-security-groups \
    --region "$REGION" \
    --group-ids $group_ids_csv \
    --query 'SecurityGroups[*].{GroupId:GroupId,GroupName:GroupName,Description:Description,VpcId:VpcId}' \
    --output json
}

main() {
  need_cmd aws
  need_cmd python3

  if [ -z "$PUBLIC_IP" ]; then
    log "resolving A record for ${DOMAIN_NAME}"
    PUBLIC_IP="$(resolve_domain_ip "$DOMAIN_NAME")"
  fi

  local cname
  cname="$(resolve_domain_cname "$DOMAIN_NAME")"

  cat <<EOF
Region:      $REGION
Domain:      $DOMAIN_NAME
CNAME:       ${cname:-<none>}
Resolved IP: ${PUBLIC_IP:-<none>}
EOF

  if [ -z "$PUBLIC_IP" ]; then
    printf '\nNo IPv4 address resolved. If this domain points to a load balancer alias, inspect Route 53 / ELB directly.\n'
    exit 1
  fi

  log "checking whether ${PUBLIC_IP} is an Elastic IP"
  local eip_json
  eip_json="$(describe_eip_by_ip "$PUBLIC_IP")"

  if [ -n "$eip_json" ] && [ "$eip_json" != "null" ]; then
    printf '\nElastic IP:\n'
    printf '%s\n' "$eip_json" | python3 -m json.tool
  else
    printf '\nElastic IP:\n<not found in region %s>\n' "$REGION"
  fi

  local instance_id
  instance_id="$(printf '%s\n' "$eip_json" | python3 - <<'PY'
import json, sys
raw = sys.stdin.read().strip()
if not raw or raw == "null":
    print("")
else:
    obj = json.loads(raw)
    print(obj.get("InstanceId", ""))
PY
)"

  if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
    log "checking for an instance with public IP ${PUBLIC_IP}"
    instance_id="$(instance_id_from_public_ip "$PUBLIC_IP")"
  fi

  if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
    printf '\nCould not map %s to an EC2 instance in region %s.\n' "$PUBLIC_IP" "$REGION"
    printf 'If the domain points to an ALB/ELB, inspect that load balancer instead.\n'
    exit 1
  fi

  printf '\nInstance ID:\n%s\n' "$instance_id"

  local instance_json
  instance_json="$(describe_instance "$instance_id")"
  printf '\nInstance Summary:\n'
  printf '%s\n' "$instance_json" | python3 - <<'PY'
import json, sys
obj = json.load(sys.stdin)
summary = {
    "InstanceId": obj.get("InstanceId"),
    "InstanceType": obj.get("InstanceType"),
    "State": obj.get("State", {}).get("Name"),
    "ImageId": obj.get("ImageId"),
    "Architecture": obj.get("Architecture"),
    "PlatformDetails": obj.get("PlatformDetails"),
    "LaunchTime": obj.get("LaunchTime"),
    "PublicIpAddress": obj.get("PublicIpAddress"),
    "PrivateIpAddress": obj.get("PrivateIpAddress"),
    "VpcId": obj.get("VpcId"),
    "SubnetId": obj.get("SubnetId"),
    "AvailabilityZone": obj.get("Placement", {}).get("AvailabilityZone"),
    "KeyName": obj.get("KeyName"),
    "IamInstanceProfile": (obj.get("IamInstanceProfile") or {}).get("Arn"),
    "SecurityGroups": obj.get("SecurityGroups"),
    "Tags": obj.get("Tags"),
}
print(json.dumps(summary, indent=2))
PY

  local eni_json
  eni_json="$(describe_network_interfaces "$instance_id")"
  printf '\nNetwork Interfaces:\n'
  printf '%s\n' "$eni_json" | python3 -m json.tool

  local sg_ids
  sg_ids="$(printf '%s\n' "$instance_json" | python3 - <<'PY'
import json, sys
obj = json.load(sys.stdin)
print(" ".join(g["GroupId"] for g in obj.get("SecurityGroups", [])))
PY
)"

  if [ -n "$sg_ids" ]; then
    printf '\nSecurity Groups:\n'
    describe_security_groups "$sg_ids" | python3 -m json.tool
  fi
}

main "$@"
