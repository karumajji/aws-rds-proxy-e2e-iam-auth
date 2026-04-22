#!/bin/bash
# =============================================================================
# Step 6: Grant Client IAM Role Permission to Connect via Proxy
# =============================================================================
# The client (EC2, Lambda, ECS, etc.) needs rds-db:connect on the PROXY
# resource ID — not the cluster resource ID.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

# Get proxy resource ID from ARN
PROXY_RESOURCE_ID=$(aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" \
  --query 'DBProxies[0].DBProxyArn' --output text --region "$REGION" | grep -oP 'prx-[a-z0-9]+')

echo "Proxy Resource ID: $PROXY_RESOURCE_ID"
echo "Granting rds-db:connect to client role: $CLIENT_ROLE_NAME"

aws iam put-role-policy \
  --role-name "$CLIENT_ROLE_NAME" \
  --policy-name RdsProxyIAMAuth \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"rds-db:connect\",
      \"Resource\": \"arn:aws:rds-db:${REGION}:${ACCOUNT_ID}:dbuser:${PROXY_RESOURCE_ID}/${DB_IAM_USER}\"
    }]
  }"

echo ""
echo "=== Step 6 Complete ==="
echo "  Client role: $CLIENT_ROLE_NAME"
echo "  Permission:  rds-db:connect"
echo "  Resource:    arn:aws:rds-db:${REGION}:${ACCOUNT_ID}:dbuser:${PROXY_RESOURCE_ID}/${DB_IAM_USER}"
echo ""
echo "NOTE: IAM policy changes can take up to 30 seconds to propagate."
