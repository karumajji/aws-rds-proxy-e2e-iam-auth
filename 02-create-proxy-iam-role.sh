#!/bin/bash
# =============================================================================
# Step 2: Create IAM Role for RDS Proxy with rds-db:connect Permission
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

echo "Creating IAM role: $PROXY_ROLE_NAME"

# Create role with RDS trust policy
aws iam create-role \
  --role-name "$PROXY_ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "rds.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

# Get cluster resource ID
CLUSTER_RESOURCE_ID=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].DbClusterResourceId' \
  --output text --region "$REGION")

echo "Cluster Resource ID: $CLUSTER_RESOURCE_ID"

# Attach rds-db:connect policy — this is what lets the proxy authenticate to the DB via IAM
# The wildcard /* allows the proxy to connect as any DB user
aws iam put-role-policy \
  --role-name "$PROXY_ROLE_NAME" \
  --policy-name RdsDbConnect \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"rds-db:connect\",
      \"Resource\": \"arn:aws:rds-db:${REGION}:${ACCOUNT_ID}:dbuser:${CLUSTER_RESOURCE_ID}/*\"
    }]
  }"

echo ""
echo "=== Step 2 Complete ==="
echo "  Role:   $PROXY_ROLE_NAME"
echo "  ARN:    arn:aws:iam::${ACCOUNT_ID}:role/${PROXY_ROLE_NAME}"
echo "  Policy: rds-db:connect on ${CLUSTER_RESOURCE_ID}/*"
echo ""
echo "NOTE: No Secrets Manager permissions needed for end-to-end IAM auth."
