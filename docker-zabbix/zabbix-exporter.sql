-- Run to see all metrics
-- See https://github.com/prometheus-community/postgres_exporter?tab=readme-ov-file#running-as-non-superuser
GRANT EXECUTE ON FUNCTION pg_ls_waldir() TO zabbix;
ALTER USER zabbix
SET SEARCH_PATH TO zabbix,
    pg_catalog;
GRANT CONNECT ON DATABASE postgres TO zabbix;
GRANT pg_monitor to zabbix;
GRANT USAGE ON SCHEMA pg_catalog TO zabbix;
GRANT SELECT ON ALL TABLES IN SCHEMA pg_catalog TO zabbix;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
-- GRANT SELECT ON pg_stat_bgwriter TO zabbix;
-- CREATE SCHEMA monitoring;
-- CREATE VIEW monitoring.bgwriter_stats AS
-- SELECT *
-- FROM pg_stat_bgwriter;
-- GRANT USAGE ON SCHEMA monitoring TO zabbix;
-- GRANT SELECT ON monitoring.bgwriter_stats TO zabbix;