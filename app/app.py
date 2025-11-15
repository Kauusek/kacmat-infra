import os, json, secrets
from datetime import datetime, timedelta, timezone
from dateutil import parser as dtp
from flask import Flask, request, redirect, render_template, session, url_for, jsonify
import psycopg2, psycopg2.extras
from werkzeug.security import generate_password_hash, check_password_hash

DB_HOST = os.getenv("DB_HOST")
DB_NAME = os.getenv("DB_NAME", "kacmatdb")
DB_USER = os.getenv("DB_USER", "kacmat")
DB_PASS = os.getenv("DB_PASS")

app = Flask(__name__)
app.secret_key = os.getenv("APP_SECRET", secrets.token_hex(16))
app.config.update(
    SESSION_COOKIE_SECURE=os.getenv("SESSION_COOKIE_SECURE", "true").lower() == "true",
    SESSION_COOKIE_SAMESITE=os.getenv("SESSION_COOKIE_SAMESITE", "Lax"),
)

def db_conn():
    return psycopg2.connect(host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS)

def q(sql, params=None, fetch="all"):
    with db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params or [])
            if fetch == "one": return cur.fetchone()
            if fetch == "all": return cur.fetchall()
            return None

@app.route("/healthz")
def healthz():
    try:
        q("SELECT 1", fetch="one")
        return "ok", 200
    except Exception as e:
        return f"db-error: {e}", 500

@app.route("/login", methods=["GET","POST"])
def login():
    if request.method == "POST":
        u = request.form["username"].strip()
        p = request.form["password"]
        row = q("SELECT * FROM app_users WHERE username=%s", [u], fetch="one")
        if row and check_password_hash(row["password_hash"], p):
            session["user"] = {"id": row["id"], "username": u, "role": row["role"]}
            return redirect(url_for("dashboard"))
        return render_template("login.html", error="Zły login/hasło")
    return render_template("login.html")

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

def require_login(f):
    from functools import wraps
    @wraps(f)
    def inner(*a, **kw):
        if not session.get("user"):
            return redirect(url_for("login"))
        return f(*a, **kw)
    return inner

@app.route("/")
def index():
    return redirect("/dashboard")

@app.route("/dashboard")
@require_login
def dashboard():
    try:
        date_from = dtp.parse(request.args.get("from")) if request.args.get("from") else datetime.now(timezone.utc) - timedelta(minutes=10)
        date_to   = dtp.parse(request.args.get("to"))   if request.args.get("to")   else datetime.now(timezone.utc)
    except:
        date_from = datetime.now(timezone.utc) - timedelta(minutes=10)
        date_to   = datetime.now(timezone.utc)

    metric = request.args.get("metric")
    available_metrics = [r["metric"] for r in q("SELECT DISTINCT metric FROM metrics")]
    if metric not in available_metrics:
        metric = available_metrics[0] if available_metrics else "requests"

    try:
        rows = q("""
          SELECT date_trunc('minute', ts)::timestamp(0) - interval '1 minute' * (extract(minute from ts)::int % 5) AS bucket,
          avg(value) AS avg_val
          FROM metrics
          WHERE metric=%s AND ts BETWEEN %s AND %s
          GROUP BY 1 ORDER BY 1 ASC
        """, [metric, date_from, date_to])
    except Exception as e:
        rows = []

    labels = [r["bucket"].isoformat() for r in rows]
    values = [float(r["avg_val"]) for r in rows]

    try:
        kpi_24h = q("SELECT COALESCE(avg(value),0) AS v FROM metrics WHERE metric=%s AND ts>=now()-interval '24 hours'", [metric], "one")["v"]
        kpi_7d  = q("SELECT COALESCE(avg(value),0) AS v FROM metrics WHERE metric=%s AND ts>=now()-interval '7 days'", [metric], "one")["v"]
        kpi_30d = q("SELECT COALESCE(avg(value),0) AS v FROM metrics WHERE metric=%s AND ts>=now()-interval '30 days'", [metric], "one")["v"]
    except:
        kpi_24h = kpi_7d = kpi_30d = 0

    last_events = q("SELECT id, ts, metric, value FROM metrics ORDER BY ts DESC LIMIT 20")

    return render_template("dashboard.html",
        metric=metric,
        labels=json.dumps(labels),
        values=json.dumps(values),
        kpi24=kpi_24h,
        kpi7=kpi_7d,
        kpi30=kpi_30d,
        last_events=last_events,
        date_from=date_from,
        date_to=date_to,
        available_metrics=available_metrics
    )

@app.route("/api/metrics", methods=["POST"])
@require_login
def api_add_metric():
    body = request.get_json(force=True)
    ts = dtp.parse(body.get("ts")) if body.get("ts") else datetime.now(timezone.utc)
    metric = body["metric"]
    value = float(body["value"])
    tags  = json.dumps(body.get("tags", {}))
    q("INSERT INTO metrics(ts, metric, value, tags) VALUES (%s,%s,%s,%s)", [ts, metric, value, tags], fetch=None)
    q("INSERT INTO audit_log(actor, action, details) VALUES (%s,%s,%s)",
      [session["user"]["username"], "create_metric", json.dumps(body)], fetch=None)
    return jsonify({"ok": True})

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000)
