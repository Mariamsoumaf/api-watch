-- =====================================================
--  API Watch - Database Schema
--  Database Management Project
--  Run this file in MySQL Workbench (File > Open SQL Script > Execute)
-- =====================================================

-- 1) Create the database
DROP DATABASE IF EXISTS api_watch;
CREATE DATABASE api_watch
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE api_watch;

-- =====================================================
-- 2) Tables
-- =====================================================

-- USERS: people who use the system
CREATE TABLE users (
    user_id        INT           AUTO_INCREMENT PRIMARY KEY,
    full_name      VARCHAR(100)  NOT NULL,
    email          VARCHAR(150)  NOT NULL UNIQUE,
    password_hash  VARCHAR(255)  NOT NULL,
    created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- PROJECTS: each user owns many projects
CREATE TABLE projects (
    project_id   INT           AUTO_INCREMENT PRIMARY KEY,
    owner_id     INT           NOT NULL,
    name         VARCHAR(100)  NOT NULL,
    description  TEXT,
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_projects_owner
        FOREIGN KEY (owner_id) REFERENCES users(user_id)
        ON DELETE CASCADE,
    CONSTRAINT uq_owner_project_name UNIQUE (owner_id, name)
);

-- PROJECT_MEMBERS: many-to-many between users and projects
CREATE TABLE project_members (
    member_id   INT                       AUTO_INCREMENT PRIMARY KEY,
    project_id  INT                       NOT NULL,
    user_id     INT                       NOT NULL,
    role        ENUM('owner', 'viewer')   NOT NULL DEFAULT 'viewer',
    joined_at   DATETIME                  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_members_project
        FOREIGN KEY (project_id) REFERENCES projects(project_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_members_user
        FOREIGN KEY (user_id) REFERENCES users(user_id)
        ON DELETE CASCADE,
    CONSTRAINT uq_member UNIQUE (project_id, user_id)   -- same person cannot join twice
);

-- MONITORS: the URLs we watch
CREATE TABLE monitors (
    monitor_id    INT           AUTO_INCREMENT PRIMARY KEY,
    project_id    INT           NOT NULL,
    name          VARCHAR(100)  NOT NULL,
    url           VARCHAR(500)  NOT NULL,
    interval_sec  INT           NOT NULL DEFAULT 60,
    is_active     BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_monitors_project
        FOREIGN KEY (project_id) REFERENCES projects(project_id)
        ON DELETE CASCADE,
    CONSTRAINT uq_project_url UNIQUE (project_id, url),
    CONSTRAINT chk_interval CHECK (interval_sec BETWEEN 30 AND 3600)
);

-- CHECKS: one row for every check (grows very fast)
CREATE TABLE checks (
    check_id       BIGINT        AUTO_INCREMENT PRIMARY KEY,
    monitor_id     INT           NOT NULL,
    checked_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status_code    SMALLINT      NULL,          -- NULL = no response (timeout)
    response_ms    INT           NULL,
    is_up          BOOLEAN       NOT NULL,
    error_message  VARCHAR(255)  NULL,
    CONSTRAINT fk_checks_monitor
        FOREIGN KEY (monitor_id) REFERENCES monitors(monitor_id)
        ON DELETE CASCADE,
    INDEX idx_checks_monitor_time (monitor_id, checked_at)   -- makes reports fast
);

-- INCIDENTS: a period when a monitor was down
CREATE TABLE incidents (
    incident_id  INT                         AUTO_INCREMENT PRIMARY KEY,
    monitor_id   INT                         NOT NULL,
    started_at   DATETIME                    NOT NULL,
    resolved_at  DATETIME                    NULL,      -- NULL = still down
    status       ENUM('open', 'resolved')    NOT NULL DEFAULT 'open',
    CONSTRAINT fk_incidents_monitor
        FOREIGN KEY (monitor_id) REFERENCES monitors(monitor_id)
        ON DELETE CASCADE,
    CONSTRAINT chk_incident_time CHECK (resolved_at IS NULL OR resolved_at >= started_at)
);

-- ALERTS: messages sent to users about incidents
CREATE TABLE alerts (
    alert_id     INT                          AUTO_INCREMENT PRIMARY KEY,
    incident_id  INT                          NOT NULL,
    user_id      INT                          NOT NULL,
    channel      ENUM('email', 'telegram')    NOT NULL DEFAULT 'email',
    sent_at      DATETIME                     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_alerts_incident
        FOREIGN KEY (incident_id) REFERENCES incidents(incident_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_alerts_user
        FOREIGN KEY (user_id) REFERENCES users(user_id)
        ON DELETE CASCADE,
    CONSTRAINT uq_alert UNIQUE (incident_id, user_id, channel)
);

-- =====================================================
-- 3) Sample data
-- =====================================================

-- Note: these are demo hashes. The Flask app will create real ones.
INSERT INTO users (full_name, email, password_hash) VALUES
('Sara Ahmed',   'sara@mail.com',  'demo_hash_sara'),
('Ahmad Ali',    'ahmad@mail.com', 'demo_hash_ahmad'),
('Lina Hassan',  'lina@mail.com',  'demo_hash_lina');

INSERT INTO projects (owner_id, name, description) VALUES
(1, 'ShopX',        'Online store website and APIs'),
(1, 'My Blog',      'Personal blog'),
(2, 'Restaurant App','Food ordering app backend');

INSERT INTO project_members (project_id, user_id, role) VALUES
(1, 1, 'owner'),
(1, 2, 'viewer'),
(2, 1, 'owner'),
(3, 2, 'owner'),
(3, 3, 'viewer');

-- Real public URLs, so the checker can test them live
INSERT INTO monitors (project_id, name, url, interval_sec, is_active) VALUES
(1, 'Home Page',   'https://example.com',                 60,  TRUE),
(1, 'Login API',   'https://httpbin.org/status/200',      60,  TRUE),
(1, 'Payment API', 'https://httpbin.org/delay/2',         120, TRUE),
(2, 'Blog Home',   'https://httpbin.org/status/404',      300, TRUE),
(3, 'Orders API',  'https://httpbin.org/status/500',      60,  FALSE);

INSERT INTO checks (monitor_id, checked_at, status_code, response_ms, is_up, error_message) VALUES
(1, '2026-11-18 14:03:00', 200, 180, TRUE,  NULL),
(1, '2026-11-18 14:04:00', 200, 175, TRUE,  NULL),
(1, '2026-11-18 14:05:00', 200, 190, TRUE,  NULL),
(2, '2026-11-18 14:03:00', 200, 210, TRUE,  NULL),
(2, '2026-11-18 14:04:00', 200, 230, TRUE,  NULL),
(2, '2026-11-18 14:05:00', 500, 95,  FALSE, 'Internal Server Error'),
(2, '2026-11-18 14:06:00', 500, 90,  FALSE, 'Internal Server Error'),
(2, '2026-11-18 14:15:00', 200, 200, TRUE,  NULL),
(3, '2026-11-18 14:04:00', 200, 640, TRUE,  NULL),
(3, '2026-11-18 14:06:00', 200, 910, TRUE,  NULL),
(3, '2026-11-18 14:08:00', NULL, NULL, FALSE, 'Timeout after 10s'),
(4, '2026-11-18 14:00:00', 200, 320, TRUE,  NULL),
(4, '2026-11-18 14:05:00', 404, 150, FALSE, 'Not Found');

INSERT INTO incidents (monitor_id, started_at, resolved_at, status) VALUES
(2, '2026-11-18 14:05:00', '2026-11-18 14:15:00', 'resolved'),
(3, '2026-11-18 14:08:00', NULL,                  'open'),
(4, '2026-11-18 14:05:00', NULL,                  'open');

INSERT INTO alerts (incident_id, user_id, channel, sent_at) VALUES
(1, 1, 'email',    '2026-11-18 14:06:00'),
(1, 2, 'telegram', '2026-11-18 14:06:00'),
(2, 1, 'email',    '2026-11-18 14:09:00'),
(3, 1, 'email',    '2026-11-18 14:06:00');

-- =====================================================
-- 4) Smart objects: View, Triggers, Procedure
--    (created AFTER the sample data, so the sample rows
--     do not fire the triggers)
-- =====================================================

-- -----------------------------------------------------
-- A1) VIEW: uptime report for every monitor
--     A view is a "saved SELECT". We use it like a table.
-- -----------------------------------------------------
CREATE OR REPLACE VIEW v_monitor_uptime AS
SELECT
    m.monitor_id,
    m.name                                   AS monitor_name,
    m.url,
    p.name                                   AS project_name,
    u.full_name                              AS owner_name,
    COUNT(c.check_id)                        AS total_checks,
    SUM(c.is_up = TRUE)                      AS successful_checks,
    ROUND(100 * SUM(c.is_up = TRUE) / NULLIF(COUNT(c.check_id), 0), 2) AS uptime_percent,
    ROUND(AVG(c.response_ms), 0)             AS avg_response_ms
FROM monitors m
JOIN projects p      ON m.project_id = p.project_id
JOIN users u         ON p.owner_id   = u.user_id
LEFT JOIN checks c   ON c.monitor_id = m.monitor_id
GROUP BY m.monitor_id, m.name, m.url, p.name, u.full_name;


-- -----------------------------------------------------
-- A2) TRIGGER: open or close incidents automatically
--     After every new check:
--       - check is DOWN and no open incident  -> open a new incident
--       - check is UP and there is an open one -> close it
-- -----------------------------------------------------
DROP TRIGGER IF EXISTS trg_check_incident;

DELIMITER $$
CREATE TRIGGER trg_check_incident
AFTER INSERT ON checks
FOR EACH ROW
BEGIN
    IF NEW.is_up = FALSE THEN
        IF NOT EXISTS (SELECT 1 FROM incidents
                       WHERE monitor_id = NEW.monitor_id AND status = 'open') THEN
            INSERT INTO incidents (monitor_id, started_at, status)
            VALUES (NEW.monitor_id, NEW.checked_at, 'open');
        END IF;
    ELSE
        UPDATE incidents
        SET    resolved_at = NEW.checked_at,
               status      = 'resolved'
        WHERE  monitor_id = NEW.monitor_id AND status = 'open';
    END IF;
END$$
DELIMITER ;


-- -----------------------------------------------------
-- A3) TRIGGER: send alerts automatically
--     When a new incident opens -> create an alert
--     for every member of that project.
-- -----------------------------------------------------
DROP TRIGGER IF EXISTS trg_incident_alerts;

DELIMITER $$
CREATE TRIGGER trg_incident_alerts
AFTER INSERT ON incidents
FOR EACH ROW
BEGIN
    INSERT INTO alerts (incident_id, user_id, channel, sent_at)
    SELECT NEW.incident_id, pm.user_id, 'email', NOW()
    FROM   monitors m
    JOIN   project_members pm ON pm.project_id = m.project_id
    WHERE  m.monitor_id = NEW.monitor_id;
END$$
DELIMITER ;


-- -----------------------------------------------------
-- A4) STORED PROCEDURE: dashboard summary for one user
--     Usage: CALL get_user_dashboard(1);
-- -----------------------------------------------------
DROP PROCEDURE IF EXISTS get_user_dashboard;

DELIMITER $$
CREATE PROCEDURE get_user_dashboard(IN p_user_id INT)
BEGIN
    SELECT
        COUNT(DISTINCT pm.project_id)                         AS my_projects,
        COUNT(DISTINCT m.monitor_id)                          AS my_monitors,
        COUNT(DISTINCT CASE WHEN i.status = 'open'
                            THEN i.incident_id END)           AS open_incidents
    FROM project_members pm
    LEFT JOIN monitors  m ON m.project_id = pm.project_id
    LEFT JOIN incidents i ON i.monitor_id = m.monitor_id
    WHERE pm.user_id = p_user_id;
END$$
DELIMITER ;


-- =====================================================
-- 5) Quick test: show every table with its row count
-- =====================================================
SELECT 'users' AS table_name, COUNT(*) AS total_rows FROM users
UNION ALL SELECT 'projects',        COUNT(*) FROM projects
UNION ALL SELECT 'project_members', COUNT(*) FROM project_members
UNION ALL SELECT 'monitors',        COUNT(*) FROM monitors
UNION ALL SELECT 'checks',          COUNT(*) FROM checks
UNION ALL SELECT 'incidents',       COUNT(*) FROM incidents
UNION ALL SELECT 'alerts',          COUNT(*) FROM alerts;
