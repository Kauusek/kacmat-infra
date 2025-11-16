#!/bin/bash
set -euo pipefail

# --- Pakiety i użytkownik ---
apt-get update -y
apt-get install -y git nginx python3-venv python3-pip postgresql-client awscli
id -u app >/dev/null 2>&1 || useradd -m -s /bin/bash app

# --- Parametry z Terraforma ---
REPO_URL="${repo_url}"
APP_DIR_BASE="${app_dir}"          # np. /home/app/kacmat-infra
APP_DIR="$APP_DIR_BASE/app"        # docelowy katalog aplikacji
AWS_REGION="${aws_region}"

# --- Pobranie parametrów z SSM (SecureString + String) ---
getp() { aws ssm get-parameter --name "$1" --with-decryption --query 'Parameter.Value' --output text --region "$AWS_REGION"; }
getps() { aws ssm get-parameter --name "$1"                 --query 'Parameter.Value' --output text --region "$AWS_REGION"; }

APP_SECRET="$(getp "/kacmat/app/APP_SECRET")"
DB_PASS="$(getp "/kacmat/app/DB_PASS")"
# Jeśli chcesz użyć z SSM także user/name, odkomentuj linie poniżej i usuń ich użycie z TF
# DB_USER="$(getps "/kacmat/app/DB_USER")"
# DB_NAME="$(getps "/kacmat/app/DB_NAME")"

DB_HOST="${db_host}"
DB_USER="${db_user}"
DB_NAME="${db_name}"

# --- Repo ---
sudo -u app bash -lc "
  if [ -d \"$APP_DIR_BASE/.git\" ]; then
    cd \"$APP_DIR_BASE\" && git reset --hard HEAD && git pull --rebase || true
  else
    if [ -d \"$APP_DIR_BASE\" ] && [ ! -d \"$APP_DIR_BASE/.git\" ]; then
      rm -rf \"$APP_DIR_BASE\"
    fi
    git clone \"$REPO_URL\" \"$APP_DIR_BASE\" || true
  fi
"
mkdir -p "$APP_DIR"
chown -R app:app "$APP_DIR_BASE"

# --- Venv + deps ---
python3 -m venv /home/app/venv
/home/app/venv/bin/pip install --upgrade pip

if [ ! -f "$APP_DIR/requirements.txt" ]; then
  cat > "$APP_DIR/requirements.txt" <<'REQ'
flask==3.0.0
gunicorn==21.2.0
psycopg2-binary==2.9.9
python-dateutil==2.9.0.post0
itsdangerous==2.2.0
werkzeug==3.0.3
REQ
  chown app:app "$APP_DIR/requirements.txt"
fi

/home/app/venv/bin/pip install -r "$APP_DIR/requirements.txt"

# --- Bootstrap DB (idempotentnie) ---
export PGPASSWORD="$DB_PASS"

EXISTS="$(psql -h "$DB_HOST" -U "$DB_USER" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" || true)"
if [ "$EXISTS" != "1" ]; then
  psql -h "$DB_HOST" -U "$DB_USER" -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
fi

cat >/tmp/schema.sql <<'SQL'
CREATE TABLE IF NOT EXISTS metrics (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT now(),
  metric TEXT NOT NULL,
  value DOUBLE PRECISION NOT NULL,
  tags JSONB DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_metrics_ts ON metrics(ts);
CREATE INDEX IF NOT EXISTS idx_metrics_metric_ts ON metrics(metric, ts DESC);

CREATE TABLE IF NOT EXISTS app_users (
  id BIGSERIAL PRIMARY KEY,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'viewer',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit_log (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor TEXT,
  action TEXT,
  details JSONB
);

CREATE TABLE IF NOT EXISTS annotations (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL,
  metric TEXT NOT NULL,
  note TEXT NOT NULL,
  author TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_metrics_metric_ts_tags ON metrics(metric, ts) INCLUDE (tags);

SQL

psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -f /tmp/schema.sql

# Admin (hash w Pythonie)
ADMIN_HASH="$(/home/app/venv/bin/python3 - <<'PY'
from werkzeug.security import generate_password_hash
print(generate_password_hash("admin123"))
PY
)"
HAS_ADMIN="$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -Atc "SELECT 1 FROM app_users WHERE username='admin'" || true)"
if [ "$HAS_ADMIN" != "1" ]; then
  psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c \
    "INSERT INTO app_users(username,password_hash,role) VALUES ('admin','$ADMIN_HASH','admin');"
fi

# --- Aplikacja (fallback plików, gdy repo nie zawiera app/) ---
if [ ! -f "$APP_DIR/app.py" ]; then
  mkdir -p "$APP_DIR/templates"
  cat > "$APP_DIR/app.py" <<'PY'
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
    SESSION_COOKIE_SECURE=os.getenv("SESSION_COOKIE_SECURE","true").lower()=="true",
    SESSION_COOKIE_SAMESITE=os.getenv("SESSION_COOKIE_SAMESITE","Lax"),
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
@require_login
def dashboard():
    try:
        date_from = dtp.parse(request.args.get("from")) if request.args.get("from") else datetime.now(timezone.utc) - timedelta(days=7)
        date_to   = dtp.parse(request.args.get("to"))   if request.args.get("to")   else datetime.now(timezone.utc)
    except:
        date_from = datetime.now(timezone.utc) - timedelta(days=7)
        date_to   = datetime.now(timezone.utc)

    metric = request.args.get("metric","requests")
    rows = q("""
      SELECT date_trunc('hour', ts) AS bucket, avg(value) AS avg_val
      FROM metrics
      WHERE metric=%s AND ts BETWEEN %s AND %s
      GROUP BY 1 ORDER BY 1 ASC
    """, [metric, date_from, date_to])

    labels = [r["bucket"].isoformat() for r in rows]
    values = [float(r["avg_val"]) for r in rows]

    kpi_24h = q("SELECT COALESCE(avg(value),0) AS v FROM metrics WHERE metric=%s AND ts>=now()-interval '24 hours'",[metric],"one")["v"]
    kpi_7d  = q("SELECT COALESCE(avg(value),0) AS v FROM metrics WHERE metric=%s AND ts>=now()-interval '7 days'",[metric],"one")["v"]
    kpi_30d = q("SELECT COALESCE(avg(value),0) AS v FROM metrics WHERE metric=%s AND ts>=now()-interval '30 days'",[metric],"one")["v"]

    last_events = q("SELECT id, ts, metric, value FROM metrics ORDER BY ts DESC LIMIT 20")

    from flask import render_template
    return render_template("dashboard.html",
        metric=metric, labels=json.dumps(labels), values=json.dumps(values),
        kpi24=kpi_24h, kpi7=kpi_7d, kpi30=kpi_30d,
        last_events=last_events, date_from=date_from, date_to=date_to
    )

@app.route("/api/metrics", methods=["POST"])
@require_login
def api_add_metric():
    from datetime import datetime, timezone
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
PY

  cat > "$APP_DIR/templates/base.html" <<'HTML'
<!doctype html>
<html lang="pl">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Kacmat Insights</title>
  <link rel="stylesheet" href="https://unpkg.com/milligram/dist/milligram.min.css">
  <style>body{margin:20px} .kpis{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}</style>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
</head>
<body>
<nav>
  <strong>Kacmat Insights</strong>
  <span style="float:right"><a href="/logout">Wyloguj</a></span>
</nav>
<hr/>
{% block content %}{% endblock %}
</body>
</html>
HTML

  cat > "$APP_DIR/templates/login.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<h3>Logowanie</h3>
<form method="post">
  <label>Użytkownik</label>
  <input name="username" required>
  <label>Hasło</label>
  <input name="password" type="password" required>
  <button type="submit">Zaloguj</button>
  {% if error %}<p style="color:red">{{ error }}</p>{% endif %}
</form>
{% endblock %}
HTML

  cat > "$APP_DIR/templates/dashboard.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<div class="kpis">
  <div><h5>Średnia 24h</h5><h3>{{ '%.2f'|format(kpi24 or 0) }}</h3></div>
  <div><h5>Średnia 7d</h5><h3>{{ '%.2f'|format(kpi7 or 0) }}</h3></div>
  <div><h5>Średnia 30d</h5><h3>{{ '%.2f'|format(kpi30 or 0) }}</h3></div>
</div>
<canvas id="chart" height="100"></canvas>
<script>
const labels = {{ labels|safe }};
const values = {{ values|safe }};
new Chart(document.getElementById('chart'), {
  type: 'line',
  data: { labels, datasets: [{ label: '{{ metric }}', data: values }] },
  options: { responsive: true, scales: { x: { ticks: { maxRotation: 0 }}}}
});
</script>

<h4>Ostatnie zdarzenia</h4>
<table>
  <thead><tr><th>ts</th><th>metric</th><th>value</th></tr></thead>
  <tbody>
  {% for r in last_events %}
    <tr><td>{{ r.ts }}</td><td>{{ r.metric }}</td><td>{{ r.value }}</td></tr>
  {% endfor %}
  </tbody>
</table>
{% endblock %}
HTML

  chown -R app:app "$APP_DIR"
fi

# --- /etc/app.env z paramami (dla systemd)
cat >/etc/app.env <<EOF
DB_HOST=$DB_HOST
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
APP_SECRET=$APP_SECRET
SESSION_COOKIE_SECURE=true
SESSION_COOKIE_SAMESITE=Lax
EOF
chown root:root /etc/app.env
chmod 600 /etc/app.env

# --- Unit systemd dla Gunicorna ---
cat >/etc/systemd/system/app.service <<EOF
[Unit]
Description=Gunicorn for kacmat app
After=network.target

[Service]
EnvironmentFile=/etc/app.env
User=app
WorkingDirectory=$APP_DIR
ExecStart=/home/app/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now app

# --- Nginx: reverse proxy ---
cat >/etc/nginx/sites-available/default <<'NGINX'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  location / {
    proxy_pass http://127.0.0.1:5000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
  location = /healthz {
  proxy_pass http://127.0.0.1:5000/healthz;
  access_log off;
  }
}
NGINX

nginx -t && systemctl reload nginx

# --- Seeder: wrzuca punkty metryk co minutę, ale tylko JEDNA instancja dzięki advisory lock ---
cat >/usr/local/bin/seed-metrics.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# Wczytaj env aplikacji (DB_* już tam masz)
source /etc/app.env

# Funkcja: generuj "żyjące" wartości (sinus)
gen_val() {
  # usage: gen_val <divider> <base> <amp>
  python3 - "$@" <<'PY'
import math, time, sys
d=float(sys.argv[1]); base=float(sys.argv[2]); amp=float(sys.argv[3])
t=time.time()
print(base + amp*math.sin(t/d))
PY
}

# Spróbuj przejąć blokadę (klucz 777). Jeśli ktoś już trzyma — wyjdź.
export PGPASSWORD="$DB_PASS"
LOCK_OK=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -Atc "SELECT pg_try_advisory_lock(777);" || echo "f")

if [ "$LOCK_OK" != "t" ]; then
  echo "[seed] no lock, skipping at $(date -Is)"
  exit 0
fi

# Wstaw pomiary
REQ=$(gen_val 600  80 40)   # requests
LAT=$(gen_val 300 150 60)   # latency_ms
ERR=$(gen_val 900   5  5)   # errors >= 0 w SQL

psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO metrics(ts, metric, value, tags) VALUES
  (now(), 'requests',   $REQ, '{}'::jsonb),
  (now(), 'latency_ms', $LAT, '{}'::jsonb),
  (now(), 'errors',     GREATEST(0, $ERR), '{}'::jsonb);
SELECT pg_advisory_unlock(777);
SQL
SH
chmod +x /usr/local/bin/seed-metrics.sh

# Jednorazowy seeder (do testu lokalnie): /usr/local/bin/seed-metrics.sh

# Unit systemd (wykonuje skrypt raz)
cat >/etc/systemd/system/seed.service <<'UNIT'
[Unit]
Description=Insert demo metrics (single run with advisory lock)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/app.env
ExecStart=/usr/local/bin/seed-metrics.sh
StandardOutput=journal
StandardError=journal
UNIT

# Timer co minutę (z losowym rozrzutem, żeby nie walić dokładnie w tę samą sekundę)
cat >/etc/systemd/system/seed.timer <<'TIMER'
[Unit]
Description=Run demo metrics seeder every minute

[Timer]
OnCalendar=*:0/1
RandomizedDelaySec=20
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now seed.timer
