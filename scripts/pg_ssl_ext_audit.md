# pg_ssl_ext_audit.sh — Cheat Sheet

**Purpose:** Zero-dependency, read-only audit of a PostgreSQL server's SSL/TLS configuration, certificate expiry, private-key permissions, `pg_hba.conf` transport exposure, and extension version alignment.

**Usage:**
```bash
./pg_ssl_ext_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [--cert-warn <days>]
```
- **Privileges:** Runs as a normal user (or `postgres`, where a peer-login wrapper strips `-h`); opportunistically uses passwordless `sudo -n` to `cat`/`stat` root-owned certificate and key files it otherwise cannot read.
- **Read-only:** Yes — only `SHOW`/`SELECT` queries plus file reads; the sole network side effect is a short `openssl s_client` TLS handshake probe. Nothing is installed, modified, or benchmarked.

## What it tests
- **SSL server config** — `ssl` on/off plus `ssl_cert_file`, `ssl_key_file`, `ssl_ca_file`, `ssl_crl_file`, `ssl_min_protocol_version`, `ssl_max_protocol_version`, `ssl_ciphers`, `ssl_prefer_server_ciphers`, `ssl_passphrase_command`.
- **Minimum TLS version** — flags `TLSv1`/`TLSv1.1`; accepts `TLSv1.2`/`TLSv1.3`.
- **Certificate expiry** — server and CA cert subject, end date, and days remaining vs the `--cert-warn` window.
- **Key file safety** — mode and owner of the private key file (flags `postgres`-owned keys with mode > 600).
- **Live transport** — actual TLS handshake capability and per-connection SSL/TLS-version breakdown of active client backends.
- **pg_hba exposure** — non-local plain `host` rules, `trust` auth on network addresses, and rule syntax errors.
- **Password hashing** — `password_encryption` (flags `md5`).
- **Extension currency** — installed extension version vs default available version.
- **Preload consistency** — `shared_preload_libraries` entries vs created extensions, and catalog extensions whose control file is missing from disk.

## How it tests
- Connects via `psql`; when `-p` is unset it probes ports 5432–5435 with `pg_isready` and confirms with `SELECT 1`. Respects `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`.
- Runs a `psql -At -F'|'` helper (`q`) for scalar/parsed values and a formatted helper (`run_query`) for tables.
- SSL GUCs from `SHOW ssl` and a `pg_settings` query; `ssl_min_protocol_version` matched with a `case` statement.
- Reads cert/key files with `$SUDO cat` (relative paths resolved against `SHOW data_directory`); parses them via `openssl x509 -noout -enddate -subject`; computes days-left with `date -d`.
- Key permissions via `$SUDO stat -c '%a %U'`.
- Live handshake via `echo | timeout 5 openssl s_client -starttls postgres -connect <host:port>`, grepping `Protocol`/`Cipher`/`Verify return`.
- Connection encryption from `pg_stat_activity` LEFT JOIN `pg_stat_ssl` (client backends only).
- HBA analysis from the `pg_hba_file_rules` view (PG10+), inspecting `error`, `type` (`host`), `address`, and `auth_method`; falls back to advising a manual `grep` when the view is unreadable.
- Extensions compared via `pg_extension` JOIN `pg_available_extensions` (`extversion` vs `default_version`); missing control files via `pg_extension` with `NOT EXISTS` in `pg_available_extensions`.
- `shared_preload_libraries` split on commas and each lib cross-checked against `pg_extension`/`pg_available_extensions`.
- Findings accumulate into `ISSUES`/`REMEDS` arrays and print a severity-tagged summary (`OK`/`INFO`/`WARN`/`CRIT`).

## Recommendations
- **SSL is OFF** → enable it: obtain certs, `ALTER SYSTEM SET ssl='on'` (+ cert/key files), `pg_reload_conf()`. *Rationale:* unencrypted transport exposes passwords and all data to network sniffers.
- **Legacy min TLS (1.0/1.1)** → `ALTER SYSTEM SET ssl_min_protocol_version='TLSv1.2'`. *Rationale:* deprecated TLS versions carry cryptographic design flaws.
- **Certificate expired or expiring within the warn window** → reissue/regenerate and `pg_reload_conf()`. *Rationale:* verifying clients cannot connect once the cert lapses.
- **Configured cert not readable** → confirm the file exists and `postgres` can read it. *Rationale:* a missing cert file breaks reload and restart.
- **Key file mode > 600 (postgres-owned)** → `chmod 600` and `chown postgres:postgres`. *Rationale:* PostgreSQL refuses to start or reload SSL with group/world-readable keys.
- **`trust` auth on a non-local address** → replace with `scram-sha-256`. *Rationale:* eliminates passwordless logins from the network.
- **Non-local plain `host` rules while SSL is on** → change `host` to `hostssl`. *Rationale:* enforces encryption instead of leaving it optional.
- **pg_hba.conf syntax errors** → fix the flagged lines and reload. *Rationale:* bad lines are ignored now and a later reload may fail outright.
- **`password_encryption=md5`** → set `scram-sha-256` and re-set passwords. *Rationale:* md5 is weak; scram has been standard since PG10.
- **Extension update available** → `ALTER EXTENSION <name> UPDATE` in every database that has it. *Rationale:* stale extensions cause query errors and miss bug fixes matching the current packages.
- **Preloaded library without its extension created** → `CREATE EXTENSION <name>`, or remove it from `shared_preload_libraries`. *Rationale:* it consumes startup resources while providing nothing.
- **Catalog extension missing its control file on disk** → reinstall the OS package for the current major version, or `DROP EXTENSION ... CASCADE` if abandoned. *Rationale:* the extension is broken after an upgrade or package removal.
