#!/bin/bash
# =============================================================================
# Step 7: Test End-to-End IAM Authentication through RDS Proxy
# =============================================================================
# NOTE: Run this from an EC2 instance in the same VPC.
#       Requires MySQL 8.0+ client and AWS CLI v2.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.env"

PROXY_ENDPOINT=$(aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" \
  --query 'DBProxies[0].Endpoint' --output text --region "$REGION")

echo "=== End-to-End IAM Auth Test ==="
echo "Proxy endpoint: $PROXY_ENDPOINT"
echo "DB user:        $DB_IAM_USER"
echo ""

# Download RDS CA bundle if not present
CA_BUNDLE="/tmp/global-bundle.pem"
if [[ ! -f "$CA_BUNDLE" ]]; then
  echo "Downloading RDS CA bundle..."
  wget -q -O "$CA_BUNDLE" https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
fi

# Generate IAM auth token against the PROXY endpoint
echo "Generating IAM auth token..."
TOKEN=$(aws rds generate-db-auth-token \
  --hostname "$PROXY_ENDPOINT" \
  --port 3306 \
  --username "$DB_IAM_USER" \
  --region "$REGION")
echo "Token length: ${#TOKEN}"

# Connect through proxy with IAM token
echo ""
echo "Connecting through proxy..."
mysql -h "$PROXY_ENDPOINT" \
  -P 3306 \
  -u "$DB_IAM_USER" \
  --password="$TOKEN" \
  --ssl-mode=REQUIRED \
  --ssl-ca="$CA_BUNDLE" \
  --enable-cleartext-plugin \
  --default-auth=mysql_clear_password \
  -e "
    SELECT 'E2E_IAM_AUTH_SUCCESS' AS result;
    SELECT current_user() AS connected_as;
    SELECT @@aurora_server_id AS server_id;
    SELECT VERSION() AS db_version;
  "

echo ""
echo "=== Test PASSED! ==="
echo "Successfully connected through RDS Proxy using end-to-end IAM authentication."
echo "No Secrets Manager was used."
