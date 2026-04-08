# Chapter 27: Azure SQL Managed Instance — Advanced Topics

You've been running workloads on Managed Instance for a while now — networking, security, backups, HA are solid. This chapter covers the features that separate "lift and shift" from "actually leveraging the platform":

- The Managed Instance link for hybrid DR and migration
- Data virtualization for querying external storage without ETL
- SQL Server engine features that survived the PaaS transition
- In-database machine learning
- The next-gen General Purpose tier
- Windows Authentication for Entra principals

## The Managed Instance Link

The Managed Instance link is the most important hybrid feature in Azure SQL. It creates a near real-time data replication channel between SQL Server (hosted anywhere) and Azure SQL Managed Instance.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/managed-instance-link-feature-overview.md -->

### Link Architecture

Under the hood, the link establishes a distributed availability group between your SQL Server instance and your managed instance. A private connection — VPN, ExpressRoute, or Azure virtual network peering if SQL Server is on an Azure VM — carries the replication traffic. The two endpoints authenticate using certificate-based trust, exchanging public keys of their respective certificates.

The link is database-scoped: one link per database, one database per availability group for that link. You can't bundle multiple databases into a single link. But you can create multiple links from the same SQL Server instance, each replicating a different database — to the same managed instance, or to different ones in different Azure regions. A single General Purpose or Business Critical instance supports up to 100 concurrent links. The Next-gen General Purpose tier supports up to 500.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/managed-instance-link-feature-overview.md -->

The link works with single-node SQL Server instances (with or without existing availability groups) and multi-node instances with existing AGs. It's available in all global Azure regions and national clouds.

| SQL Server version | Link direction | Failback support |
|---|---|---|
| 2016 SP3 | SQL Server → MI only | No |
| 2017 CU31 | SQL Server → MI only | No |
| 2019 CU20 | SQL Server → MI only | No |
| 2022 RTM+ | Bidirectional | Yes |
| 2025 RTM+ | Bidirectional | Yes |

> **Important:** The link works with Enterprise, Developer, and Standard editions of SQL Server. Versions prior to SQL Server 2016 aren't supported because distributed availability groups were introduced in 2016.

### Bidirectional Failover for Hybrid DR

With SQL Server 2016 through 2019, the link is one-way: SQL Server is always the primary, and failover to MI is a one-time event that breaks the link. You can recover data back to SQL Server afterward only through data movement options like transactional replication or bacpac export.

SQL Server 2022 adds bidirectional failover. Either SQL Server or Managed Instance can be the initial primary. You can establish the link from either direction — create it from SQL Server to MI or from MI to SQL Server 2022 (starting with CU10). And critically, you can fail back.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/managed-instance-link/managed-instance-link-disaster-recovery.md -->

When failback is needed, you have two options:

- **Online failback** using the link directly — minimal downtime, the link reverses replication direction.
- **Offline failback** by taking a backup of the database from MI and restoring it to SQL Server 2022.

> **Gotcha:** Bidirectional failover requires the managed instance to use a matching update policy. If your MI uses the Always-up-to-date policy, you can establish a link *from* SQL Server 2022, but after failover to MI, you can't replicate data back or fail back. You need the SQL Server 2022 update policy for full two-way DR.

### Ongoing Hybrid Replication Scenarios

The link isn't just for migration and DR. Because replication runs continuously, you can use it for:

- **Read offload.** Keep SQL Server as your read/write primary on-premises and use MI as a read-only replica in Azure for reporting and analytics.
- **Azure services without migration.** Feed data into Azure-based analytics, machine learning, or reporting without moving your primary workload.
- **Workload consolidation.** Replicate databases from multiple SQL Server instances to a single MI, or spread one instance's databases across multiple MIs in different regions.
- **On-premises copy.** With SQL Server 2022, establish a link from MI to SQL Server to maintain a near real-time local copy for compliance, testing, or business continuity.

Databases replicated through the link are automatically backed up to Azure storage, even when MI isn't the primary. These automated backups include full and transaction log backups (but not differential), enabling point-in-time restore to any MI in the same region.

> **Tip:** You can save on licensing costs with the hybrid failover benefit. Designate your secondary MI as a passive DR replica and Microsoft won't charge SQL Server licensing costs for its vCores. For pay-as-you-go, the discount appears on your invoice. For Azure Hybrid Benefit, those vCores are returned to your license pool.

### Migration Use of the MI Link

Chapter 23 covers migration in depth, but the short version: the link offers the most performant, minimal-downtime migration path available. It's the only solution that provides true online migration to the Business Critical tier. You establish the link, let replication catch up, then cut over — a brief moment of downtime instead of hours. See Chapter 23 for the step-by-step comparison with Log Replay Service.

### Link Limitations Worth Knowing

A few constraints to keep in mind:

- Only user databases are replicated — no system databases, no agent jobs, no logins.
- The link and failover groups are mutually exclusive on the same instance. You can't establish a link on an instance that's part of a failover group, and vice versa.
- Databases with multiple log files can't be replicated (MI doesn't support multiple log files).
- You can't link databases with file tables or file streams.
- In-Memory OLTP databases can only be replicated to Business Critical instances.
- You can only connect via the VNet-local endpoint — no public or private endpoints for the link. The link uses distributed availability group traffic, which requires direct VNet connectivity between SQL Server and MI.

## Data Virtualization

Data virtualization lets you query Parquet and CSV files in Azure Blob Storage or Azure Data Lake Storage Gen2 directly from T-SQL, without importing the data. You combine external data with local relational data using standard joins. The data stays in its original format and location — you just query it in place.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/data-virtualization-overview.md -->

### OPENROWSET: Ad Hoc External Queries

`OPENROWSET` is the fastest way to explore external files. Minimal setup — just an external data source and optionally a credential.

```sql
CREATE EXTERNAL DATA SOURCE SalesLake
WITH (
    LOCATION = 'abs://sales@myaccount.blob.core.windows.net/data'
);

SELECT TOP 100 *
FROM OPENROWSET(
    BULK '2024/Q4/*.parquet',
    DATA_SOURCE = 'SalesLake',
    FORMAT = 'parquet'
) AS rows;
```

For non-public storage, you need a database-scoped credential. MI supports two authentication types: managed identity and shared access signature (SAS). Managed identity is cleaner — grant the MI's system-assigned managed identity the **Storage Blob Data Reader** role on the storage account, then create the credential:

```sql
CREATE DATABASE SCOPED CREDENTIAL LakeCredential
WITH IDENTITY = 'Managed Identity';

CREATE EXTERNAL DATA SOURCE SalesLake
WITH (
    LOCATION = 'abs://sales@myaccount.blob.core.windows.net/data',
    CREDENTIAL = LakeCredential
);
```

> **Important:** Always use the endpoint-specific prefixes (`abs://` for Blob Storage, `adls://` for Data Lake). The generic `https://` prefix is disabled.

`OPENROWSET` supports wildcards for querying multiple files and folders. All files accessed in a single call must share the same schema. You can use `filepath()` and `filename()` functions to project file metadata and filter by partition:

```sql
SELECT
    r.filepath(1) AS [year],
    r.filepath(2) AS [month],
    COUNT_BIG(*) AS row_count
FROM OPENROWSET(
    BULK 'puYear=*/puMonth=*/*.parquet',
    DATA_SOURCE = 'SalesLake',
    FORMAT = 'parquet'
) AS r
WHERE r.filepath(1) = '2024'
GROUP BY r.filepath(1), r.filepath(2);
```

Schema inference works automatically for Parquet files. For CSV files, you must always specify columns using the `WITH` clause. Even for Parquet, specifying types explicitly improves performance — inferred types can be larger than necessary (e.g., `varchar(8000)` instead of `varchar(50)`).

### External Tables: Persistent Access

When you need repeatable access to the same external data, create an external table. It requires an external file format and an external data source, but once created, it behaves like any other table:

```sql
CREATE EXTERNAL FILE FORMAT ParquetFormat
WITH (FORMAT_TYPE = PARQUET);

CREATE EXTERNAL TABLE dbo.ExternalSales (
    OrderId INT,
    OrderDate DATETIME2,
    CustomerId INT,
    TotalAmount DECIMAL(18,2)
)
WITH (
    LOCATION = 'orders/year=*/month=*/*.parquet',
    DATA_SOURCE = SalesLake,
    FILE_FORMAT = ParquetFormat
);

SELECT TOP 10 * FROM dbo.ExternalSales;
```

You can also create views on top of `OPENROWSET` for a lighter alternative to external tables, with the added benefit that `filepath()` works in `WHERE` clauses for partition elimination.

> **Tip:** Create statistics on external data. MI automatically creates single-column statistics on incoming queries, but you can also create them manually with `CREATE STATISTICS ... WITH FULLSCAN`. Good statistics dramatically improve query plan quality for external data.

### Exporting Data with CETAS

`CREATE EXTERNAL TABLE AS SELECT` (CETAS) exports query results to Parquet or CSV files in Blob Storage or ADLS Gen2. It creates the external table and writes the files in a single operation. Because CETAS introduces data exfiltration risk, it's disabled by default on MI — you must explicitly enable it via Azure PowerShell.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/data-virtualization-overview.md -->

## SQL Server Engine Features in Managed Instance

Managed Instance carries forward several SQL Server engine features that Azure SQL Database doesn't support. These are the features that make "near-100% compatibility" real for lift-and-shift scenarios.

### Transactional Replication

MI can act as publisher, distributor, and subscriber in a transactional replication topology — a major differentiator from Azure SQL Database, which can only be a push subscriber.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/sql-server-features/replication-transactional-overview.md -->

| Role | SQL Database | Managed Instance |
|---|---|---|
| Publisher | No | Yes |
| Distributor | No | Yes |
| Pull subscriber | No | Yes |
| Push subscriber | Yes | Yes |

Supported replication types include standard transactional, snapshot, and bidirectional. Merge replication, peer-to-peer, and updatable subscriptions aren't supported.

Common topologies:

- **Publisher with local distributor.** A single MI acts as both publisher and distributor, pushing changes to other MIs, SQL Database, or SQL Server instances.
- **Publisher with remote distributor.** Two MIs — one publishes, the other distributes — but both must be on the same VNet and in the same location.
- **On-premises publisher/distributor with MI subscriber.** Your existing SQL Server publishes, MI subscribes. This is the classic migration and sync pattern.

> **Gotcha:** MI doesn't automatically clean up snapshot files from the Azure Storage account. Unlike on-premises SQL Server, you must delete obsolete snapshot files yourself — via the Azure portal, Storage Explorer, or CLI.

Requirements to keep in mind:

- Use SQL Authentication for connectivity between replication participants. Replication agents don't support Entra authentication for MI-to-MI connections.
- Configure an Azure Storage Account for the working directory. MI can't use local file system paths for snapshot storage like on-premises SQL Server can.
- Ensure TCP port 445 is open in your NSG for Azure file share access. The storage account share uses the SMB protocol, which requires this port.

The number of continuously running distribution agents is capped at 30 — use scheduled agents (with intervals as low as every 10 seconds) when you need more.

### Service Broker

Service Broker provides reliable, asynchronous, transactional messaging between databases. MI supports Service Broker including cross-instance messaging, which matters for applications that rely on queued processing patterns. The key consideration: Service Broker messaging between instances requires network connectivity and proper endpoint configuration in the MI's VNet.

> **Gotcha:** If Service Broker is disabled on the source SQL Server instance, you can't enable it on the target MI after migrating via the Managed Instance link. Verify it's enabled before you migrate.

### Database Mail

MI supports Database Mail — the same `sp_send_dbmail` you use on-premises. The key constraint: SQL Server Agent can use only one Database Mail profile, and it must be named `AzureManagedInstance_dbmail_profile`. Configure your SMTP relay (external SMTP is required), create the profile with that exact name, and Agent job notifications work as expected.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/transact-sql-tsql-differences-sql-server.md -->

> **Gotcha:** `sp_send_dbmail` can't send file attachments via the `@file_attachments` parameter — MI can't access the local file system or external file shares from that procedure. If you need to email files, generate the content inline or use an external service.

### Linked Servers

MI supports linked servers for cross-instance distributed queries via OLE DB providers. This enables querying remote SQL Server instances, other MIs, and — with appropriate providers — other database systems. Linked servers operate within MI's VNet boundaries, so the remote target must be reachable from the MI subnet.

### Server Trust Groups

Distributed transactions between managed instances require a **server trust group**. A trust group establishes certificate-based trust between its member instances, enabling cross-instance distributed queries and transactions using `BEGIN DISTRIBUTED TRANSACTION`.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/security/server-trust-group-overview.md -->

To create a trust group, navigate to the **SQL trust groups** tab under Security settings for any MI in the Azure portal, then add the instances that need to participate. You can also create groups via Azure PowerShell (`New-AzSqlServerTrustGroup`) or Azure CLI.

The mechanics are straightforward: instances in the same trust group reference each other via linked servers, and distributed transactions work natively using T-SQL or .NET `TransactionScope`. If the instances are in different VNets, you need VNet peering plus NSG rules allowing ports 5024 and 11000–12000 on all participating VNets.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/elastic-transactions-overview.md -->

> **Gotcha:** Deleting a trust group doesn't immediately revoke trust between the member instances. To force immediate trust removal, invoke a failover on each participating instance.

Trust groups only cover MI-to-MI scenarios. For transactions that span managed instances plus SQL Server, other RDBMSs, or external applications, you need the managed Distributed Transaction Coordinator (DTC) — see Chapter 18 for full coverage.

## Machine Learning Services

Machine Learning Services brings in-database Python and R execution to MI. You run scripts directly against the data engine using `sp_execute_external_script`, eliminating the need to extract data to a separate ML environment.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/machine-learning-services/machine-learning-services-overview.md -->

### Enabling ML Services

Enable extensibility with two commands (this restarts the instance briefly):

```sql
sp_configure 'external scripts enabled', 1;
RECONFIGURE WITH OVERRIDE;
```

If your MI is part of a failover group, run these commands on **each** instance in the group separately — system database configuration doesn't replicate.

### Training and Scoring In-Database

The core workflow:

1. **Prepare data** using R or Python scripts that run inside the database engine, accessing relational data directly.
2. **Train models** using any open-source framework — scikit-learn, PyTorch, TensorFlow — scaling to the full dataset without extraction.
3. **Deploy models** by embedding them in stored procedures. Applications call the stored procedure and get predictions back through the standard SQL interface.
4. **Score with PREDICT.** For high-throughput, low-latency scoring, use the native T-SQL `PREDICT` function with a serialized model.

```sql
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import pandas as pd
from sklearn.linear_model import LogisticRegression
import pickle

model = LogisticRegression()
model.fit(input_data[["feature1", "feature2"]], input_data["label"])
output_data = pd.DataFrame({"model": [pickle.dumps(model)]})
',
    @input_data_1 = N'SELECT feature1, feature2, label FROM dbo.TrainingData',
    @input_data_1_name = N'input_data',
    @output_data_1_name = N'output_data'
WITH RESULT SETS ((model VARBINARY(MAX)));
```

### MI vs. SQL Server ML Differences

Several constraints are specific to MI:
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/machine-learning-services/machine-learning-services-differences.md -->

- **Languages:** Python and R only — no Java or external languages.
- **Python version:** 3.7.2 (check docs for updates).
- **R version:** 3.5.2 (check docs for updates).
- **Resource governance:** No Resource Governor support. R is capped at 20% of MI resources by default.
- **Network access:** Outbound network is blocked. You can't install packages from the internet at runtime.
- **Instance pools:** ML Services not supported.

> **Gotcha:** Outbound network access is completely blocked for ML Services on MI. You can't `pip install` packages at runtime. Install binary packages using `sqlmlutils` from a local source instead. Also, packages that depend on external runtimes (like Java) or OS-level APIs aren't supported.

The 20% resource cap for external scripts is a default, not a hard limit. You can request a change through an Azure support ticket if your ML workload needs more headroom. But if you're hitting memory errors (`R_AllocStringBuffer` or `cannot allocate vector`), the first fix is scaling up to a higher service tier.

## Next-gen General Purpose Service Tier

The Next-gen General Purpose tier is an architectural upgrade to the existing GP tier. The core change: it replaces Azure page blobs with **Elastic SAN** for the remote storage layer. The result is significantly improved storage latency, IOPS, and throughput — at the same baseline cost.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/service-tiers-next-gen-general-purpose-use.md -->

Key characteristics:

| Capability | General Purpose | Next-gen GP |
|---|---|---|
| Max databases | 100 | 500 |
| Max storage | 16 TB | 32 TB |
| Storage backend | Page blobs | Elastic SAN |
| IOPS scaling | Tied to storage size | Independent via slider |
| Memory scaling | Fixed per vCore | Flexible (premium-series) |
| Baseline cost | Standard GP pricing | Same as GP |

You get 3 free IOPS for every GB of reserved storage. A 1,024 GB instance gets 3,072 IOPS included. You can scale IOPS above that up to the VM limit at additional cost — each additional IOPS costs the regional per-GB storage price divided by three.

The tier also supports **flexible memory** — you can adjust the memory-to-vCore ratio independently, available on premium-series hardware for locally redundant instances. This is a significant shift from traditional GP, where memory allocation is fixed to the vCore count.

You can upgrade existing GP instances in the portal (Compute + storage → Enable Next-gen General Purpose) and adjust IOPS and memory using sliders. Your billing statement still reflects "General Purpose" — the next-gen upgrade doesn't change the SKU name.

> **Gotcha:** Zone redundancy isn't available for the Next-gen General Purpose tier. If you need zone-redundant HA in GP, stay on the standard General Purpose tier.

If you need any of the higher limits shown above — more databases, more storage, independent IOPS scaling — enable the next-gen upgrade.

## Windows Authentication for Entra Principals

This feature solves a specific, painful migration blocker: legacy applications that use Windows Authentication and can't be changed to use Entra (formerly Azure AD) authentication. Maybe the source code is gone. Maybe the app depends on legacy drivers. Maybe the client machines can't be reconfigured. Whatever the reason, the app sends a Kerberos ticket and expects it to work.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/security/windows-auth-for-microsoft-entra-principals/winauth-azuread-overview.md -->

Windows Authentication for Entra principals on MI uses Kerberos to bridge that gap. It works for devices or VMs joined to Active Directory, Microsoft Entra ID, or hybrid Entra ID. No need to deploy Entra Domain Services, and no new on-premises infrastructure required.

### Two Authentication Flows

There are two flows, depending on your client environment:
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/security/windows-auth-for-microsoft-entra-principals/winauth-azuread-setup.md -->

| Flow | Client requirement | Join type |
|---|---|---|
| Modern interactive | Win 10 20H1+ / Server 2022+ | Entra or hybrid joined |
| Incoming trust-based | Win 10+ / Server 2012+ | AD joined |

The **modern interactive flow** is the recommended option for organizations with Entra-joined or hybrid-joined clients. It requests Kerberos TGTs during login — no trust object in AD, no domain controller visibility required. The catch: it only works for interactive sessions (SSMS, web apps), not service accounts.

The **incoming trust-based flow** covers AD-joined clients in traditional environments. It requires a trust object created in your on-premises AD and registered in Entra ID, plus line of sight to a domain controller. This flow supports a broader range of scenarios including service-to-service authentication.

### Setup Overview

Setup has two phases:

1. **One-time infrastructure setup.** Sync AD with Entra ID using Entra Connect (if not already done). Then configure one or both authentication flows based on your client environment.
2. **Per-instance configuration.** Create a system-assigned service principal for each MI.

The feature also enables patterns that traditional on-premises SQL Servers use frequently — "double hop" authentication where IIS impersonates end users, and extended events traces launched using Windows Authentication.

> **Tip:** If you're migrating legacy apps to MI and Windows Auth is the blocker, this feature eliminates the need to rewrite authentication code. Set up the appropriate flow, configure the MI, and the existing Windows Auth connection strings work as-is.

This chapter covered the features that make Managed Instance more than a SQL Server in the cloud — it's a hybrid platform that bridges on-premises and Azure. The next chapter shifts to SQL Server on Azure VMs, where you trade managed convenience for full engine control and the advanced HADR and storage configurations that come with it.
