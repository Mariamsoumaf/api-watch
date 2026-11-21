# API Watch 🟢

**A website and API uptime monitoring system built on a relational MySQL database.**

API Watch checks your websites and APIs automatically. It saves every check in the database, opens an **incident** when a service goes down, and sends **alerts** to the project team. Database triggers do this automatically.

> Database Management course project · Istanbul Gelisim University

---

## ✨ Features

- **Dashboard:** live status of all monitors, open incidents, recent alerts and average uptime
- **Monitors:** add, search, filter, edit, pause and delete monitored URLs (full CRUD)
- **Monitor details:** response-time chart, check history and incident timeline
- **Reports:** search checks with JOINs, uptime ranking, most incidents, project teams
- **Background checker:** checks every active URL on its own interval
- **Smart database:** triggers open and close incidents and create alerts automatically
- **Roles:** project `owner` can edit, `viewer` can only watch

## 🧱 Tech stack

| Layer | Technology |
|---|---|
| Database | MySQL 8 (MySQL Workbench) |
| Backend | Python 3, Flask |
| Frontend | HTML, CSS, JavaScript, Chart.js |

## 🗄️ Database design

7 related tables: `users`, `projects`, `project_members`, `monitors`, `checks`, `incidents`, `alerts`.

```
users ──< projects ──< monitors ──< checks
  │          │            └──────< incidents ──< alerts >── users
  └──< project_members >──┘
```

| Concept | Where it is used |
|---|---|
| Primary keys + `AUTO_INCREMENT` | Every table |
| Foreign keys + `ON DELETE CASCADE` | All relationships |
| `NOT NULL`, `UNIQUE`, `CHECK`, `ENUM` | Emails, URLs per project, interval range, roles, status |
| Many-to-many | `project_members` (users ↔ projects) |
| Index | `checks(monitor_id, checked_at)` for fast reports |
| View | `v_monitor_uptime`: uptime % and average response per monitor |
| Triggers | `trg_check_incident`, `trg_incident_alerts` |
| Stored procedure | `get_user_dashboard(user_id)` |

### How the triggers work

```
checker inserts a check ──► trg_check_incident
                              ├─ down + no open incident → open incident ──► trg_incident_alerts → alerts for all members
                              └─ up + open incident      → close incident
```

## 🚀 How to run

**1. Create the database**

Open `database/schema.sql` in MySQL Workbench and run it with the ⚡ button.
(`database/queries.sql` has extra example queries for the presentation.)

**2. Install the Python packages**

```bash
python -m venv venv
venv\Scripts\activate          # Windows
# source venv/bin/activate     # Mac / Linux
pip install -r requirements.txt
```

**3. Add your MySQL password**

Copy `.env.example` to `.env`, then write your MySQL password in `DB_PASSWORD`.

**4. Start the app**

```bash
python app.py
```

Open **http://127.0.0.1:5000**

## 📁 Project structure

```
api-watch/
├── app.py              # Flask routes (the 4 pages + actions)
├── db.py               # MySQL helper functions
├── checker.py          # Background URL checker
├── config.py           # Settings (read from .env)
├── database/
│   ├── schema.sql      # Tables, sample data, view, triggers, procedure
│   └── queries.sql     # CRUD + JOIN examples
├── templates/          # HTML pages (Jinja2)
└── static/             # CSS and JavaScript
```

## 🔮 Future ideas

- Telegram and email notifications
- Public status page for customers
- SSL certificate expiry monitoring
- Anomaly detection with AI (warn before a service fails)
- Login and registration

---

Made by **Mariam Soumaf** · [GitHub](https://github.com/Mariamsoumaf)
