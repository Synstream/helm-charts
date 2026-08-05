# SynStream Helm Charts

This repository contains Helm charts for deploying SynStream components on Kubernetes.

## Usage

[Helm](https://helm.sh) must be installed to use the charts. Please refer to Helm's [documentation](https://helm.sh/docs) to get started.

Once Helm has been set up correctly, add the repo as follows:

```bash
helm repo add roots-innovation https://rootsinnovation.github.io/helm-charts
helm repo update
```

You can then run `helm search repo roots-innovation` to see the available charts.

## Quick Start

Deploy the complete SynStream platform with these steps:

```bash
# Step 1: Add Helm repository
helm repo add roots-innovation https://rootsinnovation.github.io/helm-charts
helm repo update

# Step 2: Install Synstream Operator
helm install synstream-operator roots-innovation/synstream-operator \
  --namespace synstream-operator \
  --create-namespace

# Step 3: Install Synstream Manager
helm install synstream-manager roots-innovation/synstream-manager \
  --namespace synstream-operator

# Step 4: Install Synstream Console (Platform)
helm install synstream-console roots-innovation/synstream-console \
  --namespace synstream \
  --create-namespace \
  --set 'global.imagePullSecrets[0].name=ghcr-imagepullsecret'

helm install synstream-console-project roots-innovation/synstream-console-project \
  --namespace synstream-project \
  --create-namespace \
  --set 'global.imagePullSecrets[0].name=ghcr-imagepullsecret'
```

## Available Charts

### synstream-console
Complete SynStream platform deployment (umbrella chart) including:
- Frontend console (synstream-console-vite)
- Backend services: Auth, AI
- K8s resource management service
- Reverse proxy service
- Nginx gateway

```bash
# Install full platform
helm install console roots-innovation/synstream-console \
  --namespace synstream \
  --create-namespace

# Install with ImagePullSecret
helm install console roots-innovation/synstream-console \
  --namespace synstream \
  --create-namespace \
  --set 'global.imagePullSecrets[0].name=ghcr-imagepullsecret'
```

[View synstream-console documentation →](charts/synstream-console/README.md)

### synstream-operator
Kubernetes operator for managing SynStream flows and custom resources.

```bash
helm install synstream-operator roots-innovation/synstream-operator \
  --namespace synstream-operator \
  --create-namespace
```

[View synstream-operator documentation →](charts/synstream-operator/README.md)

### synstream-manager
SynStream Manager service for flow and license management.

```bash
helm install synstream-manager roots-innovation/synstream-manager \
  --namespace synstream-operator
```

[View synstream-manager documentation →](charts/synstream-manager/README.md)

## Uninstalling

To uninstall a chart:

```bash
helm uninstall <release-name>
```

For example:
```bash
helm uninstall synstream-console --namespace synstream
helm uninstall synstream-operator --namespace synstream-operator
helm uninstall synstream-manager --namespace synstream-operator
```

## Development

### Testing Charts Locally

```bash
# Lint a chart
helm lint charts/<chart-name>

# Test rendering templates
helm template test-release charts/<chart-name>

# Install from local directory
helm install test-release charts/<chart-name>
```

### Chart Structure

Each chart follows standard Helm best practices:
- `Chart.yaml` - Chart metadata
- `values.yaml` - Default configuration values
- `templates/` - Kubernetes resource templates
- `README.md` - Chart-specific documentation

## Operations

Beyond the charts, this repository holds the operational tooling for the nonprod
cluster, because backup and recovery span every service and belong to none of
the per-service repositories:

- `scripts/synstream-backup.sh` — nightly backup, run from cron on the node
- `scripts/synstream-restore.sh` — restore counterpart, safe by default
- `docs/backup-dr/` — the DR plan, runbook, and S3 lifecycle configuration

Neither directory is packaged or released: `release.yml` only ever touches
`charts/`. See `docs/backup-dr/README.md`.

## Contributing

When adding or updating charts:
1. Update the chart version in `Chart.yaml`
2. Test locally with `helm lint` and `helm template`
3. Update chart-specific README
4. Commit and push to main branch
5. GitHub Actions will automatically package and release the chart

## License

Apache License 2.0 - see individual chart LICENSE files for details.
