# Appendix B: Feature Comparison Matrix

Chapter 2 gave you the high-level picture — this is the full matrix of what's supported where across **SQL Database**, **SQL Managed Instance**, and **SQL Server on Azure VMs**.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md, azure-sql-database-sql-db/concepts/transact-sql-tsql-differences-sql-server.md, shared-sql-db-sql-mi-docs/shared-concepts/security/microsoft-entra-authentication/authentication-aad-overview.md -->

## How to Read This Appendix

Each table uses a simple notation:

| Symbol | Meaning |
|---|---|
| ✅ | Fully supported |
| ⚠️ | Partially supported (see notes) |
| ❌ | Not supported |

SQL Server on Azure VMs runs the full SQL Server engine on your own virtual machine. It supports everything SQL Server supports — period. The interesting question is always what SQL Database and Managed Instance *don't* support, and why. That's where this appendix earns its keep.

> **Tip:** If a feature shows ⚠️, the notes column explains the limitation. In most cases, there's a PaaS alternative that achieves the same outcome differently.

---

## Database Engine Features

These are core SQL Server engine capabilities — the features you use in T-SQL code, database design, and day-to-day operations.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md, azure-sql-database-sql-db/how-to/load-and-move-data/change-data-capture-overview.md, azure-sql-database-sql-db/concepts/in-memory-technologies-in-azure-sql-database/in-memory-oltp-overview.md -->

### Security and Compliance

| Feature | DB | MI | VM | Notes |
|---|---|---|---|---|
| Always Encrypted | ✅ | ✅ | ✅ | Key Vault + cert store |
| Auditing | ✅ | ✅ | ✅ | MI: minor differences |
| Ledger | ✅ | ✅ | ✅ | |
| Row-level security | ✅ | ✅ | ✅ | |
| TDE | ✅ | ✅ | ✅ | |

### Replication and Data Movement

| Feature | DB | MI | VM | Notes |
|---|---|---|---|---|
| Always On AGs | ❌ | ❌ | ✅ | PaaS uses built-in HA; see HA/DR below |
| Change data capture | ⚠️ | ✅ | ✅ | DB: DTU S3+; all vCore |
| Change tracking | ✅ | ✅ | ✅ | |
| Database mirroring | ❌ | ❌ | ✅ | Deprecated in SQL Server; use AGs |
| Linked servers | ❌ | ⚠️ | ✅ | MI: SQL targets, no DTC |
| Service Broker | ❌ | ✅ | ✅ | MI: intra-instance only |
| Txn replication | ⚠️ | ✅ | ✅ | DB: subscriber only |

### Programmability and Storage

| Feature | DB | MI | VM | Notes |
|---|---|---|---|---|
| CLR integration | ❌ | ✅ | ✅ | MI: no file system access |
| Columnstore indexes | ✅ | ✅ | ✅ | DB: DTU S3+ or vCore |
| Contained databases | ✅ | ✅ | ✅ | |
| Cross-database queries | ❌ | ✅ | ✅ | DB: use elastic query |
| Cross-database txns | ❌ | ✅ | ✅ | DB: elastic transactions |
| Data compression | ✅ | ✅ | ✅ | |
| Data virtualization | ✅ | ✅ | ✅ | Varies by data source |
| Database mail | ❌ | ✅ | ✅ | |
| Database snapshots | ❌ | ❌ | ✅ | PaaS: use PITR instead |
| DBCC statements | ⚠️ | ⚠️ | ✅ | Subset in PaaS |
| DDL triggers | ⚠️ | ✅ | ✅ | DB: database-level only |
| Distributed txns | ❌ | ✅ | ✅ | DB: elastic transactions |
| Extended events | ⚠️ | ⚠️ | ✅ | PaaS: target differences |
| Extended stored procs | ❌ | ❌ | ✅ | Legacy; avoid |
| Filestream | ❌ | ❌ | ✅ | |
| FileTable | ❌ | ❌ | ✅ | |
| Files and filegroups | ⚠️ | ⚠️ | ✅ | DB: primary only. MI: auto |
| Full-text search | ✅ | ✅ | ✅ | No 3rd-party filters in PaaS |
| Graph processing | ✅ | ✅ | ✅ | |
| In-memory OLTP | ⚠️ | ⚠️ | ✅ | DB: Prem/BC/HS. MI: BC only |
| JSON support | ✅ | ✅ | ✅ | |
| Machine Learning Svc | ❌ | ✅ | ✅ | |
| Partitioning | ✅ | ✅ | ✅ | |
| Query notifications | ❌ | ✅ | ✅ | |
| Query Store | ✅ | ✅ | ✅ | Incl. secondary replicas |
| Resource Governor | ❌ | ✅ | ✅ | |
| Semantic search | ❌ | ❌ | ✅ | |
| Sequence numbers | ✅ | ✅ | ✅ | |
| Spatial data | ✅ | ✅ | ✅ | |
| SQL Server Agent | ❌ | ✅ | ✅ | DB: use elastic jobs |
| Temporal tables | ✅ | ✅ | ✅ | |
| Trace flags | ❌ | ⚠️ | ✅ | MI: limited set |
| Vector search | ✅ | ✅ | ✅ | |
| XML indexes | ✅ | ✅ | ✅ | |

---

## Authentication and Identity

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

| Feature | SQL DB | MI | VM | Notes |
|---|---|---|---|---|
| Microsoft Entra auth | ✅ | ✅ | ✅ | |
| Microsoft Entra logins | ⚠️ | ✅ | ✅ | SQL DB: preview. VM: SQL Server 2022+ |
| SQL authentication | ✅ | ✅ | ✅ | |
| Windows authentication | ❌ | ✅ | ✅ | MI: Kerberos/Entra ID |
| Contained DB users | ✅ | ✅ | ✅ | Recommended for DB |
| Server-level logins | ⚠️ | ✅ | ✅ | DB: limited CREATE/ALTER LOGIN |

---

## Backup and Restore

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

| Feature | SQL DB | MI | VM | Notes |
|---|---|---|---|---|
| Automated backups | ✅ | ✅ | ❌ | VM: you manage backups |
| User-initiated BACKUP | ❌ | ⚠️ | ✅ | MI: copy-only to Blob Storage |
| RESTORE from backup | ❌ | ✅ | ✅ | MI: FROM URL only |
| Point-in-time restore | ✅ | ✅ | ❌ | Built into PaaS |
| Long-term retention | ✅ | ✅ | ❌ | Up to 10 years in PaaS |
| Geo-restore | ✅ | ✅ | ❌ | Requires geo-redundant backup |
| Restore to SQL Server | ❌ | ⚠️ | ✅ | MI: SQL Server 2022+; depends on update policy |

> **Important:** SQL Database doesn't support user-initiated BACKUP or RESTORE commands. You rely entirely on the platform's automated backup system. This is by design — it guarantees consistent backups without human error — but it means you can't bring a `.bak` file and restore it directly. Use BACPAC import or Azure Database Migration Service instead.

---

## High Availability and Disaster Recovery

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

| Feature | SQL DB | MI | VM | Notes |
|---|---|---|---|---|
| Built-in HA | ✅ | ✅ | ❌ | VM: configure AGs yourself |
| Zone redundancy | ✅ | ✅ | ❌ | MI GP: preview. MI BC: GA |
| Failover groups | ✅ | ✅ | ❌ | Cross-region automatic failover |
| Active geo-replication | ✅ | ❌ | ❌ | SQL DB only; MI uses failover groups |
| Read replicas | ✅ | ⚠️ | ✅ | MI: 1 built-in readable replica |
| Always On AGs | ❌ | ❌ | ✅ | Full control on VMs; PaaS uses built-in HA |
| Failover cluster instances | ❌ | ❌ | ✅ | |
| Log shipping | ❌ | ❌ | ✅ | |
| Managed Instance Link | ❌ | ✅ | ❌ | Near-real-time repl to/from SQL Server |

---

## Platform Capabilities

These are Azure-level features layered on top of the database engine.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

| Feature | SQL DB | MI | VM | Notes |
|---|---|---|---|---|
| Auto-scale (serverless) | ✅ | ❌ | ❌ | DB serverless tier only |
| Automatic tuning | ✅ | ❌ | ❌ | Index + plan forcing in DB |
| Database watcher | ✅ | ✅ | ❌ | Preview |
| Elastic jobs | ✅ | ❌ | ❌ | MI: use SQL Agent |
| Elastic pools | ✅ | ❌ | ❌ | MI: instance pools instead |
| Fabric mirroring | ✅ | ✅ | ❌ | |
| Maintenance windows | ✅ | ✅ | ❌ | Choose preferred schedule |
| Pause/resume | ✅ | ✅ | ✅ | Different per option |
| Query Performance Insight | ✅ | ❌ | ❌ | MI: use SSMS reports |
| Synapse Link | ✅ | ❌ | ❌ | |
| VNet integration | ⚠️ | ✅ | ✅ | DB: Private Link. MI: VNet-native |

---

## T-SQL Surface Area Gaps

SQL Database has the most notable T-SQL restrictions because it's a fully managed, multi-tenant service. The engine deliberately omits features that require OS access, server-level configuration, or cross-database operations.

<!-- Source: azure-sql-database-sql-db/concepts/transact-sql-tsql-differences-sql-server.md -->

### Not Supported in SQL Database

These T-SQL features work in SQL Server and Managed Instance but are **not available** in SQL Database:

- **Server-level configuration** — `sp_configure`, `RECONFIGURE`, trace flags, server memory/CPU affinity settings. Use `ALTER DATABASE SCOPED CONFIGURATION` and service tiers instead.
- **Cross-database queries** — Three- and four-part names (except `tempdb`). Use elastic query for read-only cross-database access.
- **CLR assemblies** — No .NET Framework integration. Rewrite as T-SQL or move logic to the application tier.
- **Service Broker** — No message queuing inside the database engine. Use Azure Service Bus or similar.
- **SQL Server Agent** — No agent jobs. Use elastic jobs, Azure Automation, or Logic Apps.
- **Filestream / FileTable** — No file-based blob storage. Use Azure Blob Storage with app-tier integration.
- **BACKUP / RESTORE** — Managed entirely by the platform.
- **OPENQUERY, OPENDATASOURCE** — No ad-hoc distributed queries.
- **Event notifications / query notifications** — Use Azure Monitor alerts.
- **USE statement** — Can't switch database context. Open a new connection instead.
- **Server-scoped triggers** — Database-level DDL triggers only.
- **`EXECUTE AS LOGIN`** — Use `EXECUTE AS USER`.
- **`SHUTDOWN`** — Not applicable in PaaS.

### Partially Supported in SQL Database

These work but with restrictions:

- **`CREATE DATABASE` / `ALTER DATABASE`** — No file placement options. Additional PaaS-specific options (service objective, elastic pool) are available instead.
- **`CREATE LOGIN` / `ALTER LOGIN`** — Supported, but with fewer options than SQL Server. Prefer contained database users.
- **DMVs** — Most are available, but server-level and AG-related views are absent.
- **`BULK INSERT` / `OPENROWSET`** — Only from Azure Blob Storage.

> **Gotcha:** If you're migrating from SQL Server and your application uses `USE [OtherDatabase]` to switch context, you'll need to refactor. Each SQL Database connection targets a single database. There's no `USE` statement.

---

## Resource Limits at a Glance

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md, azure-sql-database-sql-db/concepts/hyperscale/service-tier-hyperscale.md, azure-sql-database-sql-db/concepts/resource-limits/single-database-resources/resource-limits-vcore-single-databases.md, azure-sql-managed-instance-sql-mi/concepts/architecture/resource-limits.md -->

### SQL Database

- **Max vCores:** 128 (GP/BC); 192 preview (HS premium-series memory optimized)
- **Max storage:** 128 TB (Hyperscale); 4 TB (GP/BC)
- **Max tempdb:** 32 GB per vCore
- **Max log throughput:** 100 MiB/s (GP/BC); 150 MiB/s (HS premium-series)
- **Backup retention:** 1–35 days (PITR), up to 10 years (LTR)
- **Read replicas:** BC: 1 built-in readable secondary. HS: up to 4 HA + 30 named. GP: none

### SQL Managed Instance

- **Max vCores:** 128
- **Max storage:** 16 TB (32 TB next-gen GP)
- **Max tempdb:** 24 GB per vCore (GP); up to available instance storage (BC)
- **Max log throughput:** GP: 4.5 MiB/s per vCore, max 120 MiB/s. BC standard-series: 4.5 MiB/s per vCore, max 96 MiB/s. BC premium-series: 12 MiB/s per vCore, max 192 MiB/s
- **Backup retention:** 1–35 days (PITR), up to 10 years (LTR)
- **Read replicas:** BC: 1 built-in readable secondary. GP: none

### SQL Server on Azure VMs

- **Max vCores / storage / tempdb / log throughput:** VM-dependent — no platform-imposed engine limits
- **Backup retention:** You manage
- **Read replicas:** You configure via Always On AGs

For complete, tier-specific resource limits, see Appendix A.

---

## Tools and Management

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

| Tool | SQL DB | MI | VM | Notes |
|---|---|---|---|---|
| Azure portal | ✅ | ✅ | ✅ | |
| Portal query editor | ✅ | ❌ | ❌ | |
| Azure CLI | ✅ | ✅ | ✅ | |
| Azure PowerShell | ✅ | ✅ | ✅ | |
| SSMS | ✅ | ✅ | ✅ | MI: v18.0+ |
| SSDT | ✅ | ✅ | ✅ | |
| SQL Server Profiler | ❌ | ✅ | ✅ | SQL DB: use extended events |
| BACPAC import/export | ✅ | ✅ | ✅ | |
| SMO | ✅ | ✅ | ✅ | MI: v150+ |

---

## Migration Paths

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/features-comparison.md -->

| Source → Target | SQL Database | MI | VM |
|---|---|---|---|
| SQL Server (on-prem/VM) | BACPAC, BCP, txn repl | MI Link, LRS, DMS, backup/restore | Backup/restore, lift-and-shift |
| SQL Database | DMS, BACPAC, BCP | BACPAC, BCP | BACPAC, BCP |
| MI | Txn repl, BACPAC, BCP | DB copy/move, cross-instance PITR | Native backup/restore, BACPAC |

> **Tip:** For SQL Server to Managed Instance, the **Managed Instance Link** is the preferred online migration path. It provides near-real-time replication and supports a clean cutover with minimal downtime.

---

## Using This Matrix

Don't memorize these tables. Use them as a decision tool:

1. **List your must-have features.** CLR? Service Broker? Cross-database queries? Check the matrix.
2. **Identify blockers.** A single ❌ on a must-have feature narrows your options immediately.
3. **Weigh the ⚠️ items.** Partial support often means an alternative approach exists. Read the notes — the PaaS alternative might actually be better than what you're using today.
4. **Factor in the operational trade-offs.** SQL Server on VMs gives you 100% feature parity, but you own patching, backups, and HA. That operational cost is real — don't ignore it because a PaaS option is missing one feature you might not even need.

The feature matrix is a starting point, not the whole story. Pair it with the decision framework in Chapter 1 and the purchasing model details in Chapter 2 to make the right call for your workload.
