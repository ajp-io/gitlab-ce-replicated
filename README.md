# GitLab Community Edition for Replicated

This repository contains the packaging of GitLab Community Edition for deployment via Replicated, supporting both Embedded Cluster and KOTS installation methods.

## Overview

**GitLab Version**: 18.8.4 (Helm chart 9.8.4)
**Replicated App**: gitlab-community-edition
**Deployment Methods**: Embedded Cluster, KOTS on existing cluster

## Features

### Core Features
- GitLab Community Edition with all standard features
- Integrated PostgreSQL database (embedded or external)
- Integrated Redis cache (embedded only)
- Integrated MinIO object storage (embedded only)
- Automatic HTTPS with Let's Encrypt (Embedded Cluster)

### Optional Features
- **Container Registry**: Enable/disable integrated Docker registry
- **GitLab Runner**: Enable/disable CI/CD runner for pipeline execution

### Configuration Options
- Root administrator password
- Custom hostname (Embedded Cluster)
- Let's Encrypt environment (staging/production)
- PostgreSQL database (embedded or external)
- Container Registry (enable/disable)
- GitLab Runner (enable/disable, configurable replicas)

## Installation Methods

### Embedded Cluster

Installs GitLab with all dependencies (Kubernetes, ingress-nginx, cert-manager) in a single installation:

```bash
curl -fsSL https://k8s.kurl.sh/gitlab-community-edition | sudo bash
```

**Features**:
- Includes Kubernetes cluster
- Automatic HTTPS with Let's Encrypt
- Ingress-nginx for routing
- Cert-manager for certificate management
- Access via custom domain

### KOTS on Existing Cluster

Installs GitLab on an existing Kubernetes cluster using KOTS:

```bash
kubectl kots install gitlab-community-edition
```

**Requirements**:
- Existing Kubernetes cluster (v1.21+)
- kubectl access
- 16GB RAM, 8 vCPU minimum

**Features**:
- Uses ClusterIP services
- Port-forward for UI access
- Recommended for integration with existing infrastructure

## Resource Requirements

### Minimum (Testing)
- **CPU**: 8 vCPU
- **RAM**: 16GB
- **Storage**: 50GB

### Recommended (Production)
- **CPU**: 16 vCPU
- **RAM**: 32GB
- **Storage**: 100GB+

## Architecture

### Components

**Core GitLab Components**:
- **Webservice**: Main GitLab application (Rails)
- **Sidekiq**: Background job processor
- **Gitaly**: Git repository storage
- **GitLab Shell**: SSH access for Git operations
- **Toolbox**: Administrative utilities
- **Migrations**: Database migration job

**Optional Components**:
- **Registry**: Docker container registry
- **Runner**: CI/CD pipeline executor

**Dependencies**:
- **PostgreSQL**: Database (embedded or external)
- **Redis**: Cache and session storage (embedded)
- **MinIO**: Object storage for artifacts, uploads, LFS (embedded)

**Embedded Cluster Only**:
- **ingress-nginx**: HTTP/HTTPS routing
- **cert-manager**: TLS certificate management

### Deployment Weights

Components are deployed in order:
1. **Weight -20**: ingress-nginx (if Embedded Cluster)
2. **Weight -10**: cert-manager (if Embedded Cluster)
3. **Weight 0**: GitLab (with all sub-components)

## Configuration

### Database

**Embedded PostgreSQL** (default):
- Automatically deployed as StatefulSet
- Suitable for development/testing
- Requires persistent storage

**External PostgreSQL**:
- Connect to existing PostgreSQL server
- Required for production deployments
- Supports SSL/TLS connections

### Optional Features

**Container Registry**:
- Enable to store Docker images
- Accessible via subdomain (registry.yourdomain.com)
- Requires additional storage

**GitLab Runner**:
- Enable to execute CI/CD pipelines
- Runs as pods in the same cluster
- Configurable number of replicas
- Note: Shares cluster resources with GitLab

## Security

### Default Credentials
- **Username**: root
- **Password**: Set during installation via config page

### TLS/HTTPS
- **Embedded Cluster**: Automatic Let's Encrypt certificates
- **KOTS**: Manual TLS configuration recommended for production

### Database Security
- **Embedded**: Password-protected, cluster-internal only
- **External**: Supports SSL/TLS, configurable SSL mode

## Backup and Restore

GitLab includes the `gitlab-toolbox` pod for backup operations:

```bash
# Backup
kubectl exec -it <toolbox-pod> -- backup-utility --skip=registry

# Restore
kubectl exec -it <toolbox-pod> -- backup-utility --restore
```

**Velero Integration**: KOTS includes Velero backup/restore capabilities for the entire application.

## Troubleshooting

### Common Issues

**Migrations not completing**:
- Check logs: `kubectl logs job/gitlab-migrations-1`
- Ensure database is accessible
- Verify database credentials

**Pods not starting**:
- Check resource availability: `kubectl top nodes`
- Verify persistent volume claims: `kubectl get pvc`
- Check events: `kubectl get events --sort-by='.lastTimestamp'`

**UI not accessible (Embedded Cluster)**:
- Verify ingress: `kubectl get ingress`
- Check cert-manager: `kubectl get certificaterequest`
- Verify DNS points to cluster

**UI not accessible (KOTS)**:
- Use port-forward: `kubectl port-forward svc/gitlab-webservice-default 8080:8080`
- Access via http://localhost:8080

### Logs

```bash
# Webservice logs
kubectl logs -l app=webservice -c webservice

# Sidekiq logs
kubectl logs -l app=sidekiq -c sidekiq

# Migrations logs
kubectl logs job/gitlab-migrations-1

# All GitLab pods
kubectl logs -l release=gitlab --tail=100
```

## Development

### Creating a Release

```bash
export REPLICATED_APP=gitlab-community-edition
./scripts/release.sh <version>
```

### Testing

```bash
# Test embedded cluster installation
./scripts/test-embedded-install.sh

# Test KOTS installation
./scripts/test-kots-install.sh
```

## Support

- **GitLab Documentation**: https://docs.gitlab.com/
- **Replicated Documentation**: https://docs.replicated.com/
- **Issues**: Report issues via GitHub Issues

## License

GitLab Community Edition is licensed under the MIT License.
This packaging is provided as-is for use with Replicated.
