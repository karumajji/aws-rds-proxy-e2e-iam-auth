# End-to-End IAM Authentication through Amazon RDS Proxy

## Overview

This guide configures **end-to-end IAM authentication** for Amazon RDS Proxy with Aurora MySQL. With this setup, both the client-to-proxy and proxy-to-database connections use IAM authentication — **no Secrets Manager required**.

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

## Prerequisites

- AWS CLI v2
- MySQL 8.0+ client (`--enable-cleartext-plugin` support required)
- An existing VPC with subnets spanning 2+ AZs
- A security group allowing port 3306 within itself

## Steps

| Step | Script | Description |
|------|--------|-------------|
| 1 | `01-create-aurora-cluster.sh` | Create Aurora MySQL cluster with IAM auth enabled |
| 2 | `02-create-proxy-iam-role.sh` | Create IAM role for the proxy with `rds-db:connect` |
| 3 | `03-create-rds-proxy.sh` | Create RDS Proxy with `DefaultAuthScheme: IAM_AUTH` |
| 4 | `04-register-proxy-target.sh` | Register the Aurora cluster as the proxy target |
| 5 | `05-create-db-user.sh` | Create database user with `AWSAuthenticationPlugin` |
| 6 | `06-grant-client-permissions.sh` | Grant `rds-db:connect` to the client IAM role |
| 7 | `07-test-connection.sh` | Test E2E IAM auth through the proxy |
| 8 | `08-cleanup.sh` | Delete all resources |

## Quick Start

1. Edit `config.env` with your environment values
2. Run each step in order:

```bash
source config.env
./01-create-aurora-cluster.sh
./02-create-proxy-iam-role.sh
./03-create-rds-proxy.sh
./04-register-proxy-target.sh
./05-create-db-user.sh        # Run from EC2 in the same VPC
./06-grant-client-permissions.sh
./07-test-connection.sh        # Run from EC2 in the same VPC
```

## Key Differences from Standard IAM Auth

| | Standard IAM Auth | End-to-End IAM Auth |
|---|---|---|
| Client → Proxy | IAM token | IAM token (same) |
| Proxy → Database | Secrets Manager | **IAM token (no secrets)** |
| Secrets Manager required? | Yes | **No** |
| Key API setting | `IAMAuth: REQUIRED` | **`DefaultAuthScheme: IAM_AUTH`** |
| Auth config | Secrets ARN in `--auth` | **`--auth '[]'` (empty)** |

## Important Notes

- **MySQL 8.0+ client required**: Older clients (5.7, MariaDB 5.5) have bugs with long IAM tokens and the cleartext plugin.
- **TLS is mandatory**: The proxy must have `--require-tls` enabled for IAM auth.
- **Two IAM policies needed**: One for the proxy role (to auth to the DB), one for the client role (to auth to the proxy).
- **Connection pooling is the value**: Proxy doesn't make IAM auth faster — it makes it happen less often by reusing backend connections.

## Supported Versions

- Aurora MySQL 3.x (MySQL 8.0 compatible) — all versions
- Aurora MySQL 2.07+ and 2.11+ (MySQL 5.7 compatible)
- Available in all regions where RDS Proxy is supported

## References

- [Moving to end-to-end IAM authentication for RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy-iam-migration.html)
- [Amazon RDS Proxy announces support for end-to-end IAM authentication](https://aws.amazon.com/about-aws/whats-new/2025/09/amazon-rds-proxy-end-to-end-iam-authentication/)
- [IAM database authentication](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/UsingWithRDS.IAMDBAuth.html)
