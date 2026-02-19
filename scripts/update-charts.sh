#!/bin/bash
# Update GitLab Helm chart dependencies

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="$SCRIPT_DIR/../charts"

echo "Updating GitLab chart dependencies..."
helm dependency update "$CHARTS_DIR/gitlab"

echo "✅ Chart dependencies updated!"
echo ""
echo "Updated dependencies:"
ls -lh "$CHARTS_DIR/gitlab/charts/"
