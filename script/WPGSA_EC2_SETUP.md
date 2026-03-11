# EC2 Launch Script

These scripts create a fresh Amazon Linux 2023 EC2 instance and bootstrap it into a running `wpgsa.org` host.

Files:

- `script/launch-wpgsa-ec2.sh`: run this from your local machine
- `script/bootstrap-wpgsa-instance.sh`: runs on the EC2 instance via user data

## What It Sets Up

- Amazon Linux 2023 instance
- Security group for `22`, `80`, `443`
- `nginx` reverse proxy
- `docker`
- Ruby + Bundler
- app checkout from `https://github.com/inutano/wpgsa.org.git`
- branch `master`
- `systemd` service named `wpgsa`
- app config pointing at `data/merged_mouse_150904_trim.network`
- Docker image pull for `inutano/wpgsa:0.5.2`

## Assumptions

- You already have AWS credentials for the target account.
- You already have an EC2 key pair in the target region.
- The GitHub repo is publicly cloneable.
- The Docker image `inutano/wpgsa:0.5.2` is pullable from the instance.
- You either use an existing Elastic IP or are fine with a new public IP first.

## Required Environment Variables

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN` if you use temporary credentials
- `AWS_REGION` or `AWS_DEFAULT_REGION`
- `KEY_NAME`

## Optional Environment Variables

- `INSTANCE_TYPE`
- `DOMAIN_NAME`
- `APP_BRANCH`
- `EIP_ALLOCATION_ID`
- `SUBNET_ID`
- `VPC_ID`
- `SECURITY_GROUP_ID`
- `SSH_CIDR`
- `ROOT_VOLUME_SIZE`
- `INSTANCE_PROFILE_NAME`
- `ENABLE_TLS=true`
- `LETSENCRYPT_EMAIL=you@example.org`

## Example

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
export AWS_REGION=us-east-1
export KEY_NAME=my-ec2-key
export EIP_ALLOCATION_ID=eipalloc-0123456789abcdef0
export DOMAIN_NAME=wpgsa.org
export INSTANCE_TYPE=t3.small

bash script/launch-wpgsa-ec2.sh
```

## Notes

- If `ENABLE_TLS=true`, the instance bootstrap will try `certbot --nginx`.
- TLS only succeeds after the domain resolves to the new instance.
- If the certbot packages are unavailable in the region image mirror, bootstrap falls back to plain HTTP and leaves the app up.
