"""
One-off seed script, run as a Kubernetes Job (see helm/templates/seed-job.yaml).
Creates the initial admin user with a bcrypt-hashed password pulled from
Secrets Manager (ADMIN_PASSWORD), never a hard-coded value.
"""
import os
from werkzeug.security import generate_password_hash
from db import get_connection, init_db


def main():
    init_db()
    admin_user = os.environ["ADMIN_USERNAME"]
    admin_password = os.environ["ADMIN_PASSWORD"]  # from Secrets Manager
    password_hash = generate_password_hash(admin_password)

    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO admins (username, password_hash) VALUES (%s, %s) "
                "ON DUPLICATE KEY UPDATE password_hash = VALUES(password_hash)",
                (admin_user, password_hash),
            )
            cur.execute("SELECT COUNT(*) AS c FROM materials")
            if cur.fetchone()["c"] == 0:
                sample = [
                    ("Engine Block", 120, "produced"),
                    ("Chassis Frame", 95, "assembled"),
                    ("Wiring Harness", 210, "delivered"),
                    ("Gearbox", 60, "pending_assembly"),
                    ("Dashboard Panel", 140, "delivered"),
                    ("Tyre Set", 300, "pending_delivery"),
                ]
                cur.executemany(
                    "INSERT INTO materials (material_type, quantity, status) VALUES (%s,%s,%s)",
                    sample,
                )
        conn.commit()
        print("Seed complete.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
