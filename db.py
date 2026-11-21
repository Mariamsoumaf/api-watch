"""Small helper functions to talk to MySQL.

Every query uses %s placeholders, so user input is never pasted
into the SQL text. This protects the app from SQL injection.
"""
import mysql.connector
from flask import g

from config import Config


def get_db():
    """One connection per request, saved in Flask's 'g' object."""
    if "db" not in g:
        g.db = mysql.connector.connect(**Config.DB)
    return g.db


def close_db(_error=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def query(sql, params=(), one=False):
    """Run a SELECT. Returns a list of dicts (or one dict if one=True)."""
    cur = get_db().cursor(dictionary=True)
    cur.execute(sql, params)
    rows = cur.fetchall()
    cur.close()
    if one:
        return rows[0] if rows else None
    return rows


def execute(sql, params=()):
    """Run INSERT / UPDATE / DELETE and save the change (commit)."""
    db = get_db()
    cur = db.cursor()
    cur.execute(sql, params)
    db.commit()
    last_id, count = cur.lastrowid, cur.rowcount
    cur.close()
    return last_id, count


def call_proc(name, args=()):
    """Call a stored procedure and return its result as a list of dicts."""
    cur = get_db().cursor()
    cur.callproc(name, args)
    rows = []
    for result in cur.stored_results():
        cols = result.column_names
        rows = [dict(zip(cols, r)) for r in result.fetchall()]
    cur.close()
    return rows
