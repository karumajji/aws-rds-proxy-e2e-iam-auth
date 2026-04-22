#!/bin/bash
# =============================================================================
# Step 3: Create RDS Proxy with End-to-End IAM Authentication
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

echo "Creating RDS Proxy: $PROXY_NAME"

# Convert space-separated subnets to JSON array
SUBNET_JSON=$(echo "$VPC_SUBNETS" | tr ' ' '\n' | sed 's/.*/"&"/' | paste -sd, | sed 's/^/[/;s/$/]/')
SG_JSON="[\"$VPC_SECURITY_GROUP\"]"

# Key settings:
#   --default-auth-scheme IAM_AUTH  → enables end-to-end IAM (new feature, Sep 2025)
#   --auth '[]'                     → empty, no Secrets Manager needed
#   --require-tls                   → mandatory for IAM auth
aws rds create-db-proxy \
  --db-proxy-name "$PROXY_NAME" \
  --engine-family MYSQL \
  --default-auth-scheme IAM_AUTH \
  --auth '[]' \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${PROXY_ROLE_NAME}" \
  --vpc-subnet-ids "$SUBNET_JSON" \
  --vpc-security-group-ids "$SG_JSON" \
  --require-tls \
  --region "$REGION"

echo ""
echo "Waiting for proxy to be available..."
while true; do
  STATUS=$(aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" \
    --query 'DBProxies[0].Status' --output text --region "$REGION")
  echo "  Status: $STATUS"
  [[ "$STATUS" == "available" ]] && break
  sleep 15
done

PROXY_ENDPOINT=$(aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" \
  --query 'DBProxies[0].Endpoint' --output text --region "$REGION")

echo ""
echo "=== Step 3 Complete ==="
echo "  Proxy:             $PROXY_NAME"
echo "  Endpoint:          $PROXY_ENDPOINT"
echo "  DefaultAuthScheme: IAM_AUTH"
echo "  Auth:              [] (no secrets)"
echo "  RequireTLS:        true"
