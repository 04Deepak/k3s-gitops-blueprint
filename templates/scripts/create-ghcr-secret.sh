#!/usr/bin/env bash
# Create GHCR imagePullSecret in a Kubernetes namespace
#
# Usage: ./create-ghcr-secret.sh <namespace> <github_username> <github_pat>
# Example: ./create-ghcr-secret.sh my-project my-org ghp_xxxxxxxxxxxx
#
# The PAT needs `read:packages` scope at minimum.
# Run this on the server (via SSH) or pipe it through:
#   ssh {{SSH_HOST}} 'bash -s' < create-ghcr-secret.sh my-ns my-user ghp_xxx

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <github_username> <github_pat>}"
GH_USER="${2:?Missing GitHub username}"
GH_PAT="${3:?Missing GitHub PAT}"
SECRET_NAME="ghcr-secret"

echo "Creating imagePullSecret '$SECRET_NAME' in namespace '$NAMESPACE'..."

# Create namespace if it doesn't exist
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create or update the secret
kubectl create secret docker-registry "$SECRET_NAME" \
  --namespace="$NAMESPACE" \
  --docker-server=ghcr.io \
  --docker-username="$GH_USER" \
  --docker-password="$GH_PAT" \
  --docker-email="$GH_USER@users.noreply.github.com" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Done. Use in Deployments:"
echo "  spec:"
echo "    template:"
echo "      spec:"
echo "        imagePullSecrets:"
echo "          - name: $SECRET_NAME"
