# WPGSA Maintenance Plan

This document turns the current maintenance work into a concrete sequence with decision points.

## Current State

- Web app: Sinatra app running as a native process
- Analysis: invoked via `docker run` from the web process
- Data: one bundled mouse reference network in `data/`
- Hosting: AWS EC2
- Immediate web fix: asset URL generation was fixed on branch `fix-css-layout-issues`

Relevant code:

- App URL helper: `app.rb`
- Analysis launcher: `lib/wpgsa/docker.rb`
- Network initialization: `lib/tasks/init.rake`

## Phase 0: Production Stabilization

Goal: restore correct HTTPS page rendering and remove obvious mixed-content risks.

Checklist:

- Deploy branch `fix-css-layout-issues`
- Confirm the reverse proxy or load balancer forwards `X-Forwarded-Proto=https`
- Verify these pages load with no blocked assets:
  - `/`
  - `/download`
  - `/result?uuid=example`
  - `/result/heatmap?uuid=example`
- Test upload flow and result rendering
- Check browser console for mixed-content and JavaScript errors
- Merge the remaining external-link HTTPS cleanup in templates

Exit criteria:

- CSS/JS assets are loaded over HTTPS
- Layout renders correctly on home, result, and heatmap pages
- Upload and analysis still work

## Phase 1: EC2 Migration to Amazon Linux 2023

Goal: move off the old instance with minimal application change.

Strategy:

- Build a new host in parallel
- Reproduce the current runtime first
- Cut over only after validation

Inventory on the current host:

- AMI and OS version
- Ruby version and Bundler version
- App process manager (`systemd`, init script, or other)
- Front proxy (`nginx`, `apache`, or ALB only)
- Docker version and image pull behavior
- TLS/certificate handling
- Log file paths
- Disk layout and backup points
- Cron jobs or ad hoc scripts

Build on the new host:

- Launch a fresh EC2 instance on Amazon Linux 2023
- Install Ruby runtime dependencies
- Install Docker
- Create app directory and service user
- Deploy app code and config
- Copy the reference network and any persistent `public/data` you need to keep
- Recreate the app service definition
- Recreate proxy/TLS configuration
- Run smoke tests before cutover

Cutover:

- Lower DNS TTL in advance
- Switch DNS or load balancer target
- Monitor logs and rollback window

Exit criteria:

- New AL2023 instance serves production traffic
- Analysis jobs still execute successfully via Docker
- Restart/runbook is documented

## Phase 2: ECS Feasibility Spike

Goal: decide whether ECS is worth the refactor cost.

Current blocker:

- The app shells out to `docker run`, which is not a clean fit for ECS Fargate

Options:

- Keep EC2: lowest risk, fastest
- ECS on EC2: possible, but operationally less compelling
- ECS Fargate: requires refactor

Recommended spike:

- Build one container image that contains both the Sinatra app and the analysis code
- Replace `docker run ... wpgsa` with a direct local process invocation inside the same container
- Externalize `config.yaml` and reference network path
- Test whether CPU, memory, temp disk, and runtime are acceptable under a single-task model

Decision gate:

- If the single-container design works cleanly, proceed toward ECS/Fargate
- If not, keep production on EC2 and revisit architecture later

## Phase 3: Reference Network Refresh

Goal: replace the outdated mouse-only network with a versioned network built from newer data, likely using ChIP-Atlas target-gene resources.

Why this is separate:

- This changes scientific inputs and output interpretation
- It needs validation, not just deployment

Work items:

- Define the source dataset and versioning scheme
- Map ChIP-Atlas target-gene output to the current network columns:
  - `TF_Uniprot`
  - `TF_egSym`
  - `TargetSym`
  - `Target_geneID`
  - `positive No.`
  - `experiment No.`
- Generate a mouse replacement first
- Add support for selecting network by species and version in config
- Add at least one human network if required by the product direction
- Benchmark old versus new results on known datasets
- Document provenance and update cadence

Exit criteria:

- New network file is reproducible and versioned
- Results are validated on benchmark inputs
- App can switch networks without code edits

## Immediate Next Actions

1. Finish and merge the HTTPS/layout fixes.
2. Capture the current production instance inventory.
3. Build the replacement AL2023 EC2 host.
4. Only after stable cutover, start the ECS spike.
5. Run the network-refresh project as a separately validated release.
