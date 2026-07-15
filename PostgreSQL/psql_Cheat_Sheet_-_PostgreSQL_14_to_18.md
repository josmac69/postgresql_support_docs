# psql Cheat Sheet — PostgreSQL 14 to 18

A desk reference for the `psql` command-line client covering PostgreSQL 14, 15, 16, 17, and 18. Commands are organized two ways: by database object and by workflow. Version annotations indicate when a feature was introduced or changed, based on the official PostgreSQL release notes and documentation.

> This document is formatted as Markdown and can be saved directly as a `.md` file (for example, `psql-cheatsheet-pg14-18.md`).

## Version-Compatibility Legend

Notation: "14" means present in PostgreSQL 14 and later; "16+" means introduced in 16; "≤13" means it predates the range covered here and is present throughout 14–18.

| Feature / meta-command | Introduced | Notes |
|---|---|---|
| `\dX` (list extended statistics) | 14 | New in 14 |
| `\df`/`\do` accept argument types | 14 | Reduces overloaded-name clutter |
| Access-method column in `\di+`/`\dm+`/`\dt+` | 14 | |
| `\dt`/`\di` show TOAST tables/indexes | 14 | |
| `\e`/`\ef`/`\ev` discard on editor exit without save | 14 | Behavior change |
| `\dconfig` (show server config parameters) | 15 | New in 15 |
| `\getenv` (read env var into psql variable) | 15 | New in 15 |
| `\dl+` / `\lo_list+` (large-object privileges) | 15 | |
| `PSQL_WATCH_PAGER` pager for `\watch` | 15 | Unix only |
| `SHOW_ALL_RESULTS` variable | 15 | Default on; all results of multi-statement strings shown |
| `\bind` (extended query protocol / parameters) | 16 | New in 16 |
| `\drg` (role membership detail) | 16 | "Member of" removed from `\du`/`\dg` |
| `\dpS` / `\zS` (system objects in privilege lists) | 16 | |
| `\df+` shows internal name, not source | 16 | Use `\sf` for bodies |
| `\pset xheader_width` | 16 | Expanded-header width control |
| `SHELL_ERROR` / `SHELL_EXIT_CODE` variables | 16 | |
| `\watch` execution-count limit | 16 | |
| `\d+` marks FOREIGN partitions | 16 | |
| `\watch min_rows` parameter | 17 | Stop after minimum rows |
| Cancel connection attempts with Ctrl-C | 17 | |
| `FETCH_COUNT` honored for non-SELECT queries | 17 | |
| `\dp` shows `(none)` for empty privileges | 17 | Backslash commands honor `\pset null` |
| `\parse`, `\bind_named`, `\close_prepared` | 18 | Named prepared statements |
| Pipeline commands (`\startpipeline` etc.) | 18 | See pipeline section |
| `\conninfo` tabular, expanded output | 18 | Overhauled |
| `x` suffix forces expanded mode on list commands | 18 | e.g. `\dtx`, `\dfx` |
| `SERVICE` variable and `%s` prompt escape | 18 | |
| `%P` prompt escape + pipeline state variables | 18 | |
| Leakproof indicator in `\df+`/`\do+`/`\dAo+`/`\dC+` | 18 | |
| `\dx` shows default extension version | 18 | |
| `WATCH_INTERVAL` variable (configurable default) | 18 | |
| `\dP+` shows access method for partitioned relations | 18 | |
| `\restrict` / `\unrestrict` | 18.0; backported to 17.6/16.10/15.14/14.19/13.22 | Security (CVE-2025-8714), released 2025-08-14 |

---

## Part 1 — Commands Grouped by Database Object

Most list commands accept an optional pattern (a regex-like name filter), a `+` modifier for additional detail (sizes, descriptions, definitions), and an `S` modifier to include system objects. From PostgreSQL 18, an `x` suffix forces expanded output on list commands (for example `\dtx`).

### Tables, Indexes, Views, Materialized Views, Sequences

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dt [pattern]` | List tables | `+`, `S`; shows access method in `\dt+` (14+); shows TOAST tables (14+) | ≤13 |
| `\di [pattern]` | List indexes | `+`, `S`; access method column (14+) | ≤13 |
| `\dv [pattern]` | List views | `+`, `S` | ≤13 |
| `\dm [pattern]` | List materialized views | `+`, `S`; access method column (14+) | ≤13 |
| `\ds [pattern]` | List sequences | `+`, `S` | ≤13 |
| `\dE [pattern]` | List foreign tables | `+`, `S` | ≤13 |
| `\d [pattern]` | Describe a relation (columns, indexes, constraints, triggers); with no pattern, lists tables/views/sequences | `+` adds storage, stats target, description; `\d+` marks FOREIGN partitions (16+) | ≤13 |
| `\dP [pattern]` | List partitioned tables and indexes | `+`; access method for partitioned relations in `\dP+` (18+) | 12 |

### Schemas, Databases, Tablespaces

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dn [pattern]` | List schemas | `+`, `S` (system schemas) | ≤13 |
| `\l` / `\list` | List databases | `+` adds size, tablespace, description | ≤13 |
| `\db [pattern]` | List tablespaces | `+` adds options, size, permissions | ≤13 |

### Roles / Users and Role Grants

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\du [pattern]` | List roles | `+`; "Member of" column removed in 16 (moved to `\drg`) | ≤13 |
| `\dg [pattern]` | List roles (alias of `\du`) | Same as `\du`; "Member of" removed in 16 | ≤13 |
| `\drg [pattern]` | Show role membership details | New in 16 | 16 |

### Functions, Procedures, Aggregates, Operators

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\df [pattern]` | List functions/procedures | Accepts argument types (14+), e.g. `\df foo(int, text)`; `\df+` shows internal name not source (16+); leakproof indicator in `\df+` (18+) | ≤13 |
| `\dfn` / `\dfa` / `\dft` / `\dfw` | List normal/aggregate/trigger/window functions | Filter by function kind | ≤13 |
| `\da [pattern]` | List aggregate functions | `+`, `S` | ≤13 |
| `\do [pattern]` | List operators | Accepts argument types (14+); leakproof indicator in `\do+` (18+) | ≤13 |
| `\sf funcname` | Show function/procedure definition | `\sf+` adds line numbers; preferred for viewing bodies (16+) | ≤13 |
| `\ef [funcname [line]]` | Edit function definition in editor | Discards edits if editor exits without saving (14+) | ≤13 |

### Types, Domains, Collations, Text Search

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dT [pattern]` | List data types | `+`, `S`; understands array syntax and grammar aliases like `int` for `integer` (14+) | ≤13 |
| `\dD [pattern]` | List domains | `+`, `S` | ≤13 |
| `\dO [pattern]` | List collations | `+`, `S` | ≤13 |
| `\dF [pattern]` | List text-search configurations | `+` | ≤13 |
| `\dFd` / `\dFp` / `\dFt` | List TS dictionaries / parsers / templates | `+` | ≤13 |

### Access Methods and Operator Families/Classes

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dA [pattern]` | List access methods | `+` | ≤13 |
| `\dAc` | List operator classes | | 13 |
| `\dAf` | List operator families | | 13 |
| `\dAo` | List operators of operator families | Leakproof indicator in `\dAo+` (18+) | 13 |
| `\dAp` | List support functions of operator families | | 13 |
| `\dC [pattern]` | List casts | Leakproof indicator in `\dC+` (18+) | ≤13 |

### Extensions and Extended Statistics

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dx [pattern]` | List installed extensions | `\dx+` lists member objects; shows default version (18+) | ≤13 |
| `\dX [pattern]` | List extended statistics objects | New in 14; columns per statistic kind (Ndistinct, Dependencies, Mcv) | 14 |

### Triggers, Event Triggers, Rules

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dy [pattern]` | List event triggers | `+` | ≤13 |
| Table triggers/rules | Shown in the `\d`/`\d+` output for a table | | ≤13 |

### Publications / Subscriptions (Logical Replication)

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dRp [pattern]` | List replication publications | `+` shows tables/schemas; `x` for expanded | 10 |
| `\dRs [pattern]` | List replication subscriptions | `+` shows extra properties | 10 |

### Foreign Data Wrappers / Servers / User Mappings

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dew [pattern]` | List foreign-data wrappers | `+` | ≤13 |
| `\des [pattern]` | List foreign servers | `+` | ≤13 |
| `\deu [pattern]` | List user mappings | `+` | ≤13 |
| `\det [pattern]` | List foreign tables | `+` | ≤13 |

### Large Objects

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dl` / `\lo_list` | List large objects | `+` shows privileges (15+) | ≤13 |
| `\lo_import file [comment]` | Import a file as a large object | Client-side | ≤13 |
| `\lo_export loid file` | Export a large object to a file | Client-side | ≤13 |
| `\lo_unlink loid` | Delete a large object | | ≤13 |

### Access Privileges

| Command | Description | Modifiers / Notes | Version |
|---|---|---|---|
| `\dp [pattern]` | List table/view/sequence access privileges | `\dpS` includes system objects (16+); shows `(none)` for empty privileges (17+) | ≤13 |
| `\z [pattern]` | Alias of `\dp` | `\zS` includes system objects (16+) | ≤13 |

---

## Part 2 — Commands Grouped by Workflow

### Connecting and Switching Connections

| Command | Description | Version |
|---|---|---|
| `\c [dbname [user [host [port]]]]` / `\connect` | Connect to another database/host/role, reusing unspecified parameters | ≤13 |
| `\conninfo` | Show current connection details; tabular, expanded output including SSL info (18+) | ≤13 (overhauled 18) |
| `\password [user]` | Change a role's password; encrypts client-side so plaintext never reaches history or server log | ≤13 |
| `\encoding [name]` | Show or set client character-set encoding | ≤13 |

Connection service files (`~/.pg_service.conf`, referenced via `PGSERVICE` / the `service=` keyword) let you name and reuse connection parameter sets. PostgreSQL 18 adds the `SERVICE` psql variable and the `%s` prompt escape to surface the active service name.

### Query Buffer: Editing and Execution

| Command | Description | Version |
|---|---|---|
| `\g [file]` / `\g [(options)]` | Execute the query buffer; optionally send output to a file or pipe. `\g` with no argument equals a semicolon. Accepts formatting options like `\g (format=csv)` (13+); accepts an argument target (13+) | ≤13 |
| `\gx [file]` | As `\g`, but forces expanded output | 10 |
| `\gexec` | Execute the buffer, then run each returned value as a new SQL command | 9.6 |
| `\gset [prefix]` | Execute the buffer and store the single result row's columns into psql variables | 9.6 |
| `\gdesc` | Describe the result column types of the buffer without executing it | 11 |
| `\p` | Print the current query buffer | ≤13 |
| `\r` / `\reset` | Reset (clear) the query buffer | ≤13 |
| `\w file` | Write the query buffer to a file | ≤13 |
| `\e [file] [line]` | Edit the buffer or a file in an external editor; edits discarded if editor exits without saving (14+); loads unterminated query for review (13+) | ≤13 |
| `\ef` / `\ev` | Edit a function or view definition | ≤13 |
| `\bind [param ...]` | Set parameters and run the next query via the extended query protocol, e.g. `SELECT $1::int + $2::int \bind 1 2 \g` | 16 |
| `\bind_named stmt [param ...]` | Bind parameters to a named prepared statement | 18 |
| `\parse stmt` | Create a named (or unnamed) prepared statement from the buffer via a Parse message | 18 |
| `\close_prepared stmt` | Close/deallocate a prepared statement (named `\close` internally before rename) | 18 |

### Output Formatting

| Command | Description | Version |
|---|---|---|
| `\x [on\|off\|auto]` | Toggle expanded (vertical) display; `auto` chooses based on width | ≤13 |
| `\a` | Toggle aligned/unaligned output | ≤13 |
| `\t [on\|off]` | Toggle tuples-only (suppress headers/footers) | ≤13 |
| `\H` | Toggle HTML output | ≤13 |
| `\f [char]` | Set field separator for unaligned output | ≤13 |
| `\pset option [value]` | Set a printing option (see format list below) | ≤13 |
| `\C [title]` | Set/clear the table title | ≤13 |

`\pset format` accepts: `aligned` (default, human-readable), `unaligned` (columns separated by the active field separator), `wrapped` (aligned but wraps wide values to the target width), `csv` (RFC 4180 quoting, compatible with server COPY CSV), `html`, `latex`, `latex-longtable`, `asciidoc`, and `troff-ms`. The `csv` field separator is set with `\pset csv_fieldsep`. PostgreSQL 16 added `\pset xheader_width` to bound the width of expanded-mode header lines.

### Scripting and Automation

| Command | Description | Version |
|---|---|---|
| `\i file` | Execute commands from a file | ≤13 |
| `\ir file` | Include a file relative to the location of the current script | 9.2 |
| `\o [file]` / `\out` | Redirect query output to a file or pipe | ≤13 |
| `\set [name [value]]` | Set (or list) a psql variable | ≤13 |
| `\unset name` | Unset a psql variable | ≤13 |
| `\getenv var envvar` | Read an environment variable into a psql variable | 15 |
| `\setenv name [value]` | Set/unset an environment variable | 9.2 |
| `\echo [text]` | Write text to standard output | ≤13 |
| `\qecho [text]` | Write text to the query output stream | ≤13 |
| `\warn [text]` | Write text to standard error | 13 |
| `\if` / `\elif` / `\else` / `\endif` | Conditional execution blocks | 10 |

Variables can be interpolated into SQL with `:name`, quoted as a literal with `:'name'`, or quoted as an identifier with `:"name"`. The `:{?name}` form tests whether a variable is defined. The `\gset` and `\gexec` commands make results feed back into subsequent statements, which is central to metaprogramming SQL from within psql.

### Performance and Monitoring

| Command | Description | Version |
|---|---|---|
| `\timing [on\|off]` | Toggle display of query execution time | ≤13 |
| `\watch [[i=]sec] [c=N] [m=min_rows]` | Re-run the buffer periodically; `c=N` limits execution count (16+); `m=min_rows` stops when fewer than that many rows return (17+); default interval configurable via `WATCH_INTERVAL` (18+) | ≤13 |
| `\gdesc` | Inspect result types without running the query | 11 |

On Unix, the `PSQL_WATCH_PAGER` environment variable (15+) sets a pager for `\watch` output.

### Import / Export of Data

| Command | Description | Version |
|---|---|---|
| `\copy table TO 'file' [options]` | Client-side export; the file path is resolved on the client, requires no superuser rights, and streams over the existing connection | ≤13 |
| `\copy table FROM 'file' [options]` | Client-side import | ≤13 |
| `\copy (query) TO 'file' CSV HEADER` | Export a query result | ≤13 |
| `\g file` | Alternative export by sending query output to a file | ≤13 |

The server-side SQL `COPY` command reads/writes files on the database host and requires appropriate privileges; the psql `\copy` meta-command is the client-side equivalent and is preferred when the file is on your workstation. Note the PostgreSQL 18 change: `COPY FROM` no longer treats `\.` as an end-of-file marker when reading CSV files (psql still treats `\.` as EOF for in-line CSV from STDIN), and `\.` must appear alone on a line. Older psql clients connecting to an 18 server (which was released September 25, 2025) may see `\copy` problems.

### Pipeline Mode (PostgreSQL 18)

PostgreSQL 18 added psql support for libpq pipeline mode, letting multiple queries be queued without waiting for each result, which reduces round trips over high-latency links.

| Command | Description |
|---|---|
| `\startpipeline` | Begin pipeline mode |
| `\sendpipeline` | Queue the current buffer into the pipeline |
| `\syncpipeline` | Send a synchronization point without flushing |
| `\flushrequest` | Request the server to flush its output buffer |
| `\flush` | Flush pending data to the server |
| `\getresults` | Retrieve available results |
| `\endpipeline` | Exit pipeline mode |

Related additions: the `%P` prompt escape shows pipeline status (`on`/`off`/`abort`), and the variables `PIPELINE_SYNC_COUNT`, `PIPELINE_COMMAND_COUNT`, and `PIPELINE_RESULT_COUNT` track pipeline state.

### Transactions and Error Handling

- `AUTOCOMMIT` (default `on`): when off, psql issues an implicit `BEGIN` before commands not already in a transaction.
- `ON_ERROR_STOP`: when on, a script aborts on the first error. In `--single-transaction` mode from PostgreSQL 15, the final command becomes `ROLLBACK` instead of `COMMIT` on error only when `ON_ERROR_STOP` is set.
- `ON_ERROR_ROLLBACK` (`on`/`off`/`interactive`): with `interactive`, psql wraps each interactive statement in an implicit savepoint so a single failure does not abort the whole transaction.
- `\errverbose`: reprint the most recent server error at maximum verbosity.

### Working With Query Results

| Command | Description | Version |
|---|---|---|
| `\crosstabview [colV [colH [colD [sortcolH]]]]` | Execute the buffer and render results as a cross-tab grid; the query must return at least three columns | 9.6 |
| `\gset` | Capture a one-row result into variables | 9.6 |
| `\gexec` | Turn result values into executable SQL | 9.6 |

### Help and History

| Command | Description | Version |
|---|---|---|
| `\?` | Help on backslash commands | ≤13 |
| `\? options` | Help on command-line options | ≤13 |
| `\? variables` | Help on special variables | ≤13 |
| `\h [name]` | Help on SQL command syntax (`\h *` for all) | ≤13 |
| `\s [file]` | Show or save command-line history | ≤13 |
| `\! [command]` | Run a shell command | ≤13 |
| `\copyright` | Show distribution terms | ≤13 |
| `\q` | Quit | ≤13 |

### Restricted Mode (Security)

| Command | Description | Version |
|---|---|---|
| `\restrict RESTRICT_KEY` | Enter "restricted" mode with the provided key; in this mode the only allowed meta-command is `\unrestrict` | 18.0; backported to 17.6, 16.10, 15.14, 14.19, 13.22 |
| `\unrestrict RESTRICT_KEY` | Exit restricted mode if the key matches | Same |

These commands were added as the fix for CVE-2025-8714, which carries a CVSS v3.1 Base Score of 8.8 (vector `AV:N/AC:L/PR:N/UI:R/S:U/C:H/I:H/A:H`) and affected supported vulnerable versions 13 through 17. The fix shipped in the release of "PostgreSQL 17.6, 16.10, 15.14, 14.19, 13.22, and 18 Beta 3" on 2025-08-14, which "fixes 3 security vulnerabilities and over 55 bugs." Per the PostgreSQL 15.14 release notes, the change was to "extend psql with a `\restrict` command that prevents execution of further meta-commands, and teach pg_dump to issue that before any data coming from the source server." `pg_dump`, `pg_dumpall`, and `pg_restore` now wrap plain-text dumps in `\restrict`/`\unrestrict` with a random per-run key, preventing a malicious source server from injecting psql meta-commands into a dump that is later restored. (A companion flaw fixed in the same release, CVE-2025-8715, converts newlines to spaces in names included in pg_dump comments.)

---

## Part 3 — Command-Line Invocation Flags

| Flag | Long form | Meaning |
|---|---|---|
| `-c cmd` | `--command` | Run a single command string (or one backslash command), then exit |
| `-f file` | `--file` | Read commands from a file; may be repeated and mixed with `-c` |
| `-d name` | `--dbname` | Database to connect to (may be a connection string) |
| `-h host` | `--host` | Server host or socket directory |
| `-p port` | `--port` | Server port |
| `-U user` | `--username` | Connect as this role |
| `-w` | `--no-password` | Never prompt for a password |
| `-W` | `--password` | Force a password prompt |
| `-l` | `--list` | List databases and exit |
| `-A` | `--no-align` | Unaligned output |
| `-t` | `--tuples-only` | Suppress headers and footers |
| `-F sep` | `--field-separator` | Field separator for unaligned output |
| `-P opt=val` | `--pset` | Set a printing option (name and value joined by `=`) |
| `-H` | `--html` | HTML output |
| `--csv` | | CSV output (added in PostgreSQL 12) |
| `-x` | `--expanded` | Expanded output |
| `-X` | `--no-psqlrc` | Do not read startup files |
| `-1` | `--single-transaction` | Wrap a `-f`/`-c` run in a single transaction |
| `-v name=val` | `--set` / `--variable` | Assign a psql variable |
| `-o file` | `--output` | Write all query output to a file |
| `-L file` | `--log-file` | Additionally log session output to a file |
| `-q` | `--quiet` | Quiet mode |
| `-a` | `--echo-all` | Echo all input lines (sets `ECHO=all`) |
| `-b` | `--echo-errors` | Echo failed SQL to stderr (sets `ECHO=errors`) |
| `-e` | `--echo-queries` | Echo queries sent to the server (sets `ECHO=queries`) |
| `-E` | `--echo-hidden` | Echo the queries generated by backslash commands |
| `-n` | `--no-readline` | Disable readline editing/history |
| `-s` | `--single-step` | Prompt before each command |
| `--help=variables` | | Show help on special variables |

Exit codes: 0 normal, 1 fatal psql error, 2 bad connection in a non-interactive session, 3 script error with `ON_ERROR_STOP` set.

---

## Part 4 — Special Variables

| Variable | Purpose |
|---|---|
| `AUTOCOMMIT` | Auto-commit each statement (default on) |
| `ON_ERROR_STOP` | Abort scripts on error |
| `ON_ERROR_ROLLBACK` | `on`/`off`/`interactive` savepoint behavior on error |
| `VERBOSITY` | `default`/`verbose`/`terse` (also `sqlstate`) error verbosity |
| `SHOW_CONTEXT` | `never`/`errors`/`always` — display of message CONTEXT |
| `ECHO` | `all`/`queries`/`errors`/`none` |
| `ECHO_HIDDEN` | Echo internal queries of backslash commands (`on`/`noexec`) |
| `HISTCONTROL` | `ignorespace`/`ignoredups`/`ignoreboth` |
| `HISTSIZE` | Number of history entries retained |
| `HISTFILE` | History file path (often set per-database) |
| `PROMPT1` / `PROMPT2` / `PROMPT3` | Main / continuation / COPY prompts |
| `FETCH_COUNT` | Fetch/display rows in batches of N; from 17 honored for non-SELECT queries too |
| `COMP_KEYWORD_CASE` | Keyword case for tab completion |
| `SHOW_ALL_RESULTS` | Show results of every statement in a multi-statement string (added 15, default on) |
| `SHELL_ERROR` / `SHELL_EXIT_CODE` | Status of the last shell command or backquote (added 16) |
| `SERVICE` / `SERVICEFILE` | Active connection service name / service file |
| `WATCH_INTERVAL` | Default `\watch` interval (added 18) |
| `PIPELINE_SYNC_COUNT` / `PIPELINE_COMMAND_COUNT` / `PIPELINE_RESULT_COUNT` | Pipeline state (added 18) |
| `VERSION` / `VERSION_NAME` / `VERSION_NUM` | Client version info |
| `SERVER_VERSION_NAME` / `SERVER_VERSION_NUM` | Server version info |
| `ERROR` / `SQLSTATE` / `ROW_COUNT` / `LAST_ERROR_MESSAGE` / `LAST_ERROR_SQLSTATE` | Last-query status variables |

---

## Part 5 — Environment Variables

| Variable | Purpose |
|---|---|
| `PGHOST` / `PGHOSTADDR` | Default host / host address |
| `PGPORT` | Default port |
| `PGUSER` | Default role |
| `PGDATABASE` | Default database |
| `PGPASSWORD` | Password (discouraged; visible via `ps`) |
| `PGPASSFILE` | Password file location (default `~/.pgpass`) |
| `PGSERVICE` / `PGSERVICEFILE` | Service name / service file |
| `PGOPTIONS` | Extra server command-line options |
| `PSQL_HISTORY` | History file location |
| `PSQL_PAGER` / `PAGER` | Pager program |
| `PSQL_WATCH_PAGER` | Pager for `\watch` (Unix; added 15) |
| `PSQL_EDITOR` / `EDITOR` / `VISUAL` | Editor for `\e`, `\ef`, `\ev` |
| `PSQLRC` | Location of the user startup file |
| `COLUMNS` | Target width for wrapped format / expanded auto |

---

## Part 6 — The .psqlrc File and Customization

`psql` reads a system-wide `psqlrc` then the user's `~/.psqlrc` at startup unless `-X` is given. Version-specific files (for example `~/.psqlrc-18` or `~/.psqlrc-18.1`) are read if the version matches, which is useful when multiple installations coexist. A representative configuration:

```
\set QUIET 1
\pset null '¤'
\set PROMPT1 '%n@%m %~%R%#%x '
\set PROMPT2 '... > '
\timing
\x auto
\set VERBOSITY verbose
\set HISTFILE ~/.psql_history- :DBNAME
\set HISTCONTROL ignoredups
\set COMP_KEYWORD_CASE upper
\set ON_ERROR_ROLLBACK interactive
\unset QUIET
```

Wrapping the file in `\set QUIET 1` … `\unset QUIET` suppresses feedback noise during startup.

### Prompt Substitutions

| Escape | Meaning |
|---|---|
| `%M` | Server host (full), `[local]` for a Unix socket |
| `%m` | Server host (short) |
| `%>` | Server port |
| `%n` | Session user name |
| `%/` | Current database |
| `%~` | Like `%/` but `~` when the database equals the user name |
| `%#` | `#` for superuser, `>` otherwise |
| `%R` | In PROMPT1: `=` normally, `^` single-line, `!` if disconnected; in PROMPT2: `-`, `*`, `'`, `"`, or `$` by pending state |
| `%x` | Transaction status (included by default in PROMPT1/PROMPT2 since 13) |
| `%p` | Backend PID |
| `%w` | Whitespace matching the width of the last PROMPT1 (invisible PROMPT2, added 13) |
| `%l` | Statement line number |
| `%S` | Current `search_path` (added 18) |
| `%s` | Service name (added 18) |
| `%P` | Pipeline status: `on`/`off`/`abort` (added 18) |
| `%[ ... %]` | Delimit non-printing (terminal control/color) sequences |

---

## Recommendations

1. **Standardize scripts on defensive settings.** For any non-interactive run, invoke `psql -X -v ON_ERROR_STOP=1 --single-transaction` so a failure aborts cleanly and does not leave partial changes. Add `-q` and `--csv` (or `-A -t -F','`) when producing machine-readable output.
2. **Use `\copy`, not `COPY`, for client-side files.** It needs only ordinary table privileges and resolves paths on your workstation. Reserve server-side `COPY` for files staged on the database host. On PostgreSQL 18, review any scripts that relied on `\.` as a CSV end-of-data marker in files.
3. **Adopt the newer inspection commands where the server supports them.** From 16, use `\drg` for role memberships (the "Member of" column is gone from `\du`/`\dg`) and `\sf` to read function bodies (`\df+` no longer prints source). From 14, use `\dX` for extended statistics.
4. **Exploit `\gexec` and `\gset` for repetitive DDL/DML.** Generating `VACUUM`/`REINDEX`/`GRANT` statements from a catalog query and piping them through `\gexec` is more reliable than hand-editing.
5. **Pin behavior per version with `.psqlrc-<major>` files** when you operate a mixed fleet (14 through 18), since several defaults and available commands differ across the range.
6. **Do not hand-edit the `\restrict`/`\unrestrict` lines** that `pg_dump` now emits; they are a security control keyed per run. If they cause noise in version-controlled dumps, that is expected behavior for clients patched on or after 2025-08-14.
7. **Benchmark thresholds that would change the above:** if a client-side `\copy` of a large dataset is I/O- or network-bound, switch to server-side `COPY` with the file staged on the host; if interactive result sets exceed available memory, set `FETCH_COUNT` to 100–1000 and prefer a non-aligned format to avoid per-batch column-width churn.

## Caveats

- **Version applies to the psql client, not the server.** Meta-commands are executed client-side, so a newer psql can offer commands that produce errors or degraded output against an older server; the project supports connecting back to servers as old as 9.2 for backslash commands. Prefer matching client and server major versions.
- **Introduction versions here reflect the meta-command's availability in the psql binary of that release.** Some catalog-dependent output additionally requires a server new enough to expose the underlying data.
- **The `\restrict`/`\unrestrict` backport is unusual.** These commands shipped simultaneously in 18.0 (which was in Beta 3 at the time) and in the 13.22/14.19/15.14/16.10/17.6 minor releases on 2025-08-14, rather than only in a single feature release. Exact availability therefore depends on your minor version, not just the major.
- **`x`-suffix expanded mode on list commands is a PostgreSQL 18 addition** and is not available on earlier clients; the `x` cannot immediately follow `\d` (because `\dx` is a distinct command) and may only appear after an `S` or `+` modifier.
- Where a feature's exact minor-version origin could not be pinned to primary documentation, the major version shown is the conservative (earliest confirmed) attribution from the official release notes.