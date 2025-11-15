#!/usr/bin/env bash
set -euo pipefail
source /etc/app.env

gen_val() {
  python3 - "$@" <<'PY'
import math, time, sys
d=float(sys.argv[1]); base=float(sys.argv[2]); amp=float(sys.argv[3])
t=time.time()
print(base + amp*math.sin(t/d))
PY
}

export PGPASSWORD="$DB_PASS"
LOCK_OK=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -Atc "SELECT pg_try_advisory_lock(777);" || echo "f")

if [ "$LOCK_OK" != "t" ]; then
  exit 0
fi

REQ=$(gen_val 600  80 40)
LAT=$(gen_val 300 150 60)
ERR=$(gen_val 900   5  5)

psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO metrics(ts, metric, value, tags) VALUES
  (now(), 'requests',   $REQ, '{}'::jsonb),
  (now(), 'latency_ms', $LAT, '{}'::jsonb),
  (now(), 'errors',     GREATEST(0, $ERR), '{}'::jsonb);
SELECT pg_advisory_unlock(777);
SQL
