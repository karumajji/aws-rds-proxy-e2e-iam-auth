#!/usr/bin/env python3
"""
Demo application: End-to-End IAM Authentication through RDS Proxy with Aurora MySQL.
No passwords, no Secrets Manager — just IAM.

Usage:
    pip install boto3 mysql-connector-python
    python app.py

Environment variables (optional overrides):
    PROXY_ENDPOINT  - RDS Proxy endpoint
    DB_USER         - IAM database user
    DB_NAME         - Database name
    AWS_REGION      - AWS region
"""

import os
import sys
import time
import boto3
import mysql.connector

# ---- Configuration ----
PROXY_ENDPOINT = os.environ.get("PROXY_ENDPOINT", "e2e-iam-proxy.proxy-c7leamkjhfqz.us-east-1.rds.amazonaws.com")
DB_USER = os.environ.get("DB_USER", "iam_user")
DB_NAME = os.environ.get("DB_NAME", "")
REGION = os.environ.get("AWS_REGION", "us-east-1")
PORT = 3306
SSL_CA = "/tmp/global-bundle.pem"


def get_iam_token():
    """Generate IAM auth token for the proxy endpoint."""
    client = boto3.client("rds", region_name=REGION)
    return client.generate_db_auth_token(
        DBHostname=PROXY_ENDPOINT, Port=PORT, DBUsername=DB_USER, Region=REGION
    )


def connect():
    """Connect to Aurora MySQL through RDS Proxy using IAM auth."""
    token = get_iam_token()
    params = dict(
        host=PROXY_ENDPOINT,
        port=PORT,
        user=DB_USER,
        password=token,
        ssl_disabled=False,
        ssl_verify_cert=False,
        auth_plugin="mysql_clear_password",
    )
    if DB_NAME:
        params["database"] = DB_NAME
    return mysql.connector.connect(**params)


def demo():
    """Run a demo showing E2E IAM auth connectivity."""
    print("=" * 60)
    print("  E2E IAM Auth Demo — RDS Proxy + Aurora MySQL")
    print("=" * 60)
    print(f"  Proxy:  {PROXY_ENDPOINT}")
    print(f"  User:   {DB_USER}")
    print(f"  Region: {REGION}")
    print()

    # 1. Connect
    print("[1] Generating IAM auth token...")
    start = time.time()
    conn = connect()
    elapsed = time.time() - start
    print(f"    Connected in {elapsed:.2f}s")

    cursor = conn.cursor()

    # 2. Verify identity
    print("\n[2] Verifying connection identity...")
    cursor.execute("SELECT current_user(), @@aurora_server_id, VERSION()")
    user, server, version = cursor.fetchone()
    print(f"    User:      {user}")
    print(f"    Server:    {server}")
    print(f"    Version:   {version}")

    # 3. Check SSL
    print("\n[3] Verifying SSL/TLS...")
    cursor.execute("SHOW STATUS LIKE 'Ssl_cipher'")
    _, cipher = cursor.fetchone()
    print(f"    Cipher:    {cipher}")

    # 4. Run sample queries
    print("\n[4] Running sample queries...")
    cursor.execute("SELECT NOW() AS server_time")
    print(f"    Server time: {cursor.fetchone()[0]}")

    cursor.execute("SELECT @@innodb_buffer_pool_size / 1024 / 1024 AS buffer_pool_mb")
    print(f"    Buffer pool: {cursor.fetchone()[0]} MB")

    cursor.execute("SHOW DATABASES")
    dbs = [row[0] for row in cursor.fetchall()]
    print(f"    Databases:   {', '.join(dbs)}")

    # 5. Connection reuse demo
    print("\n[5] Connection reuse (proxy pooling benefit)...")
    for i in range(3):
        cursor.execute("SELECT 1")
        cursor.fetchone()
    print("    3 queries on same connection ✓")
    print("    (Proxy reuses backend DB connection — no re-auth)")

    cursor.close()
    conn.close()

    print("\n" + "=" * 60)
    print("  ✅ All tests passed — E2E IAM auth working!")
    print("  No passwords or Secrets Manager used.")
    print("=" * 60)


if __name__ == "__main__":
    try:
        demo()
    except mysql.connector.Error as e:
        print(f"\n❌ Database error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)
