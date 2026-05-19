#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?image reference required, e.g. 123456789012.dkr.ecr.us-east-2.amazonaws.com/repo:tag}"
SEVERITY="${TRIVY_SEVERITY:-CRITICAL,HIGH}"

if ! command -v trivy >/dev/null 2>&1; then
  echo "Installing Trivy..."
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
fi

echo "Scanning image ${IMAGE} (severity: ${SEVERITY})"
trivy image \
  --exit-code 1 \
  --scanners vuln \
  --severity "${SEVERITY}" \
  --ignore-unfixed \
  --no-progress \
  "${IMAGE}"

echo "Trivy scan passed for ${IMAGE}"
