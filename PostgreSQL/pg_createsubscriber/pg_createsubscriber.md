# PostgreSQL pg_createsubscriber utility

Upgrading major versions of PostgreSQL with minimal downtime has historically been one of the biggest challenges for database administrators. Before PostgreSQL 17, doing a near-zero downtime upgrade meant relying on logical replication, which required a massive—and often incredibly slow—initial data sync from the primary to the new node.

The introduction of the **`pg_createsubscriber`** utility in PostgreSQL 17 completely changes this. It allows you to transform an already-synced physical standby server into a logical replica in seconds, bypassing the initial data copy entirely.

Here is exactly how `pg_createsubscriber` works and how to use it to perform a major version upgrade.

---

### **How the Upgrade Workflow Works**

Because physical replication requires both servers to be on the exact same major version, you cannot use it directly for upgrades. Logical replication, however, *does* support cross-version replication.

The magic of `pg_createsubscriber` combined with `pg_upgrade` (which, as of PG 17, now preserves logical subscription states) allows you to bridge these two facts.

#### **Step 1: Start with a Standard Physical Replication Setup**

You begin with your current production setup:

* **Node A (Primary):** Running PostgreSQL 17 (accepting read/write traffic).
* **Node B (Standby):** Running PostgreSQL 17 (replicating physically via streaming replication).

#### **Step 2: Stop the Standby Server**

Before running the utility, you must shut down Node B. `pg_createsubscriber` needs exclusive control over the data directory to perform the conversion.

```bash
pg_ctl -D /path/to/standby/data stop

```

#### **Step 3: Run `pg_createsubscriber` on the Standby**

You execute the `pg_createsubscriber` command on Node B.

```bash
pg_createsubscriber \
  --pgdata=/path/to/standby/data \
  --publisher-server="host=node_a port=5432 user=repuser dbname=postgres" \
  --subscriber-port=5432 \
  --database=your_database \
  --publication=upgrade_pub \
  --subscription=upgrade_sub

```

**Under the hood, the tool will:**

1. Connect to the Primary (Node A) and create a publication (`FOR ALL TABLES`) and a logical replication slot.
2. Start Node B locally, recover it up to the exact Log Sequence Number (LSN) of the newly created replication slot, and promote it to be its own independent primary database.
3. Create the logical subscription on Node B, linking it back to Node A.

Node B is now a logical subscriber of Node A, and your physical data is perfectly intact without any copying.

#### **Step 4: Upgrade the Logical Subscriber**

Now that Node B is a disconnected, standalone logical node, you can upgrade it to the new major version (e.g., PostgreSQL 18) using the standard `pg_upgrade` utility.

```bash
pg_upgrade \
  --old-datadir=/path/to/standby/data \
  --new-datadir=/path/to/new_pg18/data \
  --old-bindir=/usr/lib/postgresql/17/bin \
  --new-bindir=/usr/lib/postgresql/18/bin

```

*Note: Because PG 17 added the ability for `pg_upgrade` to retain logical subscription metadata, your subscription configuration will safely migrate to the new PG 18 data directory.*

#### **Step 5: Start the Upgraded Node**

Start Node B using the new PostgreSQL 18 binaries.

As soon as it boots, the logical subscription will wake up, connect to Node A (which is still running PG 17 and serving your application), and begin catching up on any transactions that occurred while Node B was being upgraded.

#### **Step 6: The Cutover**

Once Node B has fully caught up to Node A via logical replication:

1. Briefly pause or stop application traffic to Node A.
2. Wait a few moments for the final WAL records to replicate to Node B.
3. Reconfigure your application connection strings to point to Node B.
4. Resume traffic.

You are now successfully running on the new major version with minimal downtime!

---

### **Important Prerequisites & Limitations**

* **Version Limit:** This workflow is only possible when upgrading **from PostgreSQL 17 or higher**. If you are on PG 16 or earlier, the `pg_createsubscriber` tool does not exist, and `pg_upgrade` will not preserve subscription states.
* **Logical Replication Limits:** Because the resulting setup relies on logical replication, you are bound by its limitations during the transition window. Specifically, **DDL commands (schema changes) and sequence updates on the primary will not replicate** to the subscriber while you are waiting to cut over. Freeze schema changes during this maintenance window.
* **Parameter Requirements:** Your source server (Node A) must have `wal_level = logical` set, and `max_replication_slots` must be configured high enough to accommodate the new slots created by the tool.