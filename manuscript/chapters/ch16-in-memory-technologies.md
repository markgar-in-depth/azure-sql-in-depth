# Chapter 16: In-Memory Technologies

Your database has a table under extreme insert pressure. Every row passes through latch acquisition, buffer pool management, lock escalation, and transaction log writes — the same machinery that handles a 10-row lookup. That machinery is battle-tested and general-purpose, but it wasn't designed for this level of throughput.

In-memory technologies let you bypass those bottlenecks entirely — faster transactions, faster analytics, or both at once.

Azure SQL supports two complementary in-memory technologies: **In-Memory OLTP** for high-throughput transactional workloads, and **columnstore indexes** for analytics acceleration. Both shipped in SQL Server years ago (columnstore in 2012, In-Memory OLTP in 2014), and Azure SQL Database, Azure SQL Managed Instance, and SQL Server on Azure VMs share the same implementation. This chapter covers how each technology works, when to use it, and how to monitor it in production.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

## In-Memory OLTP

In-Memory OLTP (internally codenamed "Hekaton," informally called XTP for "Extreme Transaction Processing") eliminates the disk-based storage engine's overhead entirely. Data lives in memory in optimized structures. Queries can be natively compiled to machine code. Latch-free algorithms replace traditional lock-based concurrency. The result: order-of-magnitude improvements in transaction throughput for workloads that hit the engine's hot path.

### Memory-Optimized Tables

The foundation of In-Memory OLTP is the **memory-optimized table**. Unlike traditional disk-based tables where pages shuttle between the buffer pool and disk, memory-optimized tables keep all rows in memory at all times, organized as hash or range indexes rather than B-trees.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

There are two durability modes:

- **Durable tables** (`SCHEMA_AND_DATA`) persist rows across restarts. The engine writes transaction log records for recovery, but the data path during normal operation is entirely in-memory. These behave like regular tables from an application perspective — your data survives failovers and reboots.
- **Non-durable tables** (`SCHEMA_ONLY`) preserve only the table schema. Rows vanish on restart. These are ideal for staging data, replacing temp tables, or caching intermediate results where persistence doesn't matter but speed does.

Creating a memory-optimized table looks like standard DDL with a few additions:

```sql
CREATE TABLE dbo.SensorReadings
(
    ReadingId   bigint IDENTITY NOT NULL
                PRIMARY KEY NONCLUSTERED HASH WITH (BUCKET_COUNT = 1000000),
    SensorId    int          NOT NULL,
    ReadingTime datetime2(3) NOT NULL,
    Value       float        NOT NULL,

    INDEX ix_sensor_time NONCLUSTERED (SensorId, ReadingTime)
)
WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);
```

A few things to notice. The primary key uses a **hash index** — you pick a bucket count roughly equal to the number of unique key values you expect. Hash indexes give O(1) point lookups but don't support range scans. The secondary index is a **nonclustered range index** (internally a Bw-tree), which does support ordered scans.

Memory-optimized tables require at least one index. In Azure SQL Database there's no specific cap on the number of indexes per memory-optimized table (the engine-wide maximum is 999).
<!-- TODO: source needed for "engine-wide maximum is 999" -->

> **Gotcha:** Hash index bucket counts matter. Too few buckets means long chains that degrade point-lookup performance. Too many wastes memory. Aim for a bucket count between 1× and 2× the expected number of distinct key values. You can't change the bucket count without recreating the index.

### Architecture Under the Hood

Traditional tables use page-based storage with latches to protect concurrent access to the same page. Memory-optimized tables use a completely different approach: each row is a separate memory object, and all rows are connected through index structures that use lock-free, compare-and-swap (CAS) operations for concurrency.

Versioning is built in. Every write creates a new row version with begin and end timestamps. Readers see a consistent snapshot without acquiring locks. Writers validate at commit time — if two transactions modify the same row, the later commit detects the conflict and retries. This is **optimistic multi-version concurrency control**, and it's why In-Memory OLTP eliminates latch contention entirely.

For durable tables, the engine writes log records to a transaction log stream, which is then persisted to checkpoint file pairs (data files and delta files) on storage. This is the recovery mechanism — on restart, the engine replays the checkpoint files and any remaining log to rebuild the in-memory state.

> **Note:** In-Memory OLTP data cannot be offloaded to disk. The entire dataset for memory-optimized tables must fit in the allocated In-Memory OLTP storage. This is fundamentally different from the buffer pool, which pages data in and out.

### Natively Compiled Stored Procedures

Memory-optimized tables can be queried with regular interpreted T-SQL — you don't have to change your application to start using them. But for maximum throughput, you can write **natively compiled stored procedures** that compile T-SQL directly to machine code (DLL) at creation time.

```sql
CREATE PROCEDURE dbo.InsertSensorReading
    @SensorId    int,
    @ReadingTime datetime2(3),
    @Value       float
WITH NATIVE_COMPILATION, SCHEMABINDING
AS
BEGIN ATOMIC WITH
(
    TRANSACTION ISOLATION LEVEL = SNAPSHOT,
    LANGUAGE = N'us_english'
)
    INSERT INTO dbo.SensorReadings (SensorId, ReadingTime, Value)
    VALUES (@SensorId, @ReadingTime, @Value);
END;
```
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-configure.md -->

The key differences from regular procedures:

- `NATIVE_COMPILATION` tells the engine to compile to native code.
- `SCHEMABINDING` is required — the procedure is bound to the table schema.
- The body must be a single `ATOMIC` block. No explicit `BEGIN TRANSACTION` or `ROLLBACK`. The atomic block handles transaction management automatically. If a business rule violation is detected, use `THROW` to abort.
- Supported isolation levels are `SNAPSHOT`, `REPEATABLE READ`, and `SERIALIZABLE`.

Natively compiled procedures avoid the interpreter overhead of regular T-SQL execution. For high-frequency, low-complexity operations — inserts, lookups, simple updates — the difference is dramatic. Microsoft's benchmarks show up to 9× throughput improvement on a simplistic OLTP workload when combining memory-optimized tables with natively compiled procedures.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-sample.md -->

> **Gotcha:** Natively compiled procedures support a subset of T-SQL. You can't use `MERGE`, CTEs, subqueries in some contexts, or reference disk-based tables directly. Check the supported surface area before committing to native compilation for complex logic. Natively compiled **inline table-valued functions** follow the same rules and provide the same compilation benefit for reusable query fragments.

### The Memory Optimization Advisor

You don't have to figure out migration candidates on your own. SSMS includes a **Transaction Performance Analysis Overview** report that analyzes your workload and identifies tables and procedures that would benefit from In-Memory OLTP. Run it against a database with an active workload:

1. In Object Explorer, right-click your database.
2. Select **Reports** → **Standard Reports** → **Transaction Performance Analysis Overview**.

For individual tables, the **Memory Optimization Advisor** (right-click a table → **Memory Optimization Advisor**) validates whether the table's schema is compatible with memory-optimized tables and flags unsupported features — things like computed columns with certain expressions, foreign keys referencing disk-based tables, or IDENTITY columns with non-default seeds. If the table passes validation, the advisor can generate the migration script for you.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-configure.md -->

### Storage Caps and Resource Governance

In-Memory OLTP isn't available everywhere. In Azure SQL Database, it requires the **Premium** (DTU) or **Business Critical** (vCore) service tier. The Hyperscale tier supports a subset of In-Memory OLTP objects — memory-optimized table types, table variables, and natively compiled modules — but **not** durable or non-durable memory-optimized tables. General Purpose, Standard, and Basic tiers don't support it at all.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md, azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale.md -->

In Azure SQL Managed Instance, In-Memory OLTP is available in the **Business Critical** tier only.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/in-memory-oltp-in-azure-sql-managed-instance/in-memory-oltp-overview.md -->

Each service objective has a hard cap on In-Memory OLTP storage — the total memory that memory-optimized tables, table variables, and their indexes can consume. Here's what that looks like across the key tiers:

**Azure SQL Database — Premium (DTU)**

| SLO | XTP storage (GB) |
|---|---|
| P1 | 1 |
| P2 | 2 |
| P4 | 4 |
| P6 | 8 |
| P11 | 14 |
| P15 | 32 |

<!-- Source: azure-sql-database-sql-db/concepts/resource-limits/single-database-resources/resource-limits-dtu-single-databases.md -->

**Azure SQL Database — Business Critical (vCore, Gen5)**

| vCores | XTP storage (GB) |
|---|---|
| 4 | 3.14 |
| 8 | 6.28 |
| 16 | 15.77 |
| 32 | 37.94 |
| 80 | 131.64 |
| 128 | 227.02 |

<!-- Source: azure-sql-database-sql-db/concepts/resource-limits/single-database-resources/resource-limits-vcore-single-databases.md -->

**Azure SQL Managed Instance — Business Critical**

*Gen5*

| vCores | XTP storage (GB) |
|---|---|
| 4 | 3.14 |
| 8 | 6.28 |
| 16 | 15.77 |
| 32 | 37.94 |
| 64 | 99.9 |
| 80 | 131.68 |

*Premium-series*

| vCores | XTP storage (GB) |
|---|---|
| 4 | 4.39 |
| 8 | 8.79 |
| 16 | 22.06 |
| 32 | 53.09 |
| 64 | 139.82 |
| 80 | 184.30 |

*Memory-optimized premium-series*

| vCores | XTP storage (GB) |
|---|---|
| 4 | 8.79 |
| 8 | 22.06 |
| 16 | 57.58 |
| 32 | 128.61 |
| 64 | 288.61 |
| 80 | 288.61 |

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/architecture/resource-limits.md -->

These caps count active user data rows, indexes on memory-optimized tables, and operational overhead from `ALTER TABLE` operations. Old row versions from MVCC don't count against the cap.

> **Important:** If you hit the In-Memory OLTP storage cap, inserts and updates fail with error 41823 (single databases) or 41840 (elastic pools). The active transaction aborts. Your options are to delete data from memory-optimized tables or scale up to a higher service objective. In rare cases these errors are transient — build retry logic into your application.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-monitor-space.md -->

In elastic pools, In-Memory OLTP storage is shared across all databases in the pool. One database's heavy usage can starve others. Use `Max eDTU` or `Max vCore` per database to cap individual consumption, and `Min eDTU` or `Min vCore` to guarantee minimums.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

> **Warning:** You can't scale a database that contains In-Memory OLTP objects down to General Purpose, Standard, or Basic. You must drop all memory-optimized tables, table types, and natively compiled modules first. Even after dropping them, you can't restore to a non-OLTP tier from a backup taken before the objects were removed — you'd need to scale to General Purpose first, then back to Business Critical to reset the backup chain.

## Columnstore Indexes

If In-Memory OLTP is about making transactions faster, columnstore indexes are about making analytics faster. A columnstore index stores data column-by-column instead of row-by-row, enabling massive compression and batch-mode query execution that can accelerate analytical queries by up to 10× over traditional row-oriented storage.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

### Clustered vs. Nonclustered Columnstore

There are two types, and the choice depends on your workload pattern:

**Clustered columnstore indexes** reorganize the entire table into columnar format. Every row lives in the columnstore. This gives you the full compression benefit — 10× to 100× reduction in data size is common — and the fastest analytical query performance. Use clustered columnstore for dedicated analytics tables, data warehouse fact tables, and large historical tables where row-level lookups are rare.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

> **Tip:** Bulk loads of 100,000+ rows compress directly into columnar segments before hitting storage. For maximum columnstore efficiency, batch your inserts above this threshold.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

```sql
CREATE TABLE dbo.SalesHistory
(
    SaleDate    date         NOT NULL,
    ProductId   int          NOT NULL,
    CustomerId  int          NOT NULL,
    Quantity    int          NOT NULL,
    Amount      decimal(18,2) NOT NULL
);

CREATE CLUSTERED COLUMNSTORE INDEX cci_SalesHistory
ON dbo.SalesHistory;
```

**Nonclustered columnstore indexes** add a columnstore structure alongside the existing rowstore table. The base table stays as-is — your OLTP workload keeps running against the B-tree rowstore with no impact. The columnstore index provides a secondary path for analytical queries. The query optimizer automatically chooses rowstore or columnstore access based on the query pattern.

```sql
-- Add analytics capability to an existing OLTP table
CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_Orders
ON dbo.Orders (OrderDate, ProductId, CustomerId, Quantity, Amount);
```

This is the foundation of **HTAP (Hybrid Transactional/Analytical Processing)** — running analytics directly against your operational database without ETL pipelines or separate data warehouses. More on that shortly.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

> **Tip:** Nonclustered columnstore indexes don't reduce the base table's storage — the rowstore data stays intact. But the columnstore index itself is typically much smaller than an equivalent set of B-tree nonclustered indexes, so you may actually save space overall by replacing multiple B-tree indexes with a single columnstore index.

### Batch-Mode Execution

The real power of columnstore indexes isn't just the storage format — it's **batch-mode execution**. Traditional row-mode execution processes one row at a time through each operator in the query plan. Batch mode processes rows in batches of hundreds at a time, with each batch stored in a columnar format in memory. This allows SIMD (Single Instruction, Multiple Data) vectorized operations on modern CPUs and dramatically reduces per-row overhead.

Batch mode is automatically enabled for queries that touch columnstore indexes. Starting with compatibility level 150 (SQL Server 2019 / Azure SQL Database), **batch mode on rowstore** is also available — the optimizer can choose batch-mode execution even for queries that don't involve columnstore indexes, as long as the workload characteristics suggest it would help.

This means you get some analytics acceleration benefits just by being on a modern compatibility level.

For a sense of the impact: Microsoft's benchmark on the `AdventureWorksLT` sample database showed 9× performance improvement at the P2 service objective and 57× at P15 when comparing a clustered columnstore index against a page-compressed B-tree for the same analytical query.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-sample.md -->

### HTAP: Operational Analytics Without ETL

The traditional approach to analytics is well-known: extract data from your OLTP database, transform it, load it into a warehouse, then run reports. It's reliable, but it introduces latency — your analytics are always stale by the time the ETL runs.

HTAP eliminates that latency by running analytics directly against the live operational database. The approach in Azure SQL is straightforward: add a nonclustered columnstore index to your OLTP tables. Transactional workloads continue operating against the rowstore. Analytical queries run against the columnstore index. The optimizer routes each query to the appropriate path automatically.

For the most demanding scenarios, you can combine memory-optimized tables with columnstore indexes. A memory-optimized table with a memory-optimized clustered columnstore index gives you both fast in-memory transactions and fast analytical queries on the same data — true real-time operational analytics.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

> **Gotcha:** HTAP isn't free. The nonclustered columnstore index adds write overhead — every insert, update, or delete on the base table must also update the columnstore's delta store. For write-heavy OLTP workloads, test the impact before deploying. The delta store (a rowstore structure that stages changes before they're compressed into columnstore segments) can also grow if the tuple mover can't keep up, degrading analytics performance.

### Columnstore Tier Requirements

Columnstore indexes have broader availability than In-Memory OLTP:

- **Azure SQL Database (vCore):** Supported in all service tiers including General Purpose, Business Critical, and Hyperscale.
- **Azure SQL Database (DTU):** Supported in Standard S3 and above, and all Premium tiers. Not available in Basic or Standard S0–S2.
- **Azure SQL Managed Instance:** Supported in all service tiers.
<!-- Source: azure-sql-database-sql-db/concepts/purchasing-models/service-tiers-dtu.md, azure-sql-managed-instance-sql-mi/concepts/in-memory-oltp-in-azure-sql-managed-instance/in-memory-oltp-overview.md -->

Unlike In-Memory OLTP, columnstore indexes don't require data to fit in memory. The only cap on columnstore index size is the maximum database size for your service objective. Data that doesn't fit in memory spills to disk transparently.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

> **Warning:** If you scale a DTU database below S3, columnstore indexes stop working — but the impact depends on the type. **Nonclustered** columnstore indexes become invisible to the optimizer: the system still maintains the index on DML operations, but queries never use it. The base table remains fully accessible. **Clustered** columnstore indexes are worse — the entire table becomes unavailable. Drop clustered columnstore indexes and replace them with rowstore clustered indexes or heaps before scaling below S3.

## Monitoring In-Memory Workloads

In-memory technologies introduce monitoring surfaces that don't exist in traditional workloads. The standard DMVs for disk-based tables won't tell you much about memory-optimized table health or columnstore segment efficiency. You need XTP-specific tooling.

### XTP-Specific DMVs

The core DMV for memory-optimized table monitoring is `sys.dm_db_xtp_table_memory_stats`. It shows per-table memory consumption including row data, indexes, and system overhead:

```sql
SELECT
    object_name(object_id) AS table_name,
    memory_allocated_for_table_kb / 1024 AS table_mb,
    memory_allocated_for_indexes_kb / 1024 AS index_mb,
    memory_used_by_table_kb / 1024 AS used_mb
FROM sys.dm_db_xtp_table_memory_stats
WHERE object_id > 0;
```
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-monitor-space.md -->

For the overall XTP engine memory footprint, query the memory clerks:

```sql
SELECT
    [type],
    [name],
    memory_node_id,
    pages_kb / 1024 AS pages_mb
FROM sys.dm_os_memory_clerks
WHERE [type] LIKE '%xtp%';
```
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-monitor-space.md -->

The `MEMORYCLERK_XTP` clerk type accounts for all memory allocated to the In-Memory OLTP engine. You'll see entries per database (`DB_ID_N`) and default entries for the engine itself.

For out-of-memory events, check:

```sql
SELECT * FROM sys.dm_os_out_of_memory_events
ORDER BY event_time DESC;
```

### Memory Consumption Tracking

In the Azure portal, the **In-memory OLTP Storage percent** metric shows how close you are to the storage cap as a percentage. Set up an alert rule on this metric — you want to know when you're approaching the limit, not when you've hit it.

From T-SQL, the `xtp_storage_percent` column in `sys.dm_db_resource_stats` gives the same percentage:

```sql
SELECT
    end_time,
    xtp_storage_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-monitor-space.md -->

> **Tip:** Set an alert at 80% XTP storage utilization. Memory-optimized tables can't spill to disk, so once you hit 100%, writes fail immediately. Unlike disk storage where you might get graceful degradation, an XTP out-of-space error is a hard stop.

### XTP Wait Types

In-Memory OLTP introduces its own family of wait types, all prefixed with `WAIT_XTP_`. The most common ones you'll encounter in production:

| Wait type | What it means |
|---|---|
| `WAIT_XTP_OFFLINE_CKPT_NEW_LOG` | Checkpoint waiting for new log records |
| `WAIT_XTP_CKPT_CLOSE` | Checkpoint closing |
| `WAIT_XTP_RECOVERY` | Database recovery rebuilding in-memory state |
| `WAIT_XTP_HOST_WAIT` | Engine waiting on database engine trigger |
| `WAIT_XTP_PROCEDURE_ENTRY` | Waiting for native proc executions to drain (during DROP) |

Most of these are background maintenance waits. If you see `WAIT_XTP_OFFLINE_CKPT_NEW_LOG` accumulating heavily, it means checkpoint operations are working hard to keep up with your write volume — which may indicate you're pushing the limits of your service objective.

### Columnstore Segment Health

Columnstore performance depends heavily on the quality of your **rowgroups** — the compressed column segments that store your data. Each rowgroup holds up to approximately 1,048,576 rows.
<!-- Source: azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md --> Rowgroups that are undersized (from small batch loads or heavy deletes) degrade query performance because the engine must process more segments to cover the same data.

Check rowgroup health with:

```sql
SELECT
    object_name(object_id) AS table_name,
    index_id,
    state_desc,
    total_rows,
    deleted_rows,
    size_in_bytes / 1024 / 1024 AS size_mb
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.SalesHistory')
ORDER BY row_group_id;
```

Key things to look for:

- **OPEN** rowgroups: These are the delta store — uncompressed rows waiting to be compressed. A few are normal; many indicate the tuple mover is falling behind.
- **COMPRESSED** rowgroups with low `total_rows`: Undersized segments from small batch inserts. Ideally, each compressed rowgroup should be close to the 1M row maximum.
- **COMPRESSED** rowgroups with high `deleted_rows`: Logically deleted rows that haven't been cleaned up. These bloat scans. Use `ALTER INDEX ... REORGANIZE` to trigger cleanup.

**Dictionary pressure** is another concern. Columnstore uses dictionaries to compress string columns — if your string cardinality is very high, dictionary size can grow, consuming memory and reducing compression effectiveness. Consider whether high-cardinality string columns truly belong in the columnstore, and watch for undersized compressed rowgroups as an indicator that dictionary pressure is limiting compression.

> **Tip:** Periodic `ALTER INDEX cci_SalesHistory ON dbo.SalesHistory REORGANIZE` merges small rowgroups and cleans up deleted rows. For more aggressive maintenance, `REBUILD` reconstructs the entire index — but it locks the table and uses significant resources. Prefer `REORGANIZE` for online maintenance.

## When to Use In-Memory (and When Not To)

In-memory technologies aren't a universal performance lever. They excel in specific scenarios and can actively hurt in others. Here's a decision framework.

### OLTP Acceleration

**Use In-Memory OLTP when:**

- You have high-throughput point operations — thousands to millions of inserts, updates, or lookups per second on relatively small rows.
- Latch contention on hot pages is your bottleneck. Memory-optimized tables eliminate latches entirely.
- You need ultra-low latency for individual transactions — think trading systems, gaming leaderboards, IoT telemetry ingestion.
- You're using temp tables heavily and want to replace them with `SCHEMA_ONLY` memory-optimized tables for dramatic speedup.
- Session state or caching workloads where data is transient and speed matters more than persistence.

**Don't use In-Memory OLTP when:**

- Your dataset exceeds the XTP storage cap for your service objective (see Storage Caps above).
- Your workload is I/O-bound on large scans rather than latch-bound on hot rows. In-Memory OLTP won't help if the bottleneck is reading terabytes of data.
- You need features not supported in memory-optimized tables: cross-database queries, distributed transactions, certain T-SQL constructs in natively compiled procedures.
- You're on General Purpose or Standard tier. In-Memory OLTP requires Premium/Business Critical, which means a tier upgrade with significant cost implications.

### Analytics Acceleration

**Use columnstore indexes when:**

- You run aggregation-heavy analytical queries — `SUM`, `AVG`, `COUNT`, `GROUP BY` — across large datasets. Columnstore + batch mode can deliver 10× to 57× improvement.
- You have fact tables or historical data where compression matters. With the compression ratios discussed above, a 1 TB table might shrink to 100 GB or less.
- You want to reduce storage costs without archiving data out of the database.

**Don't use columnstore indexes when:**

- Your workload is dominated by single-row lookups. Columnstore is optimized for scanning, not seeking.
- You frequently update individual rows in a clustered columnstore table. Updates decompress the row, mark the old version as deleted, and insert a new one — creating fragmentation. Columnstore is designed for append-heavy patterns.
- Your table has fewer than ~100,000 rows. The overhead of columnstore structures doesn't pay off at small scale.

### HTAP (Hybrid)

**Use HTAP when:**

- You need real-time analytics on operational data — dashboards that reflect the current state of the business, not yesterday's ETL snapshot.
- You want to eliminate a separate data warehouse for a subset of analytical queries.
- Your OLTP write volume is moderate enough that the columnstore maintenance overhead won't degrade transactions.

**Don't use HTAP when:**

- Your analytical queries are complex enough to justify a proper data warehouse (star schemas, slowly changing dimensions, heavy transformations).
- Your OLTP workload is write-intensive and latency-sensitive. The nonclustered columnstore maintenance adds overhead to every write.

### The Anti-Patterns

The most common mistake is treating In-Memory OLTP as "make my database faster" without understanding the bottleneck. If your slow query is doing a 10-million-row table scan with complex joins, converting it to a memory-optimized table won't help — you've just moved the same scan to memory, where it's still a scan. The wins come from eliminating latching, locking, and buffer pool overhead on high-frequency, narrow operations.

The second most common mistake is adding a clustered columnstore index to an OLTP table that processes frequent single-row updates. You'll get worse write performance and fragmented rowgroups that degrade read performance too.

> **Important:** In-memory technologies solve specific performance problems. Profile your workload first. Identify whether your bottleneck is latch contention (In-Memory OLTP), scan performance (columnstore), or something else entirely (missing indexes, bad query plans, network latency). The right tool for the wrong problem doesn't make anything faster.

The next chapter shifts from engine internals to data modeling — how to use JSON, graph, temporal tables, and multi-tenant patterns to build applications that match how your data actually behaves.
