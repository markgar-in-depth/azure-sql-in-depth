# Chapter 5: Your First Database Design

You've provisioned a server, picked a tier, and connected from your app. Now it's time to put something in it. This chapter walks through designing a schema, loading data into it, and understanding the T-SQL compatibility boundaries that will shape how you write code against Azure SQL.

## Designing a Schema in Azure SQL

If you've built schemas in SQL Server, building one in Azure SQL will feel familiar — the core DDL is the same. `CREATE TABLE`, `ALTER TABLE`, `CREATE INDEX`, foreign keys, check constraints, computed columns, sequences — they all work. The differences are at the edges: features tied to the file system or the operating system don't exist in PaaS, and a few statements have slightly different option sets.

But the fundamentals of good relational design don't change just because you're in the cloud. Normalize your data. Define your keys. Add indexes for your query patterns. Let's walk through it.

### Creating Tables

A table in Azure SQL Database or Managed Instance is created the same way you'd create one in SQL Server:

```sql
CREATE TABLE dbo.Customers (
    CustomerID    INT           NOT NULL IDENTITY(1, 1),
    Email         NVARCHAR(256) NOT NULL,
    DisplayName   NVARCHAR(128) NOT NULL,
    CreatedAtUtc  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED (CustomerID),
    CONSTRAINT UQ_Customers_Email UNIQUE (Email)
);
```

A few things to note:

- **Use `DATETIME2` instead of `DATETIME`.** It's more precise, uses less storage at lower precision, and aligns with the ISO standard. There's no reason to reach for the legacy type.
- **Use `NVARCHAR` for user-facing text.** Unicode support is non-negotiable for any app with a global audience. Reserve `VARCHAR` for system-internal strings where you control the character set.
- **Name your constraints.** Auto-generated names like `PK__Customer__A4AE64B85070F446` are miserable to debug. Name everything explicitly.

> **Tip:** Always specify precision on `DATETIME2`. `DATETIME2(3)` gives you millisecond precision in 7 bytes — more than enough for most application timestamps and cheaper than the default `DATETIME2(7)`.

### Foreign Keys and Referential Integrity

Foreign keys work exactly as you'd expect. Define them inline or as separate constraints:

```sql
CREATE TABLE dbo.Orders (
    OrderID       INT           NOT NULL IDENTITY(1, 1),
    CustomerID    INT           NOT NULL,
    OrderDateUtc  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    TotalAmount   DECIMAL(18,2) NOT NULL,
    Status        NVARCHAR(20)  NOT NULL DEFAULT N'Pending',
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID),
    CONSTRAINT FK_Orders_Customers
        FOREIGN KEY (CustomerID) REFERENCES dbo.Customers (CustomerID)
);

CREATE TABLE dbo.OrderItems (
    OrderItemID   INT           NOT NULL IDENTITY(1, 1),
    OrderID       INT           NOT NULL,
    ProductName   NVARCHAR(256) NOT NULL,
    Quantity      INT           NOT NULL,
    UnitPrice     DECIMAL(18,2) NOT NULL,
    CONSTRAINT PK_OrderItems PRIMARY KEY CLUSTERED (OrderItemID),
    CONSTRAINT FK_OrderItems_Orders
        FOREIGN KEY (OrderID) REFERENCES dbo.Orders (OrderID)
);
```

> **Gotcha:** In Azure SQL Database, cross-database foreign keys aren't supported. Each database is an isolated unit — there's no equivalent of three-part names referencing another database on the same server. If you need cross-database referential integrity, enforce it in your application layer or consolidate into a single database. Managed Instance supports cross-database queries within the same instance, but cross-database foreign keys still aren't a T-SQL feature in any edition.

### Indexes

Every table needs a clustered index. Beyond that, your nonclustered indexes should be driven by your query patterns, not guesswork.

```sql
-- Support lookups by customer
CREATE NONCLUSTERED INDEX IX_Orders_CustomerID
    ON dbo.Orders (CustomerID)
    INCLUDE (OrderDateUtc, TotalAmount, Status);

-- Support lookups by order
CREATE NONCLUSTERED INDEX IX_OrderItems_OrderID
    ON dbo.OrderItems (OrderID)
    INCLUDE (ProductName, Quantity, UnitPrice);
```

**Covering indexes** — where the `INCLUDE` columns satisfy the query without a key lookup — are your best friend for read-heavy workloads. They're exactly the same in Azure SQL as in SQL Server.

A few Azure SQL–specific considerations for indexing:

| Feature | SQL Database | Managed Instance |
|---|---|---|
| Columnstore indexes | Yes (GP, BC, HS) | Yes |
| In-memory OLTP | Premium/BC only; HS limited | BC only |
| Online index ops | Yes | Yes |
| Resumable index ops | Yes | Yes |

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

> **Tip:** Resumable index operations let you pause and restart a `CREATE INDEX` or `ALTER INDEX REBUILD` without losing progress. This is especially useful in Azure SQL where maintenance windows matter and you can't control when failovers happen.

### Walk-Through: A Sample Application Schema

Let's flesh out a complete schema for a simple e-commerce application. This gives you a realistic reference point — not a toy `DimDate2` table, but something that exercises foreign keys, indexes, constraints, and common patterns.

```sql
-- Products catalog
CREATE TABLE dbo.Products (
    ProductID     INT           NOT NULL IDENTITY(1, 1),
    SKU           NVARCHAR(50)  NOT NULL,
    Name          NVARCHAR(256) NOT NULL,
    Description   NVARCHAR(MAX) NULL,
    Price         DECIMAL(18,2) NOT NULL,
    IsActive      BIT           NOT NULL DEFAULT 1,
    CreatedAtUtc  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Products PRIMARY KEY CLUSTERED (ProductID),
    CONSTRAINT UQ_Products_SKU UNIQUE (SKU),
    CONSTRAINT CK_Products_Price CHECK (Price >= 0)
);

-- Inventory tracking
CREATE TABLE dbo.Inventory (
    ProductID       INT NOT NULL,
    QuantityOnHand  INT NOT NULL DEFAULT 0,
    LastUpdatedUtc  DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Inventory PRIMARY KEY CLUSTERED (ProductID),
    CONSTRAINT FK_Inventory_Products
        FOREIGN KEY (ProductID) REFERENCES dbo.Products (ProductID),
    CONSTRAINT CK_Inventory_Qty CHECK (QuantityOnHand >= 0)
);

-- Extend Orders to reference products properly
ALTER TABLE dbo.OrderItems ADD
    ProductID INT NULL;

-- After backfilling ProductID from ProductName lookups:
-- ALTER TABLE dbo.OrderItems
--     ADD CONSTRAINT FK_OrderItems_Products
--     FOREIGN KEY (ProductID) REFERENCES dbo.Products (ProductID);
```

This schema uses several patterns worth calling out:

- **Surrogate keys with `IDENTITY`** for every table. Simple, monotonically increasing, and clustered index–friendly.
- **Natural key constraints** (`UQ_Products_SKU`, `UQ_Customers_Email`) enforced alongside surrogate keys. The surrogate is your join key; the natural key is your business rule.
- **Check constraints** for data integrity (`Price >= 0`, `QuantityOnHand >= 0`). These are cheap and catch bugs that application validation misses.
- **`DEFAULT` expressions** for timestamps and initial states, reducing the burden on application code.

> **Note:** Azure SQL Database uses the `PRIMARY` filegroup only — you can't create additional filegroups or control file placement. This is managed by the service. Managed Instance supports multiple filegroups but auto-assigns file paths. Design your schema without depending on file placement.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md -->

## Loading Data

A schema is useless without data. Azure SQL supports several approaches to get data in, depending on your source and scale.

### Bulk Loading with bcp

The `bcp` (bulk copy program) utility has been around since the early days of SQL Server, and it works with Azure SQL Database and Managed Instance. It's a command-line tool — fast, scriptable, and good for moving flat-file data.

Here's the basic flow: create your target table, then run `bcp` to push data from a file:

```bash
bcp dbo.Products in products.csv \
    -S yourserver.database.windows.net \
    -d yourdb \
    -U youradmin \
    -P yourpassword \
    -c -t "," -q
```

The flags: `-c` for character mode, `-t ","` for comma-delimited, `-q` for quoted identifiers. For production use, you'll want to add `-b` to set a batch size — this controls how many rows are committed per transaction and keeps the transaction log from growing unbounded.

<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/monitor-tune/load-from-csv-with-bcp.md -->

> **Gotcha:** `bcp` doesn't support UTF-8. Your data must be ASCII or UTF-16 encoded. If you're working with UTF-8 source files, convert them first, or use `BULK INSERT` with an appropriate code page instead.

<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/monitor-tune/load-from-csv-with-bcp.md -->

### Loading CSV Data

For server-side loading, `BULK INSERT` is the T-SQL alternative to `bcp`. In Azure SQL, the source file must reside in Azure Blob Storage — you can't reference local file paths or network shares.

```sql
-- First, create a credential and external data source
CREATE DATABASE SCOPED CREDENTIAL BlobCredential
    WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
    SECRET = '<your-sas-token>';

CREATE EXTERNAL DATA SOURCE BlobStorage
    WITH (
        TYPE = BLOB_STORAGE,
        LOCATION = 'https://youraccount.blob.core.windows.net/data',
        CREDENTIAL = BlobCredential
    );

-- Then bulk insert
BULK INSERT dbo.Products
    FROM 'products.csv'
    WITH (
        DATA_SOURCE = 'BlobStorage',
        FORMAT = 'CSV',
        FIRSTROW = 2,
        FIELDTERMINATOR = ',',
        ROWTERMINATOR = '\n'
    );
```

This pattern works in both SQL Database and Managed Instance. The `DATA_SOURCE` parameter is required — there's no direct file system access in PaaS.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md -->

> **Important:** Azure SQL Database operates in `FULL` recovery mode only. There's no `BULK_LOGGED` recovery model, which means bulk operations are fully logged. For very large loads, this can generate significant transaction log activity. Plan your batch sizes accordingly and consider scaling up your compute tier during the load.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

### Restoring from BACPAC Files

A **BACPAC** file is a ZIP archive containing both the schema and data of a database. It's the standard portable format for moving databases into Azure SQL Database. You can import one through the Azure portal, SqlPackage, PowerShell, or the Azure CLI.

**SqlPackage** is the recommended tool for production imports. It's faster and handles larger databases better than the portal:

```bash
SqlPackage /a:import \
    /tcs:"Server=yourserver.database.windows.net;Initial Catalog=mydb;User Id=admin;Password=secret" \
    /sf:AdventureWorks.bacpac \
    /p:DatabaseEdition=GeneralPurpose \
    /p:DatabaseServiceObjective=GP_Gen5_2
```

A few things to know about BACPAC imports:

- **Scale up for the import, then scale back down.** Import speed is directly tied to your compute tier. A P6 or BC_Gen5_8 will import dramatically faster than an S0.
- **BACPAC files over 150 GB can fail** when imported through the portal or PowerShell for two separate reasons: (1) a known DacFX bug produces a "File contains corrupted data" error on large BACPACs, and (2) the portal/PowerShell processing machines have only 450 GB of local disk space, which can be exhausted because temp files may reach three times the database size. Use SqlPackage on a machine with adequate disk space to avoid both issues.
- **Importing directly into an elastic pool isn't supported** via the portal, PowerShell, or Azure CLI. Create a standalone database, import into it, then move it to the pool.
- **The imported database's compatibility level matches the source.** You can raise it after import with `ALTER DATABASE ... SET COMPATIBILITY_LEVEL`.

<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/load-and-move-data/database-import.md -->

> **Tip:** For a quick test database, the AdventureWorks and Wide World Importers sample databases are available as BACPAC files from Microsoft. They're excellent for prototyping queries and testing deployment pipelines.

### Restoring from Backup Files (Managed Instance and VMs)

If you're using **Azure SQL Managed Instance**, you can restore native SQL Server `.bak` files — something SQL Database can't do. This is one of MI's key advantages for migrations: you back up your on-premises database, upload the `.bak` to Azure Blob Storage, and restore directly.

```sql
-- Create a credential for blob storage access
CREATE CREDENTIAL [https://youraccount.blob.core.windows.net/backups]
    WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
    SECRET = '<your-sas-token>';

-- Restore the database
RESTORE DATABASE [MyApp]
    FROM URL = 'https://youraccount.blob.core.windows.net/backups/MyApp.bak'
    WITH REPLACE;
```

Key constraints for MI restores:

- Only `RESTORE FROM URL` is supported — no `DISK`, `TAPE`, or backup devices.
- `COPY_ONLY` is required for user-initiated backups. Differential and log backups aren't supported for user-initiated operations.
- The maximum backup stripe size is 195 GB (the max blob size). Use multiple stripes for larger databases.
- Databases with `FILESTREAM` data can't be restored.
- `.bak` files with multiple backup sets or multiple log files can't be restored.
- General Purpose instances can't restore databases larger than 8 TB or with more than 280 files.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md -->

For **SQL Server on Azure VMs**, you have full SQL Server restore capabilities — `RESTORE FROM DISK`, `RESTORE FROM URL`, differential restores, log restores, everything. The experience is identical to on-premises SQL Server with Azure-managed storage underneath.

> **Note:** Native backups from Managed Instance can be restored to SQL Server — but which version depends on the MI update policy. Instances on the SQL Server 2022 policy (the default) restore to SQL Server 2022. Instances on the SQL Server 2025 policy restore to SQL Server 2025. Instances on the Always-up-to-date policy lose the ability to restore to any SQL Server version.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md, azure-sql-managed-instance-sql-mi/how-to/manage/update-policy.md -->

## T-SQL Compatibility: What's Different

This is the section you'll come back to when something works fine on your dev SQL Server but breaks in Azure. Azure SQL Database and Managed Instance share the SQL Server engine, but they're not identical to it. Understanding the compatibility surface saves you from discovering the gaps in production.

### Unsupported and Partially Supported T-SQL in SQL Database

Azure SQL Database has the most restrictions because it's the most fully managed option. The core SQL language — data types, operators, string functions, arithmetic, cursors, stored procedures, variables, control flow — works identically to SQL Server. The gaps are in infrastructure-level features.

**Things that aren't supported at all:**

- **Cross-database queries.** Three-part names (`OtherDb.dbo.MyTable`) don't work. Each SQL Database is an isolated unit. The only exception is three-part names referencing `tempdb`. For read-only cross-database access, look at elastic queries.
- **CLR integration.** No `CREATE ASSEMBLY`, no .NET code inside the database.
- **`USE` statement.** You can't switch databases within a connection. Open a new connection to the target database.
- **`BACKUP` and `RESTORE`.** The service manages backups automatically. You get point-in-time restore through the portal or API — not through T-SQL.
- **SQL Server Agent.** No agent jobs. Use Azure Automation, Logic Apps, or elastic jobs instead.
- **`OPENQUERY`, `OPENDATASOURCE`, four-part names.** No linked servers.
- **Server-scoped DDL triggers and logon triggers.**
- **`FILESTREAM` and `FILETABLE`.**
- **Service Broker, event notifications, query notifications.**
- **Trace flags and `sp_configure`.** Use `ALTER DATABASE SCOPED CONFIGURATION` instead.

<!-- Source: azure-sql-database-sql-db/concepts/transact-sql-tsql-differences-sql-server.md -->

**Partially supported features — same name, different options:**

- **`CREATE DATABASE`** — no file placement options; adds service tier and elastic pool parameters.
- **`CREATE TABLE`** — no `FILETABLE` or `FILESTREAM` options.
- **`CREATE LOGIN`** — fewer options than SQL Server; contained database users preferred.
- **File properties** — size, placement, and growth managed by the service.

<!-- Source: azure-sql-database-sql-db/concepts/transact-sql-tsql-differences-sql-server.md -->

> **Gotcha:** Server-level `GRANT`, `REVOKE`, and `DENY` aren't supported in SQL Database. Some server-level permissions are replaced by database-level equivalents or granted through built-in server roles. If your migration scripts contain server-level permission statements, they'll fail silently or with cryptic errors.

<!-- Source: azure-sql-database-sql-db/concepts/transact-sql-tsql-differences-sql-server.md -->

### T-SQL Differences in Managed Instance

Managed Instance has much higher compatibility with SQL Server — that's its selling point. It supports cross-database queries, CLR, SQL Server Agent, Service Broker, linked servers (to SQL targets), Database Mail, and native backup/restore. But it's still a PaaS service, and some things are different.

**Key differences:**

- **Always On is built-in and not user-controllable.** `CREATE AVAILABILITY GROUP`, `ALTER AVAILABILITY GROUP`, and `SET HADR` aren't supported. High availability is automatic.
- **Backups to URL only.** No `DISK`, `TAPE`, or backup devices. User-initiated backups require `COPY_ONLY`.
- **File system access is gone.** `CREATE ASSEMBLY FROM FILE`, certificate backup to file, and `xp_cmdshell` don't work. Use `CREATE ASSEMBLY FROM BINARY` instead.
- **`tempdb` is fixed at 12 data files** and can't be reconfigured. Max file size is 24 GB per core on General Purpose.
- **General Purpose tier: 280 file limit per instance** (data + log files combined across all databases). Business Critical supports 32,767 files per database.
- **`FILESTREAM` and `FILETABLE` aren't supported** on any MI tier.
- **Some `ALTER DATABASE` options can't be changed:** `AUTO_CLOSE`, `SINGLE_USER`, `OFFLINE`, `READ_ONLY`, `ENABLE_BROKER`/`DISABLE_BROKER`, and more. These are locked by the service.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md -->

**System functions that behave differently:**

| Function | Behavior in MI |
|---|---|
| `@@SERVERNAME` | Returns full DNS name |
| `SERVERPROPERTY('EngineEdition')` | Returns 8 (unique to MI) |
| `SERVERPROPERTY('InstanceName')` | Returns NULL |
| `@@SERVICENAME` | Returns NULL |

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md -->

These seem minor until your application code branches on `SERVERPROPERTY` or `@@SERVERNAME` to detect the environment. Test your detection logic.

### The Compatibility Surface: Where SQL Database and MI Diverge from SQL Server

The differences between SQL Database and Managed Instance are larger than the differences between MI and SQL Server. Here's a quick reference:

| Capability | SQL Database | Managed Instance | SQL Server VM |
|---|---|---|---|
| Cross-DB queries | No | Yes | Yes |
| CLR | No | Yes (binary only) | Yes |
| SQL Agent | No | Yes | Yes |
| Linked servers | No | Yes (SQL targets) | Yes |
| `BACKUP`/`RESTORE` | No | URL only, COPY_ONLY | Full |
| `USE` statement | No | Yes | Yes |
| Service Broker | No | Yes (within MI) | Yes |
| Database Mail | No | Yes | Yes |
| FILESTREAM | No | No | Yes |
| Change data capture | Yes; DTU requires S3+ | Yes | Yes |
| Filegroups | PRIMARY only | Yes (auto-paths) | Yes |
| Compatibility levels | 100–160 | 100–160 | Varies by version |

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md, azure-sql-database-sql-db/concepts/transact-sql-tsql-differences-sql-server.md, azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md, azure-sql-database-sql-db/how-to/load-and-move-data/change-data-capture-overview.md -->

The pattern is clear: SQL Database trades compatibility for full management. Managed Instance gives you near-full SQL Server compatibility at the cost of a few PaaS constraints. SQL Server on VMs gives you everything but puts operations on you.

### Anti-Patterns: Assuming Full T-SQL Parity Without Checking

The most common migration failures come from untested assumptions. Here are the patterns that bite people:

**"It worked on my SQL Server, so it'll work in Azure."** This is the root of most problems. Code that uses `xp_cmdshell`, references `msdb` system tables, creates CLR assemblies from file paths, or switches databases with `USE` will fail in SQL Database and potentially in MI. Always run your scripts against the target platform before go-live.

**Relying on three-part names in SQL Database.** See the unsupported features list earlier in this chapter. Consolidate into one database, use elastic queries for read-only access, or restructure your application.

**Using `sp_configure` for server settings.** See the unsupported features list earlier in this chapter.

**Hard-coding `@@SERVERNAME` or `SERVERPROPERTY` values.** These return different formats in Azure SQL — see the system functions table earlier in this chapter. Test your detection logic against your actual deployment targets.

**Assuming `BULK INSERT` can read from local paths.** As covered in the Loading Data section, `BULK INSERT` requires an Azure Blob Storage data source. Stage your data in blob storage first.

> **Tip:** Before migrating, use **Azure Database Migration Service** or the **Data Migration Assistant** to scan your database for compatibility issues. They'll flag unsupported features, partially supported syntax, and behavior differences before you discover them the hard way.

The right mental model: Azure SQL isn't SQL Server with some features removed. It's a managed relational database service that shares the SQL Server engine. Some features are replaced (backups → automatic backups), some are elevated to the platform level (HA → built-in), and some are genuinely absent (FILESTREAM, CLR in SQL Database). Know which category each gap falls into, and you'll make better design decisions.

In the next chapter, we move from schema design to defense — network security, the first layer of the security model that protects everything you've built here.
