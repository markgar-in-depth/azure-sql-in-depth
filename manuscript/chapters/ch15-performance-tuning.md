# Chapter 15: Performance Tuning

Your database is live, monitoring is humming along, and then a dashboard lights up red. CPU is pegged, queries are crawling, and your users are filing tickets. The monitoring tools from Chapter 14 told you *something* is wrong — this chapter teaches you how to fix it.

Performance tuning in Azure SQL is a layered discipline. You'll start by diagnosing *where* the bottleneck lives — running versus waiting — then work through the automated tools that Azure SQL provides, and finally get into the manual techniques for CPU spikes, blocking, deadlocks, and application-level inefficiencies. Every production database eventually needs this chapter.

## Query Performance Bottleneck Detection

Every slow query falls into one of two buckets: it's either *running* (consuming CPU, doing work inefficiently) or *waiting* (stuck behind a lock, an I/O operation, or a resource limit). Your first diagnostic step is always determining which bucket you're in, because the fix for each is completely different.
<!-- Source: azure-sql-database-sql-db/how-to/monitor-tune/identify-query-performance-issues.md -->

### Running vs. Waiting States

A query in a **running** state is actively executing on a scheduler but producing results slowly. The usual culprits are suboptimal execution plans, missing indexes, stale statistics, or parameter sniffing gone wrong. A query in a **waiting** state is suspended — blocked by locks, waiting for I/O pages, stalled on tempdb contention, or starved for memory grants.

Use `sys.dm_exec_requests` to see active queries and their `wait_type`. A NULL `wait_type` or CPU-related waits means you're in running territory. Common waiting-state indicators:

- `LCK_M_*` — lock contention
- `PAGEIOLATCH_*` — data I/O waits
- `WRITELOG` — transaction log flushes
- `RESOURCE_SEMAPHORE` — memory grant queuing

Database watcher and Query Store's wait statistics view can also categorize this for you over time.

### Suboptimal Query Plans and Plan Regression

The query optimizer usually picks a good plan. When it doesn't, you get table scans where seeks should exist, nested loops where hash joins would win, or parallelism where serial execution is faster. **Plan regression** is the particularly nasty variant: a query that used to run fine suddenly gets a worse plan after a recompile, a statistics update, or a schema change.

Query Store is your primary weapon here. It tracks every plan a query has used along with runtime statistics for each. When you spot a query whose duration or CPU spiked, check Query Store for plan changes. If the old plan was better, you can force it:

```sql
EXEC sp_query_store_force_plan
    @query_id = 42,
    @plan_id = 7;
```

This pins the query to the known-good plan until you explicitly unforce it. It's a surgical fix — use it when you've confirmed the older plan is genuinely better, not just different.

### Parameter-Sensitive Plan Problems

**Parameter-sensitive plan (PSP)** problems happen when the optimizer compiles a plan based on one parameter value and caches it for all subsequent executions — even when a different value would benefit from a completely different plan. A classic example: a stored procedure that filters on `Status` works great when called with a rare value (index seek), but the cached plan is terrible for common values that should scan.
<!-- Source: azure-sql-database-sql-db/how-to/monitor-tune/identify-query-performance-issues.md -->

Several workarounds exist, each with tradeoffs:

- **Parameter Sensitive Plan optimization** (database compatibility level 160, from SQL Server 2022) automatically generates multiple plans for a single parameterized query based on parameter cardinality. PSP optimization is enabled at compat level 160 in both Azure SQL Database and Managed Instance — this is the cleanest solution.
- **`OPTION (RECOMPILE)`** forces a fresh plan every execution. Good for infrequently run queries; expensive for high-throughput workloads.
- **`OPTION (OPTIMIZE FOR (@param UNKNOWN))`** tells the optimizer to use the density vector average instead of the sniffed value. Good when you want a plan that's "okay for everyone" rather than "perfect for one."
- **Query Store hints** let you apply query hints without changing application code — attach a hint to a query_id, and Query Store injects it at compile time.

> **Tip:** Before chasing PSP problems, confirm you're looking at one. Query Store's "Regressed Queries" view shows queries with multiple plans that have significant performance variance — that's your signal.

### Missing Indexes and Improper Parameterization

Missing indexes are the single most common cause of poor query performance. The optimizer tells you about them — both in execution plans (the green "Missing Index" text) and through the missing index DMVs:

```sql
SELECT
    mid.statement AS table_name,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    migs.avg_total_user_cost * migs.avg_user_impact
        * (migs.user_seeks + migs.user_scans) AS improvement_measure
FROM sys.dm_db_missing_index_groups AS mig
INNER JOIN sys.dm_db_missing_index_group_stats AS migs
    ON migs.group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid
    ON mig.index_handle = mid.index_handle
ORDER BY improvement_measure DESC;
```

The `improvement_measure` column gives you a rough prioritization. Don't blindly create every suggested index — each one adds write overhead and consumes storage. Focus on the top recommendations and validate with actual execution plans.

**Improper parameterization** is the flip side. When queries contain literal values instead of parameters, each unique literal produces a separate cached plan, consuming plan cache memory and causing constant recompilations. You can detect this by looking for high `number_of_distinct_query_ids` for the same `query_hash` in Query Store:

```sql
SELECT TOP 10
    q.query_hash,
    COUNT(DISTINCT p.query_id) AS distinct_query_ids,
    MIN(qt.query_sql_text) AS sample_query_text
FROM sys.query_store_query_text AS qt
JOIN sys.query_store_query AS q ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan AS p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(hour, -2, GETUTCDATE())
    AND query_parameterization_type_desc IN ('User', 'None')
GROUP BY q.query_hash
ORDER BY COUNT(DISTINCT p.query_id) DESC;
```
<!-- Source: azure-sql-database-sql-db/how-to/monitor-tune/identify-query-performance-issues.md -->

If a single query hash has dozens of query IDs, you've found an improperly parameterized query. Fix it in the application code by using parameterized queries, or use Database Advisor's forced parameterization recommendation.

### Resource Limit Bottlenecks

Sometimes the plan is fine, the indexes exist, and the query is still slow. The problem is the database itself — you've hit the ceiling on CPU, data I/O, log I/O, or worker threads for your service tier.
<!-- Source: azure-sql-database-sql-db/how-to/monitor-tune/identify-query-performance-issues.md -->

Use `sys.dm_db_resource_stats` to check. It returns a row every 15 seconds with consumption percentages:

```sql
SELECT TOP 20
    end_time,
    avg_cpu_percent,
    avg_data_io_percent,
    avg_log_write_percent,
    avg_memory_usage_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

If any metric is consistently above 80%, you're resource-constrained. The fix is either to optimize the workload (the rest of this chapter) or to scale up to a larger service objective. Chapter 3 covers the service tier options.

### Wait Category Analysis

For a broader view, Query Store aggregates wait statistics by category. The mapping in `sys.query_store_wait_stats` groups hundreds of individual wait types into a handful of categories: CPU, Lock, Latch, Buffer Latch, Buffer IO, Compilation, SQL CLR, Mirroring, Transaction, Idle, Preemptive, and Service Broker. Use the "Top Wait Statistics" report in SSMS or query the view directly to see which wait category dominates your workload. That tells you where to focus.

You can also use `sys.dm_db_wait_stats` for a database-level aggregate or `sys.dm_os_waiting_tasks` for a real-time snapshot of what's waiting right now.

## Automatic Tuning

Azure SQL Database includes a built-in automatic tuning engine that can detect and fix plan regressions without human intervention. The database watches itself, identifies regressions, applies corrections, validates the results, and rolls back if things get worse.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/automatic-tuning-overview.md -->

### FORCE_LAST_GOOD_PLAN: Automatic Plan Regression Correction

When Query Store detects that a query's performance has regressed due to a plan change, automatic tuning can force the previous good plan — the same `sp_query_store_force_plan` mechanism you'd use manually, but applied automatically. The engine validates the forced plan over a period of 30 minutes to 72 hours (longer for infrequently executed queries). If the forced plan isn't actually better, it's automatically reverted.

This option is **enabled by default** for new Azure SQL databases. It's also the only automatic tuning option available on Azure SQL Managed Instance.

```sql
-- Check current automatic tuning state
SELECT name, actual_state_desc, desired_state_desc
FROM sys.database_automatic_tuning_options;
```

### CREATE_INDEX and DROP_INDEX Recommendations

The automatic indexing options analyze workload patterns and create or drop indexes to improve performance:

- **CREATE_INDEX** identifies missing indexes and creates them after validation. The process has several guardrails:
  - Waits for high confidence before acting
  - Creates the index during a low-utilization window
  - Validates that query performance actually improved — if it didn't, or if it regressed, the index is dropped
  - Won't create an index that would push space utilization above 90% of the maximum data size
  - Skips tables where the clustered index or heap exceeds 10 GB
- **DROP_INDEX** identifies indexes that haven't been used in the last 90 days or duplicate indexes. It never drops unique indexes or indexes backing primary key and unique constraints. On Premium and Business Critical tiers, it only drops duplicates, never unused indexes.

Both options are **disabled by default**. Enable them at the server level to apply across all databases:

```sql
ALTER DATABASE CURRENT
SET AUTOMATIC_TUNING (CREATE_INDEX = ON, DROP_INDEX = ON);
```

> **Important:** CREATE_INDEX and DROP_INDEX are only available in Azure SQL Database, not Managed Instance. Managed Instance supports only FORCE_LAST_GOOD_PLAN.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/automatic-tuning-overview.md -->

### Auto-Validation and Rollback

Every automatic tuning action goes through a validation cycle. The engine compares post-change performance against the pre-change baseline. If there's no measurable improvement — or if performance degrades — the change is reverted automatically. This makes automatic tuning safe for production workloads. You can review the full history of actions, including what was applied, validated, and rolled back.

Tuning history is retained for 21 days and can be viewed in the Azure portal's Performance Recommendations page, via the `Get-AzSqlDatabaseRecommendedAction` PowerShell cmdlet, or by enabling the **AutomaticTuning** diagnostic setting for longer retention.

> **Gotcha:** If you apply tuning recommendations manually via T-SQL (for example, creating an index yourself based on an advisor recommendation), the automatic validation and rollback mechanisms don't apply. The recommendation will show as active for 24–48 hours, then the system withdraws it.

### Server-Level vs. Database-Level Configuration

Automatic tuning can be configured at two levels. **Server-level** settings are inherited by all databases on the logical server unless overridden. **Database-level** settings can be set to `AUTO` (Azure defaults), `INHERIT` (from the server), or `CUSTOM` (explicit per-database choices).

| Scope | Default | Options |
|---|---|---|
| Server | Azure defaults | FORCE_LAST_GOOD_PLAN: ON, CREATE_INDEX: OFF, DROP_INDEX: OFF |
| Database | Inherit from server | AUTO, INHERIT, or CUSTOM |

The recommended approach is to configure at the server level and let databases inherit. Override at the database level only when a specific database needs different behavior.

```sql
-- Database inherits from server
ALTER DATABASE CURRENT SET AUTOMATIC_TUNING = INHERIT;

-- Database uses custom settings
ALTER DATABASE CURRENT SET AUTOMATIC_TUNING
    (FORCE_LAST_GOOD_PLAN = ON, CREATE_INDEX = ON, DROP_INDEX = OFF);
```

> **Gotcha:** For active geo-replication, configure automatic tuning on the primary only. Tuning actions (like creating or dropping indexes) are automatically replicated to geo-secondaries. Trying to enable automatic tuning via T-SQL on a read-only secondary fails.
<!-- Source: azure-sql-database-sql-db/how-to/performance/automatic-tuning-enable.md -->

## Database Advisor

Database Advisor is the recommendation engine behind automatic tuning's index and plan suggestions. Even if you don't enable automatic application, Advisor continuously analyzes your workload and surfaces four categories of recommendations:
<!-- Source: azure-sql-database-sql-db/how-to/performance/database-advisor-implement-performance-recommendations.md -->

| Recommendation | What it does |
|---|---|
| Create index | Suggests indexes based on workload analysis |
| Drop index | Identifies unused (90+ days) and duplicate indexes |
| Parameterize queries (preview) | Flags constant-recompilation candidates for forced parameterization |
| Fix schema issues (preview) | Detects anomalous schema-related SQL errors |

### Viewing, Applying, and Discarding Recommendations via Portal

Navigate to your database in the Azure portal and select **Performance overview** under **Intelligent Performance**. The page shows active recommendations, tuning activity history, and a link to the automatic tuning configuration.

Each recommendation includes an estimated performance impact (high, medium, or low), the T-SQL script to apply it manually, and an **Apply** button for one-click application. Applied recommendations go through the same validation cycle as automatic tuning — if the change doesn't help, it's reverted.

You can also **Discard** a recommendation if you know it's not applicable. Discarded recommendations won't resurface unless the underlying workload changes significantly.

> **Tip:** The **Query Performance Insight** blade provides a complementary view. It shows the top resource-consuming queries by CPU, duration, and execution count over the last 24 hours. It requires Query Store to be enabled (which it is by default on Azure SQL Database).

## Intelligent Insights (Preview)

Intelligent Insights takes a different approach from Database Advisor. Instead of offering prescriptive recommendations, it uses AI-based anomaly detection to identify *when and how* your database performance has degraded. It compares the current workload against a rolling seven-day baseline and flags deviations across 15 detection patterns.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/monitor-and-tune/intelligent-insights-overview.md -->

### AI-Based Anomaly Detection: 15 Performance Degradation Patterns

Intelligent Insights monitors four core metrics — query duration, timeout requests, excessive wait times, and errored-out requests — and maps anomalies to specific patterns:

| Pattern | Detects |
|---|---|
| Reaching resource limits | CPU/DTU/worker/session ceiling hit |
| Workload increase | Spike or continuous accumulation |
| Memory pressure | Memory grant wait queuing |
| Locking | Excessive lock contention |
| Increased MAXDOP | Parallelism configuration change |
| Pagelatch contention | Buffer page hot-spots |
| Missing index | Missing index gaps |
| New query | New query impact |
| Unusual wait statistic | Abnormal waits |
| TempDB contention | Temp object hot-spotting |
| Elastic pool DTU shortage | Pool-level resource starvation |
| Plan regression | Execution plan change degradation |
| DB-scoped config change | Configuration drift |
| Slow client | App not consuming results fast enough |
| Pricing tier downgrade | Post-scale-down resource shortage |

Each detected issue includes root cause analysis, impacted query hashes, impact severity (1–3), and where possible, a remediation recommendation.

> **Note:** Intelligent Insights is a preview feature and is not available in all regions. Check the Azure documentation for current regional availability.

### Diagnostics Log Format and Integration

Intelligent Insights outputs its findings to the **SQLInsights** diagnostic log in JSON format. You configure this through the database's **Diagnostic settings** in the Azure portal, streaming to one or more destinations:

- **Log Analytics workspace** — enables querying with KQL and viewing through Azure SQL Analytics
- **Azure Event Hubs** — for custom alerting and SIEM integration
- **Azure Storage** — for archival and custom analysis

Each log entry includes the detection time range, database identifier, issue ID, impact metrics, affected query hashes, and root cause details. The issue ID tracks a problem from initial detection through resolution, so you can monitor the lifecycle of recurring performance issues.

## High-CPU Diagnosis

CPU spikes are the most common performance emergency. When your database's CPU percentage is sustained above 80%, queries slow down, workers back up, and if you're on serverless, your bill climbs. The fix depends on the cause.
<!-- Source: azure-sql-database-sql-db/how-to/performance/high-cpu-diagnose-troubleshoot.md -->

### Identifying Top CPU-Consuming Queries

Start with the Azure portal's **Query Performance Insight**, which overlays CPU usage with the top queries consuming it. For deeper analysis, query the Query Store directly:

```sql
SELECT TOP 15
    q.query_id,
    qt.query_sql_text,
    SUM(rs.count_executions) AS total_executions,
    SUM(rs.count_executions * rs.avg_cpu_time) AS total_cpu_time_us,
    AVG(rs.avg_cpu_time) AS avg_cpu_time_us
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_plan AS p ON rs.plan_id = p.plan_id
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(hour, -1, GETUTCDATE())
GROUP BY q.query_id, qt.query_sql_text
ORDER BY total_cpu_time_us DESC;
```

This gives you the top 15 queries by total CPU consumption in the last hour. Check whether the problem is a few expensive queries or many individually cheap queries executing at high frequency — the remediation differs.

For currently executing queries during an active incident, use DMVs:

```sql
SELECT
    r.session_id,
    r.cpu_time,
    r.total_elapsed_time,
    r.logical_reads,
    t.text AS query_text,
    p.query_plan
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) p
WHERE r.status = 'running'
ORDER BY r.cpu_time DESC;
```

### Plan Regression and Excessive Parallelism

Two root causes dominate high-CPU scenarios:

**Plan regression** — covered in detail earlier in "Suboptimal Query Plans and Plan Regression." If automatic tuning's `FORCE_LAST_GOOD_PLAN` is enabled, most regressions are handled automatically, but subtle ones may not trigger detection.

**Excessive parallelism** — queries that go wide across too many threads actually hurt throughput by starving other concurrent queries of CPU and worker threads. This is especially common when MAXDOP is set to 0 on databases with many vCores.

### MAXDOP Configuration

Azure SQL Database defaults MAXDOP to **8** for new databases — a deliberate choice based on years of telemetry across millions of databases. Databases created before September 2020 may still have the legacy default of 0 (unlimited parallelism).
<!-- Source: azure-sql-database-sql-db/how-to/performance/configure-max-degree-of-parallelism.md -->

| MAXDOP | Behavior |
|---|---|
| `= 1` | Serial execution only |
| `> 1` | Up to MAXDOP parallel threads per query |
| `= 0` | Up to the number of logical processors (or 64, whichever is smaller) |

Check your current setting:

```sql
SELECT [value] FROM sys.database_scoped_configurations WHERE [name] = 'MAXDOP';
```

If it's 0 and you're seeing excessive CPU or worker thread exhaustion, set it to 8 or lower:

```sql
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;
```

For databases with read scale-out, you can configure MAXDOP independently on primary and secondary replicas:

```sql
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;
ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET MAXDOP = 1;
```

> **Tip:** Don't set MAXDOP to 0 even if things seem fine today. Future hardware changes, service objective upgrades, or workload growth can make excessive parallelism suddenly problematic.

You can also override MAXDOP on individual queries without changing the database-level setting:

```sql
SELECT ProductID, SUM(LineTotal) AS Total
FROM SalesLT.SalesOrderDetail
WHERE UnitPrice < 5
GROUP BY ProductID
OPTION (MAXDOP 2);
```

> **Note:** Azure SQL Database uses compute resources for internal operations — high availability, backup, Query Store, automatic tuning. This is particularly noticeable on low vCore counts. Don't be surprised if you see some CPU usage that doesn't correspond to your workload queries.

## Blocking and Deadlock Analysis

Locking is how relational databases maintain data consistency. Blocking — where one session waits for another to release a lock — is normal. It becomes a *problem* when the waits are long enough to affect user experience, or when they escalate into deadlocks.
<!-- Source: azure-sql-database-sql-db/how-to/performance/understand-resolve-blocking.md, azure-sql-database-sql-db/how-to/performance/analyze-prevent-deadlocks.md -->

### RCSI and Snapshot Isolation Defaults in Azure SQL

Azure SQL Database creates new databases with two concurrency-friendly defaults that traditional SQL Server installations often lack:

- **Read Committed Snapshot Isolation (RCSI)** is enabled by default. SELECT statements don't acquire shared locks — they read a version of the row from the version store instead. This eliminates the most common source of reader-writer blocking.
- **Snapshot isolation** is also enabled by default (though applications must explicitly request the `SNAPSHOT` isolation level to use it).

Verify both:

```sql
SELECT name,
       is_read_committed_snapshot_on,
       snapshot_isolation_state_desc
FROM sys.databases
WHERE name = DB_NAME();
```

> **Gotcha:** If you migrated a database from on-premises SQL Server, RCSI might be disabled. Before re-enabling it, verify that your application doesn't depend on reader-writer blocking behavior — some legacy apps use shared lock waits as a de facto synchronization mechanism, and enabling RCSI can introduce race conditions.

Even with RCSI enabled, writer-writer conflicts still cause blocking. UPDATE and DELETE statements acquire exclusive locks, and two sessions modifying the same rows will block each other.

### Identifying and Resolving Long-Held Locks

When blocking becomes problematic, your goal is to find the **head blocker** — the session at the top of the blocking chain — and understand what it's doing.

```sql
WITH cteBL (session_id, blocking_these) AS (
    SELECT s.session_id, blocking_these = x.blocking_these
    FROM sys.dm_exec_sessions s
    CROSS APPLY (
        SELECT ISNULL(CONVERT(varchar(6), er.session_id), '') + ', '
        FROM sys.dm_exec_requests AS er
        WHERE er.blocking_session_id = ISNULL(s.session_id, 0)
            AND er.blocking_session_id <> 0
        FOR XML PATH('')
    ) AS x(blocking_these)
)
SELECT s.session_id,
       blocked_by = r.blocking_session_id,
       bl.blocking_these,
       t.text AS batch_text,
       ib.event_info AS input_buffer
FROM sys.dm_exec_sessions s
LEFT OUTER JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
INNER JOIN cteBL AS bl ON s.session_id = bl.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
OUTER APPLY sys.dm_exec_input_buffer(s.session_id, NULL) AS ib
WHERE blocking_these IS NOT NULL OR r.blocking_session_id > 0
ORDER BY LEN(bl.blocking_these) DESC, r.blocking_session_id DESC;
```

Common causes of long-held locks:

- **Open transactions with no COMMIT/ROLLBACK** — the application opened a transaction, did some work, then went to the network or user interface without closing it. The locks stay held.
- **Long-running transactions** — legitimate business logic that holds locks across large data sets.
- **Application-level connection management issues** — connection pooling that reuses connections with abandoned transactions.

The fix is almost always in the application: keep transactions short, commit or rollback promptly, and ensure connections are properly closed (use `using` statements in C# or equivalent in other languages).

### Deadlock Graphs and Query Store Analysis

A deadlock is a special case of blocking: two or more sessions form a cycle, each waiting for a lock held by the other. The database engine detects this via its deadlock monitor and terminates one of the transactions (the **deadlock victim**) with error 1205.

Capture deadlock graphs using Extended Events:

```sql
CREATE EVENT SESSION [deadlocks] ON DATABASE
ADD EVENT sqlserver.database_xml_deadlock_report
ADD TARGET package0.ring_buffer
WITH (STARTUP_STATE = ON, MAX_MEMORY = 4 MB);
GO

ALTER EVENT SESSION [deadlocks] ON DATABASE STATE = START;
GO
```

The deadlock graph tells you exactly which sessions, queries, and resources were involved. The most effective prevention strategies, in order of risk:

1. **Tune nonclustered indexes** to reduce the number of rows each query touches. Fewer rows locked means less chance of conflict.
2. **Force a specific plan** via Query Store if the deadlock only occurs with a particular execution plan.
3. **Rewrite the T-SQL** to access tables in a consistent order and keep explicit transactions as short as possible.

> **Important:** Design your application to retry after error 1205. Use a short, randomized delay before retrying to avoid hitting the same deadlock again.

### Optimized Locking: TID-Based Locking and Lock-After-Qualification

**Optimized locking** is a Database Engine feature that dramatically reduces lock memory consumption and the number of locks held during write operations. It uses two mechanisms:
<!-- Source: azure-sql-database-sql-db/how-to/performance/optimized-locking.md -->

- **Transaction ID (TID) locking** — instead of acquiring row-level locks for each modified row, the engine locks by transaction ID. Other transactions that need to check whether a row is locked just look at the TID, drastically cutting the number of lock structures in memory.
- **Lock after qualification (LAQ)** — the engine evaluates WHERE clause predicates *before* acquiring locks, so it only locks rows that actually qualify for modification. Without LAQ, the engine might lock rows it evaluates but ultimately doesn't modify.

Together, these reduce lock escalation events, decrease blocking duration, and lower the memory footprint of write-heavy workloads. Optimized locking requires no configuration — it's always enabled in Azure SQL Database (and SQL database in Fabric). On Managed Instance, it's available on instances using the *Always-up-to-date* or *SQL Server 2025* update policy.
<!-- Source: azure-sql-database-sql-db/how-to/performance/analyze-prevent-deadlocks.md, azure-sql-managed-instance-sql-mi/overview/doc-changes-updates-release-notes-whats-new.md -->

## Application-Level Tuning Guidance

The most impactful performance improvements often aren't in the database at all — they're in how your application talks to the database. Network round trips, inefficient data access patterns, and missing caching layers cause more real-world slowdowns than any query plan issue.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/monitor-tune/performance-guidance.md, shared-sql-db-sql-mi-docs/shared-how-tos/monitor-tune/performance-improve-use-batching.md -->

### Chatty-App Anti-Patterns

A "chatty" application makes many small database calls where fewer, larger calls would do. Each round trip incurs network latency — on the order of a few milliseconds within an Azure datacenter, but tens of milliseconds from an external client. When you multiply that by thousands of tiny queries per request, the latency dominates execution time.

Common chatty patterns:

- Fetching a parent record, then looping to fetch each child record individually
- Issuing individual INSERT statements inside an application loop
- Calling a stored procedure once per item in a list

The fix is to batch operations: retrieve parent and children in a single query with a JOIN, use set-based inserts, or pass collections to stored procedures via table-valued parameters.

### Client-Side Batching: TVPs, SqlBulkCopy, BULK INSERT

When you need to send many rows to the database, the batching technique matters enormously:

**Table-Valued Parameters (TVPs)** let you pass an entire DataTable as a parameter to a stored procedure. It's the most flexible option — you can INSERT, UPDATE, or DELETE based on the incoming rows:

```sql
-- Create the table type
CREATE TYPE OrderDetailType AS TABLE (
    ProductID INT,
    Quantity INT,
    UnitPrice DECIMAL(10,2)
);
GO

-- Use it in a stored procedure
CREATE PROCEDURE dbo.usp_UpsertOrderDetails
    @Details OrderDetailType READONLY
AS
BEGIN
    MERGE INTO SalesLT.OrderDetail AS target
    USING @Details AS source
    ON target.ProductID = source.ProductID
    WHEN MATCHED THEN
        UPDATE SET Quantity = source.Quantity, UnitPrice = source.UnitPrice
    WHEN NOT MATCHED THEN
        INSERT (ProductID, Quantity, UnitPrice)
        VALUES (source.ProductID, source.Quantity, source.UnitPrice);
END
GO
```

```csharp
using (var connection = new SqlConnection(connectionString))
{
    connection.Open();
    var table = new DataTable();
    table.Columns.Add("ProductID", typeof(int));
    table.Columns.Add("Quantity", typeof(int));
    table.Columns.Add("UnitPrice", typeof(decimal));

    // Populate rows...
    foreach (var item in orderDetails)
        table.Rows.Add(item.ProductId, item.Quantity, item.UnitPrice);

    using var cmd = new SqlCommand("dbo.usp_UpsertOrderDetails", connection);
    cmd.CommandType = CommandType.StoredProcedure;
    cmd.Parameters.Add(new SqlParameter("@Details", SqlDbType.Structured)
    {
        TypeName = "OrderDetailType",
        Value = table
    });
    cmd.ExecuteNonQuery();
}
```

**SqlBulkCopy** is optimized for INSERT-only scenarios and can load thousands of rows per second. It maps directly to the BULK INSERT pathway in the engine:

```csharp
using (var bulkCopy = new SqlBulkCopy(connectionString))
{
    bulkCopy.DestinationTableName = "SalesLT.OrderDetail";
    bulkCopy.BatchSize = 5000;
    bulkCopy.WriteToServer(dataTable);
}
```

**Explicit transactions** are the simplest optimization. Wrapping sequential operations in a single transaction batches the log writes, because the transaction log flushes at commit rather than after each statement. For 1,000 inserts within the same Azure datacenter, this alone can improve throughput by nearly 8× compared to autocommit mode.

### Missing Index Identification and Creation

Database Advisor surfaces index recommendations in the Azure portal with estimated impact scores (complementing the DMV query from earlier). When evaluating these recommendations:

- Look for overlapping indexes that could be consolidated into a single covering index
- Examine the table size — indexes on small tables rarely matter
- Consider write overhead — heavily written tables pay a higher price for each new index

Create indexes online to avoid blocking production queries:

```sql
CREATE NONCLUSTERED INDEX IX_Order_CustomerID
ON SalesLT.SalesOrderHeader (CustomerID)
INCLUDE (OrderDate, TotalDue)
WITH (ONLINE = ON);
```

### Sharding, Caching, and Query Hint Strategies

When single-database optimization isn't enough, three architectural patterns help:

**Sharding** distributes data across multiple databases based on a partition key (tenant ID, region, date range). Azure SQL Database provides the Elastic Database client library to manage shard maps. Sharding doesn't reduce aggregate resource needs — it spreads them. Use it when you've hit the ceiling on a single database's maximum size or compute. Chapter 17 covers the tenancy patterns that motivate sharding; Chapter 19 covers the Elastic Database tools for implementing it.

**Application-tier caching** with Azure Cache for Redis reduces read load on the database. Cache frequently read, slowly changing data — reference tables, user profiles, configuration data. Accept the tradeoff that cached reads may be slightly stale. For read-heavy workloads, caching can significantly reduce database CPU without changing a single query.

> **Gotcha:** Caching writes through to the database while serving reads from cache creates a consistency window. If your application can't tolerate any staleness, caching isn't the right tool for that data path.

**Query hints** are a last resort for persistent optimizer issues. The most commonly useful hints in Azure SQL Database:

- `OPTION (MAXDOP N)` — control parallelism for specific queries
- `OPTION (OPTIMIZE FOR (@param UNKNOWN))` — avoid parameter sniffing
- `OPTION (RECOMPILE)` — force a fresh plan every execution
- `OPTION (USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION'))` — fall back to the older CE when the new one produces bad estimates

Prefer Query Store hints over modifying application code — they let you attach hints to queries by `query_id` without deploying code changes.

Chapter 16 continues the performance story with in-memory technologies — memory-optimized tables and columnstore indexes — that fundamentally change the performance profile for specific workload patterns.
