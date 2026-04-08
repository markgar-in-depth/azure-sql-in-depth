# Chapter 18: Moving Data

Every database eventually needs to move — across servers, between environments, out to a warehouse, or into a new region. Azure SQL provides several mechanisms for these scenarios, from one-time BACPAC exports to real-time change data capture. The trick is matching the right tool to the right job.

This chapter covers each data movement mechanism available across Azure SQL Database and Managed Instance. Some are for bulk, one-shot operations. Others provide continuous streams. A few handle distributed consistency across multiple databases. By the end, you'll know which tool to reach for and when.

## BACPAC Import and Export

A **BACPAC** file is a ZIP archive (with a `.bacpac` extension) containing both the schema and data of a database. It's the go-to format for archiving databases, moving them between environments, or migrating to Azure SQL from on-premises SQL Server.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/load-and-move-data/database-export.md -->

> **Important:** BACPACs aren't backups. Azure automatically manages point-in-time backups for every user database. Use BACPACs for archival, cross-platform moves, and migrations — not for disaster recovery.

### How Export Works

Exporting creates a transactionally consistent snapshot of your database. If your database has active writes during the export, you should either quiesce writes or export from a database copy (covered later in this chapter) to guarantee consistency.

Key constraints on export:

- Maximum BACPAC size when exporting to Azure Blob storage is **200 GB**. For larger databases, export to local storage using SqlPackage.
- Export operations that exceed **20 hours** may be canceled by the service.
- Exporting to Azure premium storage isn't supported.
- Storage behind a firewall or with immutable storage isn't supported.

### Tools for Import and Export

You have several options for running BACPAC operations:

| Tool | Import | Export | Notes |
|---|---|---|---|
| Azure portal | Yes | Yes | SQL Database only |
| SqlPackage CLI | Yes | Yes | Best for production |
| SSMS wizard | Yes | Yes | Works for both DB and MI |
| PowerShell | Yes | Yes | SQL Database only |
| Azure CLI | Yes | No | Import only |
| VS Code (MSSQL) | Yes | Yes | Preview experience |

> **Tip:** For production workloads, always use SqlPackage. The portal and PowerShell route import/export through a shared service with **450 GB local disk space** — databases larger than 150 GB frequently fail with disk space errors. SqlPackage runs on your own machine, so you control the resources.
<!-- Source: azure-sql-database-sql-db/how-to/load-and-move-data/database-import.md -->

A basic SqlPackage export looks like this:

```bash
SqlPackage /a:Export \
  /tf:mydb.bacpac \
  /scs:"Data Source=myserver.database.windows.net;Initial Catalog=MyDB;" \
  /ua:True \
  /tid:"contoso.onmicrosoft.com"
```

And the corresponding import:

```bash
SqlPackage /a:Import \
  /sf:mydb.bacpac \
  /tcs:"Data Source=targetserver.database.windows.net;Initial Catalog=NewDB;User Id=sqladmin;Password=<password>" \
  /p:DatabaseEdition=GeneralPurpose \
  /p:DatabaseServiceObjective=GP_Gen5_4
```

> **Gotcha:** The Import/Export service doesn't support Microsoft Entra ID authentication when MFA is required. If your environment enforces MFA, run SqlPackage locally with `--ua:True` for interactive Entra auth, or use a service principal.

### Managed Identity Workflows (Preview)

Azure SQL Database supports import and export using **managed identity** authentication, eliminating the need to pass SQL admin credentials or storage keys. The setup requires:

1. A **user-assigned managed identity (UAMI)** assigned to the logical server.
2. The managed identity configured as the **Microsoft Entra administrator** on the server.
3. The identity granted **Storage Blob Data Contributor** (for export) or **Storage Blob Data Reader** (for import) on the target storage account.
4. The logical server, managed identity, and storage account all in the **same Entra tenant**.
<!-- Source: azure-sql-database-sql-db/tutorials/move-data/database-import-export-managed-identity.md -->

Credential-free operations are preferable when your environment supports them.

### Import/Export with Azure Services Access Disabled

If you've disabled the "Allow Azure services and resources to access this server" setting (and you should, for production), the portal-based import/export won't work. You have two options:

1. **Run SqlPackage from an Azure VM** in the same region, with the VM's IP added to the server firewall. This gives you full control over disk space and network proximity.
2. **Use Private Link** (preview) — the import/export service creates service-managed private endpoints in the same VNet as your SQL server's existing private endpoint. You must manually approve the private endpoint connections for both the SQL server and the storage account before the operation proceeds.
<!-- Source: azure-sql-database-sql-db/how-to/load-and-move-data/database-import-export-azure-services-off.md, azure-sql-database-sql-db/how-to/load-and-move-data/database-import-export-private-link.md -->

> **Gotcha:** When using Private Link for import, you can't specify backup storage redundancy. The service creates the database with the default geo-redundant backup. Workaround: create an empty database with your preferred redundancy first, then import the BACPAC into it.

### Managed Instance Differences

Managed Instance can't export BACPACs via the Azure portal or PowerShell — you must use SqlPackage or SSMS. Import is similarly limited: the portal and PowerShell aren't supported for MI. SqlPackage or SSMS is your only path — no portal shortcut here.

## Database Copy

**Database copy** creates a transactionally consistent snapshot of a database on the same or a different logical server. Under the hood, it uses the same geo-replication technology that powers active geo-replication — it seeds the copy, then automatically terminates the replication link when seeding completes.
<!-- Source: azure-sql-database-sql-db/how-to/load-and-move-data/database-copy.md -->

The simplest form is a T-SQL statement:

```sql
-- Same server
CREATE DATABASE OrdersArchive AS COPY OF Orders;

-- Different server (run on the target server's master database)
CREATE DATABASE OrdersArchive AS COPY OF sourceserver.Orders;

-- Into an elastic pool
CREATE DATABASE OrdersArchive
AS COPY OF Orders
(SERVICE_OBJECTIVE = ELASTIC_POOL(name = archive_pool));
```

### Hyperscale Copy Behavior

For Hyperscale databases, copy behavior depends on the target location:

- **Same region, same backup redundancy:** Fast copy from blob snapshots — effectively instant regardless of database size.
- **Different region or different backup redundancy:** Size-of-data copy, though page server blobs are copied in parallel.

### Key Considerations

- The copy is fully independent after completion — logins, users, and permissions are managed separately.
- When copying cross-server, **contained database users** are the simplest path. Server-level logins won't exist on the target and must be recreated with matching SIDs.
- Cross-subscription copies are supported via T-SQL (with matching SQL auth logins on both sides), but not via the portal, PowerShell, or Azure CLI. The portal and CLI tools can't authenticate across subscription boundaries, so T-SQL with SQL auth is the only way to bridge that gap.
- You can't copy via T-SQL when connecting to the destination over a **private endpoint** exclusively — public network access must be enabled during the copy.

> **Tip:** If you need a copy with a substantially smaller service objective than the source, the target may lack resources to complete seeding and the copy will fail. In this case, use geo-restore instead.

Monitor copy progress using DMVs:

```sql
SELECT state_desc, replication_lag_sec
FROM sys.dm_database_copies;
```

## Change Data Capture (CDC)

**Change data capture** records row-level insert, update, and delete operations to change tables within the same database. It's designed for downstream ETL — feeding an incremental change stream to a data warehouse, event pipeline, or sync process.
<!-- Source: azure-sql-database-sql-db/how-to/load-and-move-data/change-data-capture-overview.md -->

### How It Works in Azure SQL Database

In SQL Server, CDC relies on SQL Agent jobs. Azure SQL Database replaces these with a built-in **scheduler** that runs capture and cleanup automatically:

- **Capture job:** Runs every **20 seconds**.
- **Cleanup job:** Runs every **hour**, with a default retention of 3 days.

You can't change these frequencies. But you can adjust `maxtrans`, `maxscans`, and the retention period via `sp_cdc_change_job`.

### Enabling CDC

Enable at the database level first, then on individual tables:

```sql
-- Enable CDC for the database
EXEC sys.sp_cdc_enable_db;
GO

-- Enable CDC on a specific table
EXEC sys.sp_cdc_enable_table
    @source_schema = N'Sales',
    @source_name   = N'Orders',
    @role_name     = NULL,
    @supports_net_changes = 1;
GO
```

Setting `@supports_net_changes = 1` generates a net changes function that returns only the final state of each row within a time window — useful when you only care about the end result, not every intermediate change.

### Service Tier Requirements

CDC is available on **any vCore tier** — including serverless, General Purpose, Business Critical, and Hyperscale. In the DTU model, you need **S3 or higher**. Basic, S0, S1, and S2 don't support CDC.

> **Gotcha:** When CDC is enabled, the aggressive log truncation behavior of Accelerated Database Recovery (ADR) is disabled. Active transactions prevent log truncation until CDC scan catches up. Monitor log utilization closely, especially on databases with heavy write workloads — you may need to scale up to prevent log full conditions.

### Performance Impact

CDC adds overhead proportional to write volume. Each tracked change writes additional rows to change tables. The capture process itself consumes CPU and log throughput. Key recommendations:

- Test with your production workload before enabling CDC.
- Monitor space utilization — CDC artifacts live in the same database.
- For elastic pools, CDC-enabled databases share pool resources. Don't enable CDC on more databases than you have vCores in the pool.
- Consider Hyperscale if you need higher log throughput to absorb CDC overhead.

> **Note:** There's no SLA on how quickly changes appear in change tables. Subsecond latency is not supported.

## Transactional Replication

Transactional replication pushes changes from a publisher to one or more subscribers in near real-time. It's a mature SQL Server feature that works across Azure SQL Database, Managed Instance, SQL Server on VMs, and on-premises SQL Server.
<!-- Source: azure-sql-database-sql-db/how-to/load-and-move-data/replication-to-sql-database.md, azure-sql-managed-instance-sql-mi/concepts/sql-server-features/replication-transactional-overview.md -->

### The Role Matrix

Understanding what each deployment option can do in a replication topology is critical:

| Role | SQL Database | Managed Instance |
|---|---|---|
| Publisher | No | Yes |
| Distributor | No | Yes |
| Push subscriber | Yes | Yes |
| Pull subscriber | No | Yes |

Azure SQL Database can **only be a push subscriber** — it can't publish or distribute. If you need to publish from the cloud, use Managed Instance.

### Supported Replication Types

| Type | SQL Database | Managed Instance |
|---|---|---|
| Standard transactional | Subscriber only | Full |
| Snapshot | Subscriber only | Full |
| Bidirectional | No | Yes |
| Merge | No | No |
| Peer-to-peer | No | No |

### Common Topologies

**SQL Server → Azure SQL Database:** The classic migration and ongoing sync pattern. SQL Server (on-premises or VM) acts as publisher and distributor, with Azure SQL Database as a push subscriber. This works for data migration where you cut over after replication stabilizes.

**Managed Instance → Managed Instance:** Both instances can be publisher, distributor, and subscriber. You can place the distributor on the same instance as the publisher or on a separate instance (both must be in the same VNet and region).

**Managed Instance → Azure SQL Database:** MI publishes, SQL DB subscribes. Useful for feeding a read-optimized SQL Database from a MI that handles the write workload.

### Key Limitations

- Replicated tables **must have a primary key**.
- The distribution database and replication agents can't live in Azure SQL Database — only in MI or SQL Server.
- Merge replication and peer-to-peer replication aren't supported anywhere in Azure SQL.
- Replication management, monitoring, and troubleshooting must happen from the publisher or distributor — not from the subscriber.
- Snapshot files on Azure Storage aren't automatically cleaned up by MI. Delete them manually when no longer needed.

> **Tip:** MI limits distribution agents configured to run continuously to **30**. Need more? Switch to scheduled agents with a frequency as low as every 10 seconds — you'll see only a few seconds of added latency.

## Database Copy and Move (Managed Instance)

Managed Instance offers a dedicated **copy and move** feature that uses Always On availability group technology to replicate databases across instances — including across different subscriptions within the same Entra tenant.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage/database-copy-move-how-to.md -->

### How It Works

1. You initiate a copy or move operation (via portal, PowerShell, or CLI).
2. The service seeds the destination using Always On AG technology.
3. Once seeding completes, the operation enters a **"ready for completion"** state. Changes continue replicating until you explicitly complete the operation.
4. You have **24 hours** to complete the operation — after that, it auto-cancels and drops the destination database.
5. For a **copy**, both databases become independent after completion. For a **move**, the source database is dropped.

> **Important:** The move operation guarantees **zero data loss**. When you complete the move, the source stops accepting workloads, the final transaction log is replicated to the destination, and only then does the destination come online and the source get dropped.

### Seeding Performance

Under optimal conditions with global VNet peering, seeding runs up to **360 GB per hour**. Monitor progress via:

```sql
SELECT role_desc, transfer_rate_bytes_per_second,
       transferred_size_bytes, database_size_bytes,
       estimate_time_complete_utc
FROM sys.dm_hadr_physical_seeding_stats;
```

### Limitations

- Source and destination must be in the **same Azure region**.
- A source instance can run multiple copy/move operations concurrently (additional operations queue automatically).
- You can't rename a database during the operation.
- PITR backups don't transfer — the destination starts a fresh backup chain.
- Databases in failover groups or using the Managed Instance link can't participate.
- The destination instance must have a matching or higher **update policy** version than the source. The update policy (SQL Server 2022, SQL Server 2025, or Always-up-to-date) controls the internal database format, and a higher-version instance can read a lower-version format but not the reverse. Once a database moves to a higher update policy, it can't go back.

## SQL Data Sync (Retiring September 2027)

**SQL Data Sync** provides hub-and-spoke bidirectional synchronization across multiple databases in Azure SQL Database and on-premises SQL Server. The hub must be an Azure SQL Database; members can be SQL Database or SQL Server instances.
<!-- Source: azure-sql-database-sql-db/concepts/sql-data-sync/sql-data-sync-data-sql-server-sql-database.md, azure-sql-database-sql-db/concepts/sql-data-sync/sql-data-sync-retirement-migration.md -->

> **Warning:** SQL Data Sync retires on **September 30, 2027**. Don't build new solutions on it. Plan your migration to alternatives now.

Data Sync tracks changes via insert, update, and delete triggers and synchronizes them according to a configurable interval. Conflict resolution is straightforward: **hub wins** or **member wins**.

### Why It's Being Retired

Data Sync has significant drawbacks:

- **No transactional consistency** — syncs are eventual and trigger-based.
- **SQL authentication only** — no Entra ID support, no managed identities. This is a security gap.
- **Higher performance impact** than replication alternatives.
- **No Managed Instance support.**

### Migration Alternatives

The right replacement depends on your scenario:

| Scenario | Alternatives |
|---|---|
| Hybrid sync (on-prem ↔ cloud) | Replication, Always On AGs, ADF |
| Distributed read workloads | Read replicas, geo-replication, copy |
| Global data distribution | Geo-replication, ADF |
| General data movement | ADF, Fabric mirrored databases |

If you're using Data Sync for simple hub-spoke synchronization between Azure SQL databases, transactional replication via Managed Instance is typically the cleanest replacement — it offers lower latency and transactional consistency.

## Elastic Database Transactions

When your application spans multiple Azure SQL databases — whether vertically partitioned or horizontally sharded — you sometimes need atomic operations across them. **Elastic database transactions** provide distributed two-phase commit without requiring MSDTC.
<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-transactions-overview.md -->

### How It Works

Elastic transactions integrate with .NET's `System.Transactions` namespace. Open multiple `SqlConnection` objects within a `TransactionScope`, and the runtime automatically promotes to a distributed transaction:

```csharp
using (var scope = new TransactionScope())
{
    using (var conn1 = new SqlConnection(connStrDb1))
    {
        conn1.Open();
        var cmd1 = conn1.CreateCommand();
        cmd1.CommandText = "INSERT INTO Orders VALUES (1, 'Widget', 10)";
        cmd1.ExecuteNonQuery();
    }

    using (var conn2 = new SqlConnection(connStrDb2))
    {
        conn2.Open();
        var cmd2 = conn2.CreateCommand();
        cmd2.CommandText = "UPDATE Inventory SET Qty = Qty - 10 WHERE Item = 'Widget'";
        cmd2.ExecuteNonQuery();
    }

    scope.Complete();
}
```

For sharded applications using the Elastic Database client library, use `OpenConnectionForKey` instead of direct connection strings to route to the correct shard (→ see Chapter 19 for shard map details).

### Setup for SQL Database

Before databases on different logical servers can participate in elastic transactions, you must establish **communication links** between the servers:

```powershell
New-AzSqlServerCommunicationLink `
  -ServerName "server1" `
  -PartnerServer "server2" `
  -ResourceGroupName "myRG"
```

The link is symmetric — once created, databases on either server can initiate transactions with the other.

### Setup for Managed Instance

Managed instances use **server trust groups** instead of communication links. Instances in the same trust group can execute distributed transactions using both .NET (`TransactionScope`) and T-SQL (`BEGIN DISTRIBUTED TRANSACTION` via linked servers).

```sql
-- On Managed Instance (T-SQL distributed transactions)
SET XACT_ABORT ON;
BEGIN DISTRIBUTED TRANSACTION;

DELETE AdventureWorks.HumanResources.JobCandidate
    WHERE JobCandidateID = 13;
DELETE RemoteServer.AdventureWorks.HumanResources.JobCandidate
    WHERE JobCandidateID = 13;

COMMIT TRANSACTION;
```

> **Important:** Elastic transactions between Azure SQL Database and Managed Instance aren't supported. You can span databases within SQL Database *or* within Managed Instance, but not across the two deployment types.

### Limitations

- SQL Database supports only **client-side** (.NET) coordination — no T-SQL `BEGIN DISTRIBUTED TRANSACTION`.
- Managed Instance supports both .NET and T-SQL distributed transactions.
- Performance is best with fewer than **100 databases** per transaction. The limit isn't enforced, but success rates degrade beyond it.
- WCF service transactions aren't supported.
- SQL Database elastic transactions can't include resources outside of SQL Database — no on-premises SQL Server, no other RDBMS. For those scenarios on MI, use DTC (next section).

## Distributed Transaction Coordinator (Managed Instance)

For scenarios that elastic transactions can't cover — transactions spanning Managed Instance, on-premises SQL Server, and external RDBMS systems — Managed Instance provides a **managed DTC** service. It's the same Windows DTC you know from on-premises, but Azure handles the infrastructure: logging, storage, availability, and networking.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/distributed-transaction-coordinator-dtc.md -->

### When to Use DTC vs. Elastic Transactions

| Scenario | Use |
|---|---|
| MI ↔ MI (databases only) | Elastic transactions |
| MI ↔ SQL Server | DTC |
| MI ↔ External RDBMS | DTC |
| MI ↔ Custom app (XA, COM+, ODBC, JDBC) | DTC |

> **Note:** DTC also works for MI ↔ MI scenarios, but elastic transactions are the better choice — they're simpler and don't require network configuration beyond trust groups.

Reach for DTC only when you need to cross outside the managed instance boundary to external participants.

### Configuration

Enable DTC via the portal, PowerShell, or CLI:

```powershell
Set-AzSqlInstanceDtc `
  -InstanceName "myMI" `
  -ResourceGroupName "myRG" `
  -DtcEnabled $true
```

You'll also need to configure:

- **Network connectivity:** Port 135 for inbound/outbound, ports 14000–15000 for inbound, and ports 49152–65535 for outbound in both the VNet NSG and any external firewalls.
- **DNS settings:** DTC uses NetBIOS names for participant resolution. Since Azure networking doesn't support NetBIOS, DTC relies on DNS. Register external DTC hosts with a DNS server and exchange DNS suffixes between the MI VNet and the external environment.

> **Note:** DNS configuration isn't required if you're only using DTC for XA transactions.

### Limitations

- Distributed T-SQL transactions between MI and third-party RDBMS aren't supported (linked servers to third-party systems aren't supported). Use XA, COM+, or ODBC/JDBC instead.
- External host names can't exceed **15 characters** (NetBIOS limit).
- Distributed transactions to **Azure SQL Database** aren't supported via DTC.
- DTC supports only the **"no authentication"** option. Mutual authentication isn't available — but since DTC communicates only within the VNet exchanging sync messages (not user data), this isn't the security risk it sounds like.

## Choosing the Right Data Movement Tool

With this many options, the decision tree matters. Here's a quick reference:

| Need | Tool |
|---|---|
| One-time database archive or migration | BACPAC import/export |
| Transactionally consistent snapshot | Database copy |
| Incremental change feed for ETL | CDC |
| Continuous replication to subscribers | Transactional replication |
| Move databases between MI instances | MI copy/move |
| Bidirectional sync (legacy) | SQL Data Sync (retiring) |
| Atomic writes across multiple databases | Elastic transactions |
| Distributed transactions with external systems | DTC (MI only) |

In the next chapter, we'll explore the Elastic Database Tools that let you shard data across many databases — and how elastic transactions fit into that picture.
