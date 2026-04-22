#!/bin/bash
# =============================================================================
# Step 1: Create Aurora MySQL Cluster with IAM Authentication Enabled
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

echo "Creating Aurora MySQL cluster: $CLUSTER_ID"

# Convert space-separated subnets to JSON array for security groups
SG_JSON=$(echo "[\"$VPC_SECURITY_GROUP\"]")

aws rds create-db-cluster \
  --db-cluster-identifier "$CLUSTER_ID" \
  --engine aurora-mysql \
  --engine-version "$ENGINE_VERSION" \
  --master-username "$DB_MASTER_USER" \
  --master-user-password "$DB_MASTER_PASS" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$SG_JSON" \
  --enable-iam-database-authentication \
  --no-deletion-protection \
  --region "$REGION"

echo ""
echo "Creating writer instance: $INSTANCE_ID"

aws rds create-db-instance \
  --db-instance-identifier "$INSTANCE_ID" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --db-instance-class "$INSTANCE_CLASS" \
  --engine aurora-mysql \
  --region "$REGION"

echo ""
echo "Waiting for instance to be available (this takes 5-10 minutes)..."
aws rds wait db-instance-available \
  --db-instance-identifier "$INSTANCE_ID" \
  --region "$REGION"

# Print results
ENDPOINT=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text --region "$REGION")
RESOURCE_ID=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].DbClusterResourceId' --output text --region "$REGION")

echo ""
echo "=== Step 1 Complete ==="
echo "  Cluster:     $CLUSTER_ID"
echo "  Endpoint:    $ENDPOINT"
echo "  Resource ID: $RESOURCE_ID"
echo "  IAM Auth:    enabled"
echo ""
echo "Save this Resource ID — you need it for Step 2."
