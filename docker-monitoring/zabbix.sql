-- Run to see all metrics
-- See https://github.com/prometheus-community/postgres_exporter?tab=readme-ov-file#running-as-non-superuser
GRANT EXECUTE ON FUNCTION pg_ls_waldir() TO zabbix;
ALTER USER zabbix
SET SEARCH_PATH TO zabbix,
    pg_catalog;
GRANT CONNECT ON DATABASE postgres TO zabbix;
GRANT pg_monitor to zabbix;