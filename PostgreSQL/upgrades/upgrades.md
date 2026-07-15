# PostgreSQL upgrades (pg_upgrade)

## How many versions can you skip using pg_upgrade?

There is no official or hardcoded limit to how many major versions you can skip using pg_upgrade, but skipping more than 2 to 3 major versions significantly increases your risk of a failed migration. [1, 2, 3]
Technically, the [official PostgreSQL 18 pg_upgrade tool](https://www.postgresql.org/docs/current/pgupgrade.html) allows you to leap straight from version 9.2 up to 18 in a single step. However, database administrators generally separate what is "technically possible" from what is "practically safe." [4]

## The Safe vs. Risky Thresholds

* 1 to 2 Versions (Highly Safe): Upgrading from v16 to v18, or v15 to v17. The system catalogs, standard data types, and default extension behaviors rarely change drastically enough in this window to break the pg_upgrade process. [4, 5]
* 3 to 4 Versions (Moderate Risk): Upgrading from v14 to v18. You will likely encounter minor hiccups, such as old configuration parameters in your postgresql.conf that have been deprecated or removed, requiring manual cleanup before the tool passes its checks. [6, 7]
* 5+ Versions (High Risk / Hard Stop): Upgrading from v13 or older straight to v18. While pg_upgrade might still copy the raw data files successfully, the enormous architectural gap introduces complex breaking points. [8]

## Why Big Version Jumps Fail with pg_upgrade
When you skip too many versions at once, pg_upgrade itself might not fail, but your database cluster can break immediately afterward due to several structural issues:

* OS Collation Changes (The Silent Killer): Modern Linux operating systems periodically update their glibc or ICU collation libraries. If you upgrade across a wide timeline, the underlying OS sorting rules change. Because pg_upgrade reuses your exact same data files, your indexes will silently corrupt, leading to duplicate primary keys and missing query results unless you manually REINDEX the entire cluster immediately. [9, 10, 11]
* Removed Data Types and Functions: Features like old implicit type casts, legacy geometric types, or public schema permissions change significantly over a 5-year span. pg_upgrade cannot recreate system catalogs if your old databases contain objects using syntax that no longer exists in version 18.
* Extension Compatibility: If your old cluster relies on popular extensions like PostGIS or timescaledb, skipping many versions creates a catch-22. The version of the extension compiled for PostgreSQL 9.2 or 12 cannot run on PostgreSQL 18, and pg_upgrade will abort.

## The Industry Standard Recommendation
If your database is large enough that you must use pg_upgrade (and cannot use the safer logical pg_dump), do not try to make a massive multi-version jump directly in production.
Instead, perform a stepping-stone upgrade on a staging environment first. For instance, migrate from 9.2 → 12 → 15 → 18. This allows you to run the compatibility checks at intermediate milestones and resolve breaking catalog structural changes incrementally. [12]

[1] [https://www.reddit.com](https://www.reddit.com/r/PostgreSQL/comments/1796szu/there_is_any_way_to_safely_know_if_i_can_upgrade/)
[2] [https://www.youtube.com](https://www.youtube.com/watch?v=TH63oaFvzL0&t=323)
[3] [https://discussion.fedoraproject.org](https://discussion.fedoraproject.org/t/cant-upgrade-postgres-after-f42-f43/171071?page=2)
[4] [https://www.postgresql.org](https://www.postgresql.org/docs/current/pgupgrade.html)
[5] [https://www.postgresql.org](https://www.postgresql.org/docs/9.0/pgupgrade.html)
[6] [https://yogeshwar9354.medium.com](https://yogeshwar9354.medium.com/postgresql-18-the-incremental-release-that-matters-more-than-you-think-9f3e049ad30a)
[7] [https://www.reddit.com](https://www.reddit.com/r/node/comments/10jbiya/i_am_feeling_really_scared_of_upgrading_so_many/)
[8] [https://www.reddit.com](https://www.reddit.com/r/PostgreSQL/comments/1g0f88s/upgrade_postgresql_version/)
[9] [https://docs.severalnines.com](https://docs.severalnines.com/clustercontrol/2.3.3/user-guide/management/upgrades-patches/)
[10] [https://www.crunchydata.com](https://www.crunchydata.com/blog/glibc-collations-and-data-corruption)
[11] [https://medium.com](https://medium.com/@valentim.dba/how-to-upgrade-postgresql-17-to-18-on-linux-a-complete-step-by-step-guide-2ff0f11e5592)
[12] [https://www.zest-logic.com](https://www.zest-logic.com/blogs/news/common-challenges-when-upgrading-magento-2-to-2-4-8-php-8-4)
