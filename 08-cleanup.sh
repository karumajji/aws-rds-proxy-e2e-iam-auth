#!/bin/bash
# =============================================================================
# Step 8: Cleanup — Delete All Test Resources
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

echo "=== Cleanup: E2E IAM Auth Test Resources ==="
echo ""
echo "This will delete:"
echo "  - RDS Proxy:    $PROXY_NAME"
echo "  - DB Instance:  $INSTANCE_ID"
echo "  - DB Cluster:   $CLUSTER_ID"
echo "  - IAM Role:     $PROXY_ROLE_NAME"
echo "  - Client policy: RdsProxyIAMAuth on $CLIENT_ROLE_NAME"
echo ""
read -p "Are you sure? (yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0

echo ""
echo "Deregistering proxy targets..."
aws rds deregister-db-proxy-targets \
  --db-proxy-name "$PROXY_NAME" \
  --db-cluster-identifiers "$CLUSTER_ID" \
  --region "$REGION" 2>/dev/null || true

echo "Deleting proxy: $PROXY_NAME"
aws rds delete-db-proxy \
  --db-proxy-name "$PROXY_NAME" \
  --region "$REGION" 2>/dev/null || true

echo "Deleting instance: $INSTANCE_ID"
aws rds delete-db-instance \
  --db-instance-identifier "$INSTANCE_ID" \
  --skip-final-snapshot \
  --region "$REGION" 2>/dev/null || true

echo "Waiting for instance deletion..."
aws rds wait db-instance-deleted \
  --db-instance-identifier "$INSTANCE_ID" \
  --region "$REGION" 2>/dev/null || true

echo "Deleting cluster: $CLUSTER_ID"
aws rds delete-db-cluster \
  --db-cluster-identifier "$CLUSTER_ID" \
  --skip-final-snapshot \
  --region "$REGION" 2>/dev/null || true

echo "Deleting proxy IAM role: $PROXY_ROLE_NAME"
aws iam delete-role-policy \
  --role-name "$PROXY_ROLE_NAME" \
  --policy-name RdsDbConnect 2>/dev/null || true
aws iam delete-role \
  --role-name "$PROXY_ROLE_NAME" 2>/dev/null || true

echo "Removing client IAM policy: RdsProxyIAMAuth"
aws iam delete-role-policy \
  --role-name "$CLIENT_ROLE_NAME" \
  --policy-name RdsProxyIAMAuth 2>/dev/null || true

echo ""
echo "=== Cleanup Complete ==="
