# End-to-End IAM Authentication through Amazon RDS Proxy

## Overview

This guide configures **end-to-end IAM authentication** for Amazon RDS Proxy with Aurora MySQL. With this setup, both the client-to-proxy and proxy-to-database connections use IAM authentication — **no Secrets Manager required**.

This feature was [announced in September 2025](https://aws.amazon.com/about-aws/whats-new/2025/09/amazon-rds-proxy-end-to-end-iam-authentication/) and is available for MySQL and PostgreSQL engines in all AWS Regions where RDS Proxy is supported.

## Architecture

```
Client App                      RDS Proxy                     Aurora MySQL
  │                               │                              │
  │  generate-db-auth-token       │                              │
  │  (against proxy endpoint)     │                              │
  │                               │                              │
  │  IAM Token ──────────────────►│                              │
  │  Proxy validates via ARPS     │                              │
  │  (cached after first call)    │                              │
  │                               │  Proxy generates its own     │
  │                               │  IAM token using its role    │
  │                               │  (rds-db:connect)            │
  │                               │ ────────────────────────────►│
  │                               │  DB validates via IAM agent  │
  │                               │  (token cached & reused)     │
  │                               │                              │
  │ ◄──────── Results ────────────│◄──────── Pooled connection ──│
```

When a client sends an IAM auth token to RDS Proxy:                                                                                                       

1. Proxy sends the token to ARPS in the same region
2. ARPS verifies the signature, checks expiration, and evaluates the IAM policies attached to the caller's identity
3. ARPS returns allow/deny
4. Proxy caches the result (crypto offload cache) so it doesn't call ARPS again for the same token
**Note**: ARPS stands for AWS Regional Policy Service — it's an internal AWS service that evaluates IAM policies and validates authentication tokens.

**In the worst case (no caching), every connection triggers two IAM validation calls.** Proxy's value is amortizing those calls across many client requests via connection pooling.  


## Prerequisites

- AWS CLI v2
- MySQL 8.0+ client (`--enable-cleartext-plugin` support required)
- Python 3.8+ with `boto3` and `mysql-connector-python` (for `app.py`)
- An existing VPC with subnets spanning 2+ AZs
- A security group allowing port 3306 within itself

## Repository Contents

```
├── README.md                      # This file
├── config.env                     # Environment variables (edit per environment)
├── 01-create-aurora-cluster.sh    # Create cluster with IAM auth enabled
├── 02-create-proxy-iam-role.sh    # Create proxy IAM role with rds-db:connect
├── 03-create-rds-proxy.sh         # Create proxy with DefaultAuthScheme: IAM_AUTH
├── 04-register-proxy-target.sh    # Register cluster as proxy target
├── 05-create-db-user.sh           # Create DB user with AWSAuthenticationPlugin
├── 06-grant-client-permissions.sh # Grant client role rds-db:connect for proxy
├── 07-test-connection.sh          # Test E2E IAM auth (bash/mysql client)
├── 08-cleanup.sh                  # Delete all resources
├── app.py                         # Python demo application
└── e2e-iam-auth-setup.sh          # All-in-one setup script
```

## Quick Start

### Option A: Step-by-Step Scripts

1. Edit `config.env` with your environment values
2. Run each step in order:

```bash
source config.env
./01-create-aurora-cluster.sh
./02-create-proxy-iam-role.sh
./03-create-rds-proxy.sh
./04-register-proxy-target.sh
./05-create-db-user.sh           # Run from EC2 in the same VPC
./06-grant-client-permissions.sh
./07-test-connection.sh           # Run from EC2 in the same VPC
```

### Option B: All-in-One Script

```bash
./e2e-iam-auth-setup.sh setup    # Create everything
./e2e-iam-auth-setup.sh test     # Test the connection
./e2e-iam-auth-setup.sh verify   # Check all config
./e2e-iam-auth-setup.sh cleanup  # Tear it all down
```

### Option C: Python Demo Application

```bash
pip install boto3 mysql-connector-python
python3 app.py
```

With custom config:

```bash
PROXY_ENDPOINT=your-proxy.proxy-xxx.us-east-1.rds.amazonaws.com \
DB_USER=iam_user \
AWS_REGION=us-east-1 \
python3 app.py
```

**Sample output:**

```
============================================================
  E2E IAM Auth Demo - RDS Proxy + Aurora MySQL
============================================================
  Proxy:  e2e-iam-proxy.proxy-xxx.us-east-1.rds.amazonaws.com
  User:   iam_user
  Region: us-east-1

[1] Generating IAM auth token...
    Connected in 0.26s

[2] Verifying connection identity...
    User:      iam_user@%
    Server:    e2e-iam-test-writer
    Version:   8.0.39

[3] Verifying SSL/TLS...
    Cipher:    TLS_AES_256_GCM_SHA384

[4] Running sample queries...
    Server time: 2026-04-22 19:57:32
    Buffer pool: 1500.00000000 MB
    Databases:   information_schema, mysql, performance_schema, sys

[5] Connection reuse (proxy pooling benefit)...
    3 queries on same connection - no re-auth
    (Proxy reuses backend DB connection)

============================================================
  All tests passed - E2E IAM auth working!
  No passwords or Secrets Manager used.
============================================================
```

## Setup Steps Explained

| Step | Script | What It Does |
|------|--------|-------------|
| 1 | `01-create-aurora-cluster.sh` | Creates Aurora MySQL cluster with `--enable-iam-database-authentication` |
| 2 | `02-create-proxy-iam-role.sh` | Creates IAM role with `rds-db:connect` permission on the cluster resource ID |
| 3 | `03-create-rds-proxy.sh` | Creates RDS Proxy with `--default-auth-scheme IAM_AUTH` and `--auth '[]'` (no secrets) |
| 4 | `04-register-proxy-target.sh` | Registers the Aurora cluster as the proxy's backend target |
| 5 | `05-create-db-user.sh` | Creates a MySQL user with `AWSAuthenticationPlugin` and `REQUIRE SSL` |
| 6 | `06-grant-client-permissions.sh` | Grants `rds-db:connect` on the **proxy** resource ID to the client's IAM role |
| 7 | `07-test-connection.sh` | Generates an IAM token and connects through the proxy using `mysql` CLI |
| 8 | `08-cleanup.sh` | Deletes all resources (proxy, cluster, IAM role, policies) |

## Key Differences from Standard IAM Auth

| | Standard IAM Auth | End-to-End IAM Auth |
|---|---|---|
| Client → Proxy | IAM token | IAM token (same) |
| Proxy → Database | Secrets Manager credentials | **IAM token (no secrets)** |
| Secrets Manager required? | Yes | **No** |
| Key API setting | `IAMAuth: REQUIRED` | **`DefaultAuthScheme: IAM_AUTH`** |
| Auth config | Secrets ARN in `--auth` | **`--auth '[]'` (empty)** |
| Credential rotation | Must rotate secrets | **Automatic (IAM tokens expire in 15 min)** |

## IAM Policies Required

### Proxy Role (Proxy → Database)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "rds-db:connect",
    "Resource": "arn:aws:rds-db:REGION:ACCOUNT_ID:dbuser:CLUSTER_RESOURCE_ID/*"
  }]
}
```

### Client Role (Client → Proxy)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "rds-db:connect",
    "Resource": "arn:aws:rds-db:REGION:ACCOUNT_ID:dbuser:PROXY_RESOURCE_ID/DB_USER"
  }]
}
```

> **Note:** The proxy role uses the **cluster** resource ID. The client role uses the **proxy** resource ID.

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| `(using password: NO)` | MySQL client < 8.0 doesn't support cleartext with long tokens | Upgrade to MySQL 8.0+ client |
| `ubyte format requires 0 <= number <= 255` | `mysql-connector-python` < 8.2.0 bug | Upgrade to `mysql-connector-python >= 9.0` |
| `SSL connection error: certificate verify failed` | Old OpenSSL can't verify newer RDS certs | Use `--ssl-mode=REQUIRED` or upgrade OS |
| `Access denied (using password: YES)` | Client IAM role missing `rds-db:connect` | Add policy with proxy resource ID |
| `--enable-cleartext-plugin` ignored | Must also pass `--default-auth` | Use both: `--enable-cleartext-plugin --default-auth=mysql_clear_password` |

## Important Notes

- **MySQL 8.0+ client required**: Older clients (5.7, MariaDB 5.5) have bugs with long IAM tokens and the cleartext plugin.
- **TLS is mandatory**: The proxy must have `--require-tls` enabled for IAM auth.
- **Two IAM policies needed**: One for the proxy role (to auth to the DB), one for the client role (to auth to the proxy).
- **Connection pooling is the value**: Proxy doesn't make IAM auth faster — it makes it happen less often by reusing backend connections.
- **Token lifetime**: IAM auth tokens are valid for 15 minutes. Generate a new token for each new connection.

## Supported Versions

- Aurora MySQL 3.x (MySQL 8.0 compatible) — all versions
- Aurora MySQL 2.07+ and 2.11+ (MySQL 5.7 compatible)
- Available in all AWS Regions where RDS Proxy is supported

## References

- [Moving to end-to-end IAM authentication for RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy-iam-migration.html)
- [Amazon RDS Proxy announces support for end-to-end IAM authentication](https://aws.amazon.com/about-aws/whats-new/2025/09/amazon-rds-proxy-end-to-end-iam-authentication/)
- [IAM database authentication](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/UsingWithRDS.IAMDBAuth.html)
- [Configuring IAM authentication for RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy-iam-setup.html)

## License

This project is provided as-is for educational and demonstration purposes.
