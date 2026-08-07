"""
Database connection helper.

CRITICAL SECURITY NOTE:
All connection parameters come from environment variables. Those env vars
are populated in the pod spec from a Kubernetes Secret, which is itself
synced from AWS Secrets Manager by the External Secrets Operator. Nothing
here is ever hardcoded, and nothing here is ever committed to git.
See k8s/deployment.yaml + k8s/external-secret.yaml.
"""

import os
import mysql.connector
from werkzeug.security import generate_password_hash


def get_db_connection():
    return mysql.connector.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "3306")),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"],
        ssl_disabled=False,  # enforce TLS to RDS
    )


def init_db():
    """
    Idempotent schema creation + a default admin user, seeded from
    ADMIN_USERNAME / ADMIN_PASSWORD env vars (also Secrets-Manager-backed).
    This mirrors what k8s/db-init-job.yaml runs once inside the cluster.
    """
    conn = get_db_connection()
    cur = conn.cursor()

    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS admins (
            id INT AUTO_INCREMENT PRIMARY KEY,
            username VARCHAR(64) UNIQUE NOT NULL,
            password_hash VARCHAR(255) NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS materials (
            id INT AUTO_INCREMENT PRIMARY KEY,
            name VARCHAR(128) NOT NULL,
            category VARCHAR(64) NOT NULL,
            quantity INT NOT NULL DEFAULT 0,
            unit VARCHAR(32),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS production_log (
            id INT AUTO_INCREMENT PRIMARY KEY,
            material_id INT NOT NULL,
            quantity_produced INT NOT NULL DEFAULT 0,
            quantity_assembled INT NOT NULL DEFAULT 0,
            log_date DATE NOT NULL,
            FOREIGN KEY (material_id) REFERENCES materials(id) ON DELETE CASCADE
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS deliveries (
            id INT AUTO_INCREMENT PRIMARY KEY,
            material_id INT NOT NULL,
            quantity_delivered INT NOT NULL DEFAULT 0,
            status VARCHAR(32) NOT NULL DEFAULT 'pending',
            delivered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (material_id) REFERENCES materials(id) ON DELETE CASCADE
        )
        """
    )

    admin_user = os.environ.get("ADMIN_USERNAME")
    admin_pass = os.environ.get("ADMIN_PASSWORD")
    if admin_user and admin_pass:
        cur.execute("SELECT id FROM admins WHERE username = %s", (admin_user,))
        if cur.fetchone() is None:
            cur.execute(
                "INSERT INTO admins (username, password_hash) VALUES (%s, %s)",
                (admin_user, generate_password_hash(admin_pass)),
            )

    conn.commit()
    cur.close()
    conn.close()
