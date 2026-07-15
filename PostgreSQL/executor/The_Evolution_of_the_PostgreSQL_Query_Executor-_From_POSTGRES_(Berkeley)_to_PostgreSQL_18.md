# The Evolution of the PostgreSQL Query Executor: From POSTGRES (Berkeley) to PostgreSQL 18

*A detailed technical archaeology of `src/backend/executor/` across three decades, with primary-source citations to commits, READMEs, mailing-list threads, and release notes.*

---

## 1. Architectural Foundations

### 1.1 The Berkeley POSTGRES heritage

PostgreSQL's executor is a direct descendant of the executor in the original POSTGRES research prototype written at UC Berkeley in the late 1980s under Michael Stonebraker. Many of the conceptual artifacts visible today — the `Plan`/`PlanState` split, the recursive `ExecInitNode` / `ExecProcNode` / `ExecEndNode` triad, the `EState`/`ExprContext` separation, the `TupleTableSlot` indirection between executor nodes — were already present, in essentially recognizable form, when the codebase was forked from POSTGRES into Postgres95 and later renamed PostgreSQL in 1996. The original executor README (`src/backend/executor/README` — see https://github.com/postgres/postgres/blob/master/src/backend/executor/README) still preserves the canonical narrative example built around DEPT/EMP, descended verbatim from the Berkeley source, and the file headers in `execProcnode.c` still carry "Portions Copyright (c) 1994, Regents of the University of California."

Historically, these files lived as three separate sources (`execScan.c`, `execProcnode.c`, `execMain.c`); they were merged into the single `execProcnode.c` early in PostgreSQL's history "so that it is easier to keep the dispatch routines in sync when new nodes are added," as the file's leading comment records. That merge file is one of the most stable artifacts in the codebase and remains the heart of executor dispatch (https://github.com/postgres/postgres/blob/master/src/backend/executor/execProcnode.c).

### 1.2 The Volcano/iterator model

The executor is, conceptually and to a great extent literally, an implementation of Goetz Graefe's *Volcano* iterator model (1990–1994 papers). Robert Haas summarized this lineage in his 2019 "Braces Are Too Expensive" essay: "PostgreSQL has what's sometimes called a Volcano-style executor… many of the concepts in the Volcano papers have made their way into PostgreSQL over the years… The Volcano execution model has been thoroughly embedded in PostgreSQL for the entire history of the database system; the first chinks in the armor only started to appear in 2017" (http://rhaas.blogspot.com/2019/10/braces-are-too-expensive.html).

The model has three characteristic properties that PostgreSQL still satisfies in 2026:

1. **Tree of plan nodes.** The planner emits a `PlannedStmt` containing a `Plan` tree (`src/include/nodes/plannodes.h`). Each `Plan` has zero or more child plans (`lefttree`, `righttree`, sometimes lists of subplans for `Append`/`MergeAppend`/`ModifyTable`/`CustomScan`).
2. **State tree mirroring the plan tree.** At execution start, the executor builds a parallel `PlanState` tree (`src/include/nodes/execnodes.h`) containing all per-execution mutable state — buffer pins, join hash tables, `ExprContext`s, `TupleTableSlot`s, parallel coordination data, instrumentation, and so on.
3. **Pull-based "next tuple please" interface.** The top-level driver (`ExecutePlan` in `src/backend/executor/execMain.c`) calls `ExecProcNode(topPlanState)`, which recursively asks each child for one tuple at a time and either returns a `TupleTableSlot*` containing the tuple or a NULL/empty slot to signal end-of-stream.

The lifecycle is documented in `src/backend/executor/README`:

```
ExecutorStart
    CreateExecutorState / ExecInitNode (recursive)
ExecutorRun
    ExecutePlan
        ExecProcNode --- recursively called in per-query context
            ExecEvalExpr --- called in per-tuple context
            ResetExprContext --- to free memory
ExecutorFinish
    ExecPostprocessPlan --- run any unfinished ModifyTable nodes
ExecutorEnd
    ExecEndNode --- recursively releases resources
    FreeExecutorState
```

`ExecutorStart`, `ExecutorRun`, `ExecutorFinish`, and `ExecutorEnd` are exposed as the official "executor lifecycle" API and are the points at which extensions hook in via `ExecutorStart_hook`, `ExecutorRun_hook`, etc. (see `src/backend/executor/execMain.c`).

### 1.3 Plan vs. PlanState

This split has remained constant: the planner output is read-only and cacheable (used both for generic plans in plan-cache and for one-shot "custom" plans, see `src/backend/utils/cache/plancache.c`), while everything mutable lives on `PlanState`-derived structures (e.g., `SeqScanState`, `HashJoinState`, `AggState`, `GatherState`). Each `Plan` node type has a corresponding `*State` struct, an `ExecInit*` constructor, an `Exec*` per-tuple routine, and an `ExecEnd*` destructor; `execProcnode.c` is the dispatch hub that maps `nodeTag(plan)` to those callbacks.

---

## 2. Version-by-Version Evolution

### 2.1 Cumulative summary table

| Version (Year) | Headline executor changes |
|---|---|
| 6.x–7.3 (1997–2002) | Core Volcano executor; nested loop / merge / hash join; SeqScan, IndexScan; subplan and InitPlan infrastructure. |
| 7.4 (2003) | Hash-based `IN`/`NOT IN`, `HashAggregate` node (`nodeAgg.c` overhauled). |
| 8.0 (2005) | Tablespaces; PITR — no large executor change. |
| 8.1 (2005) | **Bitmap Index Scan / Bitmap Heap Scan / BitmapAnd / BitmapOr** (Tom Lane); two-level scan that decouples index ordering from heap fetch order (https://www.postgresql.org/docs/8.1/indexes-bitmap-scans.html). |
| 8.3 (2008) | HOT, async commit; planner-side improvements; minor executor changes. |
| 8.4 (2009) | **Common Table Expressions (`CTE Scan`, `WorkTable Scan`, `RecursiveUnion`)**; **window functions (`WindowAgg`)**; semi/anti-join executor support; partial-match GIN. |
| 9.0 (2010) | EvalPlanQual rewrite, `LockRows` node redesign. |
| 9.1 (2011) | Writable CTEs (`ModifyTable` reaches into CTE scans), unlogged tables, FDW (`ForeignScan`). |
| 9.2 (2012) | **Index-Only Scan** (`nodeIndexonlyscan.c`); cascading replication. |
| 9.3 (2013) | Writable FDW (`ExecForeignInsert/Update/Delete`); materialized views. |
| 9.4 (2014) | Dynamic shared memory (DSM) and dynamic background workers — foundational infrastructure for parallel query (Robert Haas). |
| 9.5 (2015) | **CustomScan API** (KaiGai Kohei) — pluggable scan node; UPSERT (`ON CONFLICT`); GROUPING SETS / `MixedAggregate`. |
| 9.6 (2016) | **Parallel query MVP** — `Gather`, `Parallel Seq Scan`, `Partial Aggregate`/`Finalize Aggregate`; partial paths in planner (Robert Haas, Amit Kapila, David Rowley). |
| 10 (2017) | **Step-machine expression interpreter (`execExprInterp.c`)** (Andres Freund, b8d7f053); **`ExecProcNode` becomes a function pointer** (178f2d56); `Gather Merge`, `Parallel Index Scan`, `Parallel Bitmap Heap Scan`, `Parallel Merge Join`; declarative partitioning. |
| 11 (2018) | **JIT compilation via LLVM** (Andres Freund); **Parallel Hash Join** (Thomas Munro); **Parallel Append** (Amit Khandekar); **runtime partition pruning** (David Rowley, 499be013). |
| 12 (2019) | **Pluggable `TupleTableSlot` (heap / minimal / virtual / buffer)** (1a0586de, 4da597ed); **Table Access Method API**; JIT inlining hardening; partition pruning improvements. |
| 13 (2020) | **HashAgg spilling to disk** (Jeff Davis, 1f39bce0); **Incremental Sort** (James Coleman, Tomas Vondra, d2d8a229); deduplication in B-tree; partitionwise join improvements. |
| 14 (2021) | **Memoize node** (David Rowley, b6002a79 / renamed in 83f4fcc6); **Async Append for postgres_fdw** (Etsuro Fujita, 27e1f145); incremental sort for window functions. |
| 15 (2022) | **MERGE** (`execMerge.c`) (Pavan Deolasee, Álvaro Herrera, Simon Riggs, 7103ebb7); planner-pushed WindowAgg early termination; sort improvements. |
| 16 (2023) | **Parallel-aware Right/Full Hash Join** (Melanie Plageman, Thomas Munro); incremental sort for `DISTINCT`; window-clause `ROWS`/`RANGE` short-circuiting; parallel `string_agg`/`array_agg`. |
| 17 (2024) | **`read_stream` API** (Thomas Munro, b5a9b18c & related); streaming I/O for sequential scans, ANALYZE, BRIN; vectored `ReadBuffer`; planner improvements for incremental sort. |
| 18 (2025) | **Asynchronous I/O subsystem (worker / io_uring / sync)** (Andres Freund, Thomas Munro, Nazir Bilal Yavuz, Melanie Plageman); AIO-aware sequential scans, bitmap heap scans and VACUUM; `pg_aios` system view; `effective_io_concurrency` default raised to 16. |

Tree views of the executor source for any version are accessible via `https://git.postgresql.org/gitweb/?p=postgresql.git;a=tree;f=src/backend/executor;hb=REL_X_Y` (substitute, e.g., `REL_18_0`, `REL_17_STABLE`, `REL9_6_24`).

---

### 2.2 7.4 — `HashAggregate`

7.4 added grouped aggregation by hash table in `src/backend/executor/nodeAgg.c`, augmenting the previously existing sorted aggregation. Until this point, `GROUP BY` on unsorted input forced an explicit `Sort`; with hashed aggregation, an `AggState` could maintain a `TupleHashTable` keyed on the grouping columns and emit tuples in `final` mode. The basic data-structures (per-aggregate transition state stored in `AggStatePerAgg` arrays, two-phase finalization) all date from this period and remain visible in modern `nodeAgg.c` (https://github.com/postgres/postgres/blob/master/src/backend/executor/nodeAgg.c).

### 2.3 8.1 — Bitmap scans

The `BitmapIndexScan` / `BitmapHeapScan` / `BitmapAnd` / `BitmapOr` machinery is one of the most visible Stonebraker-era-style additions. Tom Lane summarized the design in 2005: "A bitmap scan fetches all the tuple-pointers from the index in one go, sorts them using an in-memory 'bitmap' data structure, and then visits the table tuples in physical tuple-location order. The bitmap scan improves locality of reference to the table at the cost of more bookkeeping overhead… When [the bitmap] gets too large we convert it to 'lossy' style, in which we only remember which pages contain matching tuples instead of remembering each tuple individually" (https://www.postgresql.org/message-id/12553.1135634231@sss.pgh.pa.us). The implementing files are `nodeBitmapHeapscan.c`, `nodeBitmapIndexscan.c`, `nodeBitmapAnd.c`, `nodeBitmapOr.c`, with the in-memory bitmap (`tidbitmap.c`) supporting both exact-TID and lossy-page modes. Bitmap scans are notable as the first major executor node type whose I/O pattern is fundamentally page-rather-than-tuple-oriented; this is what made them straightforward to retrofit with prefetch (`effective_io_concurrency`, 9.6+) and now the read_stream API (PG 17/18).

### 2.4 8.4 — CTEs, recursive UNION, window functions

PostgreSQL 8.4 was an executor-feature watershed. New nodes:

- `CteScan` and `WorkTableScan` (`nodeCtescan.c`, `nodeWorktablescan.c`) — implement non-recursive and recursive CTE materialization respectively.
- `RecursiveUnion` (`nodeRecursiveunion.c`) — alternates non-recursive and recursive subplans driving a shared work-table tuplestore.
- `WindowAgg` (`nodeWindowAgg.c`) — implements SQL:2003 window functions over partitioned, ordered streams; introduced the notion of a buffered tuplestore plus a frame pointer that nodes such as `lag()`, `lead()`, `row_number()` advance.

These additions also pushed substantial planner machinery (preprocess for CTEs, separate post-scan/join `Path` node creation), but the executor footprint is large and visible in any 8.4-or-later tree (https://git.postgresql.org/gitweb/?p=postgresql.git;a=tree;f=src/backend/executor;hb=REL8_4_22).

### 2.5 9.2 — Index-Only Scans

`nodeIndexonlyscan.c` was added to allow B-tree (and later GiST/SP-GiST) index entries to satisfy queries directly when the heap row's visibility-map bit confirms the tuple is all-visible to all transactions. The executor pattern is essentially `IndexScan + heap-only-when-needed`; the visibility-map probe is in `heap_fetch`.

### 2.6 9.5 — `CustomScan` and Grouping Sets

The `CustomScan` API (KaiGai Kohei, with extensive pgsql-hackers discussion) introduced the first truly extensible scan node. Documented on the PostgreSQL wiki (https://wiki.postgresql.org/wiki/CustomScanAPI) and at https://www.postgresql.org/docs/9.5/custom-scan.html, it permits extensions to register a scan provider that participates in path generation (`add_scan_path_hook`, `add_join_path_hook`), produces a `CustomPath`, gets converted into a `CustomScan` plan, and finally a `CustomScanState` that overrides `BeginCustomScan`, `ExecCustomScan`, `EndCustomScan`. PG-Strom is the canonical user; Citus and ColumnStore-style extensions also leveraged it. The wiki entry notes the design tension with FDWs that ultimately motivated separating CustomScan as a true extensibility hook.

GROUPING SETS in 9.5 added `MixedAggregate` execution mode, allowing a single `Agg` node to evaluate several grouping sets in one pass with both hash- and sort-based phases; this is what later made `nodeAgg.c` so complex and is the locus of the 13-cycle spilling work.

### 2.7 9.6 — Parallel query MVP

9.6 was Robert Haas's parallel-query milestone after several release cycles (9.4 — DSM and dynamic background workers; 9.5 — parallel-safety machinery and infrastructure for sharing state via shared memory) (http://rhaas.blogspot.com/2015/11/parallel-sequential-scan-is-committed.html).

The executor-visible changes:

- **`Gather` node** (`nodeGather.c`) — leader-side coordinator that launches background workers via `LaunchParallelWorkers`, sets up `ParallelContext` (`src/backend/access/transam/parallel.c`), DSM segment and tuple queues (`src/backend/executor/tqueue.c`), then drains tuples from worker shm queues into the main plan stream.
- **`Parallel Seq Scan`** — `nodeSeqscan.c` becomes parallel-aware via a `ParallelHeapScanDesc` in DSM; workers `heap_parallelscan_nextpage` to claim block ranges atomically.
- **Partial / Finalize Aggregate** — partial aggregates introduced by David Rowley/Simon Riggs; allowed splitting an aggregate across leader and workers.

Robert Haas's blog ran TPC-H scale 10 with `max_parallel_degree = 4`: "Of the 22 queries, 17 switched to a parallel plan, while the plans for the other 5 were unchanged. Of the 17 queries where the plan changed, 15 got faster, 1 ran at the same speed, and 1 got slower" (http://rhaas.blogspot.com/2016/04/postgresql-96-with-parallel-query-vs.html). Notable limitations of the 9.6 version: only Seq Scan is parallel-aware on the driving side; merge join unsupported in parallel; hash join builds a private copy of the hash table per worker.

The Parallel Query wiki page tracks status across versions: https://wiki.postgresql.org/wiki/Parallel_Query.

### 2.8 PostgreSQL 10 — the executor's modern shape

10 is arguably the biggest executor refactor in PostgreSQL's history. Three changes especially:

#### 2.8.1 Step-machine expression interpreter

Commit `b8d7f053c5c2bf2a7e8734fe3327f6a8bc711755` — Andres Freund, "Faster expression evaluation and targetlist projection" (https://github.com/postgres/postgres/commit/b8d7f053c5c2bf2a7e8734fe3327f6a8bc711755) replaced the recursive tree-walking evaluator (`ExecEvalExpr` switching on `Expr` node tag for every `Var`, `Func`, `OpExpr`, etc.) with a non-recursive opcode-dispatch interpreter. Each `Expr` is "compiled" at `ExecInitExpr` time into a flat array of `ExprEvalStep` opcodes (`enum ExprEvalOp` — `EEOP_FUNCEXPR`, `EEOP_QUAL`, `EEOP_BOOL_AND_STEP`, `EEOP_AGG_PLAIN_TRANS_BYREF`, …) stored directly inside `ExprState->steps[]`. The hot loop in `src/backend/executor/execExprInterp.c` (`ExecInterpExpr`) uses GCC's computed-goto extension when available and a plain switch otherwise. Projection (the operation of producing the next plan node's output tuple from the input tuple) was folded into expression evaluation as a sequence of `EEOP_ASSIGN_*_VAR` steps, eliminating one of the most painful per-tuple overheads (the old `ExecProject` recursion through `ExecTargetList`).

The commit message itself flags "significant performance improvements, and makes future just-in-time compilation of expressions easier." It also documents two semantic changes (function permission checks and domain constraint enumeration moving from execution to initialization). Background and benchmarks are in Andres's pgsql-hackers thread "Faster Expression Processing v4" (https://www.postgresql.org/message-id/20170314173137.5r5jtgkgx6siuwsy@alap3.anarazel.de).

The companion files `execExpr.c` (initialization / opcode emission) and `execExprInterp.c` (the interpreter) are now central. View them at:

- https://github.com/postgres/postgres/blob/master/src/backend/executor/execExpr.c
- https://github.com/postgres/postgres/blob/master/src/backend/executor/execExprInterp.c

#### 2.8.2 `ExecProcNode` as function pointer

A few months later, commit `178f2d560d` (Andres Freund, Tom Lane), "Move ExecProcNode from dispatch to function pointer based model" (https://www.postgresql.org/message-id/E1dbxuN-0002A2-CW@gemulon.postgresql.org), removed the giant `switch (nodeTag(node))` from `ExecProcNode` itself. Each `PlanState` now stores `ExecProcNodeMtd ExecProcNode` and `ExecProcNodeMtd ExecProcNodeReal` — the former calls the latter through a wrapper that, on the very first invocation, does a `check_stack_depth()`, then patches itself out so that subsequent calls go directly to the per-node `Exec*` function. This pattern was originally needed because the new expression evaluator no longer guaranteed an `ExecEvalExpr` was executed somewhere in the per-tuple path (where the old stack-depth check used to live). It also yielded "a nice speedup" simply by trading a switch+function-call for a single indirect call. The code in `ExecProcNodeFirst()` and `ExecProcNodeInstr()` still bears these comments today (https://github.com/postgres/postgres/blob/master/src/backend/executor/execProcnode.c).

#### 2.8.3 Parallel query enhancements

PG10 added `Gather Merge` (Rushabh Lathia) — order-preserving gather of presorted parallel streams, implemented in `nodeGatherMerge.c` with a binary-heap merge. `Parallel Index Scan` and `Parallel Index-Only Scan` (Rahila Syed, Amit Kapila, Rafia Sabih) shared B-tree page-ranges via shared memory. `Parallel Bitmap Heap Scan` (Dilip Kumar) split the bitmap-heap-fetch phase, with one worker building the TID bitmap and all workers cooperating on the heap scan. `Parallel Merge Join` (Dilip Kumar) made merge join itself usable in parallel. See Robert Haas's "Parallel Query v2" overview: http://rhaas.blogspot.com/2017/03/parallel-query-v2.html.

### 2.9 PostgreSQL 11 — JIT and Parallel Hash

#### 2.9.1 JIT via LLVM

Commit series authored by Andres Freund in March 2018 (the umbrella discussion thread is https://www.postgresql.org/message-id/20180124072038.jviav7h3fgkv7hto@alap3.anarazel.de — "JIT compiling with LLVM v9.0"). The JIT lives in `src/backend/jit/` with a pluggable provider architecture (`jit_provider` GUC, default `llvmjit`); `src/backend/jit/llvm/` contains the LLVM-specific code generator (`llvm-config`-based build with `--with-llvm`).

Two main targets:

1. **Expression evaluation.** Each `ExprEvalStep` opcode has a corresponding LLVM IR emission in `llvm_compile_expr()`. Because the interpreter is already a flat opcode array (since PG10), the JIT effectively unrolls and inlines the same logic LLVM-side, and uses LLVM `alloca` for the `ExprState` scratchpad (`Mem2Reg`/`SROA` then promote to SSA). With pre-built `.bc` bitcode files for backend functions (shipped in `$libdir/bitcode/`), LLVM can inline operator implementations into the JITted query (`llvmjit_inline.cpp`).
2. **Tuple deforming.** `slot_compile_deform()` emits a per-relation/per-tuple-shape function that knows the column offsets and null bitmap layout, eliminating the loop overhead of the generic `slot_deform_tuple`.

The JIT documentation (https://www.postgresql.org/docs/11/jit-reason.html) lists the user-visible capabilities: "Currently PostgreSQL's JIT implementation has support for accelerating expression evaluation and tuple deforming." Three GUCs cost-gate JIT: `jit_above_cost`, `jit_inline_above_cost`, `jit_optimize_above_cost`. The Citus benchmark on TPC-H Q1 scale 10 reported "29.31% speed improvements, executing TPC-H Q1 at scale factor 10 in 20.5s instead of 29s when using PostgreSQL 10" (https://www.citusdata.com/blog/2018/09/11/postgresql-11-just-in-time/). Earlier ISP-RAS prototype work reached up to 37% TPC-H speedup (https://www.pgcon.org/2017/schedule/attachments/467_PGCon%202017-05-26%2015-00%20ISPRAS%20Dynamic%20Compilation%20of%20SQL%20Queries%20in%20PostgreSQL%20Using%20LLVM%20JIT.pdf).

The trade-off is non-trivial: planning + JIT-compile time can dominate short queries, leading to the well-known regressions for short OLTP queries when JIT is enabled with a too-low cost threshold (commit `b9f2d4d3` carries that warning). Andres's 2018 FOSDEM talk gives the design rationale (https://archive.fosdem.org/2018/schedule/event/jiting_postgresql_using_llvm/).

#### 2.9.2 Parallel-aware Hash Join

Thomas Munro's commit `1804284042e6594ce28cf25b5b1bdd2cba2727f5` (and follow-ups) made `nodeHashjoin.c` / `nodeHash.c` capable of building the hash table in shared memory cooperatively. Infrastructure: Dynamic Shared Areas (DSA, `src/backend/utils/mmgr/dsa.c`), `Barrier` synchronization primitives (`src/backend/storage/ipc/barrier.c`), `SharedTuplestore` (`src/backend/utils/sort/sharedtuplestore.c`) for spilling multi-batch joins. The blog post https://www.enterprisedb.com/blog/parallel-hash-postgresql gives the timeline diagrams. The Parallel Hash wiki page (https://wiki.postgresql.org/wiki/Parallel_Hash) tracks open issues and follow-ups, including the chunk-overhead estimation gap in `ExecChooseHashTableSize`.

#### 2.9.3 Parallel Append

Amit Khandekar's `ab72716778128fb63d54ac256adf7fe6820a1185` introduced `nodeAppend.c` parallel-aware mode: workers pick subplans (rather than splitting one subplan), enabling efficient parallelism across partitioned tables and `UNION ALL` queries. Critically, a `Parallel Append` may have *both* partial and non-partial children — non-partial children are run to completion by exactly one worker (https://www.postgresql.org/docs/11/parallel-plans.html).

#### 2.9.4 Runtime partition pruning

Commit `499be013de65242235ebdde06adb08db887f0ea5` (Álvaro Herrera, after work by David Rowley building on Beena Emerson) — "Support partition pruning at execution time" (https://www.postgresql.org/message-id/E1f4uyY-0005jE-MW@gemulon.postgresql.org). A new `src/backend/executor/execPartition.c` and `src/backend/partitioning/partprune.c` translate partition-key clauses against execution-time `Param` values into a `Bitmapset` of subpaths to actually scan. This handles three runtime cases: parameterized nested-loop inner side; InitPlan-derived parameters; and `Params` from outer subqueries. Tom Lane extended this in a follow-up to allow any non-`Var` stable expression. Coupled with the binary-search partition lookup in PG11 (replacing PG10's linear scan), it transforms partitioned-table workloads that were unusable in 10 into mainstream targets.

### 2.10 PostgreSQL 12 — `TupleTableSlot` redesign and TableAM

PG12's flagship executor work, committed by Andres Freund, is the abstraction of `TupleTableSlot`. Pre-12, `TupleTableSlot` was a single struct with fields for each possible tuple representation (`tts_tuple` for `HeapTuple`, `tts_mintuple` for `MinimalTuple`, `tts_buffer` for buffer-pinned heap tuples, plus `tts_values[]`/`tts_isnull[]` for virtual representation), and every operation (`ExecClearTuple`, `ExecMaterializeSlot`, `slot_getallattrs`, …) branched on which fields were set.

The redesign (motivated by both the upcoming Table Access Method API and possible future column stores; pgsql-hackers thread "TupleTableSlot abstraction": https://www.postgresql.org/message-id/20180220224318.gw4oe5jadhpmcdnm@alap3.anarazel.de) split this into:

- A base `TupleTableSlot` containing only common metadata (`flags`, `tts_nvalid`, `tts_values`, `tts_isnull`, `tts_tupleDescriptor`, `const TupleTableSlotOps *tts_ops`).
- Four concrete slot types each embedding the base: `HeapTupleTableSlot`, `BufferHeapTupleTableSlot`, `MinimalTupleTableSlot`, `VirtualTupleTableSlot`.
- A vtable, `TupleTableSlotOps`, with `init`, `release`, `clear`, `getsomeattrs`, `materialize`, `copyslot`, `get_heap_tuple`, `get_minimal_tuple`, `copy_heap_tuple`, `copy_minimal_tuple`.

Two commits land this: `1a0586de36` (introduce notion of slot types without implementing them) and `4da597edf1bae0cf0453b5ed6fc4347b6334dfe1` (split implementation across four slot types — https://github.com/postgres/postgres/commit/4da597edf1bae0cf0453b5ed6fc4347b6334dfe1). The current header is `src/include/executor/tuptable.h` (https://github.com/postgres/postgres/blob/master/src/include/executor/tuptable.h).

The table access method API (https://www.postgresql.org/docs/12/tableam.html, commit `c2fe139c201c48f1133e9fbea2dd99b8efe2fadd`) sits on top: the heap is now just one access method (`heap_tableam_handler`), `CREATE ACCESS METHOD ... TYPE TABLE` allows alternatives, and `default_table_access_method` chooses what `CREATE TABLE` uses. zheap (EnterpriseDB) and zedstore (Greenplum) are out-of-tree consumers; `pg_cryogen` (https://github.com/adjust/pg_cryogen) is an open-source compressed AM. There was a non-trivial breakage for FDW authors: `TupleTableSlot`s arriving in `ExecForeignInsert/Update/Delete` were no longer pre-deformed; the migration note is at https://blog.cleverelephant.ca/2019/03/fdw-pgsql12.html.

### 2.11 PostgreSQL 13 — Disk-based HashAgg and Incremental Sort

#### 2.11.1 HashAgg spilling

Long-standing limitation: `HashAggregate` would silently exceed `work_mem` when the planner under-estimated cardinality. Commit `1f39bce021540fde00990af55b4432c55ef4b3c7` (Jeff Davis), "Disk-based Hash Aggregation" (https://www.postgresql.org/message-id/E1jEhaL-0002Ur-2L@gemulon.postgresql.org). On exceeding `work_mem * hash_mem_multiplier`, `nodeAgg.c` now partitions remaining input by a hash-prefix into spill files (using `LogicalTape` infrastructure), continues producing groups for the in-memory portion, then iteratively reloads spilled partitions, possibly recursively spilling. EXPLAIN ANALYZE shows `Batches`, `Memory Usage`, `Disk Usage`, `Planned Partitions` (commit `0e3e1c4` aligned this with Hash Join's output format).

There was a known initial perf regression in classic in-memory HashAggs caused by attribute-trimming and a `LookupTupleHashEntryHash()` pipeline stall (https://www.postgresql.org/message-id/20200612213715.op4ye4q7gktqvpuo@alap3.anarazel.de). The `enable_hashagg_disk` GUC was added (later renamed/deprecated as the costing settled). Tomas Vondra extensively worked the cost model afterwards.

#### 2.11.2 Incremental Sort

Commit `d2d8a229bca5d9ef593c45e2d77ade87fa45e7da` (James Coleman, Alexander Korotkov, Tomas Vondra), `nodeIncrementalSort.c`. When the input is already sorted on a prefix of the requested keys (e.g., from an index scan on the leading column), the executor sorts only within "groups" sharing the prefix value. Two sub-modes: full-sort (collected groups large enough for batched quicksort) and pre-sort (partial groups). Disk usage instrumentation in EXPLAIN ANALYZE (`Full-sort Groups: ... Sort Method: quicksort Average Memory ...; Pre-sorted Groups: ...`). The patch was discussed for ~2 years on hackers (Commitfest patch #1124) and produced multiple post-commit fix-ups; it expanded in 14 (window functions), 16 (DISTINCT, presorted aggregates) and 17 (GiST/SP-GiST input).

### 2.12 PostgreSQL 14 — Memoize and Async Append

#### 2.12.1 Memoize

Commit `b6002a796dcd14d1cf0974c828bda08ee10571ac` (David Rowley); subsequently renamed from "Result Cache" to "Memoize" in `83f4fcc65`. New file `src/backend/executor/nodeMemoize.c`. The Memoize node sits between a parameterized inner subplan (typically an Index Scan) and a Nested Loop that drives it; it caches each (parameter-tuple → result-tuples) lookup in an LRU hash table, and on cache-hit streams the cached results back without re-invoking the subnode. EXPLAIN exposes `Cache Key`, `Cache Mode` (logical or binary), `Hits`, `Misses`, `Evictions`, `Overflows`, `Memory Usage`. The motivation was to give parameterized nested loops something close to the join performance of a hash join on workloads with high duplicate ratios in the outer side, without the up-front cost of building a full hash table. Lukas Eder reported ~10× to 1000× speedups for some lateral and aggregate-inner-side cases (https://blog.jooq.org/postgresql-14s-enable_memoize-for-improved-performance-of-nested-loop-joins/). The 16 cycle extended Memoize to UNION ALL inner sides; a series of fixes through 14.x and 15.x addressed volatile join conditions and parameterized lateral joins.

#### 2.12.2 Async Append

Commit `27e1f14563cf982f1f4d71e21ef247866662a052` (Etsuro Fujita, building on extensive design work by Kyotaro Horiguchi and Andrey Lepikhov). The basic idea: when an `Append` has multiple async-capable children (initially only `ForeignScan` on `postgres_fdw`), the executor can issue requests on all of them concurrently, and consume from whichever responds first via a `WaitEventSet`. This required a new infrastructure on `PlanState`/`Append`: `ForeignAsyncRequest`, `ForeignAsyncConfigureWait`, `ForeignAsyncNotify` callbacks (added to the FDW handler). The result is true sharded-postgres-fdw parallelism without spawning local parallel workers. See https://www.highgo.ca/2021/06/28/parallel-execution-of-postgres_fdw-scans-in-pg-14-important-step-forward-for-horizontal-scaling/ for the timeline. The GUC `enable_async_append` controls planning. Note that async execution explicitly does *not* flow through `ExecProcNode` for the async children — tuples are conveyed "out of band" via `ForeignAsyncNotify` to avoid disrupting non-async-aware nodes (this was a key design constraint addressed during review).

### 2.13 PostgreSQL 15 — MERGE

Commit `7103ebb7aae8ab8076b7e85f335ceb8fe799097c` (Pavan Deolasee, Álvaro Herrera, Amit Langote, Simon Riggs) — `Add support for MERGE SQL command`. New file `src/backend/executor/execMerge.c` and substantial changes in `nodeModifyTable.c`. The executor README (https://github.com/postgres/postgres/blob/master/src/backend/executor/README) was updated with a new section: "MERGE runs one generic plan that returns candidate target rows…" The plan is essentially a `ModifyTable` node above an outer join between the target and source; the `WHEN MATCHED`/`WHEN NOT MATCHED` clauses become a sequence of conditional actions evaluated per row, with EvalPlanQual rechecks for concurrency. Earlier MERGE patches (2018) were committed and then reverted; the 2022 commit was version 10 of the design.

### 2.14 PostgreSQL 16 — More parallelism, planner-driven executor short-circuits

Major executor-touching PG16 changes:

- **Parallel Right/Full Hash Join** (Melanie Plageman, Thomas Munro). `nodeHashjoin.c` was extended so that the "unmatched inner tuples" phase (which produces the right-side rows for a `RIGHT` or `FULL` outer join) is now safe to run in parallel; previously, the requirement for a single coordinator to scan the full hash table at end-of-probe forced these joins to be serial.
- **Incremental sort for `DISTINCT`** (David Rowley) — extends the 13/14 incremental-sort node into more planning paths.
- **Parallel `string_agg` / `array_agg`** (David Rowley) — partial aggregation support extended to two of the most popular non-parallel aggregates.
- **WindowAgg early termination via planner** (David Rowley) — when a `WHERE` clause filters a monotone window function such that no further row can match, the executor can stop early. Test cases show >500× speedups on `row_number() <= 10` patterns (https://www.citusdata.com/blog/2024/02/08/whats-new-in-postgres-16-query-planner-optimizer/).
- **`force_parallel_mode` renamed to `debug_parallel_query`** (https://www.postgresql.org/docs/16/release-16.html).

### 2.15 PostgreSQL 17 — `read_stream`

PG17 introduced the long-anticipated `read_stream` API, the first half of the asynchronous-I/O work — the half that delivers vectored, batched I/O without yet asynchronizing it. Key commits authored by Thomas Munro with co-authors Andres Freund, Melanie Plageman and Nazir Bilal Yavuz:

- **Vectored `ReadBuffer`** — a new internal API in `src/backend/storage/buffer/bufmgr.c` that submits many buffer reads in one call (`StartReadBuffers` → `WaitReadBuffers`).
- **`read_stream` API** (`src/backend/storage/aio/read_stream.c`) — a new abstraction sitting between the buffer manager and consumers, with adaptive look-ahead distance, `io_combine_limit` block coalescing using `preadv()` on Linux, and integration with `effective_io_concurrency`. The pg_analyze coverage (https://pganalyze.com/blog/5mins-postgres-17-streaming-io) walks through the commits.
- **Streaming I/O sequential scans** (Melanie Plageman) — `nodeSeqscan.c` switched to `read_stream_next_buffer()` where possible, dropping per-block `ReadBuffer` calls.
- **Streaming ANALYZE and BRIN** — the same machinery applied to maintenance scans.
- **Streaming bitmap-heap scans** (begun in 17, completed in 18) — `nodeBitmapHeapscan.c` was a major focus, integrating `read_stream` with the page-iterator over the TID bitmap.

The user-visible effect in 17 is mainly more efficient I/O packing on Linux (`preadv` instead of one `pread` per 8 kB block), with the actual asynchronous-I/O infrastructure deferred to 18.

### 2.16 PostgreSQL 18 — Asynchronous I/O

PG18 (May 2026) lands the rest. The release notes (https://www.postgresql.org/docs/release/18.0/) summarize: "Add an asynchronous I/O subsystem (Andres Freund, Thomas Munro, Nazir Bilal Yavuz, Melanie Plageman) — This feature allows backends to queue multiple read requests, which allows for more efficient sequential scans, bitmap heap scans, vacuums, etc. This is enabled by server variable `io_method`, with server variables `io_combine_limit` and `io_max_combine_limit` added to control it." The implementation lives in `src/backend/storage/aio/`.

Three modes are selectable via `io_method`:

- `sync` — the same synchronous path as PG17 (with the `read_stream` packing), retained for regression testing and compatibility.
- `worker` (default) — a pool of dedicated I/O worker processes (`io_workers`, default 3) sit alongside backends and execute submitted reads via `preadv`, returning completion via shared-memory queues. Conceptually similar to existing parallel workers but long-lived, started by postmaster, shared across all sessions.
- `io_uring` (Linux 5.1+, requires `--with-liburing`) — each backend has its own io_uring instance created in postmaster shared memory, allowing zero-copy submission queue / completion queue communication with the kernel.

The new `pg_aios` system view exposes in-flight I/O requests; `effective_io_concurrency`'s default jumped from 1 (PG17) to 16 (PG18) reflecting the AIO subsystem's capability to actually use it. Cybertec's benchmark on a 1 TB pgbench dataset showed `io_uring` beating `sync` by ~800 MB/s and worker by a smaller margin (https://www.cybertec-postgresql.com/en/postgresql-18-better-i-o-performance-with-aio/); pganalyze reported 2-3× cold-cache improvement for the worker and io_uring methods over sync (https://pganalyze.com/blog/postgres-18-async-io). Andres Freund's "The path to using AIO in postgres" talk (referenced by Microsoft's PG OSS team retrospective, https://techcommunity.microsoft.com/blog/adforpostgresql/microsoft-postgresql-oss-engine-team-reflecting-on-2024/4388700) traces the multi-year journey.

The PG18 release also includes related performance work: hash-join and GROUP BY memory-usage reductions (David Rowley, Jeff Davis); locking improvements for queries touching many relations (Tomas Vondra); page-freezing during normal vacuum (Melanie Plageman).

---

## 3. Deep-Dive Topics

### 3.1 Expression evaluation evolution

Pre-PG10: `ExecEvalExpr(ExprState *state, ExprContext *econtext, …)` was effectively a recursive interpreter walking the same `Expr` tree the planner emitted. Each tag (`T_FuncExpr`, `T_OpExpr`, `T_BoolExpr`, `T_Var`, `T_Const`, `T_Aggref`, `T_CaseExpr`, `T_CoerceViaIO`, `T_ScalarArrayOpExpr`, …) had a dedicated `ExecEval*` function, and per-tuple traversal incurred a switch + recursive call per node.

PG10's `b8d7f053`: at `ExecInitExpr`, the tree is "compiled" to an array of `ExprEvalStep` (`src/include/executor/execExpr.h`) — about a hundred opcodes. The interpreter `ExecInterpExpr` (`execExprInterp.c`) is one large dispatch loop using either GCC computed-goto (the `EEO_*` macros: `EEO_DISPATCH`, `EEO_NEXT`, `EEO_JUMP`) or a portable `switch` fallback (`EEOP_DONE` exits). Steps store offsets into a per-`ExprState` scratchpad rather than absolute pointers, enabling later JIT to store mutable state in LLVM `alloca` space. Andres explained the design in https://www.postgresql.org/message-id/20180124203616.3gx4vm45hpoijpw3@alap3.anarazel.de: "expression initialization just computes the size of required memory for all steps and puts *offsets* into that in the steps."

PG11's JIT (`src/backend/jit/llvm/llvmjit_expr.c`): each opcode is matched to an LLVM IR snippet, with constant fact such as "this `Var` reads attribute number `n` from the outer slot" baked in. Inlining of pg_proc bodies via pre-built `.bc` files in `$libdir/bitcode/postgres/` allows LLVM to fully resolve `int4pl`, `texteq`, etc. at JIT time. Reported speedups on TPC-H Q1: ~29% wall-clock vs PG10 (Citus benchmark); on Andres's TPC-H scale 5/10 measurements, expression-heavy queries reached ~2× over PG10 baseline (https://www.postgresql.org/message-id/20191023163849.sosqbfs5yenocez3@alap3.anarazel.de).

Subsequent improvements: the SQL/JSON work in PG15/16 stretched the opcode set further (`EEOP_JSONEXPR` family, `JsonBehavior` evaluation steps); ongoing 2024–2025 work by Andres Freund aims to split expression "compilation" (planner-time) from "instantiation" (per-execution, since prepared-statements re-execute), moving the steps to relative offsets and reusing a constant code template — described in https://www.postgresql.org/message-id/20191023163849.sosqbfs5yenocez3@alap3.anarazel.de and the ongoing pgsql-hackers "expression evaluation improvements" thread.

### 3.2 `TupleTableSlot` abstraction (PG12)

The pre-12 design baked all storage formats into one struct, paying a branch on every `slot_getattr` and limiting extensibility. The PG12 redesign (`tuptable.h`):

```c
typedef struct TupleTableSlot
{
    NodeTag           type;
    uint16            tts_flags;
    AttrNumber        tts_nvalid;
    const TupleTableSlotOps *const tts_ops;
    TupleDesc         tts_tupleDescriptor;
    Datum            *tts_values;
    bool             *tts_isnull;
    MemoryContext     tts_mcxt;
    ItemPointerData   tts_tid;
    Oid               tts_tableOid;
} TupleTableSlot;
```

Concrete slot types (e.g., `BufferHeapTupleTableSlot`) embed this and add storage-specific fields (`HeapTuple tuple`, `Buffer buffer`, `uint32 off` for the deform cursor). Static const `TupleTableSlotOps` instances — `TTSOpsHeapTuple`, `TTSOpsBufferHeapTuple`, `TTSOpsMinimalTuple`, `TTSOpsVirtual` — provide the vtable. Inline thin wrappers in `executor/tuptable.h` (`ExecClearTuple`, `ExecMaterializeSlot`, `slot_getsomeattrs`) call through the vtable; counter-intuitively, this *improved* branch-prediction accuracy (per Andres's measurements, since each callsite resolves to one specific implementation in a hot loop rather than a switch) (https://www.postgresql.org/message-id/20180220224318.gw4oe5jadhpmcdnm@alap3.anarazel.de).

The motivation was twofold: the in-tree TableAM (zheap, etc.) needed slots that could hold native tuples without conversion overhead, and the plan was always to leave the door open for vectorized execution where a slot might hold many rows column-wise. The latter is still future work — the 2025 PGConf.dev unconference notes (https://wiki.postgresql.org/wiki/PGConf.dev_2025_Developer_Unconference) explicitly discuss adding `ExecProcNodeBatch()` alongside `ExecProcNode()` and a `TupleBatch` abstraction; the existing slot vtable is considered a prerequisite.

### 3.3 Parallel query infrastructure

Layers (from bottom up):

1. **DSM** (`src/backend/storage/ipc/dsm.c`) — variable-size shared memory segments, 9.4.
2. **Dynamic background workers** (`src/backend/postmaster/bgworker.c`) — 9.4.
3. **Shared-memory tuple queues** (`src/backend/executor/tqueue.c`) — single-producer, single-consumer.
4. **Parallel context** (`src/backend/access/transam/parallel.c`) — set up by `Gather`/`GatherMerge`.
5. **DSA** (Dynamic Shared Areas, `src/backend/utils/mmgr/dsa.c`, Thomas Munro, PG10) — `malloc`/`free` over expandable DSM segments, used by Parallel Hash.
6. **Barrier** (`src/backend/storage/ipc/barrier.c`) and **ConditionVariable** (`src/backend/storage/lmgr/condition_variable.c`) — used by Parallel Hash for batch coordination.
7. **SharedTuplestore** (`src/backend/utils/sort/sharedtuplestore.c`) — multi-writer, multi-reader spill files for Parallel Hash batches.

Executor-visible parallel-aware nodes (cumulative): 9.6 — `Parallel Seq Scan`, `Gather`, partial/final `Aggregate`. 10 — `Gather Merge`, `Parallel Index Scan`, `Parallel Index-Only Scan`, `Parallel Bitmap Heap Scan`, `Parallel Merge Join`. 11 — `Parallel Hash Join`, `Parallel Append`. 16 — `Parallel Right/Full Hash Join`, parallel `string_agg`/`array_agg`. The Parallel Query wiki (https://wiki.postgresql.org/wiki/Parallel_Query) is the consolidated tracker.

PostgreSQL still uses processes (one parallel worker = one process) rather than threads — Thomas Munro's PG11 talk slide deck explicitly noted: "Currently, PostgreSQL uses one process per parallel worker. … We plan on converting PostgreSQL to use POSIX and Windows threads. *Actual plans may vary." Threading remains a long-standing item on the wiki Multithreading page; it has not yet landed.

Trade-offs called out in production: per-worker `work_mem` allocations (effective work_mem is `work_mem × workers + leader`), planning-cost noise from `parallel_setup_cost` and `parallel_tuple_cost`, and the leader-as-also-a-worker design (`parallel_leader_participation`).

### 3.4 Hash Join improvements (Parallel-aware Hash, PG11)

Pre-11 parallel hash join: each worker built a private copy of the inner hash table, then probed in parallel against the partial outer. Acceptable for small inner sides, but wasteful for large ones and forced the build to be effectively serial in cost.

Thomas Munro's PG11 work changed this dramatically (`src/backend/executor/nodeHash.c`, `nodeHashjoin.c`):

- The hash table itself moves to DSA-allocated shared memory.
- A `Barrier` sequences the build, probe, and (for multi-batch) batch-rotation phases. All workers participate in `MultiExecParallelHash` (each scanning its share of the inner side) before any worker enters the probe phase.
- For multi-batch joins, batches are processed *in parallel* (one batch per worker at a time, rather than all workers ganging up on each batch sequentially). The `SharedTuplestore` provides the spill format; each batch has separate shared inner and outer tuplestores.
- `ExecChooseHashTableSize` underestimates batch count because it doesn't model the 32 KB DSA chunk overhead, sometimes forcing extra batch increases at runtime — this is a known follow-up item (https://wiki.postgresql.org/wiki/Parallel_Hash).

Performance: on a TPC-H scale 30 GB join `lineitem ⨝ orders`, the speedup over PG10's serial-build parallel-probe scales near-linearly with cores up to disk bandwidth limits.

### 3.5 Sort and aggregate improvements

#### HashAgg spilling (PG13)

`nodeAgg.c` grew an "in-memory + spill" strategy (Jeff Davis, `1f39bce021`). On `work_mem` exhaustion, currently-incomplete groups are partitioned by hash prefix into spill files (using `LogicalTape`), and the executor continues finalizing in-memory groups; spilled partitions are processed iteratively, possibly recursively. The cost model in `costsize.c` learned to predict this; `enable_hashagg_disk` originally let users opt out (later collapsed into the standard `enable_hashagg`). A perf regression in classic in-memory HashAgg was found post-commit (LookupTupleHashEntryHash pipeline stall + unnecessary attribute trimming) and addressed in 13.x point releases.

#### Incremental Sort (PG13/14/16)

Already covered above (§2.11.2); subsequent extensions:
- PG14 (Tomas Vondra) — incremental sort for window functions.
- PG16 (David Rowley, ba3e76cc57) — incremental sort considered at additional planner places (DISTINCT, Gather Merge, presorted aggregates).
- PG17 (Miroslav Bendik) — GiST/SP-GiST inputs.

There have been a few notable post-commit issues — a planner bug around Gather + incremental sort interaction (https://www.postgresql.org/message-id/20201001220822.rwwxajwzobljgqwz@development) and intra-query memory leaks during rescan (fixed in 13.12).

### 3.6 Memoize (PG14)

Already covered (§2.12.1). Implementation specifics: `nodeMemoize.c` uses `simplehash.h` (the Andres Freund inline-template hash table) keyed on the `MemoizeKey` (the parameter values), with values being `MemoizeEntry` structs that own a `Tuplestore`. Two cache modes: *logical* (default, hash on values using the appropriate `=` operator) and *binary* (memcmp on the raw datum bytes — used only when types are `TYPCATEGORY_PSEUDOTYPE` or otherwise cannot use a hash equality op). LRU eviction, controlled cache size (an estimate of `work_mem` divided across nested loops). EXPLAIN ANALYZE shows hits/misses/evictions/overflows and peak memory, which are the right diagnostics for tuning.

### 3.7 Partition handling

- **Static planner-time pruning** (PG10 `constraint_exclusion`-based, PG11 dedicated `partprune.c`).
- **Runtime pruning** (PG11, §2.9.4) — `execPartition.c`; pruning at executor startup (init-time params) and per-rescan (exec-time params); never-executed partitions show "(never executed)" in EXPLAIN ANALYZE.
- **Partitionwise join** (PG10) — when partitioning schemes match, joins push down to corresponding partition pairs.
- **Partitionwise aggregate** (PG11/12) — same idea for grouping.
- **Subplan map** infrastructure (`execPartition.c`) translates partition IDs → `Append`/`MergeAppend`/`ModifyTable` subplan indices, the key data structure that makes runtime pruning possible.
- **Default partition** (PG11), **UPDATE row movement across partitions** (PG11, Amit Khandekar, splitting an UPDATE that violates partition constraint into DELETE+INSERT), **CREATE INDEX on partitioned table** (PG11, Álvaro Herrera, with partition-index matching to avoid re-scanning) — Álvaro's overview at https://www.enterprisedb.com/blog/partitioning-improvements-postgresql-11.

### 3.8 Asynchronous Append (PG14)

Already covered (§2.12.2). The FDW callback additions (in `fdwhandler.h`):

```c
bool       IsForeignPathAsyncCapable(ForeignPath *path);
void       ForeignAsyncRequest(AsyncRequest *areq);
void       ForeignAsyncConfigureWait(AsyncRequest *areq);
void       ForeignAsyncNotify(AsyncRequest *areq);
```

`postgres_fdw` issues queries with `PQsendQuery` and registers the `PGconn`'s socket with `WaitEventSet`; when readable, it consumes a row and signals the parent `Append`. Multiple foreign tables on the same `PGconn` are handled via per-connection tracking (otherwise tuples would interleave and corrupt the stream). The infrastructure is general enough to be a starting point for async `CustomScan`, but at the time of writing (May 2026), no in-tree consumer beyond `postgres_fdw` exists; an extension proposal "asynchronous execution support for Custom Scan" by KaiGai Kohei has cycled through commitfests since 2022 without commit (https://commitfest.postgresql.org/patch/3813/).

### 3.9 AIO and `read_stream` (PG17/18)

The `read_stream` API (`src/include/storage/read_stream.h`, `src/backend/storage/aio/read_stream.c`) accepts a callback that returns the next desired `BlockNumber`, plus `flags` such as `READ_STREAM_SEQUENTIAL`, `READ_STREAM_USE_BATCHING`. The implementation maintains a sliding window of block numbers, calls into the buffer manager with vectored `StartReadBuffers`/`WaitReadBuffers`, and in PG18 dispatches to one of the AIO providers.

Executor consumers (PG17 and 18):

- **`nodeSeqscan.c`** — `heap_beginscan`/`heap_getnextslot` use `table_scan_get_blocknum` style streaming under the hood (`src/backend/access/heap/heapam.c`).
- **`nodeBitmapHeapscan.c`** — converted in PG17/18 to drive `read_stream` from the TID bitmap iterator (Melanie Plageman). This is fundamentally what enabled the PG18 AIO benefits for BHS.
- **VACUUM** and **ANALYZE** — Thomas Munro's "Use streaming read API in ANALYZE" (https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg178605.html).
- **BRIN** — streaming scans for BRIN summarization.

The PG18 AIO subsystem, conceptually, presents the same `read_stream` interface to consumers but the underlying I/O is performed asynchronously: `worker` mode hands off to dedicated I/O workers (`io worker N` processes); `io_uring` mode uses per-backend rings created by postmaster. The wait-and-completion model uses `pgaio_io_get`/`pgaio_io_wait` (in `src/backend/storage/aio/`). credativ's deep dive (https://www.credativ.de/en/blog/postgresql-en/postgresql-18-asynchronous-disk-i-o-deep-dive-into-implementation/) covers the in-memory data structures.

Important caveats: AIO in 18 is **read-only** (no async writes); some consumers still fall back to sync (extensions issuing reads through the buffer manager get the benefits transparently if they use the read_stream API, otherwise not); io_uring availability depends on container/seccomp policy (Google reported 60% of 2022 Linux kernel CVEs touched io_uring, which has caused some hosts to disable it).

### 3.10 `CustomScan` and extensibility

Already discussed (§2.6). Beyond the original `CustomScan` (replaceable scan/join), the executor now offers multiple extension points:

- **Planner hooks** — `add_scan_path_hook`, `add_join_path_hook` (for CustomScan); `set_rel_pathlist_hook`, `set_join_pathlist_hook` (general).
- **Executor hooks** — `ExecutorStart_hook`, `ExecutorRun_hook`, `ExecutorFinish_hook`, `ExecutorEnd_hook` (used by `pg_stat_statements`, `auto_explain`, `pg_qualstats`).
- **TableAM** (PG12) — pluggable table storage.
- **IndexAM** — pre-existing.
- **JIT provider** (PG11) — `jit_provider` GUC, `JitProviderCallbacks`.
- **FDW** — `FdwRoutine` is the granddaddy, since 9.1.

### 3.11 Plan caching, ExecutorStart/Run/Finish, generic vs custom plans

`src/backend/utils/cache/plancache.c` caches `PlannedStmt` for prepared statements, parameterized via `Param` placeholders. After 5 executions with custom (per-parameter-values) plans, the planner compares costs to a generic plan; if the generic is competitive, subsequent executions reuse the generic plan, avoiding planning overhead. The executor itself doesn't know or care about this; it gets a `PlannedStmt`, builds a `QueryDesc` and `EState`, and runs the lifecycle:

```
ExecutorStart(QueryDesc *queryDesc, int eflags)
  - InitPlan: build PlanState tree via ExecInitNode
  - eflags include EXEC_FLAG_EXPLAIN_ONLY, EXEC_FLAG_REWIND, EXEC_FLAG_BACKWARD,
    EXEC_FLAG_MARK, EXEC_FLAG_SKIP_TRIGGERS
ExecutorRun(QueryDesc, ScanDirection, count, execute_once)
  - ExecutePlan loop: ExecProcNode on top, send tuple to DestReceiver
ExecutorFinish(QueryDesc)
  - ExecPostprocessPlan: run any pending ModifyTable subplans (e.g. SQL function calls)
  - AfterTriggerEndQuery
ExecutorEnd(QueryDesc)
  - ExecEndNode: close relations, drop pins
  - FreeExecutorState
```

Modules like `pg_stat_statements` wrap these hooks to get pre/post timing.

---

## 4. Performance and Trade-Offs Summary

| Change | Reported gain (workload) | Trade-off |
|---|---|---|
| Step-machine expr eval (PG10) | 2× on TPC-H Q1 expression-heavy queries (Andres Freund) | More complex init, slightly larger ExprState |
| `ExecProcNode` function pointer (PG10) | Small speedup; correctness for stack-depth check | Indirect call (cheap on modern CPUs) |
| LLVM JIT (PG11) | ~29% TPC-H Q1 (Citus); up to 37% earlier prototype | Planning + JIT overhead; OLTP regressions when costed wrong |
| Parallel Hash (PG11) | Near-linear scaling with cores up to disk BW | DSA chunk overhead; extra batches sometimes |
| Runtime partition pruning (PG11) | Orders of magnitude on partitioned OLTP | Per-rescan pruning cost for parameterized loops |
| Slot redesign (PG12) | Branch-prediction improvement, ~neutral throughput | Source-level breakage for FDWs |
| HashAgg spilling (PG13) | Bounds memory usage; eliminates OOM on misestimates | Initial in-mem regression (fixed in 13.x) |
| Incremental Sort (PG13) | Often 2–10× when prefix is presorted, especially with LIMIT | Bad costing → can be slower than full sort (16.x had bug reports) |
| Memoize (PG14) | ~10× to 1000× on high-duplicate nested loops | Memory; bad costing on volatile parameterizations |
| Async Append (PG14) | ~Nx for sharded postgres_fdw, N = #foreign servers | Only postgres_fdw consumer in tree |
| Parallel Right/Full hash join (PG16) | Outer-join queries newly parallel | None significant |
| Streaming I/O (PG17) | Linux preadv combining; better cache prefetch | Subtle behavior changes near ring/block boundaries |
| AIO subsystem (PG18) | 2-3× cold-cache reads (worker/io_uring vs sync) | io_uring security history; worker context-switch overhead |

---

## 5. Synthesis: Trajectory

Over three decades, PostgreSQL's executor has evolved along several roughly orthogonal axes, while preserving the Volcano contract end-to-end. The trajectory is best summarized as:

1. **Functional completeness (1995–2010).** The executor accumulated nodes for SQL features as the language evolved: subqueries (`SubqueryScan`, InitPlan), CTEs and recursion (`CteScan`, `RecursiveUnion`, `WorkTableScan` in 8.4), window functions (`WindowAgg`, 8.4), index-only scans (9.2), upserts (9.5), grouping sets (9.5), MERGE (15). This phase was almost entirely planner-output-driven and added no fundamental architectural change.

2. **Bitmap and prefetch (8.1 onwards).** Bitmap scans introduced the first non-tuple-at-a-time I/O pattern in the executor. The page-oriented work that bitmap scans pioneered turned out to be foundational for `effective_io_concurrency` and for the eventual streaming/AIO work twenty years later.

3. **Parallelism (9.4–11+).** Robert Haas's multi-cycle program added DSM, dynamic bgworkers, shared queues, parallel-aware nodes, parallel hash, parallel append, parallel-aware right/full joins. The Volcano contract was preserved at the leader; the workers each run their own Volcano subtrees and tuples are shipped via shm queues. PostgreSQL accepted the "process per worker" model (and its shared-memory tax) as the price of preserving the existing memory model and extension ABI.

4. **Executor hot-path rewrite (10–12).** Andres Freund's "slim down the executor" arc compressed the per-tuple cost dramatically. The step-machine interpreter (PG10), function-pointer ExecProcNode (PG10), JIT (PG11), and the slim-slot redesign (PG12) collectively shrank the per-row CPU overhead by roughly 2–4× depending on workload. This rewrite is the single most consequential change in the executor's history; without it, JIT and TableAM would not have been feasible. As an inadvertent side effect, the move to flat opcode arrays prefigured the eventual move to vectorized execution that, as of 18, is still being designed.

5. **Smarter tactical nodes (13–16).** HashAgg spilling, Incremental Sort, Memoize, parallel right/full hash, async append, MERGE — the executor in this period accumulated tactical nodes that fixed long-standing planner-vs-reality mismatches (HashAgg OOM, parameterized nested loop redundancy, partitioned shard fan-out).

6. **I/O modernization (17–18).** The `read_stream`/AIO program is the first systemic re-think of how the executor talks to storage since the introduction of the buffer manager. By collapsing the API surface to "tell me which blocks to read; I'll figure out batching, prefetch, and parallelism," the executor finally gets to exploit kernel features (preadv, io_uring) that have been available for years. As of 18, AIO is read-only and Linux-favored, but the architecture cleanly extends to writes and other platforms.

What PostgreSQL's executor is *not* (yet) in 2026:
- **Vectorized.** It is still tuple-at-a-time. Discussions of `ExecProcNodeBatch()` and `TupleBatch` are active in 2025–2026 (https://wiki.postgresql.org/wiki/PGConf.dev_2025_Developer_Unconference), but no commits have landed.
- **Threaded.** Still process-per-worker.
- **Push-based.** Still pull-based Volcano.

What it *is* in 2026: a JIT-compiled, parallel, AIO-aware, extensibly-pluggable, per-node-step-machine, single-threaded, tuple-at-a-time, mostly-Volcano executor — broadly comparable in raw throughput to the historical commercial competition for which it was once seen as a slow alternative, with most remaining gaps in raw analytic throughput attributable to the absence of vectorization rather than to any specific weakness of the design.

The architectural durability is striking: the comments in `src/backend/executor/execProcnode.c` describing the DEPT/EMP example trace back to Berkeley POSTGRES code from the late 1980s, and yet today's PG18 executor running parallel hash joins with io_uring asynchronous reads through a vectorized read-stream is still, recognizably, the same machine — pulling tuples one at a time out of a tree of state nodes. PostgreSQL's rare combination of architectural conservatism with steady incremental modernization is, in an important sense, the executor's story.

---

## 6. Selected Source-Tree and Commit Pointers

For convenience, here is a consolidated set of links to authoritative primary sources, suitable for further reading:

**Core executor files (HEAD):**
- `src/backend/executor/execMain.c` — https://github.com/postgres/postgres/blob/master/src/backend/executor/execMain.c
- `src/backend/executor/execProcnode.c` — https://github.com/postgres/postgres/blob/master/src/backend/executor/execProcnode.c
- `src/backend/executor/execExpr.c` — https://github.com/postgres/postgres/blob/master/src/backend/executor/execExpr.c
- `src/backend/executor/execExprInterp.c` — https://github.com/postgres/postgres/blob/master/src/backend/executor/execExprInterp.c
- `src/backend/executor/execTuples.c` — https://github.com/postgres/postgres/blob/master/src/backend/executor/execTuples.c
- `src/backend/executor/nodeAgg.c` — https://github.com/postgres/postgres/blob/master/src/backend/executor/nodeAgg.c
- `src/backend/executor/nodeHashjoin.c` — https://github.com/postgres/postgres/blob/master/src/backend/executor/nodeHashjoin.c
- `src/backend/executor/nodeMemoize.c`, `nodeIncrementalSort.c`, `nodeGather.c`, `nodeGatherMerge.c`, `nodeAppend.c`, `nodeBitmapHeapscan.c`, `execMerge.c`, `execPartition.c` — same path prefix.
- `src/backend/executor/README` — https://github.com/postgres/postgres/blob/master/src/backend/executor/README
- `src/include/executor/tuptable.h` — https://github.com/postgres/postgres/blob/master/src/include/executor/tuptable.h
- `src/backend/storage/aio/read_stream.c` — for PG17/18 AIO.

**Per-version trees:** substitute the branch into `https://git.postgresql.org/gitweb/?p=postgresql.git;a=tree;f=src/backend/executor;hb=…` (e.g., `REL_18_0`, `REL_17_STABLE`, `REL_12_STABLE`, `REL9_6_STABLE`, `REL8_4_STABLE`).

**Major commits (links to commit pages):**
- `b8d7f053c5c2bf2a7e8734fe3327f6a8bc711755` — step-machine expression evaluator (PG10).
- `178f2d560d` — ExecProcNode function pointer (PG10).
- `1804284042` — Parallel Hash (PG11).
- `ab72716778` — Parallel Append (PG11).
- `499be013de` — runtime partition pruning (PG11).
- `1a0586de36`, `4da597edf1` — slot type abstraction (PG12).
- `c2fe139c20` — TableAM API (PG12).
- `1f39bce021` — disk-based HashAgg (PG13).
- `d2d8a229bc` — Incremental Sort (PG13).
- `b6002a796d`, `83f4fcc65a` — Memoize / Result Cache rename (PG14).
- `27e1f14563` — Async Append for postgres_fdw (PG14).
- `7103ebb7aa` — MERGE (PG15).
- PG17 streaming-IO commits and PG18 AIO commits — see https://www.postgresql.org/docs/release/17.0/ and https://www.postgresql.org/docs/release/18.0/ for the linked-from-release-notes commit hashes.

**Release notes:** https://www.postgresql.org/docs/release/ (substitute version).

**Wiki:** Parallel Query (https://wiki.postgresql.org/wiki/Parallel_Query), CustomScanAPI (https://wiki.postgresql.org/wiki/CustomScanAPI), Parallel Hash (https://wiki.postgresql.org/wiki/Parallel_Hash), PG13 Open Items (https://wiki.postgresql.org/wiki/PostgreSQL_13_Open_Items), PGConf.dev 2025 Developer Unconference (https://wiki.postgresql.org/wiki/PGConf.dev_2025_Developer_Unconference).

**Key blog/talk references:**
- Robert Haas — http://rhaas.blogspot.com/ (parallel query series, "Braces Are Too Expensive").
- Thomas Munro — https://speakerdeck.com/macdice/parallelism-in-postgresql-11; Parallel Hash blog (https://www.enterprisedb.com/blog/parallel-hash-postgresql).
- Andres Freund — JIT FOSDEM 2018 (https://archive.fosdem.org/2018/schedule/event/jiting_postgresql_using_llvm/); the path-to-AIO talk (Microsoft retrospective links).
- Citus / pganalyze / Cybertec performance posts — covered inline above.
- ISP-RAS PGCon 2017 (https://www.pgcon.org/2017/schedule/attachments/467_PGCon%202017-05-26%2015-00%20ISPRAS%20Dynamic%20Compilation%20of%20SQL%20Queries%20in%20PostgreSQL%20Using%20LLVM%20JIT.pdf) — early LLVM JIT prototype that informed the eventual PG11 design.