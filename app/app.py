"""
AutoForge - Automobile Manufacturing Unit Dashboard
Two-tier Flask application (App tier -> RDS MySQL tier)

Security notes:
 - No secrets are hard-coded. All credentials come from environment
   variables that are populated at runtime from AWS Secrets Manager
   (see db.py / k8s SecretProviderClass).
 - Passwords are stored as bcrypt hashes, never plaintext.
 - Session cookies are marked HttpOnly + Secure + SameSite=Lax.
 - All DB access uses parameterized queries (no string-built SQL) to
   eliminate SQL injection -> keeps SonarQube security hotspots clean.
"""
import os
import logging
from datetime import datetime, timedelta
from functools import wraps

from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
from flask_wtf import CSRFProtect
from werkzeug.security import check_password_hash
from dotenv import load_dotenv

from db import get_connection, init_db

load_dotenv()  # only used for local dev; in prod, env vars are injected by k8s/Secrets Manager

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ["FLASK_SECRET_KEY"]  # required, no default -> fails fast if missing
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SECURE"] = os.environ.get("FLASK_ENV", "production") == "production"
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(hours=8)

csrf = CSRFProtect(app)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("autoforge")


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if "user" not in session:
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


@app.route("/health")
def health():
    """Liveness/readiness probe endpoint for Kubernetes."""
    try:
        conn = get_connection()
        conn.close()
        return jsonify(status="ok"), 200
    except Exception as exc:  # noqa: BLE001 - health check must not crash the pod
        logger.error("health check DB failure: %s", exc)
        return jsonify(status="degraded"), 503


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        conn = get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, username, password_hash FROM admins WHERE username = %s",
                    (username,),
                )
                row = cur.fetchone()
        finally:
            conn.close()

        if row and check_password_hash(row["password_hash"], password):
            session.clear()
            session["user"] = row["username"]
            session.permanent = bool(request.form.get("remember_me"))
            flash("Login successful. Welcome back.", "success")
            return redirect(url_for("dashboard"))

        flash("Invalid username or password.", "error")
        return render_template("login.html"), 401

    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
@login_required
def dashboard():
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS c, COALESCE(SUM(quantity),0) AS q FROM materials")
            produced = cur.fetchone()
            cur.execute("SELECT COUNT(*) AS c FROM materials WHERE status='assembled'")
            assembled = cur.fetchone()["c"]
            cur.execute("SELECT COUNT(*) AS c FROM materials WHERE status='delivered'")
            delivered = cur.fetchone()["c"]
            cur.execute("SELECT COUNT(*) AS c FROM materials WHERE status='pending_assembly'")
            pending_assembly = cur.fetchone()["c"]
            cur.execute("SELECT COUNT(*) AS c FROM materials WHERE status='pending_delivery'")
            pending_delivery = cur.fetchone()["c"]
            cur.execute("SELECT COUNT(DISTINCT material_type) AS c FROM materials")
            material_types = cur.fetchone()["c"]
            cur.execute(
                "SELECT COUNT(*) AS c FROM materials WHERE DATE(created_at) = CURDATE()"
            )
            daily_count = cur.fetchone()["c"]
            cur.execute(
                "SELECT COUNT(*) AS c FROM materials WHERE MONTH(created_at)=MONTH(CURDATE()) "
                "AND YEAR(created_at)=YEAR(CURDATE())"
            )
            monthly_count = cur.fetchone()["c"]
            cur.execute(
                "SELECT DATE(created_at) AS d, COUNT(*) AS c FROM materials "
                "WHERE created_at >= DATE_SUB(CURDATE(), INTERVAL 6 DAY) "
                "GROUP BY DATE(created_at) ORDER BY d"
            )
            trend = cur.fetchall()
    finally:
        conn.close()

    stats = {
        "total_produced": produced["q"] or 0,
        "total_assembled": assembled,
        "total_delivered": delivered,
        "pending_assembly": pending_assembly,
        "pending_delivery": pending_delivery,
        "material_types": material_types,
        "daily_count": daily_count,
        "monthly_count": monthly_count,
        "trend_labels": [r["d"].strftime("%a") for r in trend],
        "trend_values": [r["c"] for r in trend],
    }
    return render_template("dashboard.html", stats=stats, year=datetime.now().year)


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=5000)
