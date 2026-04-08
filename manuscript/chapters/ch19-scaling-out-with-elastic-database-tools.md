# Chapter 19: Scaling Out with Elastic Database Tools

Your database just hit the ceiling. Even the largest single Azure SQL Database has a hard upper bound on compute and storage — and some workloads blow past it. Maybe you're running a SaaS platform with thousands of tenants who each expect isolated performance. Maybe your transaction throughput needs more parallelism than one database engine can provide. Maybe compliance requirements demand that certain tenants' data lives in specific geographies.

When scaling *up* isn't enough, you scale *out*. Sharding — distributing data across multiple databases based on a key — is the classic horizontal scaling pattern. It's also one of the hardest things to get right. Azure SQL Database's **Elastic Database tools** exist to take the worst of that pain away: a client library for shard map management and data-dependent routing, a split-merge service for online data rebalancing, and elastic queries for cross-database reporting. This chapter covers all of it.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-introduction.md -->

## Horizontal Sharding Architecture

Vertical scaling means giving a single database more resources — more vCores, more memory. It's simple, it requires no application changes, and it has a hard ceiling. Horizontal scaling means spreading data across multiple databases, each handling a slice of the workload. The databases are identical in schema; they differ only in which rows they hold.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-introduction.md -->

The combination is common in practice. A SaaS application might use horizontal scaling to provision new tenants across separate databases while using vertical scaling to let individual databases grow or shrink as each tenant's workload demands.

### Single-Tenant and Multi-Tenant Shard Patterns

There are two fundamental approaches to distributing tenants across shards:

**Single-tenant sharding** assigns one database per tenant. Each database is associated with a specific tenant ID, but that key doesn't need to exist in the data itself — the application routes requests to the correct database, and everything inside belongs to that tenant. This pattern gives you full isolation: independent backup/restore, independent scaling, and no noisy-neighbor risk.

**Multi-tenant sharding** packs multiple tenants into each database. Every row carries a sharding key column (typically a tenant ID), and the application routes requests based on that key. This pattern is cheaper when you have large numbers of small tenants — you're amortizing database overhead across many customers. The trade-off is reduced isolation. You'll want row-level security (→ see Chapter 8) to prevent cross-tenant data leaks, and you'll need the split-merge tool to rebalance when one database gets overloaded.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-introduction.md -->

> **Tip:** A common SaaS pattern is to start new customers in a shared multi-tenant database during a trial period, then use the split-merge tool to move them to a dedicated single-tenant database when they convert to a paid plan. This keeps trial costs low while giving paying customers full isolation.

> **Gotcha:** Sharding works best when every transaction operates on a single shard. Cross-shard transactions are possible through elastic database transactions (→ see Chapter 18), but they add latency and complexity. Design your schema so cross-shard operations are the exception, not the rule.

The sharding key you choose determines how data is distributed, and it's the most consequential design decision in a sharded architecture. A good key has three qualities:

- **High cardinality.** Enough distinct values to distribute data evenly across shards. Low-cardinality keys create hotspots.
- **Stability.** Updating a sharding key means moving data between databases — an expensive operation you want to avoid.
- **Query-pattern alignment.** The vast majority of queries should include the key in their predicates so they route to a single shard.

Tenant ID is the most common choice for SaaS workloads because nearly every query is scoped to a single tenant. Date-based keys work for time-series ingestion. Avoid composite keys — they complicate routing without adding real value.

## The Elastic Database Client Library

The **Elastic Database client library** is the core of the toolset. It's a .NET and Java library that manages shard maps, routes connections to the correct database, and executes fan-out queries across multiple shards. Install it from NuGet (`Microsoft.Azure.SqlDatabase.ElasticScale.Client`) or Maven Central.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-database-client-library.md -->

The library provides three capabilities:

| Capability | What It Does |
|---|---|
| Shard map management | Tracks which databases exist and which key ranges they own |
| Data-dependent routing | Opens a connection to the right shard based on a sharding key value |
| Multi-shard queries | Fans out a query to all shards and merges results with `UNION ALL` |

### Shard Map Management

A **shard map** is the metadata layer that tracks the mapping between sharding key values and physical databases. The shard map lives in a dedicated database called the **shard map manager** (SMM). The library stores this metadata in tables under the `__ShardManagement` schema — you don't touch them directly.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-shard-map-management.md -->

The metadata is maintained at three levels:

1. **Global Shard Map (GSM):** A single database that holds the complete picture — every shard, every mapping. This is a small, lightly accessed database. Don't co-locate it with application data.
2. **Local Shard Map (LSM):** Each shard database contains a copy of the mappings relevant to itself. The LSM lets the library validate cached lookups without hitting the GSM on every request.
3. **Application cache:** The client library caches mappings in memory. Most routing operations resolve from cache without any database call at all.

> **Important:** Instantiate `ShardMapManager` only once per app domain. Creating additional instances wastes memory and CPU. A single instance can contain any number of shard maps.

#### List and Range Shard Maps

The library supports two types of shard maps, and the choice depends on your tenancy model:

**List shard maps** map individual key values to databases. Each value maps to exactly one shard, but multiple values can point to the same shard. This is the natural fit for single-tenant-per-database and for multi-tenant models where you want explicit control over which tenants share a database.

**Range shard maps** map contiguous ranges of key values to databases. A range `[0, 100)` includes all keys from 0 up to (but not including) 100. Ranges must be disjoint but don't need to be contiguous — gaps are allowed. This works well for multi-tenant models where you assign blocks of tenant IDs to each shard.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-shard-map-management.md -->

Both .NET and Java support `int`, `long`, `Guid`/`UUID`, `byte[]`, `DateTime`/`Timestamp`, `TimeSpan`/`Duration`, and `DateTimeOffset`/`OffsetDateTime` as shard key types.

#### Creating the Shard Map Manager

You create the SMM once, then retrieve it on subsequent application starts:

```csharp
// First-time setup: create the shard map manager
ShardMapManager shardMapManager;
bool exists = ShardMapManagerFactory.TryGetSqlShardMapManager(
    connectionString,
    ShardMapManagerLoadPolicy.Lazy,
    out shardMapManager);

if (!exists)
{
    ShardMapManagerFactory.CreateSqlShardMapManager(connectionString);
    shardMapManager = ShardMapManagerFactory.GetSqlShardMapManager(
        connectionString,
        ShardMapManagerLoadPolicy.Lazy);
}
```

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-shard-map-management.md -->

Then create a shard map and register shards:

```csharp
// Create a range shard map for tenant IDs
RangeShardMap<int> tenantMap;
if (!shardMapManager.TryGetRangeShardMap("tenantMap", out tenantMap))
{
    tenantMap = shardMapManager.CreateRangeShardMap<int>("tenantMap");
}

// Register a shard and create a mapping
var shard = tenantMap.CreateShard(
    new ShardLocation("server1.database.windows.net", "tenants_0"));
tenantMap.CreateRangeMapping(
    new Range<int>(0, 1000), shard);
```

> **Gotcha:** `CreateShard`, `DeleteShard`, and the mapping methods only modify metadata in the shard map. They don't create or delete the actual databases, and they don't move any user data. You provision databases separately — the shard map just tracks them.

### Data-Dependent Routing

**Data-dependent routing** (DDR) is the core routing mechanism. You give the library a sharding key value, and it returns an open `SqlConnection` to the correct shard database. No connection string juggling, no lookup tables — the library resolves it from the shard map and its in-memory cache.

```csharp
int tenantId = 42;

using (SqlConnection conn = tenantMap.OpenConnectionForKey(
    tenantId,
    credentialsConnectionString,
    ConnectionOptions.Validate))
{
    SqlCommand cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT Name FROM Tenants WHERE TenantId = @id";
    cmd.Parameters.AddWithValue("@id", tenantId);
    // Execute against the correct shard automatically
}
```

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-data-dependent-routing.md -->

The `connectionString` parameter contains only user credentials — no server name or database name. The library fills those in based on the shard map lookup.

The `ConnectionOptions.Validate` flag adds a round-trip to the LSM on the target shard to confirm the mapping is still valid. Use this when shards might be rebalancing. Use `ConnectionOptions.None` when you know the shard map is stable — it skips the validation and reduces latency.

An async variant, `OpenConnectionForKeyAsync`, is available for async workflows.

> **Tip:** Wrap data-dependent routing calls in a transient fault retry loop. The connection might fail due to transient Azure networking issues, and the retry should re-execute the entire `using` block — including the `OpenConnectionForKey` call — to ensure the routing lookup is refreshed.

```csharp
SqlRetryPolicy.ExecuteAction(() =>
{
    using (SqlConnection conn = tenantMap.OpenConnectionForKey(
        tenantId, credentialsConnectionString, ConnectionOptions.Validate))
    {
        var cmd = conn.CreateCommand();
        cmd.CommandText = "UPDATE Tenants SET Plan = @plan WHERE TenantId = @id";
        cmd.Parameters.AddWithValue("@plan", "premium");
        cmd.Parameters.AddWithValue("@id", tenantId);
        cmd.ExecuteNonQuery();
    }
});
```

#### Credential Separation

The elastic database client library uses three distinct credential levels. This isn't optional — it's a security design:

| Credential Type | Permissions | When Used |
|---|---|---|
| Management | Read/write on GSM and shards | Shard map administration |
| Access | Read-only on GSM | Loading shard maps at startup |
| Connection | Read on LSM tables | Validating mappings per-shard |

Management credentials are for creating shard maps, adding or removing shards, and modifying mappings. Access credentials load the shard map into the application's in-memory cache at startup. Connection credentials are passed to `OpenConnectionForKey` — the library uses them to validate cached mappings against the LSM on the target shard before returning the connection.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-manage-credentials.md -->

> **Gotcha:** Connection strings for shard map credentials must not include the `@servername` suffix in the user ID. Use `User ID=myuser`, not `User ID=myuser@myserver`. The credentials need to work across multiple servers.

### Multi-Shard Fan-Out Queries

Data-dependent routing handles the common case where a query targets a single shard. But sometimes you need to query across all shards — aggregating analytics, running reports, or searching globally. That's what **multi-shard queries** are for.

```csharp
using (var conn = new MultiShardConnection(
    tenantMap.GetShards(), shardConnectionString))
{
    using (var cmd = conn.CreateCommand())
    {
        cmd.CommandText = "SELECT TenantId, COUNT(*) AS OrderCount FROM Orders GROUP BY TenantId";
        cmd.CommandType = CommandType.Text;
        cmd.ExecutionOptions = MultiShardExecutionOptions.IncludeShardNameColumn;
        cmd.ExecutionPolicy = MultiShardExecutionPolicy.PartialResults;

        using (MultiShardDataReader reader = cmd.ExecuteReader())
        {
            while (reader.Read())
            {
                Console.WriteLine($"Tenant {reader.GetInt32(0)}: {reader.GetInt32(1)} orders");
            }
        }
    }
}
```

<!-- Source: azure-sql-database-sql-db/how-to/database-sharding/elastic-scale-multishard-querying.md -->

The query fans out to every shard in the shard map, executes independently on each, and merges results using `UNION ALL` semantics. `IncludeShardNameColumn` appends a column identifying which shard each row came from — invaluable for debugging.

`PartialResults` means the query returns whatever it can even if some shards are unavailable. The alternative is to fail the entire query if any shard is down. For reporting workloads, partial results are usually acceptable.

> **Note:** Multi-shard queries work well for tens to hundreds of shards. They don't validate shardlet membership — if a shard has been removed from the shard map but still exists, the query might skip it. If a split-merge operation is in progress, you might see duplicate or missing rows. Avoid running multi-shard queries during active rebalancing.

## Split-Merge Service

Shards drift out of balance over time. One tenant grows faster than expected, or a batch of new tenants lands on the same shard. The **split-merge service** redistributes data online — splitting a range across two shards, merging ranges back together, or moving individual shardlets (the smallest unit of data associated with a single sharding key value) between shards.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-overview-split-and-merge.md -->

The service runs as a customer-hosted deployment in your Azure subscription. You deploy it as two Azure Web Apps — a worker app that performs the actual data movement, and a UI app that exposes a management dashboard and accepts split/merge/move requests via its REST API. The NuGet package `Microsoft.Azure.SqlDatabase.ElasticScale.Service.SplitMerge` contains the deployment artifacts and a configuration template.

Security configuration is a required step, not optional. You create a self-signed certificate (or use a CA-issued one), upload the PFX to both Web Apps, and set client certificate mode to `Require` so only callers presenting the certificate can submit requests. You also configure app settings on each Web App: the `ElasticScaleMetadata` connection string pointing to a status database that tracks operation progress, the `DataEncryptionPrimaryCertificateThumbprint`, and the allowed client certificate thumbprints. The status database is a regular Azure SQL Database that you provision separately — the service uses it to log request progress, and you can query it directly to monitor operations.

<!-- Source: azure-sql-database-sql-db/how-to/database-sharding/elastic-scale-configure-deploy-split-and-merge.md, azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-overview-split-and-merge.md -->

> **Tip:** The split-merge service incurs Azure Web App charges while running. If you don't need it continuously, delete the deployment between rebalancing operations and redeploy when needed — the configuration template makes this straightforward.

### How It Works

The split-merge service integrates directly with the shard map. When you submit a split, merge, or move request, the service:

1. Marks the affected shardlets as **offline** in the shard map. Data-dependent routing calls for those key values will fail until the operation completes.
2. Copies data from the source shard to the target shard in batches.
3. Updates the shard map to point the affected key ranges to the new shard.
4. Deletes the copied data from the source shard.
5. Marks the shardlets as **online** on the target shard.

Only the current batch of shardlets goes offline at any time — the rest of the shard remains fully operational. The batch size is configurable, letting you trade off between availability (smaller batches = less downtime per shardlet) and throughput (larger batches = fewer round trips).

> **Warning:** During a split-merge operation, any existing connections to the affected shardlets are killed. Your application must handle connection failures and retry. Connections to *other* shardlets on the same shard are also killed but succeed immediately on retry.

### Table Types

The split-merge service distinguishes three kinds of tables:

- **Sharded tables** have data distributed by the sharding key. These rows are moved, split, or merged.
- **Reference tables** are small lookup tables replicated to every shard. The service copies them during data movement to keep shards self-contained.
- **Other tables** are ignored by the service.

You declare which is which using the `SchemaInfo` API:

```csharp
var schemaInfo = new SchemaInfo();
schemaInfo.Add(new ReferenceTableInfo("dbo", "Regions"));
schemaInfo.Add(new ShardedTableInfo("dbo", "Orders", "TenantId"));
schemaInfo.Add(new ShardedTableInfo("dbo", "OrderItems", "TenantId"));

shardMapManager.GetSchemaInfoCollection()
    .Add("tenantMap", schemaInfo);
```

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-scale-overview-split-and-merge.md -->

The service respects foreign key relationships, copying reference tables first in dependency order, then sharded tables in FK order within each batch.

> **Gotcha:** The split-merge service doesn't create or delete databases. For a split operation, the target database must already exist with the correct schema and be registered in the shard map. For a merge, you delete the emptied shard manually after the operation completes.

## Cross-Database Elastic Queries (Preview)

Elastic queries let you run T-SQL that spans multiple databases without changing your application's data access layer. You define external tables that point to remote databases, and SQL Database handles the rest — opening parallel connections, executing remotely, and assembling the results.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-query-overview.md -->

There are two topologies:

### Vertical Partitioning

Different databases hold different tables — inventory on one, accounting on another. You create an external data source of type `RDBMS` pointing to the remote database, then define external tables that mirror the remote schema:

```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong_password>';

CREATE DATABASE SCOPED CREDENTIAL RemoteCred
    WITH IDENTITY = 'app_reader',
    SECRET = '<password>';

CREATE EXTERNAL DATA SOURCE InventoryDB
    WITH (
        TYPE = RDBMS,
        LOCATION = 'inventory-server.database.windows.net',
        DATABASE_NAME = 'Inventory',
        CREDENTIAL = RemoteCred
    );

CREATE EXTERNAL TABLE [dbo].[Products] (
    ProductId INT,
    Name NVARCHAR(100),
    Price DECIMAL(10,2)
)
WITH (DATA_SOURCE = InventoryDB);
```

<!-- Source: azure-sql-database-sql-db/how-to/query-distributed-data/elastic-query-vertical-partitioning.md -->

Now you can join `Products` with local tables as if everything were in one database. The query optimizer pushes predicates to the remote side when possible.

### Horizontal Partitioning

All databases share the same schema, and you query across all of them using the shard map. Create an external data source of type `SHARD_MAP_MANAGER`:

```sql
CREATE EXTERNAL DATA SOURCE ShardedOrders
    WITH (
        TYPE = SHARD_MAP_MANAGER,
        LOCATION = 'smm-server.database.windows.net',
        DATABASE_NAME = 'ShardMapDB',
        CREDENTIAL = SMMCred,
        SHARD_MAP_NAME = 'tenantMap'
    );

CREATE EXTERNAL TABLE [dbo].[Orders] (
    OrderId INT,
    TenantId INT,
    Amount DECIMAL(10,2)
)
WITH (DATA_SOURCE = ShardedOrders, DISTRIBUTION = SHARDED(TenantId));
```

SQL Database automatically opens parallel connections to all shards, runs the query, and merges the results.

> **Warning:** Elastic query in shard map manager mode (`SHARD_MAP_MANAGER` external data sources) reaches end of support on **March 31, 2027**. After that date, existing workloads continue functioning but receive no support, and you can't create new external data sources of this type. Plan your migration now.

### Limitations

Elastic query is still in preview, and the limitations are real:

- **Read-only.** External tables support only `SELECT`. You can work around this by selecting into a local temp table, then manipulating locally.
- **LOB types not supported** in external table definitions (except `nvarchar(max)`). The workaround is to create a view on the remote database that casts the LOB column to `nvarchar(max)`, then define your external table over the view instead of the base table. Cast back to the original type in your local queries.
- **No column statistics** on external tables. You must create table-level statistics manually.
- **SQL Server Authentication only.** Microsoft Entra ID authentication isn't supported for elastic query connections.
- **No private links** to target databases of external data sources.
- **Performance scales with service tier.** Lower tiers may take several minutes to load the elastic query engine on first use.

<!-- Source: azure-sql-database-sql-db/concepts/database-sharding/elastic-query-overview.md -->

> **Tip:** Elastic query is best for reporting scenarios where most filtering and aggregation happens on the remote side. It's not designed for ETL workloads that transfer large volumes of data. For heavy analytics across sharded data, consider Azure Synapse Analytics instead.

## ORM Integration

The elastic database client library works with ORMs because its routing mechanism returns standard `SqlConnection` objects. The key insight is simple: replace wherever you create a connection with a call to `OpenConnectionForKey`.

### Entity Framework with Data-Dependent Routing

The integration requires a custom `DbContext` subclass that accepts a shard map and sharding key, then creates the database connection through data-dependent routing:

```csharp
public class ShardedDbContext : DbContext
{
    public DbSet<Order> Orders { get; set; }

    public ShardedDbContext(ShardMap shardMap, int tenantId, string connectionString)
        : base(CreateConnection(shardMap, tenantId, connectionString),
               contextOwnsConnection: true)
    { }

    private static DbConnection CreateConnection(
        ShardMap shardMap, int tenantId, string connectionString)
    {
        return shardMap.OpenConnectionForKey(
            tenantId, connectionString, ConnectionOptions.Validate);
    }
}
```

<!-- Source: azure-sql-database-sql-db/how-to/database-sharding/elastic-scale-use-entity-framework-applications-visual-studio.md -->

Use the sharded context exactly like any other `DbContext`:

```csharp
using (var ctx = new ShardedDbContext(tenantMap, tenantId, credentialsString))
{
    var orders = ctx.Orders.Where(o => o.Status == "Active").ToList();
}
```

> **Note:** The EF integration documented here applies to Entity Framework 6 (EF6), not EF Core. The underlying `OpenConnectionForKey` returns a standard `SqlConnection`, so the same pattern can be adapted to EF Core by passing the connection to `DbContextOptionsBuilder.UseSqlServer(connection)`.

### Dapper with OpenConnectionForKey

Dapper integration is even simpler because Dapper operates on raw `SqlConnection` objects. Replace your connection creation with `OpenConnectionForKey` and everything else stays the same:

```csharp
using (SqlConnection conn = shardMap.OpenConnectionForKey(
    tenantId, credentialsString, ConnectionOptions.Validate))
{
    var orders = conn.Query<Order>(
        "SELECT * FROM Orders WHERE TenantId = @TenantId AND Status = @Status",
        new { TenantId = tenantId, Status = "Active" });
}
```

<!-- Source: azure-sql-database-sql-db/how-to/database-sharding/elastic-scale-working-with-dapper.md -->

DapperExtensions works identically — the `GetList` and `Insert` extension methods operate on whatever `SqlConnection` you hand them.

## Shard Map Recovery and Operations

### GSM/LSM Inconsistency Repair

In a sharded environment, the Global Shard Map and Local Shard Maps can fall out of sync. This happens after geo-failovers (the shard moves to a new server but the GSM still points to the old one), after point-in-time restores (the restored database has stale LSM data), or after accidental shard deletion.

The `RecoveryManager` class detects and repairs these inconsistencies:

```csharp
RecoveryManager rm = shardMapManager.GetRecoveryManager();

// After a geo-failover: detach old location, attach new one
rm.DetachShard(oldLocation);
rm.AttachShard(newLocation);

// Detect GSM/LSM differences on the new shard
var differences = rm.DetectMappingDifferences(newLocation);

// Resolve by trusting the LSM (the shard has the latest data after failover)
foreach (RecoveryToken token in differences)
{
    rm.ResolveMappingDifferences(token, MappingDifferenceResolution.KeepShardMapping);
}
```

<!-- Source: azure-sql-database-sql-db/how-to/database-sharding/elastic-database-recovery-manager.md -->

The five-step recovery pattern after a geo-failover:

1. Retrieve the `RecoveryManager` from the `ShardMapManager`.
2. Detach the old shard location from the shard map.
3. Attach the new shard location (new server, same database name).
4. Detect mapping differences between GSM and LSM.
5. Resolve differences by trusting the LSM — after failover, the shard has the authoritative data.

> **Tip:** Automate this recovery logic in your geo-failover workflow. Manual intervention during an outage is error-prone and slow. The `RecoveryManager` API is designed to be called programmatically from your failover scripts.

### Performance Counters

The client library exposes Windows Performance Monitor counters under the **"Elastic Database: Shard Management"** category. These counters track cache hit rates, routing operations per second, and mapping changes — essential for monitoring a production sharded deployment.

<!-- Source: azure-sql-database-sql-db/how-to/database-sharding/elastic-database-perf-counters.md -->

Key counters include:

- **Cached mappings:** Total number of mappings in the in-memory cache.
- **DDR operations/sec:** Rate of successful data-dependent routing connections.
- **Mapping lookup cache hits/sec** and **misses/sec:** Your cache effectiveness. High miss rates mean the library is hitting the GSM on every request — check whether mappings are changing too frequently.
- **Mappings added or updated in cache/sec:** Rate of cache churn.

Create the counters by calling `ShardMapManagerFactory.CreatePerformanceCategoryAndCounters()` once before initializing the `ShardMapManager`. Creating the performance category requires membership in the local **Administrators** group, but updating the counters at runtime only requires membership in the **Performance Monitor Users** group.

<!-- Source: azure-sql-database-sql-db/how-to/database-sharding/elastic-database-perf-counters.md -->

### Client Library Upgrades

When upgrading the elastic database client library, update in this order:

1. **Application code** — install the new NuGet package and rebuild.
2. **PowerShell scripts** — copy the new library DLL to your script directory.
3. **Split-merge service** — deploy the latest version from NuGet.
4. **Shard map manager metadata** — run `UpgradeGlobalStore()` on the SMM and `UpgradeLocalStore()` on each shard.

<!-- Source: azure-sql-database-sql-db/how-to/database-sharding/elastic-scale-upgrade-client-library.md -->

```csharp
// Upgrade metadata after updating the client library
shardMapManager.UpgradeGlobalStore();

foreach (ShardLocation loc in shardMapManager.GetDistinctShardLocations())
{
    shardMapManager.UpgradeLocalStore(loc);
}
```

The upgrade is idempotent — running it multiple times is safe. New library versions remain backward-compatible with older metadata, but you need the upgrade to access new features.

## When to Shard (and When Not To)

Sharding adds real complexity. Every query must know its shard. Joins across shards require multi-shard queries or application-level aggregation. Schema changes must be deployed to every shard database. Backup and restore become per-shard operations. Monitoring multiplies by your shard count.

Before you shard, ask whether the problem has a simpler solution:

**Hyperscale can handle most "big database" scenarios.** Azure SQL Database Hyperscale supports up to 192 vCores on premium-series hardware, up to 128 TB of storage per database, and scales read workloads with up to 30 named replicas, each independently sized (→ see Chapter 10). If your bottleneck is database size or read throughput, start there.

<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale.md, azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale-replicas.md -->

**Elastic pools solve the "many small databases" problem without sharding.** If you have hundreds of tenant databases but don't need to route queries programmatically, elastic pools give you shared compute resources with per-database isolation — no shard maps required.

**Sharding is the right answer when:**

- A single database can't handle your write throughput, even at the highest tier.
- You need physical data isolation for compliance — tenants in different regions, different security boundaries.
- You have thousands of tenants and need fine-grained control over which tenant lands on which database.
- Your data volume exceeds even Hyperscale limits (rare, but it happens).

### Anti-Patterns

**Sharding prematurely.** If you're not hitting resource limits today and don't have a regulatory requirement for data isolation, don't shard. Concrete signals that you're not ready: your database CPU stays below 70% at peak, your storage is well within Hyperscale's 128 TB ceiling, you haven't exhausted read replicas for query offloading, and your tenant count is low enough that elastic pools can handle the isolation. Sharding is an architectural commitment that's expensive to reverse. Start with a single database or Hyperscale and shard when actual load demands it, not when a capacity planning spreadsheet suggests you might need it someday.

**Poor shard key selection.** A shard key that doesn't align with your query patterns forces constant cross-shard queries. A shard key with low cardinality creates hotspots. A shard key that changes over time means data migration with every update. Take the time to model your access patterns before choosing.

**Ignoring reference data.** Sharded queries that need to join against lookup tables (countries, product categories, configuration) perform badly if those tables only exist on one shard. Use the split-merge service's reference table feature to replicate them to every shard.

**Skipping shard map recovery automation.** After a geo-failover, your shard map is stale. If you don't have automated recovery using `RecoveryManager`, your application is down until someone manually fixes the mappings. This is Chapter 13's disaster recovery planning, applied to your shard infrastructure.

The elastic database tools won't hide sharding's fundamental complexity. But they handle the mechanical parts — routing, metadata management, data movement — so you can focus on the parts that actually require human judgment: key selection, tenancy models, and knowing when sharding is the right trade-off in the first place.

In the next chapter, we'll shift from data architecture to application architecture, covering how to build production applications against Azure SQL — from Kubernetes deployments to CI/CD pipelines to AI integration.
