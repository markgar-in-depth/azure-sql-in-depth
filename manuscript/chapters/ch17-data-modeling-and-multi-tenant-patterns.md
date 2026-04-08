# Chapter 17: Data Modeling and Multi-Tenant Patterns

Your relational schema is only the starting point. Azure SQL stores JSON, XML, graph relationships, spatial coordinates, and full temporal history — all queryable with T-SQL, all backed by the same transaction engine. And when you're building SaaS, the way you partition tenant data across databases matters as much as the schema inside them.

This chapter covers both sides: the multi-model capabilities that let you handle semi-structured and specialized data without leaving Azure SQL, and the tenancy patterns that determine how your SaaS architecture scales, isolates, and costs.

## Multi-Model Data Capabilities

Azure SQL isn't a document database, a graph database, or a time-series database. But it handles all of those workloads inside the relational engine you already know. You get JSONPath expressions, XQuery, graph `MATCH` queries, spatial functions, and temporal `FOR SYSTEM_TIME` clauses — all in the same T-SQL query, against the same transaction log, with the same security model.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/multi-model-features.md -->

### JSON: The Semi-Structured Workhorse

JSON support in Azure SQL has evolved from a set of string functions into a full-fledged data model. You can store JSON as plain `nvarchar(max)`, or — on Azure SQL Database and Managed Instance — use the native **json** data type for binary-optimized storage.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/develop-data-applications/json-features.md -->

#### Storing JSON

The simplest approach stores JSON in an `nvarchar(max)` column with an `ISJSON` check constraint:

```sql
CREATE TABLE Products (
    Id int IDENTITY PRIMARY KEY,
    Name nvarchar(200) NOT NULL,
    Attributes nvarchar(max) NOT NULL,
    CONSTRAINT CK_Attributes_JSON CHECK (ISJSON(Attributes) > 0)
);
```

This works everywhere. The check constraint prevents malformed JSON from entering the table, but the engine still treats the column as a string — every read parses the text.

The native `json` data type changes that equation. It stores documents in a parsed binary format, so reads skip the parsing step and writes can update individual properties without rewriting the entire document:

```sql
CREATE TABLE Products (
    Id int IDENTITY PRIMARY KEY,
    Name nvarchar(200) NOT NULL,
    Attributes json NOT NULL
        CHECK (JSON_PATH_EXISTS(Attributes, '$.category') = 1)
);
```

> **Important:** The native `json` data type is generally available on Azure SQL Database. On Azure SQL Managed Instance, it requires the **SQL Server 2025 update policy** (the default update policy is SQL Server 2022, which doesn't include it). It stores data internally as UTF-8 in `Latin1_General_100_BIN2_UTF8`. Input must be a JSON object or array — scalar values like `'true'` or `'"hello"'` are rejected.
<!-- Source: T-SQL reference — json data type (https://learn.microsoft.com/sql/t-sql/data-types/json-data-type), azure-sql-managed-instance-sql-mi/how-to/manage/update-policy.md -->

The `json` type has concrete size limits: up to 2 GB of binary data, a maximum of 65,535 properties per object, 65,535 elements per array, and 128 levels of nesting. For most application workloads, you'll never approach these.
<!-- Source: T-SQL reference — json data type, Size limitations table (https://learn.microsoft.com/sql/t-sql/data-types/json-data-type) -->

#### Querying JSON

The core functions haven't changed since SQL Server 2016, but they remain the backbone of JSON work:

| Function | Returns | Use For |
|---|---|---|
| `JSON_VALUE` | Scalar | Extract a single value |
| `JSON_QUERY` | Object/array | Extract nested structures |
| `JSON_MODIFY` | Updated string | Patch a value in place |
| `ISJSON` | 0 or 1 | Validate JSON text |
| `JSON_PATH_EXISTS` | 0 or 1 | Test for a path |

```sql
-- Extract and filter
SELECT Id, Name,
       JSON_VALUE(Attributes, '$.category') AS Category,
       JSON_VALUE(Attributes, '$.price') AS Price
FROM Products
WHERE JSON_VALUE(Attributes, '$.category') = 'Electronics';

-- Update a nested value without rewriting
UPDATE Products
SET Attributes = JSON_MODIFY(Attributes, '$.price', 59.99)
WHERE Id = 42;
```

`JSON_VALUE` returns an `nvarchar(4000)` by default. If your value might exceed that, cast explicitly or use `JSON_QUERY` for objects and arrays.

#### FOR JSON and OPENJSON: Bridging Relational and JSON

`FOR JSON` transforms query results into JSON text. Two modes:

- **`FOR JSON PATH`** — you control the structure through column aliases. Dot notation in aliases creates nested objects.
- **`FOR JSON AUTO`** — the engine infers nesting from joins.

```sql
-- Dot notation in aliases creates nested objects
SELECT c.CustomerName AS [Name],
       c.Phone AS [Contact.Phone]
FROM Sales.Customers c
WHERE c.CustomerId = 931
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
```

Dot notation in the alias `[Contact.Phone]` produces a nested `Contact` object in the output — `{"Name":"Nada Jovanovic","Contact":{"Phone":"(215) 555-0100"}}`. But `FOR JSON PATH` doesn't infer parent-child nesting from joins. If you join `Customers` to `Orders`, each join row becomes a flat object with customer fields repeated. To get true nesting — one customer object with an embedded `Orders` array — use `FOR JSON AUTO`, which infers the hierarchy from table aliases:

```sql
-- FOR JSON AUTO nests Orders under each Customer
SELECT c.CustomerName AS Name, c.Phone, c.Fax,
       o.OrderId, o.OrderDate, o.ExpectedDeliveryDate
FROM Sales.Customers c
JOIN Sales.Orders o ON c.CustomerId = o.CustomerId
WHERE c.CustomerId = 931
FOR JSON AUTO, WITHOUT_ARRAY_WRAPPER;
```

This produces a single JSON object with an `Orders` array nested under the customer — no application-layer transformation needed.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/develop-data-applications/json-features.md -->

`OPENJSON` goes the other direction, shredding JSON text into rows:

```sql
CREATE PROCEDURE dbo.InsertOrders @orders nvarchar(max)
AS
BEGIN
    INSERT INTO Orders (Number, OrderDate, Customer, Quantity)
    SELECT Number, Date, Customer, Quantity
    FROM OPENJSON(@orders)
    WITH (
        Number varchar(200),
        Date datetime,
        Customer varchar(200),
        Quantity int
    );
END;
```

The `WITH` clause maps JSON properties to typed columns. Without it, `OPENJSON` returns key-value-type triples — useful for dynamic schemas but harder to work with.

#### JSON Constructors and Aggregates

Beyond `FOR JSON`, Azure SQL provides direct constructor functions:

- **`JSON_OBJECT`** builds a JSON object from key-value pairs in a single expression.
- **`JSON_ARRAY`** builds a JSON array from a list of values.

```sql
SELECT JSON_OBJECT('id': ProductId, 'name': ProductName, 'price': UnitPrice)
FROM Products
WHERE CategoryId = 1;
```

For building JSON from grouped data, the aggregate functions `JSON_OBJECTAGG` and `JSON_ARRAYAGG` construct objects and arrays across rows:

```sql
SELECT c.CategoryName,
       JSON_ARRAYAGG(p.ProductName ORDER BY p.ProductName)
           AS ProductNames
FROM Categories c
JOIN Products p ON c.CategoryId = p.CategoryId
GROUP BY c.CategoryName;
```

> **Note:** `JSON_OBJECTAGG` and `JSON_ARRAYAGG` are generally available on Azure SQL Database. On Managed Instance, they require the **SQL Server 2025 update policy**. Both accept `NULL ON NULL` or `ABSENT ON NULL` to control how SQL `NULL` values are represented.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage/update-policy.md -->

#### Indexing JSON

JSON columns can't be indexed directly. Instead, create computed columns that extract the values you query most, then index those:

```sql
ALTER TABLE Products
ADD Category AS JSON_VALUE(Attributes, '$.category');

CREATE INDEX IX_Products_Category ON Products (Category);
```

The computed column can be persisted or virtual. For a persisted column, the value is materialized on write and the index behaves like any other B-tree index. For a virtual column, the engine evaluates the expression at query time but the index still accelerates lookups.

> **Tip:** If you're filtering on multiple JSON properties, create a computed column and index for each. The query optimizer treats them like regular columns — it can use index intersection and covering indexes as usual.

### Graph Data

When your data model is dominated by many-to-many relationships — social networks, recommendation engines, organizational hierarchies with multiple parents — graph queries express intent more naturally than multi-way joins.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/multi-model-features.md -->

Azure SQL implements graph as **node tables** and **edge tables** layered on top of the relational engine. A node table represents entities. An edge table represents relationships and can carry its own properties.

```sql
CREATE TABLE Person (
    PersonId int PRIMARY KEY,
    Name nvarchar(100)
) AS NODE;

CREATE TABLE FriendOf (
    Since date
) AS EDGE;

-- Insert nodes
INSERT INTO Person (PersonId, Name) VALUES (1, 'Alice'), (2, 'Bob');

-- Insert edge
INSERT INTO FriendOf ($from_id, $to_id, Since)
VALUES (
    (SELECT $node_id FROM Person WHERE PersonId = 1),
    (SELECT $node_id FROM Person WHERE PersonId = 2),
    '2024-01-15'
);
```

Query graph data with the `MATCH` clause in a `WHERE` predicate:

```sql
-- Find friends of friends
SELECT p1.Name, p2.Name AS FriendOfFriend
FROM Person p1, FriendOf f1, Person mid,
     FriendOf f2, Person p2
WHERE MATCH(p1-(f1)->mid-(f2)->p2)
  AND p1.PersonId = 1
  AND p1.PersonId <> p2.PersonId;
```

For shortest-path traversals, use `SHORTEST_PATH`:

```sql
SELECT p1.Name,
       STRING_AGG(p2.Name, '->') WITHIN GROUP (GRAPH PATH) AS Path,
       LAST_VALUE(p2.Name) WITHIN GROUP (GRAPH PATH) AS Destination
FROM Person p1, FriendOf FOR PATH f, Person FOR PATH p2
WHERE MATCH(SHORTEST_PATH(p1(-(f)->p2)+))
  AND p1.PersonId = 1;
```

Graph tables are relational tables underneath — they get the same indexing, security, backup, and replication as everything else. The `$node_id` and `$edge_id` pseudo-columns are computed from the underlying integer identifiers.

> **Tip:** Use graph tables when you need multi-hop traversals or when the number of relationship types will grow over time. For simple parent-child hierarchies, `hierarchyid` is more efficient.

### XML

XML support predates JSON in the SQL Server engine and remains fully supported. The native `xml` data type stores documents in a validated, indexed binary format. You can apply XML Schema collections for type validation, use XQuery expressions to query and transform, and build primary and secondary XML indexes for performance.

```sql
CREATE TABLE Documents (
    DocId int PRIMARY KEY,
    Content xml NOT NULL
);

-- XQuery to extract values
SELECT DocId,
       Content.value('(/order/customer/name)[1]', 'nvarchar(100)') AS CustomerName
FROM Documents
WHERE Content.exist('/order[@priority="high"]') = 1;
```

If you're starting a new project, JSON is almost always the better choice — it's lighter, more widely supported in application frameworks, and the tooling is more actively evolving. XML remains the right call when you're integrating with systems that produce or consume XML natively (SOAP services, industry-standard formats like HL7, XBRL, or SVG).

### Spatial Data

Azure SQL supports two spatial types: **geometry** for flat (Euclidean) coordinate systems and **geography** for round-earth (geodetic) calculations. Both types implement the Open Geospatial Consortium (OGC) standards.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/multi-model-features.md -->

```sql
CREATE TABLE Stores (
    StoreId int PRIMARY KEY,
    Name nvarchar(100),
    Location geography
);

INSERT INTO Stores (StoreId, Name, Location)
VALUES (1, 'Downtown', geography::Point(47.6062, -122.3321, 4326));

-- Find stores within 5 km of a point
DECLARE @here geography = geography::Point(47.6097, -122.3331, 4326);

SELECT Name,
       Location.STDistance(@here) / 1000.0 AS DistanceKm
FROM Stores
WHERE Location.STDistance(@here) < 5000
ORDER BY Location.STDistance(@here);
```

Spatial indexes use a tessellation grid to decompose the coordinate space into cells. Create them to accelerate `STDistance`, `STIntersects`, and `STContains` queries:

```sql
CREATE SPATIAL INDEX IX_Stores_Location ON Stores (Location)
USING GEOGRAPHY_AUTO_GRID;
```

> **Note:** SRID 4326 (WGS 84) is the standard for GPS coordinates. Always specify it when creating `geography` instances — mismatched SRIDs cause runtime errors on spatial operations.

### Temporal Tables: System-Versioned History

Temporal tables give you automatic, query-time-travel history. The engine tracks every version of every row with no application code changes.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/temporal-tables.md -->

#### Creating a Temporal Table

```sql
CREATE TABLE Employees (
    EmployeeId int NOT NULL PRIMARY KEY CLUSTERED,
    Name nvarchar(100) NOT NULL,
    Department nvarchar(50) NOT NULL,
    Salary decimal(10,2) NOT NULL,
    ValidFrom datetime2(0) GENERATED ALWAYS AS ROW START,
    ValidTo datetime2(0) GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.EmployeesHistory));
```

Three mandatory elements: the `ValidFrom` and `ValidTo` columns (both `datetime2`), the `PERIOD FOR SYSTEM_TIME` declaration, and `SYSTEM_VERSIONING = ON`. The history table is created automatically if you don't specify one — but naming it explicitly keeps your schema readable.

#### Converting an Existing Table

You can add temporal tracking to a table that already has data:

```sql
ALTER TABLE Employees
ADD ValidFrom datetime2(0) GENERATED ALWAYS AS ROW START HIDDEN
        CONSTRAINT DF_ValidFrom DEFAULT DATEADD(SECOND, -1, SYSUTCDATETIME()),
    ValidTo datetime2(0) GENERATED ALWAYS AS ROW END HIDDEN
        CONSTRAINT DF_ValidTo DEFAULT '9999-12-31 23:59:59',
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo);

ALTER TABLE Employees
SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.EmployeesHistory));
```

The `HIDDEN` keyword keeps the period columns out of `SELECT *` results, so existing application code doesn't break.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/temporal-tables.md -->

#### Querying History

The `FOR SYSTEM_TIME` clause is where temporal tables earn their keep:

```sql
-- Point-in-time snapshot
SELECT * FROM Employees
FOR SYSTEM_TIME AS OF '2025-06-01T00:00:00'
WHERE Department = 'Engineering';

-- All changes in a time range
SELECT * FROM Employees
FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2025-07-01'
WHERE EmployeeId = 42
ORDER BY ValidFrom;

-- Rows fully contained in a window
SELECT * FROM Employees
FOR SYSTEM_TIME CONTAINED IN ('2025-03-01', '2025-06-01');
```

`AS OF` returns the row as it existed at a single instant. `BETWEEN` returns all versions that overlapped the range. `CONTAINED IN` returns versions whose entire validity period falls within the range.

#### Schema Evolution

Schema changes propagate automatically to the history table. `ALTER TABLE` statements that add columns, widen types, or drop columns apply to both the current and history tables:

```sql
ALTER TABLE Employees ADD Title nvarchar(100) NOT NULL DEFAULT 'N/A';
```

This is one area where temporal tables are genuinely friction-free. You don't manage the history schema separately.

### Temporal History Retention Policies

The history table grows with every update and delete. Without intervention, it grows forever. Azure SQL Database and Managed Instance provide a built-in retention mechanism that automatically ages out old history rows.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/business-continuity/temporal-tables-retention-policy.md -->

#### Configuring Retention

First, verify that temporal retention is enabled at the database level:

```sql
SELECT is_temporal_history_retention_enabled, name
FROM sys.databases;
```

The flag defaults to `ON`, but it's automatically set to `OFF` after a point-in-time restore (so you can inspect all history before cleanup kicks in). Enable it explicitly:

```sql
ALTER DATABASE [MyAppDb]
SET TEMPORAL_HISTORY_RETENTION ON;
```

Then set retention per table:

```sql
CREATE TABLE AuditLog (
    LogId int NOT NULL PRIMARY KEY CLUSTERED,
    Action nvarchar(50) NOT NULL,
    Details nvarchar(max),
    ValidFrom datetime2(0) GENERATED ALWAYS AS ROW START,
    ValidTo datetime2(0) GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
)
WITH (
    SYSTEM_VERSIONING = ON (
        HISTORY_TABLE = dbo.AuditLogHistory,
        HISTORY_RETENTION_PERIOD = 6 MONTHS
    )
);
```

Supported units: `DAYS`, `WEEKS`, `MONTHS`, `YEARS`. Omitting the period or specifying `INFINITE` means no automatic cleanup.

Change retention on an existing table with `ALTER TABLE`:

```sql
ALTER TABLE AuditLog
SET (SYSTEM_VERSIONING = ON (HISTORY_RETENTION_PERIOD = 90 DAYS));
```

> **Gotcha:** Setting `SYSTEM_VERSIONING` to `OFF` does *not* preserve the retention period. When you re-enable it without specifying `HISTORY_RETENTION_PERIOD`, the default is `INFINITE` — and your cleanup stops.

#### How Cleanup Works

A background task identifies rows in the history table where the `ValidTo` column is older than the retention period and deletes them. The cleanup behavior depends on the history table's index:

- **B-tree clustered index** — deletes aged rows in chunks of up to 10,000 at a time, minimizing log and I/O pressure. The clustered index must start with the end-of-period column (`ValidTo`).
- **Clustered columnstore index** — removes entire row groups (typically ~1 million rows each), which is extremely efficient for high-velocity history.

Only history tables with a clustered index (B-tree or columnstore) can have a finite retention policy. If you use a clustered columnstore index with finite retention, you can't add nonclustered B-tree indexes to that history table.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/business-continuity/temporal-tables-retention-policy.md -->

> **Tip:** For high-write tables, use a clustered columnstore index on the history table. It compresses aggressively and the retention cleanup removes entire row groups in a single operation. The default history table already ships with a B-tree index on (`ValidTo`, `ValidFrom`) that works well for moderate volumes.

#### Managing History at Scale

For temporal tables with high update rates — think IoT telemetry, financial tickers, or session tracking — history can grow to dominate your database size. A practical approach:

1. **Start with retention policies** for tables where old history has no business value.
2. **Use columnstore on the history table** for tables where you need analytics over history — it compresses well and the retention cleanup is efficient.
3. **Monitor history size** by querying `sys.dm_db_partition_stats` for the history table. If a single history table is consuming a disproportionate share of storage, consider reducing the retention period or partitioning.

Review the current state of all retention policies with:

```sql
SELECT DB.is_temporal_history_retention_enabled,
       SCHEMA_NAME(T1.schema_id) AS TemporalSchema,
       T1.name AS TemporalTable,
       T2.name AS HistoryTable,
       T1.history_retention_period,
       T1.history_retention_period_unit_desc
FROM sys.tables T1
OUTER APPLY (
    SELECT is_temporal_history_retention_enabled
    FROM sys.databases WHERE name = DB_NAME()
) AS DB
LEFT JOIN sys.tables T2
    ON T1.history_table_id = T2.object_id
WHERE T1.temporal_type = 2;
```

## SaaS Tenancy Patterns

If you're building a SaaS application on Azure SQL, the tenancy model — how you map tenant data to databases — is one of the earliest architectural decisions and one of the hardest to change later. There's no universally correct answer. The right pattern depends on how many tenants you have, how much isolation they need, how much you can spend per tenant, and how complex you're willing to make your operational tooling.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/multi-tenant-saas/saas-tenancy-app-design-patterns.md -->

### Standalone Single-Tenant

Each tenant gets its own application instance and its own database, deployed in a separate Azure resource group. This is the maximum isolation model.

**How it works:** You deploy the full stack — app service, database, possibly networking — per tenant. Each tenant's infrastructure is completely independent. The vendor manages each instance via SQL connections, potentially across different subscriptions.

**When it fits:** Regulated industries where tenants require full isolation (separate encryption keys, dedicated compute, audit boundaries). Or when tenants themselves own the Azure subscription and you're managing the software on their behalf.

**The cost problem:** Elastic pools can't span resource groups or subscriptions. Each database must be sized for its own peak load. This makes standalone the most expensive model per tenant by a wide margin.

### Database-per-Tenant

A single multitenant application backed by many single-tenant databases. Each new tenant gets a new database. All databases can sit in the same resource group and share elastic pools.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/multi-tenant-saas/saas-tenancy-app-design-patterns.md -->

**How it works:** The application routes each request to the correct database using a tenant-to-database mapping (often stored in a catalog database). Azure SQL's elastic pools let you share compute and storage across databases, paying for aggregate resource consumption rather than per-database peaks.

**The strengths:**

- **Strong isolation.** Each tenant's data lives in its own database. A `DROP TABLE` accident affects one tenant.
- **Per-tenant restore.** Point-in-time restore targets a single database without touching others.
- **Schema customization.** You can alter one tenant's schema independently — add columns, indexes, or even different table structures.
- **Elastic pools.** Databases in the same pool share eDTUs or vCores, which drops the per-tenant cost dramatically compared to standalone.

**The limits:** Azure SQL Database's management features — automatic tuning, built-in backups, high availability — scale well to hundreds of thousands of databases. But provisioning, schema migration, and catalog management become operational challenges at that scale. You'll need automation.

> **Tip:** Database-per-tenant with elastic pools is the most common pattern for SaaS applications with tens to tens of thousands of tenants. It balances isolation, cost, and operational complexity well. Start here unless you have a specific reason not to.

### Single Multitenant Database

All tenants share a single database. Every table includes a `TenantId` column, and you use row-level security (RLS) to enforce data isolation at the query level.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/multi-tenant-saas/saas-tenancy-app-design-patterns.md -->

**How it works:** The application sets the tenant context on each connection (typically via `SESSION_CONTEXT`), and a security policy ensures that every query only sees rows belonging to that tenant.

```sql
-- Schema for tenant isolation
CREATE TABLE Orders (
    OrderId int IDENTITY PRIMARY KEY,
    TenantId int NOT NULL,
    OrderDate date NOT NULL,
    Total decimal(10,2) NOT NULL
);

-- Security predicate function
CREATE FUNCTION Security.fn_TenantFilter(@TenantId int)
RETURNS TABLE
WITH SCHEMABINDING
AS
    RETURN SELECT 1 AS Result
    WHERE @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS int);

-- Security policy
CREATE SECURITY POLICY Security.TenantPolicy
ADD FILTER PREDICATE Security.fn_TenantFilter(TenantId) ON dbo.Orders,
ADD BLOCK PREDICATE Security.fn_TenantFilter(TenantId) ON dbo.Orders
WITH (STATE = ON);
```

The application sets the context at connection time:

```csharp
using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

using var cmd = connection.CreateCommand();
cmd.CommandText = "EXEC sp_set_session_context @key=N'TenantId', @value=@tenantId";
cmd.Parameters.AddWithValue("@tenantId", tenantId);
await cmd.ExecuteNonQueryAsync();
```

**The strengths:**

- **Lowest per-tenant cost.** One database, one set of resources. Millions of tenants can share a single database.
- **Simplest schema management.** One migration, one backup, one monitoring target.

**The risks:**

- **Noisy neighbors.** One tenant's heavy query affects everyone. Azure SQL has no built-in per-tenant resource governance within a single database.
- **No per-tenant restore.** A point-in-time restore recovers the entire database. Restoring one tenant's data requires extracting it manually.
- **RLS overhead.** The security predicate adds a filter to every query plan. For most workloads this is negligible, but test with realistic data volumes.

> **Gotcha:** RLS filter predicates apply to `SELECT`, `UPDATE`, and `DELETE` — but not to `INSERT`. A bug in your application code can insert rows with the wrong `TenantId`. Add a block predicate (`AFTER INSERT`) to catch this, or use a default constraint tied to `SESSION_CONTEXT`.

### Sharded Multitenant

Tenant data is distributed across multiple databases, each holding multiple tenants. A shard map (managed by the Elastic Database Client Library) tracks which tenant lives in which database.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/multi-tenant-saas/saas-tenancy-app-design-patterns.md -->

**How it works:** Each database is a multitenant database with `TenantId` in every table. A catalog database holds the tenant-to-shard mapping. The application uses data-dependent routing to connect to the right shard. As the tenant count grows, you add new shards and rebalance.

**When it fits:** When you have more tenants than a single database can comfortably hold, but full database-per-tenant isolation isn't required. This pattern reaches "almost limitless" scale — millions of tenants across hundreds of shards.

**Operational complexity:** Sharding introduces split/merge operations (moving tenants between shards), catalog management, and cross-shard query coordination. Azure SQL provides a split/merge tool that works with the Elastic Database Client Library, but you're still managing more moving parts than the simpler patterns.

> **Note:** Chapter 19 covers the Elastic Database Client Library — shard map management, data-dependent routing, multi-shard queries, and the split-merge service — in detail. This section focuses on when and why to shard, not how.

### Hybrid Models

The hybrid model combines multitenant and single-tenant databases under one shard map. Every database has a `TenantId` column in its schema, making all databases technically multitenant. In practice, some databases hold a single high-value tenant while others pack many smaller tenants together.

**How it works:** Free-trial tenants share a dense multitenant database. When a tenant upgrades to a paid plan, you move them to a less-populated database. Premium tenants get their own dedicated database. The shard map handles routing regardless of density.

This is the model most real-world SaaS applications evolve toward. You start with a simpler pattern and add hybrid density as your tenant population diversifies.

### Comparison Matrix

**Standalone single-tenant:** Full isolation, full schema flexibility, per-tenant restore. Scales to hundreds of tenants. Highest cost per tenant. Low dev complexity, but ops complexity grows fast at scale.

**Database-per-tenant (with pools):** High isolation, full schema flexibility, per-tenant restore. Scales to hundreds of thousands. Low cost per tenant via elastic pools. Low dev complexity, medium ops complexity.

**Single multitenant database:** Low isolation (RLS), shared schema, no per-tenant restore. A single database holds millions of tenants at the lowest cost. Medium dev complexity (RLS plumbing), low ops complexity.

**Sharded multitenant:** Low isolation per shard, shared schema, partial per-tenant restore. Scales past millions across many databases. Lowest cost at scale, but high dev and ops complexity (shard map management, split/merge operations).

### Anti-Patterns

**Committing to single-database multitenant without load-testing for noisy neighbors.** The risk is covered above — but teams underestimate it because dev/test environments use uniform workloads. Before committing, test with realistic *skewed* loads: one tenant running a full table scan while others serve OLTP. If p99 latency for the quiet tenants isn't acceptable, you need per-tenant isolation.

**Database-per-tenant without elastic pools.** If every database is provisioned as a standalone single database sized for its peak, you're paying for idle capacity most of the time. Elastic pools exist specifically for this pattern — use them.

**Ignoring the catalog.** In database-per-tenant and sharded patterns, the tenant-to-database mapping is critical infrastructure. If your catalog is a hardcoded config file, your first major tenant migration will be painful. Use the Elastic Database Client Library's shard map manager, or build a proper catalog database.

**Sharding prematurely.** A single Azure SQL Hyperscale database supports up to 128 TB. Many applications that think they need sharding actually need a bigger database. Hyperscale with read replicas can handle surprisingly large multitenant workloads before sharding complexity is justified.
<!-- Source: azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale.md -->

## Putting It All Together: Choosing Your Data Architecture

The decisions in this chapter don't exist in isolation. Your data model (relational, multi-model, or hybrid) interacts with your tenancy pattern (shared, per-tenant, or sharded). Getting the combination right means matching both to your workload's actual characteristics.

### Decision Framework

**Start with the data model question:**

If your application is purely relational — structured entities, well-defined relationships, predictable queries — a traditional normalized schema is all you need. Don't add JSON or graph capabilities for the sake of it.

Add multi-model capabilities when the data demands it:

- **JSON** when your schema has variable attributes (product catalogs, user preferences, configuration data) or when you're exchanging data with APIs that speak JSON natively.
- **Temporal tables** when you need audit history, point-in-time reporting, or slowly changing dimension tracking. This is a "why wouldn't you?" feature for most business entities — the overhead is minimal and the capability is hard to retrofit.
- **Graph** when you have many-to-many relationships that span multiple hops (social connections, access control hierarchies, dependency graphs). If you're joining the same table to itself more than twice, consider graph.
- **Spatial** when you're storing and querying location data. Don't roll your own haversine distance calculations — the `geography` type handles the math correctly and spatial indexes make it fast.

#### Worked Example: Evaluating a Multi-Model Workload

Consider an e-commerce platform that needs to store product listings, track every price change for regulatory compliance, and let shoppers filter by location. Walk through the decision:

1. **Products have variable attributes.** A laptop has CPU speed, RAM, and screen size. A shirt has fabric, color, and fit. A normalized EAV table could work, but it turns every product query into a multi-join mess. **Decision: JSON column** for the `Attributes` field, with computed column indexes on the two or three properties you filter most (category, brand, price range).

2. **Price changes need audit history.** Regulators can ask "what was the price of product X on March 15?" This is exactly what temporal tables are built for. **Decision: system-versioned temporal table** on the `ProductPricing` table, with a retention policy of 7 years (the regulatory requirement). You'd use `FOR SYSTEM_TIME AS OF` for point-in-time lookups and a clustered columnstore index on the history table to keep long-term storage costs low.

3. **Shoppers filter by proximity.** "Show me stores within 10 km that carry this product." **Decision: `geography` column** on the `Stores` table with a spatial index. The `STDistance` function handles the distance calculation, and the spatial index keeps it fast even with hundreds of thousands of locations.

4. **No graph requirement here.** Products relate to categories and stores in straightforward one-to-many and many-to-many patterns — standard relational joins work fine. No need for `MATCH`.

The result: one Azure SQL database using three multi-model features (JSON, temporal, spatial), all queried with T-SQL, all backed by the same transaction log. No external data stores, no synchronization headaches, no separate backup strategy.

This is the evaluation you should do for every workload. For each data concern, ask: does a multi-model feature solve this more cleanly than a pure relational approach? If yes, use it. If the relational approach is just as clean, stick with it.

**Then answer the tenancy question:**

| Your situation | Start with |
|---|---|
| <100 tenants, strict isolation | Database-per-tenant |
| 100–10,000 tenants | DB-per-tenant + pools |
| 10,000+ small tenants | Single MT DB or sharded |
| Mix of large and small | Hybrid sharded |
| Regulated, tenant-owned infra | Standalone |

### Matching Tenancy to Workload

The tenancy pattern should match your tenants' actual behavior, not their contractual tier:

- **Read-heavy, analytics-oriented tenants** do well in shared databases — their queries don't generate lock contention, and columnstore indexes benefit from larger datasets.
- **Write-heavy, OLTP-oriented tenants** need isolation. A single noisy writer in a shared database degrades everyone's latency. Database-per-tenant or a dedicated shard is the right answer.
- **Bursty tenants** with unpredictable peaks belong in elastic pools, where the pool absorbs the burst without over-provisioning each database individually.

### Common Anti-Patterns in Azure SQL Data Architecture

**Querying JSON without computed column indexes.** See the JSON indexing section earlier in this chapter.

**Temporal tables without retention policies.** See the retention section earlier in this chapter.

**Picking a tenancy model based on the first 10 tenants.** Your architecture needs to handle your target scale, not today's customer list. If you're building for 50,000 tenants and starting with 5, design the database-per-tenant infrastructure now — don't start with a single shared database and plan to "migrate later."

**Mixing concerns across the models.** Don't use RLS as your *only* security boundary for tenants with contractual data isolation requirements. RLS is a defense-in-depth layer, not a compliance substitute for physical database separation. If a tenant's contract says "dedicated database," they need a dedicated database.

Chapter 18 picks up where this one leaves off — moving data between databases, which becomes operationally critical once you've committed to a multi-database tenancy architecture.
