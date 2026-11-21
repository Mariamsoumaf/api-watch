-- =====================================================
--  API Watch - Queries (Stage 2)
--  Run AFTER schema.sql
--  Tip: run everything with the first lightning button,
--       or select one query and press Ctrl + Enter.
-- =====================================================

USE api_watch;

-- #####################################################
-- PART A: SMART DATABASE OBJECTS (View, Triggers, Procedure)
-- #####################################################

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


-- #####################################################
-- PART B: CRUD (INSERT, SELECT, UPDATE, DELETE)
-- #####################################################

-- B1) INSERT: add a new monitor to project ShopX
INSERT INTO monitors (project_id, name, url, interval_sec)
VALUES (1, 'Search API', 'https://shopx.com/api/search', 60);

-- B2) SELECT: show all monitors of project 1
SELECT monitor_id, name, url, interval_sec, is_active
FROM   monitors
WHERE  project_id = 1
ORDER  BY monitor_id;

-- B3) UPDATE: pause the new monitor and check it every 5 minutes
UPDATE monitors
SET    is_active = FALSE,
       interval_sec = 300
WHERE  project_id = 1 AND url = 'https://shopx.com/api/search';

-- B4) DELETE: remove the new monitor (its checks are deleted by CASCADE)
DELETE FROM monitors
WHERE  project_id = 1 AND url = 'https://shopx.com/api/search';


-- #####################################################
-- PART C: SEARCHES WITH JOIN (reports)
-- #####################################################

-- C1) All monitors with their project and owner (3 tables)
SELECT m.name AS monitor, m.url, p.name AS project, u.full_name AS owner
FROM   monitors m
JOIN   projects p ON m.project_id = p.project_id
JOIN   users    u ON p.owner_id   = u.user_id
ORDER  BY p.name, m.name;

-- C2) Search: every failed check for one user (4 tables)
SELECT u.full_name, p.name AS project, m.name AS monitor,
       c.checked_at, c.status_code, c.error_message
FROM   checks c
JOIN   monitors m ON c.monitor_id = m.monitor_id
JOIN   projects p ON m.project_id = p.project_id
JOIN   users    u ON p.owner_id   = u.user_id
WHERE  c.is_up = FALSE
  AND  u.email = 'sara@mail.com'
ORDER  BY c.checked_at DESC;

-- C3) Open incidents right now, with how long they have been down
SELECT p.name AS project, m.name AS monitor, i.started_at,
       TIMESTAMPDIFF(MINUTE, i.started_at, NOW()) AS minutes_down
FROM   incidents i
JOIN   monitors m ON i.monitor_id = m.monitor_id
JOIN   projects p ON m.project_id = p.project_id
WHERE  i.status = 'open';

-- C4) Which monitor had the most incidents? (GROUP BY)
SELECT m.name AS monitor, p.name AS project, COUNT(i.incident_id) AS total_incidents
FROM   monitors m
JOIN   projects p       ON m.project_id = p.project_id
LEFT JOIN incidents i   ON i.monitor_id = m.monitor_id
GROUP  BY m.monitor_id, m.name, p.name
ORDER  BY total_incidents DESC;

-- C5) Who received alerts, and about what? (5 tables)
SELECT u.full_name AS sent_to, a.channel, a.sent_at,
       m.name AS monitor, p.name AS project
FROM   alerts a
JOIN   users     u ON a.user_id     = u.user_id
JOIN   incidents i ON a.incident_id = i.incident_id
JOIN   monitors  m ON i.monitor_id  = m.monitor_id
JOIN   projects  p ON m.project_id  = p.project_id
ORDER  BY a.sent_at DESC;

-- C6) Team members of every project with their role
SELECT p.name AS project, u.full_name AS member, pm.role
FROM   project_members pm
JOIN   projects p ON pm.project_id = p.project_id
JOIN   users    u ON pm.user_id    = u.user_id
ORDER  BY p.name, pm.role;

-- C7) Use the VIEW: uptime of every monitor
SELECT monitor_name, project_name, total_checks, uptime_percent, avg_response_ms
FROM   v_monitor_uptime
ORDER  BY uptime_percent ASC;

-- C8) Use the PROCEDURE: Sara's dashboard
CALL get_user_dashboard(1);


-- #####################################################
-- PART D: LIVE DEMO OF THE TRIGGERS (great for the viva!)
-- #####################################################

-- D1) Home Page goes DOWN -> trigger opens an incident + sends alerts
INSERT INTO checks (monitor_id, checked_at, status_code, response_ms, is_up, error_message)
VALUES (1, NOW(), 503, 120, FALSE, 'Service Unavailable');

SELECT * FROM incidents WHERE monitor_id = 1;   -- new incident: status = open
SELECT * FROM alerts ORDER BY alert_id DESC;     -- new alerts for Sara and Ahmad

-- D2) Home Page is UP again -> trigger closes the incident
INSERT INTO checks (monitor_id, checked_at, status_code, response_ms, is_up)
VALUES (1, NOW() + INTERVAL 1 MINUTE, 200, 180, TRUE);

SELECT * FROM incidents WHERE monitor_id = 1;   -- status = resolved
