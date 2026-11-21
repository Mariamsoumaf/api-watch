"""API Watch - a website & API uptime monitor.

Pages:
  1. /                 Dashboard
  2. /monitors         Monitors (search + add / edit / delete)
  3. /monitors/<id>    Monitor details (chart, checks, incidents)
  4. /reports          Reports (JOIN searches)
"""
import os
from datetime import datetime

import mysql.connector
from flask import (Flask, abort, flash, g, redirect, render_template,
                   request, session, url_for)

import checker
from config import Config
from db import call_proc, close_db, execute, query

app = Flask(__name__)
app.config["SECRET_KEY"] = Config.SECRET_KEY
app.teardown_appcontext(close_db)


# ---------------------------------------------------------------
# Shared SQL: every monitor of the current user + its LAST check
# ---------------------------------------------------------------
MONITORS_WITH_LAST_CHECK = """
SELECT m.monitor_id, m.name, m.url, m.interval_sec, m.is_active,
       p.project_id, p.name AS project_name, pm.role,
       lc.is_up, lc.status_code, lc.response_ms, lc.checked_at
FROM monitors m
JOIN projects p         ON p.project_id = m.project_id
JOIN project_members pm ON pm.project_id = p.project_id AND pm.user_id = %s
LEFT JOIN checks lc     ON lc.check_id = (
        SELECT c2.check_id FROM checks c2
        WHERE c2.monitor_id = m.monitor_id
        ORDER BY c2.checked_at DESC, c2.check_id DESC
        LIMIT 1)
"""


# ---------------------------------------------------------------
# Current user (simple user switcher instead of a login page)
# ---------------------------------------------------------------
@app.before_request
def load_user():
    g.users = query("SELECT user_id, full_name, email FROM users ORDER BY user_id")
    # Use the database clock, so "x min ago" is always correct
    g.db_now = query("SELECT NOW() AS now", one=True)["now"]
    user_id = session.get("user_id")
    g.user = next((u for u in g.users if u["user_id"] == user_id), None)
    if g.user is None and g.users:
        g.user = g.users[0]
        session["user_id"] = g.user["user_id"]


@app.post("/switch-user")
def switch_user():
    session["user_id"] = int(request.form["user_id"])
    return redirect(request.referrer or url_for("dashboard"))


def get_role(monitor_id):
    """Return 'owner', 'viewer' or None for the current user on this monitor."""
    row = query(
        """SELECT pm.role FROM monitors m
           JOIN project_members pm ON pm.project_id = m.project_id
           WHERE m.monitor_id = %s AND pm.user_id = %s""",
        (monitor_id, g.user["user_id"]), one=True)
    return row["role"] if row else None


def require_owner(monitor_id):
    role = get_role(monitor_id)
    if role is None:
        abort(404)
    if role != "owner":
        flash("Only project owners can change monitors.", "error")
        return False
    return True


# ---------------------------------------------------------------
# Template helpers
# ---------------------------------------------------------------
@app.template_filter("ago")
def time_ago(value):
    if not value:
        return "never"
    now = g.get("db_now") or datetime.now()
    seconds = max(0, int((now - value).total_seconds()))
    if seconds < 60:
        return "just now"
    if seconds < 3600:
        return f"{seconds // 60} min ago"
    if seconds < 86400:
        return f"{seconds // 3600} h ago"
    return f"{seconds // 86400} d ago"


@app.template_filter("duration")
def duration(minutes):
    if minutes is None:
        return "-"
    minutes = int(minutes)
    if minutes < 60:
        return f"{minutes} min"
    if minutes < 1440:
        return f"{minutes // 60} h {minutes % 60} min"
    return f"{minutes // 1440} d {(minutes % 1440) // 60} h"


def monitor_state(m):
    """up / down / paused / pending - used for colors in the UI."""
    if not m["is_active"]:
        return "paused"
    if m["is_up"] is None:
        return "pending"
    return "up" if m["is_up"] else "down"


app.jinja_env.globals["monitor_state"] = monitor_state


# ---------------------------------------------------------------
# PAGE 1: Dashboard
# ---------------------------------------------------------------
@app.get("/")
def dashboard():
    uid = g.user["user_id"]

    # Stored procedure
    stats = call_proc("get_user_dashboard", (uid,))
    stats = stats[0] if stats else {"my_projects": 0, "my_monitors": 0, "open_incidents": 0}

    # View + JOIN: average uptime of my monitors
    uptime = query(
        """SELECT ROUND(AVG(v.uptime_percent), 2) AS avg_uptime
           FROM v_monitor_uptime v
           JOIN monitors m         ON m.monitor_id = v.monitor_id
           JOIN project_members pm ON pm.project_id = m.project_id
           WHERE pm.user_id = %s""", (uid,), one=True)

    monitors = query(MONITORS_WITH_LAST_CHECK + " ORDER BY p.name, m.name", (uid,))

    open_incidents = query(
        """SELECT i.incident_id, i.started_at, m.monitor_id, m.name AS monitor_name,
                  p.name AS project_name,
                  TIMESTAMPDIFF(MINUTE, i.started_at, NOW()) AS minutes_down
           FROM incidents i
           JOIN monitors m         ON m.monitor_id = i.monitor_id
           JOIN projects p         ON p.project_id = m.project_id
           JOIN project_members pm ON pm.project_id = p.project_id
           WHERE i.status = 'open' AND pm.user_id = %s
           ORDER BY i.started_at""", (uid,))

    alerts = query(
        """SELECT a.channel, a.sent_at, m.name AS monitor_name, p.name AS project_name
           FROM alerts a
           JOIN incidents i ON i.incident_id = a.incident_id
           JOIN monitors m  ON m.monitor_id  = i.monitor_id
           JOIN projects p  ON p.project_id  = m.project_id
           WHERE a.user_id = %s
           ORDER BY a.sent_at DESC, a.alert_id DESC
           LIMIT 6""", (uid,))

    return render_template("dashboard.html", stats=stats, uptime=uptime,
                           monitors=monitors, open_incidents=open_incidents,
                           alerts=alerts, active="dashboard")


# ---------------------------------------------------------------
# PAGE 2: Monitors (search + CRUD)
# ---------------------------------------------------------------
@app.get("/monitors")
def monitors():
    uid = g.user["user_id"]
    q = request.args.get("q", "").strip()
    project_id = request.args.get("project", "")
    state = request.args.get("state", "")

    sql = MONITORS_WITH_LAST_CHECK + " WHERE 1 = 1"
    params = [uid]
    if q:
        sql += " AND (m.name LIKE %s OR m.url LIKE %s)"
        params += [f"%{q}%", f"%{q}%"]
    if project_id.isdigit():
        sql += " AND p.project_id = %s"
        params.append(int(project_id))
    if state == "paused":
        sql += " AND m.is_active = FALSE"
    elif state == "up":
        sql += " AND m.is_active = TRUE AND lc.is_up = TRUE"
    elif state == "down":
        sql += " AND m.is_active = TRUE AND lc.is_up = FALSE"
    sql += " ORDER BY p.name, m.name"

    rows = query(sql, params)
    projects = query(
        """SELECT p.project_id, p.name, pm.role
           FROM projects p
           JOIN project_members pm ON pm.project_id = p.project_id
           WHERE pm.user_id = %s ORDER BY p.name""", (uid,))
    owner_projects = [p for p in projects if p["role"] == "owner"]

    return render_template("monitors.html", monitors=rows, projects=projects,
                           owner_projects=owner_projects,
                           filters={"q": q, "project": project_id, "state": state},
                           active="monitors")


def read_monitor_form():
    name = request.form.get("name", "").strip()
    url = request.form.get("url", "").strip()
    try:
        interval = int(request.form.get("interval_sec", "60"))
    except ValueError:
        interval = 0
    errors = []
    if not name:
        errors.append("Name is required.")
    if not url.startswith(("http://", "https://")):
        errors.append("URL must start with http:// or https://")
    if not 30 <= interval <= 3600:
        errors.append("Interval must be between 30 and 3600 seconds.")
    return name, url, interval, errors


@app.post("/monitors/add")
def add_monitor():
    name, url, interval, errors = read_monitor_form()
    project_id = request.form.get("project_id", "")

    owner = query(
        """SELECT 1 FROM project_members
           WHERE project_id = %s AND user_id = %s AND role = 'owner'""",
        (project_id, g.user["user_id"]), one=True)
    if not owner:
        errors.append("You can only add monitors to your own projects.")

    if errors:
        for e in errors:
            flash(e, "error")
        return redirect(url_for("monitors"))
    try:
        execute("""INSERT INTO monitors (project_id, name, url, interval_sec)
                   VALUES (%s, %s, %s, %s)""", (project_id, name, url, interval))
        flash(f"Monitor '{name}' added. The first check will run soon.", "success")
    except mysql.connector.IntegrityError:
        flash("This URL is already monitored in this project.", "error")
    return redirect(url_for("monitors"))


@app.post("/monitors/<int:monitor_id>/edit")
def edit_monitor(monitor_id):
    if not require_owner(monitor_id):
        return redirect(url_for("monitors"))
    name, url, interval, errors = read_monitor_form()
    if errors:
        for e in errors:
            flash(e, "error")
        return redirect(request.referrer or url_for("monitors"))
    try:
        execute("""UPDATE monitors SET name = %s, url = %s, interval_sec = %s
                   WHERE monitor_id = %s""", (name, url, interval, monitor_id))
        flash("Monitor updated.", "success")
    except mysql.connector.IntegrityError:
        flash("This URL is already monitored in this project.", "error")
    return redirect(request.referrer or url_for("monitors"))


@app.post("/monitors/<int:monitor_id>/toggle")
def toggle_monitor(monitor_id):
    if require_owner(monitor_id):
        execute("UPDATE monitors SET is_active = NOT is_active WHERE monitor_id = %s",
                (monitor_id,))
        flash("Monitor status changed.", "success")
    return redirect(request.referrer or url_for("monitors"))


@app.post("/monitors/<int:monitor_id>/delete")
def delete_monitor(monitor_id):
    if require_owner(monitor_id):
        # ON DELETE CASCADE removes its checks, incidents and alerts too
        execute("DELETE FROM monitors WHERE monitor_id = %s", (monitor_id,))
        flash("Monitor deleted with all its checks and incidents.", "success")
    return redirect(url_for("monitors"))


@app.post("/monitors/<int:monitor_id>/check")
def check_now(monitor_id):
    if get_role(monitor_id) is None:
        abort(404)
    m = query("SELECT url FROM monitors WHERE monitor_id = %s", (monitor_id,), one=True)
    conn = mysql.connector.connect(**Config.DB)
    try:
        is_up = checker.save_check(conn, monitor_id, m["url"])
    finally:
        conn.close()
    flash("Check done: the URL is UP." if is_up else "Check done: the URL is DOWN.",
          "success" if is_up else "error")
    return redirect(request.referrer or url_for("monitor_detail", monitor_id=monitor_id))


# ---------------------------------------------------------------
# PAGE 3: Monitor details
# ---------------------------------------------------------------
@app.get("/monitors/<int:monitor_id>")
def monitor_detail(monitor_id):
    uid = g.user["user_id"]
    monitor = query(MONITORS_WITH_LAST_CHECK + " WHERE m.monitor_id = %s",
                    (uid, monitor_id), one=True)
    if not monitor:
        abort(404)

    stats = query("SELECT * FROM v_monitor_uptime WHERE monitor_id = %s",
                  (monitor_id,), one=True)

    checks = query(
        """SELECT checked_at, status_code, response_ms, is_up, error_message
           FROM checks WHERE monitor_id = %s
           ORDER BY checked_at DESC, check_id DESC LIMIT 50""", (monitor_id,))

    incidents = query(
        """SELECT i.incident_id, i.started_at, i.resolved_at, i.status,
                  TIMESTAMPDIFF(MINUTE, i.started_at, COALESCE(i.resolved_at, NOW())) AS minutes,
                  COUNT(a.alert_id) AS alerts_sent
           FROM incidents i
           LEFT JOIN alerts a ON a.incident_id = i.incident_id
           WHERE i.monitor_id = %s
           GROUP BY i.incident_id, i.started_at, i.resolved_at, i.status
           ORDER BY i.started_at DESC""", (monitor_id,))

    chart = list(reversed(checks))
    chart_data = {
        "labels": [c["checked_at"].strftime("%d %b %H:%M") for c in chart],
        # a failed check with no response is drawn at 0 ms (red point)
        "values": [c["response_ms"] if c["response_ms"] is not None else 0 for c in chart],
        "up": [bool(c["is_up"]) for c in chart],
    }
    return render_template("monitor_detail.html", m=monitor, stats=stats,
                           checks=checks, incidents=incidents,
                           chart_data=chart_data, active="monitors")


# ---------------------------------------------------------------
# PAGE 4: Reports
# ---------------------------------------------------------------
@app.get("/reports")
def reports():
    uid = g.user["user_id"]

    uptime = query(
        """SELECT v.* FROM v_monitor_uptime v
           JOIN monitors m         ON m.monitor_id = v.monitor_id
           JOIN project_members pm ON pm.project_id = m.project_id
           WHERE pm.user_id = %s
           ORDER BY v.uptime_percent IS NULL, v.uptime_percent""", (uid,))

    most_incidents = query(
        """SELECT m.monitor_id, m.name AS monitor_name, p.name AS project_name,
                  COUNT(i.incident_id) AS total_incidents,
                  COALESCE(SUM(TIMESTAMPDIFF(MINUTE, i.started_at,
                               COALESCE(i.resolved_at, NOW()))), 0) AS total_minutes
           FROM monitors m
           JOIN projects p         ON p.project_id = m.project_id
           JOIN project_members pm ON pm.project_id = p.project_id AND pm.user_id = %s
           LEFT JOIN incidents i   ON i.monitor_id = m.monitor_id
           GROUP BY m.monitor_id, m.name, p.name
           ORDER BY total_incidents DESC, total_minutes DESC""", (uid,))

    team = query(
        """SELECT p.name AS project_name, u.full_name, u.email, pm.role
           FROM project_members pm
           JOIN projects p ON p.project_id = pm.project_id
           JOIN users u    ON u.user_id    = pm.user_id
           WHERE pm.project_id IN (SELECT project_id FROM project_members WHERE user_id = %s)
           ORDER BY p.name, pm.role, u.full_name""", (uid,))

    # Search form: failed / all checks with filters (4-table JOIN)
    f = {
        "q": request.args.get("q", "").strip(),
        "date_from": request.args.get("date_from", ""),
        "date_to": request.args.get("date_to", ""),
        "only_failed": request.args.get("only_failed", "1"),
    }
    sql = """SELECT c.checked_at, c.status_code, c.response_ms, c.is_up, c.error_message,
                    m.monitor_id, m.name AS monitor_name, p.name AS project_name,
                    u.full_name AS owner_name
             FROM checks c
             JOIN monitors m         ON m.monitor_id = c.monitor_id
             JOIN projects p         ON p.project_id = m.project_id
             JOIN users u            ON u.user_id    = p.owner_id
             JOIN project_members pm ON pm.project_id = p.project_id AND pm.user_id = %s
             WHERE 1 = 1"""
    params = [uid]
    if f["q"]:
        sql += " AND (m.name LIKE %s OR p.name LIKE %s OR c.error_message LIKE %s)"
        params += [f"%{f['q']}%"] * 3
    if f["date_from"]:
        sql += " AND c.checked_at >= %s"
        params.append(f["date_from"])
    if f["date_to"]:
        sql += " AND c.checked_at < %s + INTERVAL 1 DAY"
        params.append(f["date_to"])
    if f["only_failed"] == "1":
        sql += " AND c.is_up = FALSE"
    sql += " ORDER BY c.checked_at DESC LIMIT 100"
    results = query(sql, params)

    return render_template("reports.html", uptime=uptime, most_incidents=most_incidents,
                           team=team, results=results, f=f, active="reports")


@app.errorhandler(404)
def not_found(_e):
    return render_template("404.html", active=""), 404


# ---------------------------------------------------------------
if __name__ == "__main__":
    debug = os.getenv("FLASK_DEBUG", "true").lower() == "true"
    # In debug mode Flask runs this file twice (reloader).
    # Start the checker only once, in the real child process.
    if Config.CHECKER_ENABLED and (not debug or os.environ.get("WERKZEUG_RUN_MAIN") == "true"):
        checker.start_checker()
    app.run(debug=debug, port=int(os.getenv("PORT", "5000")))
