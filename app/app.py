import os
from datetime import datetime
from functools import wraps

from flask import (
    Flask, render_template, request, redirect,
    url_for, session, flash, jsonify
)
from werkzeug.security import check_password_hash

from db import get_db_connection, init_db

app = Flask(__name__)

# SECRET_KEY is pulled from an env var populated by the ExternalSecret
# (see k8s/deployment.yaml) -- never hardcode this.
app.secret_key = os.environ.get("FLASK_SECRET_KEY")
if not app.secret_key:
    raise RuntimeError(
        "FLASK_SECRET_KEY is not set. It must come from AWS Secrets "
        "Manager via the ExternalSecret -- see PART-SECURITY.md."
    )

# Session hardening
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get("FORCE_SECURE_COOKIES", "true") == "true",
    PERMANENT_SESSION_LIFETIME=1800,
)


def login_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if "user_id" not in session:
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return wrapped


# ------------------------------------------------------------------- root ---
@app.route("/")
def index():
    # No route was defined for "/" itself -- visiting the bare ALB URL
    # (or your own domain root, later) 404'd even though every other page
    # worked fine. Send people somewhere useful instead.
    if "user_id" in session:
        return redirect(url_for("dashboard"))
    return redirect(url_for("login"))


# ---------------------------------------------------------------- health ---
@app.route("/healthz")
def healthz():
    # Used by the k8s readiness/liveness probes -- no auth, no secrets.
    return jsonify(status="ok"), 200


# ------------------------------------------------------------------ auth ---
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        conn = get_db_connection()
        cur = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT id, username, password_hash FROM admins WHERE username = %s",
            (username,),
        )
        user = cur.fetchone()
        cur.close()
        conn.close()

        if user and check_password_hash(user["password_hash"], password):
            session.clear()
            session["user_id"] = user["id"]
            session["username"] = user["username"]
            session.permanent = bool(request.form.get("remember_me"))
            return redirect(url_for("dashboard"))

        flash("Invalid username or password", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# -------------------------------------------------------------- dashboard --
@app.route("/dashboard")
@login_required
def dashboard():
    conn = get_db_connection()
    cur = conn.cursor(dictionary=True)

    stats = {}
    cur.execute("SELECT COALESCE(SUM(quantity_produced),0) AS v FROM production_log")
    stats["total_produced"] = cur.fetchone()["v"]
    cur.execute("SELECT COALESCE(SUM(quantity_assembled),0) AS v FROM production_log")
    stats["total_assembled"] = cur.fetchone()["v"]
    cur.execute("SELECT COALESCE(SUM(quantity_delivered),0) AS v FROM deliveries")
    stats["total_delivered"] = cur.fetchone()["v"]
    cur.execute(
        "SELECT COUNT(*) AS v FROM production_log WHERE quantity_assembled < quantity_produced"
    )
    stats["pending_assembly"] = cur.fetchone()["v"]
    cur.execute("SELECT COUNT(*) AS v FROM deliveries WHERE status = 'pending'")
    stats["pending_delivery"] = cur.fetchone()["v"]
    cur.execute("SELECT COUNT(*) AS v FROM materials")
    stats["material_types"] = cur.fetchone()["v"]
    cur.execute(
        "SELECT COALESCE(SUM(quantity_produced),0) AS v FROM production_log WHERE log_date = CURDATE()"
    )
    stats["daily_production"] = cur.fetchone()["v"]
    cur.execute(
        "SELECT COALESCE(SUM(quantity_produced),0) AS v FROM production_log "
        "WHERE MONTH(log_date) = MONTH(CURDATE()) AND YEAR(log_date) = YEAR(CURDATE())"
    )
    stats["monthly_production"] = cur.fetchone()["v"]

    cur.execute(
        "SELECT log_date, SUM(quantity_produced) AS produced FROM production_log "
        "WHERE log_date >= CURDATE() - INTERVAL 7 DAY GROUP BY log_date ORDER BY log_date"
    )
    trend = cur.fetchall()

    cur.close()
    conn.close()
    return render_template(
        "dashboard.html", stats=stats, trend=trend, year=datetime.now().year
    )


# ----------------------------------------------------------------materials--
@app.route("/materials")
@login_required
def materials():
    conn = get_db_connection()
    cur = conn.cursor(dictionary=True)
    cur.execute("SELECT * FROM materials ORDER BY created_at DESC")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return render_template("materials.html", materials=rows)


@app.route("/materials/add", methods=["GET", "POST"])
@login_required
def add_material():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        category = request.form.get("category", "").strip()
        quantity = request.form.get("quantity", "0")
        unit = request.form.get("unit", "").strip()

        if not name or not category:
            flash("Name and category are required", "error")
            return redirect(url_for("add_material"))

        try:
            quantity = int(quantity)
        except ValueError:
            flash("Quantity must be a number", "error")
            return redirect(url_for("add_material"))

        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO materials (name, category, quantity, unit, created_at) "
            "VALUES (%s, %s, %s, %s, NOW())",
            (name, category, quantity, unit),
        )
        conn.commit()
        cur.close()
        conn.close()
        flash("Material added", "success")
        return redirect(url_for("materials"))

    return render_template("add_material.html")


@app.route("/materials/delete/<int:material_id>", methods=["POST"])
@login_required
def delete_material(material_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("DELETE FROM materials WHERE id = %s", (material_id,))
    conn.commit()
    cur.close()
    conn.close()
    flash("Material deleted", "success")
    return redirect(url_for("materials"))


# ------------------------------------------------------- production tracking
@app.route("/production", methods=["GET", "POST"])
@login_required
def production_tracking():
    conn = get_db_connection()
    cur = conn.cursor(dictionary=True)

    if request.method == "POST":
        material_id = request.form.get("material_id")
        qty_produced = request.form.get("quantity_produced", "0")
        cur2 = conn.cursor()
        cur2.execute(
            "INSERT INTO production_log (material_id, quantity_produced, quantity_assembled, log_date) "
            "VALUES (%s, %s, 0, CURDATE())",
            (material_id, qty_produced),
        )
        conn.commit()
        cur2.close()
        flash("Production entry recorded", "success")
        return redirect(url_for("production_tracking"))

    cur.execute("SELECT id, name FROM materials ORDER BY name")
    materials_list = cur.fetchall()
    cur.execute(
        "SELECT pl.id, m.name, pl.quantity_produced, pl.quantity_assembled, pl.log_date "
        "FROM production_log pl JOIN materials m ON m.id = pl.material_id "
        "ORDER BY pl.log_date DESC LIMIT 50"
    )
    logs = cur.fetchall()
    cur.close()
    conn.close()
    return render_template("production.html", materials=materials_list, logs=logs)


# ------------------------------------------------------------------inventory
@app.route("/inventory")
@login_required
def inventory():
    conn = get_db_connection()
    cur = conn.cursor(dictionary=True)
    cur.execute(
        "SELECT m.name, m.category, m.quantity, m.unit, "
        "COALESCE(SUM(d.quantity_delivered),0) AS delivered "
        "FROM materials m LEFT JOIN deliveries d ON d.material_id = m.id "
        "GROUP BY m.id ORDER BY m.name"
    )
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return render_template("inventory.html", rows=rows)


# --------------------------------------------------------------------reports
@app.route("/reports")
@login_required
def reports():
    conn = get_db_connection()
    cur = conn.cursor(dictionary=True)
    cur.execute(
        "SELECT log_date, SUM(quantity_produced) AS produced, SUM(quantity_assembled) AS assembled "
        "FROM production_log GROUP BY log_date ORDER BY log_date DESC LIMIT 30"
    )
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return render_template("reports.html", rows=rows)


# --------------------------------------------------------------------profile
@app.route("/profile")
@login_required
def profile():
    return render_template("profile.html", username=session.get("username"))


if __name__ == "__main__":
    # Local dev only. In-cluster this runs under gunicorn (see Dockerfile).
    init_db()
    app.run(host="0.0.0.0", port=5000, debug=False)
