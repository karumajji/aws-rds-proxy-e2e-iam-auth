#!/bin/bash
# =============================================================================
# End-to-End IAM Authentication through RDS Proxy — Complete Setup Script
# =============================================================================
# No Secrets Manager required. Proxy authenticates to DB using IAM directly.
#
# Prerequisites:
#   - AWS CLI v2
#   - MySQL 8.0+ client
#   - jq
#
# Usage:
#   chmod +x e2e-iam-auth-setup.sh
#   ./e2e-iam-auth-setup.sh setup     # Create all resources
#   ./e2e-iam-auth-setup.sh test      # Test E2E IAM auth connection
#   ./e2e-iam-auth-setup.sh verify    # Verify all configuration
#   ./e2e-iam-auth-setup.sh cleanup   # Delete all resources
# =============================================================================

set -euo pipefail

# ---- CONFIGURATION (edit these) ----
REGION="us-east-1"
ACCOUNT_ID="123456789012"           # Replace with your AWS account ID
CLUSTER_ID="e2e-iam-test"
INSTANCE_ID="e2e-iam-test-writer"
INSTANCE_CLASS="db.t3.medium"
PROXY_NAME="e2e-iam-proxy"
PROXY_ROLE_NAME="e2e-iam-proxy-role"
DB_MASTER_USER="admin"
DB_MASTER_PASS="CHANGE_ME"
DB_IAM_USER="iam_user"
DB_SUBNET_GROUP="your-db-subnet-group"
VPC_SECURITY_GROUPS='["sg-xxxxxxxxx"]'
VPC_SUBNETS='["subnet-aaaa","subnet-bbbb","subnet-cccc"]'
ENGINE_VERSION="8.0.mysql_aurora.3.08.0"

# ---- DERIVED VALUES ----
PROXY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PROXY_ROLE_NAME}"

# ---- HELPERS ----
log() { echo -e "\n\033[1;32m==>\033[0m $1"; }
err() { echo -e "\n\033[1;31mERROR:\033[0m $1" >&2; }

wait_for_cluster() {
    log "Waiting for cluster ${CLUSTER_ID} to be available..."
    aws rds wait db-cluster-available --db-cluster-identifier "$CLUSTER_ID" --region "$REGION" 2>/dev/null || \
    while true; do
        STATUS=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
            --query 'DBClusters[0].Status' --output text --region "$REGION")
        echo "  Cluster status: $STATUS"
        [[ "$STATUS" == "available" ]] && break
        sleep 15
    done
}

wait_for_instance() {
    log "Waiting for instance ${INSTANCE_ID} to be available..."
    aws rds wait db-instance-available --db-instance-identifier "$INSTANCE_ID" --region "$REGION"
}

wait_for_proxy() {
    log "Waiting for proxy ${PROXY_NAME} to be available..."
    aws rds wait db-proxy-available --db-proxy-name "$PROXY_NAME" --region "$REGION" 2>/dev/null || \
    while true; do
        STATUS=$(aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" \
            --query 'DBProxies[0].Status' --output text --region "$REGION")
        echo "  Proxy status: $STATUS"
        [[ "$STATUS" == "available" ]] && break
        sleep 15
    done
}

get_cluster_resource_id() {
    aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
        --query 'DBClusters[0].DbClusterResourceId' --output text --region "$REGION"
}

get_cluster_endpoint() {
    aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
        --query 'DBClusters[0].Endpoint' --output text --region "$REGION"
}

get_proxy_endpoint() {
    aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" \
        --query 'DBProxies[0].Endpoint' --output text --region "$REGION"
}

get_proxy_resource_id() {
    aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" \
        --query 'DBProxies[0].DBProxyArn' --output text --region "$REGION" | grep -oP 'prx-[a-z0-9]+'
}

# =============================================================================
# SETUP
# =============================================================================
do_setup() {
    log "Step 1: Create Aurora MySQL cluster with IAM auth enabled"
    aws rds create-db-cluster \
        --db-cluster-identifier "$CLUSTER_ID" \
        --engine aurora-mysql \
        --engine-version "$ENGINE_VERSION" \
        --master-username "$DB_MASTER_USER" \
        --master-user-password "$DB_MASTER_PASS" \
        --db-subnet-group-name "$DB_SUBNET_GROUP" \
        --vpc-security-group-ids "$VPC_SECURITY_GROUPS" \
        --enable-iam-database-authentication \
        --no-deletion-protection \
        --region "$REGION" \
        --output text --query 'DBCluster.DBClusterIdentifier'

    log "Step 2: Create writer instance"
    aws rds create-db-instance \
        --db-instance-identifier "$INSTANCE_ID" \
        --db-cluster-identifier "$CLUSTER_ID" \
        --db-instance-class "$INSTANCE_CLASS" \
        --engine aurora-mysql \
        --region "$REGION" \
        --output text --query 'DBInstance.DBInstanceIdentifier'

    log "Step 3: Create IAM role for proxy"
    aws iam create-role \
        --role-name "$PROXY_ROLE_NAME" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": { "Service": "rds.amazonaws.com" },
                "Action": "sts:AssumeRole"
            }]
        }' --output text --query 'Role.Arn'

    wait_for_cluster
    CLUSTER_RESOURCE_ID=$(get_cluster_resource_id)
    log "Cluster Resource ID: $CLUSTER_RESOURCE_ID"

    log "Step 4: Attach rds-db:connect policy to proxy role"
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

    log "Step 5: Create RDS Proxy with DefaultAuthScheme IAM_AUTH"
    aws rds create-db-proxy \
        --db-proxy-name "$PROXY_NAME" \
        --engine-family MYSQL \
        --default-auth-scheme IAM_AUTH \
        --auth '[]' \
        --role-arn "$PROXY_ROLE_ARN" \
        --vpc-subnet-ids "$VPC_SUBNETS" \
        --vpc-security-group-ids "$VPC_SECURITY_GROUPS" \
        --require-tls \
        --region "$REGION" \
        --output text --query 'DBProxy.Endpoint'

    wait_for_instance
    wait_for_proxy

    log "Step 6: Register cluster as proxy target"
    aws rds register-db-proxy-targets \
        --db-proxy-name "$PROXY_NAME" \
        --db-cluster-identifiers "$CLUSTER_ID" \
        --region "$REGION" \
        --output text --query 'DBProxyTargets[*].RdsResourceId'

    log "Waiting for proxy target to be healthy..."
    sleep 30
    aws rds describe-db-proxy-targets \
        --db-proxy-name "$PROXY_NAME" \
        --query 'Targets[*].[RdsResourceId,Type,TargetHealth.State]' \
        --output table --region "$REGION"

    CLUSTER_ENDPOINT=$(get_cluster_endpoint)
    log "Step 7: Create IAM-enabled database user"
    echo "Run this SQL on the cluster (from an EC2 in the same VPC):"
    echo ""
    echo "  mysql -h ${CLUSTER_ENDPOINT} -P 3306 -u ${DB_MASTER_USER} -p'${DB_MASTER_PASS}' -e \""
    echo "    CREATE USER IF NOT EXISTS '${DB_IAM_USER}'@'%' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';"
    echo "    ALTER USER '${DB_IAM_USER}'@'%' REQUIRE SSL;"
    echo "    GRANT SELECT, INSERT, UPDATE, DELETE ON *.* TO '${DB_IAM_USER}'@'%';"
    echo "  \""
    echo ""

    PROXY_RESOURCE_ID=$(get_proxy_resource_id)
    log "Step 8: Grant client rds-db:connect for proxy"
    echo "Attach this policy to your client's IAM role:"
    echo ""
    echo "  {"
    echo "    \"Version\": \"2012-10-17\","
    echo "    \"Statement\": [{"
    echo "      \"Effect\": \"Allow\","
    echo "      \"Action\": \"rds-db:connect\","
    echo "      \"Resource\": \"arn:aws:rds-db:${REGION}:${ACCOUNT_ID}:dbuser:${PROXY_RESOURCE_ID}/${DB_IAM_USER}\""
    echo "    }]"
    echo "  }"
    echo ""

    log "Setup complete!"
    echo "  Cluster:  $CLUSTER_ID"
    echo "  Proxy:    $PROXY_NAME"
    echo "  Endpoint: $(get_proxy_endpoint)"
}

# =============================================================================
# TEST
# =============================================================================
do_test() {
    PROXY_ENDPOINT=$(get_proxy_endpoint)
    log "Testing E2E IAM auth through proxy: ${PROXY_ENDPOINT}"

    # Download CA bundle if not present
    if [[ ! -f /tmp/global-bundle.pem ]]; then
        log "Downloading RDS CA bundle..."
        wget -q -O /tmp/global-bundle.pem \
            https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
    fi

    # Generate IAM auth token
    TOKEN=$(aws rds generate-db-auth-token \
        --hostname "$PROXY_ENDPOINT" \
        --port 3306 \
        --username "$DB_IAM_USER" \
        --region "$REGION")
    echo "Token length: ${#TOKEN}"

    # Connect through proxy
    mysql -h "$PROXY_ENDPOINT" \
        -P 3306 \
        -u "$DB_IAM_USER" \
        --password="$TOKEN" \
        --ssl-mode=REQUIRED \
        --ssl-ca=/tmp/global-bundle.pem \
        --enable-cleartext-plugin \
        --default-auth=mysql_clear_password \
        -e "SELECT 'E2E_IAM_AUTH_SUCCESS' AS result; SELECT current_user(); SELECT @@aurora_server_id; SELECT VERSION();"

    log "Test PASSED!"
}

# =============================================================================
# VERIFY
# =============================================================================
do_verify() {
    log "1. Cluster IAM auth enabled?"
    aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
        --query 'DBClusters[0].IAMDatabaseAuthenticationEnabled' \
        --output text --region "$REGION"

    log "2. Proxy DefaultAuthScheme?"
    aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" \
        --query 'DBProxies[0].{DefaultAuthScheme:DefaultAuthScheme,Auth:Auth,RequireTLS:RequireTLS}' \
        --region "$REGION"

    log "3. Proxy target health?"
    aws rds describe-db-proxy-targets --db-proxy-name "$PROXY_NAME" \
        --query 'Targets[*].[RdsResourceId,Type,TargetHealth.State]' \
        --output table --region "$REGION"

    log "4. Proxy role policy?"
    aws iam get-role-policy \
        --role-name "$PROXY_ROLE_NAME" \
        --policy-name RdsDbConnect \
        --query 'PolicyDocument.Statement[0].Resource' \
        --output text
}

# =============================================================================
# CLEANUP
# =============================================================================
do_cleanup() {
    log "WARNING: This will delete all E2E IAM test resources."
    read -p "Are you sure? (yes/no): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0

    log "Deregistering proxy targets..."
    aws rds deregister-db-proxy-targets \
        --db-proxy-name "$PROXY_NAME" \
        --db-cluster-identifiers "$CLUSTER_ID" \
        --region "$REGION" 2>/dev/null || true

    log "Deleting proxy..."
    aws rds delete-db-proxy \
        --db-proxy-name "$PROXY_NAME" \
        --region "$REGION" 2>/dev/null || true

    log "Deleting DB instance..."
    aws rds delete-db-instance \
        --db-instance-identifier "$INSTANCE_ID" \
        --skip-final-snapshot \
        --region "$REGION" 2>/dev/null || true

    log "Waiting for instance deletion..."
    aws rds wait db-instance-deleted \
        --db-instance-identifier "$INSTANCE_ID" \
        --region "$REGION" 2>/dev/null || true

    log "Deleting cluster..."
    aws rds delete-db-cluster \
        --db-cluster-identifier "$CLUSTER_ID" \
        --skip-final-snapshot \
        --region "$REGION" 2>/dev/null || true

    log "Deleting IAM role..."
    aws iam delete-role-policy \
        --role-name "$PROXY_ROLE_NAME" \
        --policy-name RdsDbConnect 2>/dev/null || true
    aws iam delete-role \
        --role-name "$PROXY_ROLE_NAME" 2>/dev/null || true

    log "Cleanup complete!"
}

# =============================================================================
# MAIN
# =============================================================================
case "${1:-help}" in
    setup)   do_setup   ;;
    test)    do_test    ;;
    verify)  do_verify  ;;
    cleanup) do_cleanup ;;
    *)
        echo "Usage: $0 {setup|test|verify|cleanup}"
        echo ""
        echo "  setup   - Create cluster, proxy, IAM role, and configure E2E IAM auth"
        echo "  test    - Test E2E IAM auth connection through proxy"
        echo "  verify  - Verify all configuration is correct"
        echo "  cleanup - Delete all test resources"
        exit 1
        ;;
esac
