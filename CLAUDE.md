# Claude Code Instructions

## Release Workflow

When you ask me to "create a release" or "make a release", I should:

1. **Get current version and increment patch**
   - Get latest release: `replicated release ls | head -10`
   - Find the most recent release with a semantic version (e.g., `18.8.4`)
   - Auto-increment patch version (e.g., `18.8.4` → `18.8.5`)

2. **Package Helm charts**
   - Clean existing packages: `rm -f manifests/*.tgz 2>/dev/null || true`
   - Update GitLab dependencies: `helm dependency update charts/gitlab`
   - Package charts:
     - `helm package charts/gitlab -d manifests -u`
     - `helm package charts/ingress-nginx -d manifests -u`
     - `helm package charts/cert-manager -d manifests -u`

3. **Create and promote release**
   - `replicated release create --lint --yaml-dir ./manifests --promote Dev --version [NEW_VERSION]`

4. **Cleanup**
   - `rm -f manifests/*.tgz`
   - `rm -rf charts/gitlab/charts/`
   - Show result: `replicated release ls | head -5`

**Channel**: All releases are promoted to the **Dev** channel by default.

**App Slug**: `gitlab-community-edition`

**Note**: Production credentials are already default in your shell (set in .zshrc), but ensure `REPLICATED_APP=gitlab-community-edition` is set for this project.

## Replicated SDK Configuration

**Important**: `global.replicated.*` values (like `global.replicated.customerEmail`) are automatically injected by KOTS at runtime. These values will NOT be present in the static values.yaml files but are available when the application is deployed through KOTS. Do not treat missing `global.replicated` values as configuration errors.

## Testing Commands

- **Embedded Cluster Test**: `./scripts/test-embedded-install.sh`
- **KOTS Test**: `./scripts/test-kots-install.sh`

## Important Notes

- GitLab chart version: 9.8.4 (GitLab CE 18.8.4)
- Redis and MinIO are always embedded (no external configuration)
- PostgreSQL supports both embedded and external
- Container Registry and GitLab Runner are optional features
