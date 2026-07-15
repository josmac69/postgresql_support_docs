#!/bin/bash
# ============================================================================
# SCRIPT: pg_ssl_ext_audit.sh
# DESCRIPTION:
#   Zero-dependency diagnostic script that audits PostgreSQL SSL/TLS settings,
#   certificate expiry, private key file permissions, transport security (pg_hba.conf),
#   and extension version alignments. Read-only diagnostic script.
#
# PARAMETERS CHECKED:
#   - SSL GUCs: ssl, ssl_cert_file, ssl_key_file, ssl_ca_file, ssl_crl_file,
#     ssl_min_protocol_version, ssl_ciphers.
#   - Certificate expiry: Server and CA cert validity dates, CN/subject, and days remaining.
#   - Key file safety: File ownership, group and world permissions of the private key file.
#   - Transport: Live TLS handshake capability, active connection encryption stats (pg_stat_ssl).
#   - Security rules: pg_hba.conf rule types (host vs hostssl), trust settings, and password_encryption GUC.
#   - Extensions: Installed extension versions vs default available, preloaded libraries matching,
#     and catalog/disk file presence verification.
#
# RECOMMENDATIONS & RATIONALE:
#   - If SSL is off or network rules use 'host' instead of 'hostssl': Recommends enabling SSL and
#     changing rules. Rationale: Enforces encrypted transport over the network, protecting database
#     passwords and transaction payload details from network sniffers.
#   - If TLS protocol version is legacy (1.0 or 1.1): Recommends requiring TLS 1.2+. Rationale: Legacy
#     TLS protocols contain cryptographic design vulnerabilities.
#   - If cert key file permissions are > 600: Recommends restricting permissions. Rationale: PostgreSQL
#     actively rejects launching or reloading with keys readable by other system users.
#   - If non-local trust auth is enabled: Recommends changing to scram-sha-256. Rationale: Eliminates
#     the risk of passwordless network logins.
#   - If extensions have upgrades available or are missing from disk: Recommends running ALTER EXTENSION
#     or installing packages. Rationale: Stale or broken extensions cause query errors and miss critical
#     bug fixes matching the current database packages.
#
# USAGE:
#   ./pg_ssl_ext_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [--cert-warn <days>]
# ============================================================================

set -o nounset

# Colors for premium CLI styling
if [ -t 1 ]; then
    C_RST=$'\033[0m'
    C_RED=$'\033[1;31m'
    C_GRN=$'\033[1;32m'
    C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'
    C_BOLD=$'\033[1m'
else
    C_RST="" C_RED="" C_GRN="" C_YEL="" C_BLU="" C_BOLD=""
fi

hr() { printf '%s\n' "--------------------------------------------------------------------------------"; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
fi

# Peer login wrapper when running under postgres user
if [ "$(id -un)" = "postgres" ]; then
    psql() {
        local args=()
        local i=1
        while [ $i -le $# ]; do
            local arg="${!i}"
            if [ "$arg" = "-h" ]; then
                i=$((i + 2))
                continue
            fi
            args+=("$arg")
            i=$((i + 1))
        done
        command psql "${args[@]}"
    }
fi

# CLI Defaults
PG_HOST="${PGHOST:-localhost}"
PG_PORT="${PGPORT:-}"
PG_USER="${PGUSER:-postgres}"
PG_DBNAME="${PGDATABASE:-postgres}"
CERT_WARN_DAYS=30

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database (default: postgres or PGDATABASE)
  --cert-warn <days>      Warn if certificate expires within N days (default: 30)
  --help                  Show this help menu

Connection env variables (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE) are respected.
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--host) PG_HOST="$2"; shift 2 ;;
        -p|--port) PG_PORT="$2"; shift 2 ;;
        -U|--user) PG_USER="$2"; shift 2 ;;
        -d|--dbname) PG_DBNAME="$2"; shift 2 ;;
        --cert-warn) CERT_WARN_DAYS="$2"; shift 2 ;;
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; show_help ;;
    esac
done

if ! have psql; then
    echo "${C_RED}Error: psql utility is required but not found in PATH.${C_RST}" >&2
    exit 1
fi

# Detect running DB and connect
DB_CONNECTED=0
CONNECTED_PORT=""

PORTS_TO_TRY=()
if [ -n "$PG_PORT" ]; then
    PORTS_TO_TRY+=("$PG_PORT")
else
    for p in 5432 5433 5434 5435; do
        if pg_isready -h "$PG_HOST" -p "$p" >/dev/null 2>&1; then
            PORTS_TO_TRY+=("$p")
        fi
    done
    [ ${#PORTS_TO_TRY[@]} -eq 0 ] && PORTS_TO_TRY=(5432)
fi

for port in "${PORTS_TO_TRY[@]}"; do
    res=$(psql -h "$PG_HOST" -p "$port" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT 1;" 2>/dev/null || echo "failed")
    if [ "$res" = "1" ]; then
        DB_CONNECTED=1
        CONNECTED_PORT="$port"
        break
    fi
done

if [ "$DB_CONNECTED" -eq 0 ]; then
    echo "${C_RED}Error: Could not connect to target database at ${PG_HOST} on ports [${PORTS_TO_TRY[*]}].${C_RST}" >&2
    exit 1
fi

run_query() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -c "$1"
}
q() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "$1" 2>/dev/null || echo ""
}

ISSUES=()
REMEDS=()
warn() { echo "${C_YEL}[WARN]${C_RST} $1"; ISSUES+=("WARN: $1"); }
crit() { echo "${C_RED}[CRIT]${C_RST} $1"; ISSUES+=("CRIT: $1"); }
ok()   { echo "${C_GRN}[OK]${C_RST} $1"; }
info() { echo "${C_BLU}[INFO]${C_RST} $1"; }
remed() { REMEDS+=("$1"); }

echo
echo "${C_BOLD}PostgreSQL SSL/TLS & Extension Health Audit${C_RST}"
hr
echo "Host            : $PG_HOST"
echo "Port            : $CONNECTED_PORT"
echo "Database        : $PG_DBNAME"
echo "Cert warn window: ${CERT_WARN_DAYS} days"
hr

# ============================================================================
# 1. SSL SERVER CONFIGURATION
# ============================================================================
echo
echo "${C_BOLD}1. SSL Server Configuration${C_RST}"
hr

SSL_ON=$(q "SHOW ssl;")
echo "ssl = $SSL_ON"

if [ "$SSL_ON" != "on" ]; then
    warn "SSL is OFF — all traffic (including passwords with md5, and all data) crosses the network unencrypted."
    remed "Enable SSL: generate/obtain certs, then ALTER SYSTEM SET ssl = 'on'; ALTER SYSTEM SET ssl_cert_file='server.crt'; ALTER SYSTEM SET ssl_key_file='server.key'; SELECT pg_reload_conf();"
    remed "Quick self-signed cert (acceptable stopgap, note in report): openssl req -new -x509 -days 365 -nodes -text -out server.crt -keyout server.key -subj '/CN=\$(hostname -f)' && chmod 600 server.key && chown postgres:postgres server.crt server.key"
else
    ok "SSL is enabled."
    run_query "
    SELECT name AS \"Parameter\", setting AS \"Value\"
    FROM pg_settings
    WHERE name IN ('ssl_cert_file','ssl_key_file','ssl_ca_file','ssl_crl_file',
                   'ssl_min_protocol_version','ssl_max_protocol_version',
                   'ssl_ciphers','ssl_prefer_server_ciphers','ssl_passphrase_command')
    ORDER BY name;
    "
    MIN_PROTO=$(q "SHOW ssl_min_protocol_version;")
    case "$MIN_PROTO" in
        TLSv1|TLSv1.1)
            warn "ssl_min_protocol_version=$MIN_PROTO — TLS 1.0/1.1 are deprecated and vulnerable."
            remed "Raise minimum TLS: ALTER SYSTEM SET ssl_min_protocol_version = 'TLSv1.2'; SELECT pg_reload_conf(); (verify no legacy clients first)"
            ;;
        TLSv1.2|TLSv1.3)
            ok "ssl_min_protocol_version=$MIN_PROTO."
            ;;
    esac
fi
hr

# ============================================================================
# 2. CERTIFICATE VALIDITY & EXPIRY
# ============================================================================
echo
echo "${C_BOLD}2. Certificate Validity & Expiry${C_RST}"
hr

DATA_DIR=$(q "SHOW data_directory;")

check_cert() {
    # $1 = label, $2 = path (may be relative to data dir)
    local label="$1" path="$2"
    [ -z "$path" ] && return
    case "$path" in
        /*) : ;;
        *)  path="$DATA_DIR/$path" ;;
    esac
    local content
    content=$($SUDO cat "$path" 2>/dev/null || cat "$path" 2>/dev/null || true)
    if [ -z "$content" ]; then
        warn "$label at $path is configured but NOT readable (missing file breaks reload/restart!)."
        remed "Verify file exists and postgres can read it: sudo ls -l $path; sudo -u postgres test -r $path && echo readable"
        return
    fi
    if ! have openssl; then
        info "$label present at $path (openssl not installed — cannot check expiry)."
        return
    fi
    local enddate subject
    enddate=$(echo "$content" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    subject=$(echo "$content" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//' || true)
    if [ -z "$enddate" ]; then
        warn "$label at $path could not be parsed as an X.509 certificate."
        return
    fi
    echo "  $label: $path"
    echo "    Subject : $subject"
    echo "    Expires : $enddate"
    local end_epoch now_epoch days_left
    end_epoch=$(date -d "$enddate" +%s 2>/dev/null || date -j -f '%b %e %T %Y %Z' "$enddate" +%s 2>/dev/null || echo "")
    now_epoch=$(date +%s)
    if [ -n "$end_epoch" ]; then
        days_left=$(( (end_epoch - now_epoch) / 86400 ))
        if [ "$days_left" -lt 0 ]; then
            crit "$label EXPIRED $(( -days_left )) days ago — clients enforcing verification CANNOT connect!"
            remed "Replace expired certificate at $path (reissue from CA or regenerate self-signed), then: SELECT pg_reload_conf(); -- SSL cert reload needs no restart on PG10+"
        elif [ "$days_left" -lt "$CERT_WARN_DAYS" ]; then
            warn "$label expires in $days_left days."
            remed "Renew $label before expiry ($days_left days left): plan cert rotation, then SELECT pg_reload_conf();"
        else
            ok "$label valid for $days_left more days."
        fi
    fi
    # key permission check for the key file is done separately below
}

if [ "$SSL_ON" = "on" ]; then
    CERT_FILE=$(q "SHOW ssl_cert_file;")
    KEY_FILE=$(q "SHOW ssl_key_file;")
    CA_FILE=$(q "SELECT coalesce(setting,'') FROM pg_settings WHERE name='ssl_ca_file';")
    check_cert "Server certificate" "$CERT_FILE"
    [ -n "$CA_FILE" ] && check_cert "CA certificate" "$CA_FILE"

    # Key file permissions (postgres refuses group/world-readable keys unless root-owned)
    KPATH="$KEY_FILE"
    case "$KPATH" in /*) : ;; *) KPATH="$DATA_DIR/$KPATH" ;; esac
    KPERM=$($SUDO stat -c '%a %U' "$KPATH" 2>/dev/null || stat -c '%a %U' "$KPATH" 2>/dev/null || true)
    if [ -n "$KPERM" ]; then
        KMODE=${KPERM%% *}; KOWNER=${KPERM##* }
        echo "  Key file: $KPATH (mode $KMODE, owner $KOWNER)"
        if [ "$KOWNER" = "postgres" ] && [ "$KMODE" -gt 600 ] 2>/dev/null; then
            crit "ssl_key_file mode $KMODE is too permissive — PostgreSQL will REFUSE to start/reload SSL!"
            remed "Fix key permissions: sudo chmod 600 $KPATH && sudo chown postgres:postgres $KPATH; then SELECT pg_reload_conf();"
        else
            ok "Key file permissions acceptable."
        fi
    fi

    # Live handshake test
    if have openssl; then
        echo
        echo "Live TLS handshake test (openssl s_client with PG STARTTLS):"
        HS=$(echo | timeout 5 openssl s_client -starttls postgres -connect "$PG_HOST:$CONNECTED_PORT" 2>/dev/null | grep -E 'Protocol|Cipher +:|Verify return' | head -5 || true)
        if [ -n "$HS" ]; then
            echo "$HS" | sed 's/^/  /'
        else
            info "Handshake test unavailable (older openssl without -starttls postgres, or connection refused)."
        fi
    fi

    # Current connection encryption states
    echo
    echo "Current connections by SSL state (pg_stat_ssl):"
    run_query "
    SELECT coalesce(s.ssl::text,'?') AS \"SSL\", coalesce(s.version,'-') AS \"TLS Version\",
           count(*) AS \"Connections\"
    FROM pg_stat_activity a
    LEFT JOIN pg_stat_ssl s ON s.pid = a.pid
    WHERE a.backend_type = 'client backend'
    GROUP BY 1, 2 ORDER BY 3 DESC;
    "
fi
hr

# ============================================================================
# 3. PG_HBA HOST VS HOSTSSL EXPOSURE
# ============================================================================
echo
echo "${C_BOLD}3. pg_hba.conf Transport Exposure${C_RST}"
hr

# Prefer pg_hba_file_rules view (PG10+), fall back to file grep
HBA_RULES=$(q "SELECT line_number, type, array_to_string(database,','), array_to_string(user_name,','), coalesce(address,''), auth_method FROM pg_hba_file_rules WHERE error IS NULL ORDER BY line_number;")
HBA_ERRORS=$(q "SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL;")

if [ -n "$HBA_ERRORS" ]; then
    crit "pg_hba.conf contains SYNTAX ERRORS — those lines are ignored, and a future reload may fail entirely:"
    echo "$HBA_ERRORS" | while IFS='|' read -r ln err; do echo "    line $ln: $err"; done
    remed "Fix pg_hba.conf syntax errors (SHOW hba_file; for path), validate via SELECT * FROM pg_hba_file_rules; then SELECT pg_reload_conf();"
fi

if [ -n "$HBA_RULES" ]; then
    PLAIN_HOST=0
    while IFS='|' read -r ln type dbs users addr method; do
        # Non-local 'host' rules with broad CIDRs allow unencrypted transport
        if [ "$type" = "host" ] && [ -n "$addr" ] && [ "$addr" != "127.0.0.1/32" ] && [ "$addr" != "::1/128" ]; then
            PLAIN_HOST=$((PLAIN_HOST + 1))
            echo "  line $ln: host $dbs $users $addr $method  ${C_YEL}<- allows non-SSL transport${C_RST}"
        fi
        if [ "$method" = "trust" ] && [ "$addr" != "" ] && [ "$addr" != "127.0.0.1/32" ] && [ "$addr" != "::1/128" ]; then
            crit "line $ln uses TRUST for non-local address $addr — passwordless access from the network!"
            remed "Replace trust with scram-sha-256 on line $ln of pg_hba.conf, then SELECT pg_reload_conf();"
        fi
    done <<< "$HBA_RULES"
    if [ "$PLAIN_HOST" -gt 0 ] && [ "$SSL_ON" = "on" ]; then
        warn "$PLAIN_HOST non-local 'host' rule(s) permit unencrypted connections even though SSL is enabled."
        remed "Enforce encryption: change 'host' to 'hostssl' for network rules in pg_hba.conf (keep a hostssl rule ABOVE any residual host rule), then SELECT pg_reload_conf();"
    elif [ "$PLAIN_HOST" -eq 0 ]; then
        ok "No non-local plain 'host' rules — network access is SSL-enforced or local-only."
    fi
else
    info "pg_hba_file_rules view not readable (needs superuser/pg_read_all_settings) — grep the file manually: sudo grep -vE '^\s*(#|$)' \$(psql -Atc 'SHOW hba_file;')"
fi

PASSWORD_ENC=$(q "SHOW password_encryption;")
if [ "$PASSWORD_ENC" = "md5" ]; then
    warn "password_encryption=md5 — weak hashing; scram-sha-256 has been the standard since PG10."
    remed "Upgrade password hashing: ALTER SYSTEM SET password_encryption='scram-sha-256'; SELECT pg_reload_conf(); then re-set passwords: \\password <user> (existing md5 hashes keep working until reset)."
else
    ok "password_encryption=$PASSWORD_ENC."
fi
hr

# ============================================================================
# 4. EXTENSION VERSIONS: INSTALLED VS AVAILABLE
# ============================================================================
echo
echo "${C_BOLD}4. Extension Versions (Installed vs Available)${C_RST}"
hr

run_query "
SELECT e.extname AS \"Extension\", e.extversion AS \"Installed\",
       a.default_version AS \"Available\", n.nspname AS \"Schema\",
       CASE WHEN e.extversion <> a.default_version THEN 'UPDATE AVAILABLE' ELSE 'current' END AS \"Status\"
FROM pg_extension e
JOIN pg_available_extensions a ON a.name = e.extname
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY (e.extversion <> a.default_version) DESC, e.extname;
"

STALE_EXTS=$(q "
SELECT e.extname FROM pg_extension e
JOIN pg_available_extensions a ON a.name = e.extname
WHERE e.extversion <> a.default_version;
")
if [ -n "$STALE_EXTS" ]; then
    warn "Extensions with newer versions available (typical leftover after package/pg_upgrade):"
    for ext in $STALE_EXTS; do
        echo "    ALTER EXTENSION $ext UPDATE;"
        remed "Update extension: ALTER EXTENSION $ext UPDATE;  -- run in EVERY database that has it (check with: \\c <db> then \\dx)"
    done
    info "Note: this audit only sees database '$PG_DBNAME'. Loop over all DBs: psql -At -c 'SELECT datname FROM pg_database WHERE datallowconn;'"
else
    ok "All installed extensions in '$PG_DBNAME' are at their default (latest packaged) version."
fi
hr

# ============================================================================
# 5. SHARED_PRELOAD_LIBRARIES CONSISTENCY
# ============================================================================
echo
echo "${C_BOLD}5. shared_preload_libraries Consistency${C_RST}"
hr

SPL=$(q "SHOW shared_preload_libraries;")
echo "shared_preload_libraries = '${SPL}'"

if [ -n "$SPL" ]; then
    IFS=',' read -r -a LIBS <<< "$SPL"
    for lib in "${LIBS[@]}"; do
        lib=$(echo "$lib" | tr -d ' "')
        [ -z "$lib" ] && continue
        # Libraries that back an extension should usually have it created
        HAS_EXT=$(q "SELECT count(*) FROM pg_extension WHERE extname = '$lib';")
        AVAIL=$(q "SELECT count(*) FROM pg_available_extensions WHERE name = '$lib';")
        if [ "$AVAIL" = "1" ] && [ "$HAS_EXT" = "0" ]; then
            warn "Library '$lib' is preloaded (consuming resources at startup) but extension is NOT created in '$PG_DBNAME'."
            remed "Either create it: CREATE EXTENSION $lib; or remove from shared_preload_libraries (restart required) if truly unused."
        elif [ "$HAS_EXT" = "1" ]; then
            ok "Preloaded library '$lib' has its extension installed."
        else
            info "Preloaded library '$lib' has no matching extension entry (may be a pure hook library like auto_explain — that is normal)."
        fi
    done
else
    info "No libraries preloaded. If tasks need pg_stat_statements, remember it requires preload + restart."
fi

# Extensions whose library is missing on disk (broken after major upgrade)
MISSING_CTL=$(q "
SELECT extname FROM pg_extension e
WHERE NOT EXISTS (SELECT 1 FROM pg_available_extensions a WHERE a.name = e.extname);
")
if [ -n "$MISSING_CTL" ]; then
    crit "Extensions installed in catalog but MISSING from disk (control file gone — broken after upgrade/package removal): $MISSING_CTL"
    for ext in $MISSING_CTL; do
        remed "Reinstall OS package providing '$ext' for the CURRENT server major version (apt/dnf search $ext), or if abandoned: DROP EXTENSION $ext CASCADE; (CASCADE drops dependent objects — inventory first!)"
    done
else
    ok "All catalog extensions have their control files present on disk."
fi
hr

# ============================================================================
# 6. SUMMARY & VERDICT
# ============================================================================
echo
echo "${C_BOLD}6. SSL & Extension Audit Summary${C_RST}"
hr
if [ ${#ISSUES[@]} -eq 0 ]; then
    echo "${C_GRN}No SSL/TLS or extension anomalies flagged.${C_RST}"
else
    printf "%sFLAGGED ISSUES (%d):%s\n" "$C_RED" "${#ISSUES[@]}" "$C_RST"
    i=1
    for issue in "${ISSUES[@]}"; do
        printf "  %2d. %s\n" "$i" "$issue"
        i=$((i+1))
    done
fi
if [ ${#REMEDS[@]} -gt 0 ]; then
    printf "\n%sRECOMMENDATIONS & REMEDIATION COMMANDS:%s\n" "$C_YEL" "$C_RST"
    for r in "${REMEDS[@]}"; do
        printf "  - %s\n" "$r"
    done
fi
hr
echo
