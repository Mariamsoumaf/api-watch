"""The background checker.

Every few seconds it asks the database: "which active monitors are due?"
Then it sends a request to each URL and saves the result in `checks`.

The checker only INSERTs into `checks`.
The database triggers do the rest:
  - trg_check_incident  -> opens / closes incidents
  - trg_incident_alerts -> creates alerts for project members
"""
import threading
import time

import mysql.connector
import requests

from config import Config

# Monitors that are active AND whose last check is older than their interval
DUE_MONITORS_SQL = """
SELECT m.monitor_id, m.url
FROM monitors m
LEFT JOIN (
    SELECT monitor_id, MAX(checked_at) AS last_check
    FROM checks
    GROUP BY monitor_id
) lc ON lc.monitor_id = m.monitor_id
WHERE m.is_active = TRUE
  AND (lc.last_check IS NULL
       OR lc.last_check <= NOW() - INTERVAL m.interval_sec SECOND)
"""

INSERT_CHECK_SQL = """
INSERT INTO checks (monitor_id, checked_at, status_code, response_ms, is_up, error_message)
VALUES (%s, NOW(), %s, %s, %s, %s)
"""


def check_url(url):
    """Send one request. Returns (status_code, response_ms, is_up, error)."""
    start = time.perf_counter()
    try:
        resp = requests.get(
            url,
            timeout=Config.REQUEST_TIMEOUT,
            headers={"User-Agent": "APIWatch/1.0"},
        )
        ms = int((time.perf_counter() - start) * 1000)
        is_up = 200 <= resp.status_code < 400
        error = None if is_up else f"HTTP {resp.status_code} {resp.reason}"[:255]
        return resp.status_code, ms, is_up, error
    except requests.Timeout:
        return None, None, False, f"Timeout after {Config.REQUEST_TIMEOUT}s"
    except requests.RequestException as exc:
        return None, None, False, f"{type(exc).__name__}: connection failed"[:255]


def save_check(conn, monitor_id, url):
    status, ms, is_up, error = check_url(url)
    cur = conn.cursor()
    cur.execute(INSERT_CHECK_SQL, (monitor_id, status, ms, is_up, error))
    conn.commit()
    cur.close()
    return is_up


def run_due_checks():
    """Check every monitor that is due. Used by the background thread."""
    conn = mysql.connector.connect(**Config.DB)
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute(DUE_MONITORS_SQL)
        due = cur.fetchall()
        cur.close()
        for row in due:
            save_check(conn, row["monitor_id"], row["url"])
    finally:
        conn.close()


def _loop():
    while True:
        try:
            run_due_checks()
        except Exception as exc:  # keep the thread alive if MySQL is down
            print(f"[checker] error: {exc}")
        time.sleep(Config.CHECKER_LOOP_SECONDS)


def start_checker():
    thread = threading.Thread(target=_loop, daemon=True, name="api-watch-checker")
    thread.start()
    print(f"[checker] started, runs every {Config.CHECKER_LOOP_SECONDS}s")
