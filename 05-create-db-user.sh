#!/bin/bash
# =============================================================================
# Step 5: Create Database User with AWSAuthenticationPlugin
# =============================================================================
# NOTE: Run this from an EC2 instance in the same VPC as the Aurora cluster.
#       Requires MySQL 8.0+ client installed.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

CLUSTER_ENDPOINT=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text --region "$REGION")

echo "Connecting to cluster: $CLUSTER_ENDPOINT"
echo "Creating IAM-enabled user: $DB_IAM_USER"

mysql -h "$CLUSTER_ENDPOINT" \
  -P 3306 \
  -u "$DB_MASTER_USER" \
  --password="$DB_MASTER_PASS" \
  --ssl-mode=REQUIRED \
  -e "
    CREATE USER IF NOT EXISTS '${DB_IAM_USER}'@'%' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';
    ALTER USER '${DB_IAM_USER}'@'%' REQUIRE SSL;
    GRANT SELECT, INSERT, UPDATE, DELETE ON *.* TO '${DB_IAM_USER}'@'%';
    SELECT user, host, plugin FROM mysql.user WHERE user = '${DB_IAM_USER}';
  "

echo ""
echo "=== Step 5 Complete ==="
echo "  User:   ${DB_IAM_USER}@%"
echo "  Plugin: AWSAuthenticationPlugin"
echo "  SSL:    required"
