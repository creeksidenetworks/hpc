-- MariaDB init script: grant slurm user full access to slurm_acct_db
-- This file is executed automatically on first container start by the
-- mariadb official image (files in /docker-entrypoint-initdb.d/).
-- The database and user are already created via MYSQL_* env vars;
-- this script only adjusts privileges for remote access from slurmctld.

GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'%'
      IDENTIFIED BY 'UbHGnYGid10HMHvIotB05jWpNsnuTgSC';
FLUSH PRIVILEGES;
