# The tools

## pgBackRest
**pgBackRest** (C, MIT-ish license). The de facto standard for serious self-managed deployments. Architecturally its differentiators are:

- **True block-level incremental backups** driven by a manifest — it tracks changed blocks within files, not just changed files. On multi-TB clusters with localized write patterns this is the difference between a feasible and infeasible backup window.
- **Delta restore** — restores only the blocks that differ from what's already on disk, which makes rebuilding a failed replica or doing PITR on a mostly-intact data directory dramatically faster.
- **Parallel everything** — backup, restore, compression, and archive-push/get with async queuing (spool directory) so `archive_command` latency doesn't throttle the primary.
- **Multi-repository support** — you can push to a local repo host *and* S3 *and* Azure simultaneously with independent retention, which is how people implement 3-2-1 natively.
- **Stanza model** — a stanza binds a cluster to one or more repositories, letting a single installation manage multiple clusters against multiple backends with independent retention.
- Full/differential/incremental hierarchy, zstd/lz4/gzip/bzip2, AES-256-CBC encryption, backup verification (`verify` command), page checksum validation during backup.

Cons: configuration surface is large; the repo-host topology adds infrastructure; encryption is opt-in; and the sustainability wobble is now part of its risk profile even if resolved. Requires SSH or TLS connectivity between repo host and DB hosts (or runs locally pushing to object storage).

## Barman
**Barman** (Python, GPL, EDB-backed — v3.18.0 shipped March 2026, actively maintained with corporate backing). The philosophically different one:

- **Centralized fleet management** — one Barman server managing many PostgreSQL servers is the core design, with a catalog you can reason about, `barman check` health verification across the fleet, and unified retention policy.
- **RPO=0 capability** — Barman is unique in supporting **synchronous WAL streaming** to the backup server via `pg_receivewal` with a synchronous standby-style guarantee. If your compliance requirement is literally zero data loss on the backup path, Barman is the only one of these that delivers it.
- Two backup transports: `pg_basebackup`-based (streaming, works remotely without SSH) and rsync/SSH-based, which gives file-level incremental and deduplication via hard links.
- `barman-cloud-*` utilities let you skip the dedicated Barman server entirely and push directly to S3/Azure/GCS — this is what CloudNativePG builds on.

Cons: parallel restore is implemented but historically less performant than pgBackRest's; incremental via rsync mode is functional but not in the same league as pgBackRest's manifest-driven block-level incremental, and delta restore is similarly less aggressive. Python runtime, and the central Barman server is itself a SPOF to design around. On a 40 TB cluster where nightly block-level incrementals were the only way the math worked, Barman is a downgrade you should benchmark first.

## WAL-G
**WAL-G** (Go, successor to WAL-E from Citus — v3.0.8 as of January 2026, actively maintained). The cloud-native one:

- **Object-storage-first design** — no repo host, no daemon, just a static binary invoked from `archive_command`/cron pushing to S3/GCS/Azure/Swift/local FS. Closest to a "serverless" backup model; ideal where your DB hosts can't SSH to each other.
- **Delta backups at the page level** — it reads changed pages (using LSN comparison, optionally accelerated by the ptrack extension), which sits between file-level and pgBackRest's manifest approach. The architectural gap versus pgBackRest is that its delta model operates at the file level, not block level within files — practically, its deltas are well-tuned for medium databases but less surgical.
- Genuinely fast parallel backup **and** parallel restore; broad compression support (lz4, zstd, brotli); catchup-fetch for replica reinitialization.
- **Multi-engine**: also backs up MySQL/MariaDB, MongoDB, Redis, FoundationDB — attractive if you run a heterogeneous estate with one tool.
- Interesting migration path: WAL-G has a beta pgBackRest compatibility layer that can read existing pgBackRest repositories via wal-fetch and backup-fetch, allowing parallel operation during a transition.

Cons: documentation is famously thin — plan for half a week of reading source code and writing wrapper scripts; the end state is solid. No backup catalog/control plane, no fleet view, weaker built-in verification story, and its UX is aimed at automation, not interactive 3 AM use. No native retention daemon — you script `delete` invocations yourself.

## pg_probackup
**pg_probackup** (Postgres Pro, C). Technically interesting but geopolitically/organizationally complicated:

- Its standout feature is **merge/synthetic full backups** — instead of running a full backup every Sunday that hammers your replica for hours, it can synthesize a full from incrementals, which materially reduces I/O pressure in tight windows.
- Three incremental modes (PAGE via WAL scan, DELTA via page reads, PTRACK via extension), built-in validation and corruption detection, remote mode over SSH.
- Cons: development is driven by Postgres Pro and the community edition's cadence and openness have been inconsistent; object storage support lags (historically S3 only in the enterprise edition); smaller Western community. For an EU consultancy context I'd treat it as evaluate-with-caution.

**pg_basebackup + archive_command** (in-core). Don't dismiss it: for a single small cluster with a competent operator, pg_basebackup plus archive_command plus a tested restore procedure is fine. And PG17's native **incremental backup** (`pg_basebackup --incremental` + WAL summarizer + `pg_combinebackup`) is slowly eroding the third-party tools' core differentiator, though as of PG17/18 it's still early-stage: no retention management, no encryption, no catalog, no cloud storage, no parallelism.

**Newer/niche entrants**: pgmoneta — a lightweight C daemon with full and incremental backups (PG14+), multiple compression options, AES encryption, WAL shipping, and Prometheus integration out of the box; and Cybertec's **pg_hardstorage** (Go, Apache 2.0, PG15–18), which is positioning itself around continuous WAL streaming via replication protocol, content-addressed storage, encryption-on-by-default, and notably TDE awareness — it handles the archive_command segment-header-read failure mode against encrypted WAL from PGEE/pg_tde/EDB TDE, which pgBackRest, WAL-G, and Barman have no equivalent for. Given your Patroni article work, its claimed handling of failover slot gaps might be worth a look, though it's v1.0-era software without the decade of production hardening.

## How to frame the decision

The dimensions that actually discriminate:

| Dimension | pgBackRest | Barman | WAL-G |
|---|---|---|---|
| Incremental granularity | Block-level (manifest) | File-level (rsync hardlinks) | Page-delta (LSN/ptrack) |
| Delta restore | Yes, aggressive | Limited (rsync mode) | Partial (catchup) |
| RPO=0 option | No (async archiving) | Yes (sync WAL streaming) | No |
| Topology | Repo host or local→cloud | Central backup server | Agentless, object storage |
| Fleet management/catalog | Per-stanza, decentralized | Strongest | None |
| Multi-repo (3-2-1 native) | Yes | No (script it) | No |
| Ops complexity | High | Medium | Low infra, high scripting |
| Governance risk (2026) | Coalition-funded post-crisis | EDB, steady | Community, active |

Rules of thumb that match my read of the field: pgBackRest excels at block-level incremental backup and delta recovery for large OLTP workloads above ~500 GB; Barman shines with centralized management of multiple instances for DBA teams; WAL-G offers the simplest path to object storage for Kubernetes and cloud-native environments. And the operator caveat: on Kubernetes with a Postgres operator, use what your operator uses — CloudNativePG, Zalando, Crunchy, and StackGres all have opinions — fighting the operator's backup integration is rarely worth it.

One closing point that's easy to underweight in a feature comparison: WAL archiving architecture differs meaningfully. pgBackRest's async archive-push with a local spool decouples archive latency from the primary; Barman can consume WAL via the replication protocol (no `archive_command` at all, which sidesteps a whole class of archiving bugs); WAL-G is a straightforward synchronous `archive_command` unless you wrap it. Under archive-storm conditions (bulk loads, `VACUUM FULL` on big tables) these behave very differently, and it's the kind of thing that only shows up under load.
