#!/bin/bash
# =============================================================================
# Step 4: Register Aurora Cluster as RDS Proxy Target
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

echo "Registering cluster $CLUSTER_ID as target for proxy $PROXY_NAME"

aws rds register-db-proxy-targets \
  --db-proxy-name "$PROXY_NAME" \
  --db-cluster-identifiers "$CLUSTER_ID" \
  --region "$REGION"

echo ""
echo "Waiting for target to be healthy..."
for i in $(seq 1 20); do
  sleep 15
  STATE=$(aws rds describe-db-proxy-targets --db-proxy-name "$PROXY_NAME" \
    --query 'Targets[?Type==`RDS_INSTANCE`].TargetHealth.State' \
    --output text --region "$REGION")
  echo "  Target health: $STATE"
  [[ "$STATE" == "AVAILABLE" ]] && break
done

echo ""
echo "=== Step 4 Complete ==="
aws rds describe-db-proxy-targets --db-proxy-name "$PROXY_NAME" \
  --query 'Targets[*].[RdsResourceId,Type,TargetHealth.State]' \
  --output table --region "$REGION"
