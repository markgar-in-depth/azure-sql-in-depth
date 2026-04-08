# Appendix G: Troubleshooting Reference

This appendix is the quick-reference companion to the connectivity and resilience patterns covered in Chapter 4. When something breaks at 2 a.m., you don't want to re-read a chapter — you want the error code, the likely cause, and the fix. That's what this appendix delivers.

Each section follows the same pattern: symptom, cause, resolution. Grab the error number from your logs, find it here, and get moving.

---

## Transient Faults and Retry Logic

Transient faults are the single most common class of error in Azure SQL. They're temporary failures caused by planned maintenance, load balancing, hardware faults, or resource throttling. The connection drops, the query fails, and a retry succeeds seconds later.

Chapter 4 covers retry architecture in depth — this section gives you the reference table.
<!-- Source: resources/troubleshoot/troubleshoot-common-connectivity-issues.md -->

### Recognizing Transient Errors

Every transient fault surfaces as a `SqlException` (or your driver's equivalent) with a specific error number. The key distinction: transient errors during a **connection attempt** mean you should retry the connection. Transient errors during a **query** mean you should open a fresh connection and retry the query — don't just re-execute on the same connection.

> **Important:** When an `UPDATE` or `DELETE` fails with a transient error, don't blindly retry the statement on the same connection. Open a new connection and ensure the entire transaction either completed or rolled back before retrying.

### Common Transient Error Codes

| Error | Cause |
|---|---|
| 4060 | Can't open the requested database — may be offline, mid-reconfiguration, or nonexistent |
| 40197 | Service failover — upgrade, hardware fault, or load balancing |
| 40501 | Resource throttling — database hit its resource limits |
| 40613 | Database reconfiguration in progress |
| 49918 | Elastic pool resource exhaustion |
| 49919 | Elastic pool create/update in progress |
| 49920 | Elastic pool throttling — too many operations |
| 4221 | Read replica restarted, version store not rebuilt |

<!-- Source: resources/troubleshoot/troubleshoot-common-errors-issues.md -->

For .NET connection string retry parameters (`ConnectRetryCount`, `ConnectRetryInterval`, `Connection Timeout`), retry strategy guidelines, and production retry implementations, see Chapter 4.

---

## Common Connectivity Errors

These are the errors you'll hit when connections fail outright — not transient blips, but configuration or network problems that require you to fix something.
<!-- Source: resources/troubleshoot/troubleshoot-common-errors-issues.md -->

### Error 26 / 40 / 10053: Server Not Found or Not Accessible

**Symptom:** "Error Locating server specified" or "Could not open a connection to the server" or "A transport-level error has occurred."

**Common causes:**

- Typo in the server name. Azure SQL Database server names are `<server>.database.windows.net`. Managed Instance uses `<instance>.<dns-zone>.database.windows.net`.
- The server doesn't exist in the specified region.
- A firewall or NSG is blocking outbound port 1433 (gateway) or ports 11000–11999 (redirect connections).
- DNS resolution failure — your network can't resolve the Azure SQL DNS name.

**Fix:** Verify the server name, check DNS resolution with `nslookup`, confirm your firewall allows the required ports, and verify the server exists in the Azure portal.

### Error 40615: Cannot Connect to Server (Firewall)

**Symptom:** "Cannot connect to < servername >."

**Cause:** The client IP address isn't in the server-level or database-level firewall rules, and "Allow Azure services" is off.

**Fix:** Add your client IP to the firewall rules in the Azure portal under **Networking → Firewall rules**. If your app runs in Azure, either enable "Allow Azure services and resources to access this server" or — better — use private endpoints or VNet service endpoints (see Chapter 6).

> **Tip:** If you're connecting from a development machine with a dynamic IP, the Azure portal's "Add current client IP" button on the Networking page is the fastest path. For production, use private endpoints instead of IP-based firewall rules.

### Error 5: Cannot Connect to Server (Network Path)

**Symptom:** "Cannot connect to < servername >."

**Cause:** The client's network can't reach the server. This usually means a VPN isn't connected, a VNet peering is misconfigured, or an NSG rule is blocking traffic.

**Fix:** Verify VPN/ExpressRoute connectivity, check VNet peering status, and review NSG rules on the relevant subnets. For Managed Instance, ensure the subnet's route table includes the required service-aided routes.

### Error 18456: Login Failed

**Symptom:** "Login failed for user '< username >'."

**Common causes:**

- Wrong password. This sounds obvious, but it's the #1 cause.
- The login doesn't exist on the server or the user doesn't exist in the target database.
- The database specified in the connection string doesn't exist.
- Microsoft Entra authentication misconfiguration — the server doesn't have a Microsoft Entra admin assigned, or the token is expired.
- The account is disabled or locked out.

**Fix:** Verify credentials, confirm the login exists on the logical server (`SELECT name FROM sys.sql_logins`), confirm the database user is mapped to the login, and check that you're targeting the correct database in your connection string.

> **Gotcha:** If you specify a database in your connection string that doesn't exist, you'll get error 18456 — not a "database not found" error. The login process fails before it can tell you the database is missing.

### Connection Timeout Expired

**Symptom:** `System.Data.SqlClient.SqlException (0x80131904): Connection Timeout Expired` or `Timeout expired. The timeout period elapsed prior to completion of the operation.`

**Common causes:**

- Server-level firewall blocking the connection (it silently drops packets rather than rejecting them, so you see a timeout instead of a connection refused).
- Network latency or packet loss between client and Azure.
- The server is under heavy load and can't accept new connections quickly enough.
- `Connection Timeout` set too low for the network conditions.

**Fix:** Start by checking the firewall rules — a timeout is often a firewall block in disguise. Then test network latency (`Test-NetConnection` on Windows, `nc -zv` on Linux). Increase `Connection Timeout` to at least 30 seconds if you're connecting over a VPN or from a distant region.

### Using Resource Health for Diagnostics

When connections fail and you're not sure if the problem is on your side or Azure's, check **Resource Health** in the Azure portal. It monitors login success/failure rates and reports four states:
<!-- Source: azure-sql-database-sql-db/how-to/manage/resource-health-to-troubleshoot-connectivity.md -->

| State | Meaning |
|---|---|
| Available | No system login failures detected |
| Degraded | Some system login failures detected |
| Unavailable | Significant system login failures |
| Unknown | No data received for 10+ minutes |

**Degraded** means that in 2 of the last 3 minutes, Resource Health saw at least one system login failure alongside mostly successful logins, or at least one failure with fewer than 6 total attempts. **Unavailable** means more than 5 login attempts in the last minute with over 25% failing for system reasons. **Unknown** doesn't necessarily mean something is wrong — if the resource is running normally, the status will change to Available within a few minutes. But if you're actively experiencing problems, Unknown may indicate a platform event affecting the resource.

> **Note:** Resource Health only tracks **system errors**, not user errors like wrong passwords. If Resource Health shows "Available" but your app can't connect, the problem is in your configuration, not in the Azure platform.

---

## Resource Governance Errors

Azure SQL Database enforces resource limits at the database, elastic pool, and server level. When you exceed those limits, you get specific error codes. These aren't transient — they'll keep happening until you reduce consumption or scale up.
<!-- Source: resources/troubleshoot/troubleshoot-common-errors-issues.md -->

### Error 10928 / 10936: Worker or Session Limit Reached

**Symptom:** "Resource ID: %d. The %s limit for the [database/elastic pool] is %d and has been reached."

**Cause:** Your database or elastic pool hit the maximum concurrent worker threads (Resource ID = 1) or sessions (Resource ID = 2) for its service tier. See Appendix A for the specific limits per tier.

**Fix:**

1. Connect using the **Dedicated Admin Connection (DAC)** — it's exempt from the worker limit. In SSMS, connect to `admin:<server>.database.windows.net` and specify your database.
2. Identify what's consuming all the workers:

```sql
SELECT
    r.session_id,
    r.status,
    r.command,
    r.wait_type,
    r.blocking_session_id,
    t.text AS query_text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
ORDER BY r.cpu_time DESC;
```

3. Look for blocking chains — one blocked session can cascade into hundreds of waiting workers.
4. If the workload is genuinely too large, scale up to a higher service tier.

> **Gotcha:** Only one DAC session can connect to a database at a time. If someone already has a DAC connection open, your attempt will fail. Close it before trying again.

### Error 10929: Minimum Guarantee

**Symptom:** "Resource ID: %d. The %s minimum guarantee is %d, maximum limit is %d, and the current usage for the database is %d."

**Cause:** This is the elastic pool variant — your database needs more resources than the pool can guarantee. Other databases in the pool are consuming the shared resources.

**Fix:** Reduce the workload on other pool members, increase the pool's eDTU/vCore allocation, or move the hot database to its own single database.

### Error 40501: Service Is Currently Busy

**Symptom:** "The service is currently busy. Retry the request after 10 seconds."

**Cause:** Engine-level throttling. The database is exceeding its CPU, I/O, or log rate limits.

**Fix:** This error is retriable, but if it persists, you're chronically under-provisioned. Check resource consumption in the Azure portal's **Monitoring** blade and scale up. See Chapter 15 for performance tuning approaches that reduce resource consumption.

### Error 40544: Database Size Quota Reached

**Symptom:** "The database has reached its size quota."

**Cause:** The database has hit its maximum data size for the current service tier.

**Fix:** Shrink data (delete unneeded rows, archive old data), increase the database's max size, or scale to a higher service tier. See Appendix A for max sizes per tier.

### Error 40549: Long-Running Transaction Terminated

**Symptom:** "Session is terminated because you have a long-running transaction."

**Cause:** A transaction held locks for too long, impacting other sessions. Azure SQL terminates it to protect the broader workload.

**Fix:** Break large operations into smaller batches. Avoid holding transactions open while waiting for user input or external service calls.

### Error 40551: Excessive tempdb Usage

**Symptom:** "The session has been terminated because of excessive TEMPDB usage."

**Cause:** Queries generated too much temporary data — usually from large sorts, hash joins, or spools that spill to tempdb.

**Fix:** Optimize the queries causing large tempdb spills. Add indexes to avoid sorts. Reduce result set sizes with better filtering. Check Chapter 15 for Query Store analysis techniques.

---

## Capacity and Quota Errors

These errors surface when you try to deploy or scale Azure SQL resources and hit subscription or regional limits.
<!-- Source: resources/troubleshoot/capacity-errors-troubleshoot.md -->

### Server Quota Limit Reached

**Symptom:** "Server quota limit has been reached for this location" or "Could not perform the operation because server would exceed the allowed Database Throughput Unit quota."

**Fix:**

1. **Request a quota increase** through the Azure portal: **Help + support → New support request → Service and subscription limits (Quotas) → SQL Database**.
2. If you need capacity immediately, try a different Azure region.

### Subscription Not Registered

**Symptom:** "Your subscription does not have access to create a server in the selected region."

**Fix:** Register the SQL resource provider with your subscription:

```azurecli
az provider register --namespace Microsoft.Sql
```

Or in the Azure portal: navigate to **Subscriptions → [your subscription] → Resource providers**, search for `Microsoft.Sql`, and click **Register**.

### Region Not Enabled

**Symptom:** "Provisioning is restricted in this region."

**Cause:** Your subscription type (Azure Pass, Visual Studio, BizSpark, etc.) may have restricted region access, or the specific region needs to be enabled for your subscription.

**Fix:** File a support request with issue type "Service and subscription limits" to enable the region, or choose a different region.

---

## Out-of-Memory Errors

Out-of-memory (OOM) errors happen when the database engine can't allocate enough memory for a query. In Azure SQL Database, memory is capped by your service tier — you can't just add RAM.
<!-- Source: resources/troubleshoot/troubleshoot-memory-errors-issues.md -->

### Error 701: Insufficient System Memory

**Symptom:** "There is insufficient system memory in resource pool '%ls' to run this query."

**Cause:** The query's memory grant request exceeded available memory in the resource pool for the current service tier.

### Error 802: Insufficient Buffer Pool Memory

**Symptom:** "There is insufficient memory available in the buffer pool."

**Cause:** The buffer pool is fully consumed — typically by other queries holding large memory grants or by a workload that exceeds the tier's memory allocation.

### Diagnosing OOM

**Step 1: Check recent OOM events.**

```sql
SELECT * FROM sys.dm_os_out_of_memory_events
ORDER BY event_time DESC;
```

This DMV includes a heuristic prediction of the OOM cause — not definitive, but a useful starting point.

**Step 2: Identify the top memory consumers.**

```sql
SELECT [type], [name], pages_kb, virtual_memory_committed_kb
FROM sys.dm_os_memory_clerks
WHERE memory_node_id <> 64 -- exclude DAC node
ORDER BY pages_kb DESC;
```

The clerk types tell you *what* is consuming memory:

- `MEMORYCLERK_SQLBUFFERPOOL` — buffer pool; expected to be the top consumer.
- `MEMORYCLERK_SQLQERESERVATIONS` — query memory grants; tune the offending queries with better indexes.
- `CACHESTORE_COLUMNSTOREOBJECTPOOL` — columnstore indexes; expected when using columnstore.
- `OBJECTSTORE_LOCK_MANAGER` — lock manager; indicates very large transactions or disabled lock escalation.

**Step 3: Find queries with large memory grants.**

```sql
SELECT
    s.session_id,
    mg.granted_memory_kb,
    mg.used_memory_kb,
    mg.max_used_memory_kb,
    t.text AS query_text
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
LEFT JOIN sys.dm_exec_query_memory_grants mg ON mg.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE mg.granted_memory_kb > 0
ORDER BY mg.granted_memory_kb DESC;
```

**Resolution:**

1. Tune the memory-intensive queries — add missing indexes, reduce sort sizes, avoid unnecessary `ORDER BY` on large result sets.
2. Use Query Store to check if the problem is new (plan regression) or chronic.
3. If the workload legitimately needs more memory, scale up to a higher service tier.

> **Tip:** The query that *receives* the OOM error isn't necessarily the one *causing* the problem. Often, one session hoards a large memory grant while a smaller query gets denied. Look at the biggest grant holders, not just the failed query.

---

## Transaction Log Full Errors

In Azure SQL Database, the transaction log is managed automatically — you don't control file sizes, backup frequency, or file placement. But the log can still fill up if something prevents truncation.
<!-- Source: resources/troubleshoot/troubleshoot-transaction-log-errors-issues.md -->

### Error 9002: Transaction Log Full

**Symptom:** "The transaction log for database '%ls' is full due to '%ls'."

### Error 40552: Excessive Transaction Log Space

**Symptom:** "The session has been terminated because of excessive transaction log space usage."

### Why the Log Can't Truncate

The transaction log truncates after each successful log backup. When something blocks truncation, the log grows until it hits the tier's maximum size and then starts rejecting writes. Check what's blocking truncation:

```sql
SELECT [name], log_reuse_wait_desc FROM sys.databases;
```

| log_reuse_wait_desc | Cause | Action |
|---|---|---|
| `NOTHING` | Normal — nothing blocked | None required |
| `ACTIVE_TRANSACTION` | Long-running or uncommitted txn | Find and resolve (see query below) |
| `REPLICATION` | CDC scan job behind or erroring | Check `sys.dm_cdc_errors` |
| `AVAILABILITY_REPLICA` | Sync to secondary in progress | Usually self-resolves; contact support if persistent |
| `CHECKPOINT` | Checkpoint pending | Usually self-resolves |
| `LOG_BACKUP` | Log backup needed | Usually self-resolves |

### Finding the Blocking Transaction

```sql
SELECT
    tat.transaction_id,
    tat.transaction_begin_time,
    tst.session_id,
    DATEDIFF(SECOND, tat.transaction_begin_time, SYSDATETIME()) AS duration_seconds,
    ib.event_info AS last_statement,
    r.status AS request_status,
    r.blocking_session_id
FROM sys.dm_tran_active_transactions tat
JOIN sys.dm_tran_session_transactions tst
    ON tat.transaction_id = tst.transaction_id
JOIN sys.dm_exec_sessions s
    ON s.session_id = tst.session_id
CROSS APPLY sys.dm_exec_input_buffer(s.session_id, NULL) ib
LEFT JOIN sys.dm_exec_requests r
    ON r.session_id = s.session_id
ORDER BY tat.transaction_begin_time ASC;
```

Look for transactions with high `duration_seconds` and a NULL `request_status` — that's a session holding a transaction open with no active query, often an application that started a transaction and never committed it.

### Preventing Log Full Conditions

- **Batch large operations.** A single `UPDATE` touching millions of rows generates a massive log record. Break it into batches of 10,000–50,000 rows.
- **Use `RESUMABLE = ON` for index rebuilds.** Resumable index operations allow log truncation between batches, preventing the single-transaction log explosion.
- **Don't hold transactions open during external calls.** Begin the transaction, do the database work, commit. Call your API separately.
- **Monitor log space usage proactively.** Set alerts on log percentage used in Azure Monitor.

> **Warning:** If you're using Change Data Capture (CDC), a stuck CDC scan job can prevent log truncation indefinitely. Check `sys.dm_cdc_errors` and ensure the CDC jobs are running. A database with CDC enabled and a broken scan job will eventually fill its transaction log and stop accepting writes.

---

## Import/Export Performance Issues

The Azure portal's Import/Export service uses a shared, REST-based backend that's convenient but not fast. If your export is taking hours or hanging, here's why.
<!-- Source: resources/troubleshoot/database-import-export-hang.md -->

### Why Import/Export Is Slow

- **Shared compute.** The service allocates a limited number of VMs per region. During high-demand periods, your job queues behind others.
- **Logical backup format.** BACPAC is a logical export (schema + data as BCP-format files), not a physical backup. It processes every row and every object.
- **Large tables without clustered indexes.** Tables without a clustered index can't be parallelized during export. The service exports them as a single serial operation.
- **Auto-cancel after 2 days.** If a job doesn't finish within 48 hours, the service cancels it automatically.

### Faster Alternatives

| Approach | When to Use |
|---|---|
| SqlPackage (CLI) | Most scenarios — you control the compute |
| DacFx API | Programmatic export/import in your code |
| SSMS Export | Quick interactive option, smaller DBs |
| `bcp` (bulk copy) | Data-only, no schema needed |

Run SqlPackage from a VM in the same Azure region as your database — cross-region latency kills export performance. If you need full control over parallelism and timeouts, the DacFx API lets you embed export/import in your own tooling.

> **Tip:** Make sure every table has a clustered index before exporting. Tables without one can't be parallelized and export as a single serial operation — it's the single biggest factor in export speed.

### Import/Export and Resource Consumption

Both import and export consume DTUs/CPU on the target database. If your database is already under load, the operation will be throttled and slow. Consider scaling up temporarily before a large import, then scaling back down afterward.

---

## Geo-Replication Redo Lag

Active geo-replication is asynchronous — the secondary continuously receives and replays transaction log records from the primary, but it can fall behind. When it does, you get stale reads on the secondary and longer failover times.
<!-- Source: resources/troubleshoot/troubleshoot-geo-replication-redo.md -->

### Key Concepts

- **Redo queue:** The volume of log records shipped to the secondary but not yet applied.
- **Redo lag:** The time between a transaction committing on the primary and its replay completing on the secondary.

### Symptoms of Redo Lag

- Read-only queries on the secondary return stale data.
- Failover takes longer than expected (higher RTO).
- `redo_queue_size` is growing in `sys.dm_database_replica_states`.
- `secondary_lag_seconds` is increasing.

### Monitoring Redo Lag

```sql
SELECT
    database_id,
    redo_queue_size,
    redo_rate,
    secondary_lag_seconds,
    last_commit_time
FROM sys.dm_database_replica_states;
```

### Common Causes

| Cause | Why It Happens |
|---|---|
| Undersized secondary | Fewer resources than the primary |
| Large index rebuilds | SCH-M locks block the redo thread |
| High log generation rate | Writes outpace secondary replay |
| Resource contention | CPU/IO pressure slows redo |

- **Undersized secondary:** If the secondary has fewer vCores or DTUs than the primary, it simply can't replay logs as fast as the primary generates them. This is the most common cause.
- **Large index rebuilds:** Schema modification (SCH-M) locks block the redo thread on the secondary, and the rebuild itself generates massive log volume.
- **High log generation rate:** Heavy write workloads on the primary can outpace the secondary's replay capacity even when resources match.
- **Resource contention:** Read-only query workload on the secondary competes with redo for CPU and I/O.

### Resolution

1. **Match the secondary's SLO to the primary.** This is the most common fix. A secondary with fewer resources *will* fall behind under any non-trivial write workload.
2. **Avoid large index rebuilds during peak write periods.** They generate massive log volumes and acquire SCH-M locks that block redo.
3. **Reduce long-running transactions on the primary.** Shorter transactions mean smaller redo batches and faster replay.
4. **Monitor regularly.** Set alerts on `secondary_lag_seconds` in Azure Monitor to catch drift before it becomes a failover risk.

> **Important:** Redo lag doesn't cause waits on the primary — your primary's write performance is unaffected. But it directly impacts the freshness of read-only queries routed to the secondary and your effective RTO during failover.

---

## SQL Managed Instance Known Issues

Managed Instance has a separate known-issues list maintained by Microsoft. The issues below are the most impactful ones with workarounds you should know about. For the full, current list, check the Microsoft Learn documentation.
<!-- Source: resources/troubleshoot/doc-changes-updates-known-issues.md -->

### Restore Failures After Migration from SQL Server 2019+

If you migrated a database from SQL Server 2019 or later with Accelerated Database Recovery (ADR) enabled but the persistent version store (PVS) was set to something other than the `PRIMARY` filegroup, restore operations on the target Managed Instance will fail.

**Fix:** Before migration, set the PVS to `PRIMARY` on the source SQL Server database. If you've already migrated, set PVS to `PRIMARY` on the source and re-migrate.

### Service Broker Disabled After Migration

If Service Broker was disabled on the source SQL Server database before migration, it remains disabled on the Managed Instance and can't be enabled.

**Fix:** Enable Service Broker on the source database before migrating. If already migrated, enable it on the source and re-migrate.

### sp_send_dbmail Fails with @query Under sysadmin

The `sp_send_dbmail` stored procedure can fail when using the `@query` parameter if executed under a sysadmin account, due to an impersonation bug.

**Fix:** Execute `sp_send_dbmail` from a dedicated non-sysadmin account.

### Error 8992 After Deleting Indexes

Running `DBCC CHECKDB` on a SQL Server 2022 database that originated from Managed Instance can produce error 8992 after deleting an index.

**Fix:** Drop the index on the source Managed Instance database first, then restore or link to SQL Server 2022 again.

> **Warning:** If you create a partitioned index on the affected table after dropping the original index, the table becomes inaccessible. Drop the index on the source first.

### Failover Group Listener Inaccessibility During Scaling

During a scaling operation on Managed Instance, the failover group listener may become temporarily inaccessible.

**Fix:** Your application's retry logic (see Chapter 4) should handle this. Expect brief connection failures during scaling operations, and ensure your retry intervals are long enough to outlast the scaling window.

---

## Quick Diagnostic Queries
<!-- Note: This section is bonus material beyond the outline scope — kept for practical value. -->

These queries are the ones you'll reach for most often. Bookmark this section.

### Current Blocking Chains

```sql
SELECT
    r.session_id AS blocked_session,
    r.blocking_session_id AS blocking_session,
    r.wait_type,
    r.wait_time / 1000.0 AS wait_seconds,
    t.text AS blocked_query
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id <> 0
ORDER BY r.wait_time DESC;
```

### Top CPU-Consuming Queries (Last Hour)

```sql
SELECT TOP 10
    qs.query_hash,
    SUM(qs.total_worker_time) / 1000 AS total_cpu_ms,
    SUM(qs.execution_count) AS executions,
    SUM(qs.total_worker_time) / SUM(qs.execution_count) / 1000
        AS avg_cpu_ms,
    MIN(SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
        CASE qs.statement_end_offset
            WHEN -1 THEN LEN(CONVERT(NVARCHAR(MAX), st.text))
            ELSE (qs.statement_end_offset - qs.statement_start_offset) / 2 + 1
        END)) AS sample_query
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE qs.last_execution_time > DATEADD(HOUR, -1, GETUTCDATE())
GROUP BY qs.query_hash, qs.statement_start_offset,
    qs.statement_end_offset, st.text
ORDER BY total_cpu_ms DESC;
```

### Transaction Log Space Usage

```sql
DBCC SQLPERF(LOGSPACE);
```

### Active Memory Grants

```sql
SELECT
    session_id,
    granted_memory_kb,
    used_memory_kb,
    max_used_memory_kb,
    grant_time,
    wait_time_ms
FROM sys.dm_exec_query_memory_grants
WHERE granted_memory_kb > 0
ORDER BY granted_memory_kb DESC;
```

### Geo-Replication Status

```sql
SELECT
    database_id,
    synchronization_state_desc,
    synchronization_health_desc,
    redo_queue_size,
    secondary_lag_seconds
FROM sys.dm_database_replica_states;
```

For deeper diagnostics, Chapter 14 covers monitoring and observability, and Chapter 15 covers performance tuning with Query Store and DMVs.
