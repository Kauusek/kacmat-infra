import os
from flask import Flask, render_template
import psycopg2

app = Flask(__name__)

def db_conn():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASS"],
        connect_timeout=5,
    )

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/users")
def users():
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, name TEXT NOT NULL)")
            cur.execute("INSERT INTO users(name) VALUES ('Alice') ON CONFLICT DO NOTHING;")
            cur.execute("SELECT id, name FROM users ORDER BY id ASC")
            rows = cur.fetchall()
    return render_template("users.html", users=rows)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
