"""
Database access layer.

Credentials are read ONLY from environment variables. In production those
env vars are populated by the AWS Secrets Store CSI Driver (mounted secret
files) or by External Secrets Operator syncing from AWS Secrets Manager into
a native Kubernetes Secret. Nothing here ever contains a literal password.
"""
import os
import pymysql
from pymysql.cursors import DictCursor


def _read_secret(env_name: str, file_env_name: str) -> str:
    """
    Support two secret-delivery styles:
    1) Secrets Store CSI driver mounts each secret as a file; the path is
       given by *_FILE env vars (preferred - value never lands in `env`,
       reducing exposure via `kubectl describe pod` / process listing).
    2) External Secrets Operator injects the value directly as an env var.
    """
    file_path = os.environ.get(file_env_name)
    if file_path and os.path.exists(file_path):
        with open(file_path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    return os.environ[env_name]


def get_connection():
    host = _read_secret("DB_HOST", "DB_HOST_FILE")
    user = _read_secret("DB_USER", "DB_USER_FILE")
    password = _read_secret("DB_PASSWORD", "DB_PASSWORD_FILE")
    name = _read_secret("DB_NAME", "DB_NAME_FILE")

    return pymysql.connect(
        host=host,
        user=user,
        password=password,
        database=name,
        port=int(os.environ.get("DB_PORT", 3306)),
        cursorclass=DictCursor,
        ssl={"ssl": {}},  # enforce TLS to RDS
        connect_timeout=5,
    )


def init_db():
    """Idempotent bootstrap - safe to run on every pod start."""
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS admins (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    username VARCHAR(64) UNIQUE NOT NULL,
                    password_hash VARCHAR(255) NOT NULL
                )
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS materials (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    material_type VARCHAR(64) NOT NULL,
                    quantity INT NOT NULL DEFAULT 0,
                    status ENUM('produced','assembled','delivered',
                                'pending_assembly','pending_delivery')
                                NOT NULL DEFAULT 'produced',
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
        conn.commit()
    finally:
        conn.close()
