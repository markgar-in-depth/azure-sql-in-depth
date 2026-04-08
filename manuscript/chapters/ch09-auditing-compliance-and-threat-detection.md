# Chapter 9: Auditing, Compliance, and Threat Detection

Someone changed the price of your top-selling product to zero last Tuesday. You know it happened — the support tickets tell you that much. What you don't know is who did it, from where, or whether it was malicious or accidental. Without auditing, you're guessing. With it, you're reading a trail that leads straight to the answer.

This chapter covers the full compliance and threat detection stack built into Azure SQL:

- **SQL Auditing** — tracks every operation and writes the trail to storage, Log Analytics, or Event Hubs
- **Microsoft Defender for SQL** — watches for active threats and scans for misconfigurations
- **Data Discovery & Classification** — labels your sensitive columns and feeds that context into audit logs
- **Ledger tables** — cryptographic tamper-evidence using SHA-256 and Merkle trees
- **Azure Policy** — enforces governance rules at the ARM layer before resources are created

These features work together — classification feeds audit logs, auditing feeds threat detection, and Policy ensures nothing gets deployed without the controls your organization requires.

## SQL Auditing

It's the foundation of every compliance story in Azure SQL — without an audit trail, you have nothing to show auditors and no data to feed into threat detection.

<!-- Source: azure-sql-database-sql-db/concepts/security/azure-sql-auditing/auditing-overview.md -->

> **Important:** Auditing is optimized for availability and performance. During periods of very high activity or high network load, the auditing feature might allow transactions to proceed without recording all events marked for auditing. Keep this in mind for workloads where every single event must be captured — you may need complementary controls.

### Server-Level vs. Database-Level Audit Policies

An auditing policy can be defined at the server level (applying to all databases on the logical server) or at the individual database level.

<!-- Source: azure-sql-database-sql-db/concepts/security/azure-sql-auditing/auditing-server-level-database-level.md -->

**Server-level auditing** is the recommended default. When you enable it on a logical server, it applies to every database on that server — existing and newly created. The policy follows the databases automatically, so you don't have to configure anything per-database.

**Database-level auditing** lets you override destination or retention settings for a specific database. You might use it when a single database needs a different storage account, a longer retention period, or a different set of audit action groups than the server default.

If you enable both, they run side by side — the database gets audited twice, once by each policy. That's usually wasteful. Stick with server-level auditing unless you have a specific reason to diverge for a particular database. The exception: for servers with many databases under heavy OLTP load, server-level auditing consolidates all events into a single folder, making per-database log retrieval slow. In that scenario, switch to database-level auditing so each database writes to its own folder — and review whether you really need every batch-completed event.

> **Gotcha:** Database-level auditing policies configured to Log Analytics or Event Hubs don't survive database copy, point-in-time restore, or geo-replication. The secondary database won't inherit a database-level audit policy targeting those destinations. If you need auditing on the secondary, configure it at the server level.

### Destination Choices: Storage, Log Analytics, Event Hubs

You can send audit logs to one or more of three destinations:

| Destination | Best for | Format |
|---|---|---|
| Azure Storage | Long-term retention, compliance archives | `.xel` blobs |
| Log Analytics | Interactive KQL queries, dashboards | `AzureDiagnostics` table |
| Event Hubs | SIEM integration, real-time streaming | Apache Avro / JSON |

You're not limited to one. A common pattern is Log Analytics for operational analysis plus Azure Storage for immutable long-term retention. Event Hubs makes sense when you need to feed audit data into a third-party SIEM like Splunk or Sentinel.

<!-- Source: azure-sql-database-sql-db/concepts/security/azure-sql-auditing/audit-log-format.md -->

Audit logs stored in Blob Storage land in a container named `sqldbauditlogs`. For server-level auditing, all audit logs — including those from read-only replicas — consolidate into a single `master` folder. Filter on the `is_secondary_replica_true` column to isolate replica traffic. Each file uses `.xel` format and can be opened directly in SQL Server Management Studio. You can also query them with `sys.fn_get_audit_file` in T-SQL.

> **Note:** Prior to the server auditing re-architecture (GA July 2025), server audit logs were written to separate per-database folders using the pattern `<ServerName>/<DatabaseName>/<AuditName>/<Date>/`. The current behavior — a single `master` folder — aligns with SQL Server and Managed Instance. Database-level auditing still writes to per-database folders.

When your destination is a storage account behind a VNet or firewall, you need a **general-purpose v2 storage account** and the server's managed identity needs the right role on the storage account (details in the next section). Premium storage with BlockBlobStorage is also supported.

> **Gotcha:** The `statement` and `data_sensitivity_information` fields are truncated at **4,000 characters**. If your T-SQL batches are longer than that, the audit record won't capture the full text.

### Managed Identity Authentication for Auditing

Audit destinations using Azure Storage support two authentication methods: storage access keys and managed identity. Managed identity is the better choice — it eliminates the need to rotate storage keys and works naturally with infrastructure-as-code.

<!-- Source: azure-sql-database-sql-db/concepts/security/azure-sql-auditing/auditing-managed-identity.md -->

By default, the identity used is the **primary user-assigned managed identity** on the server. If there's no user identity, the server creates and uses a system-assigned managed identity. Either way, the identity needs the **Storage Blob Data Contributor** role on the target storage account. The Azure portal assigns this role automatically, but if you're configuring via PowerShell, CLI, or ARM templates, you need to grant it yourself.

```powershell
# Configure auditing with managed identity via PowerShell
Set-AzSqlServerAudit `
  -ResourceGroupName "rg-production" `
  -ServerName "sql-contoso-prod" `
  -BlobStorageTargetState Enabled `
  -StorageAccountResourceId "/subscriptions/<sub-id>/resourceGroups/rg-production/providers/Microsoft.Storage/storageAccounts/auditlogs" `
  -UseIdentity $true
```

```azurecli
# Configure auditing with managed identity via Azure CLI
az sql server audit-policy update \
  -g rg-production \
  -n sql-contoso-prod \
  --state Enabled \
  --bsts Enabled \
  --storage-endpoint https://auditlogs.blob.core.windows.net \
  --storage-key '""'
```

> **Gotcha:** When you copy a database to a new server or create a geo-replica, the new server has a different managed identity. That identity won't have access to the original audit storage account. Grant the new server's identity the appropriate role, or audit logging breaks silently.

### Audit Log Schema and Analysis

When audit logs land in Log Analytics, they populate the `AzureDiagnostics` table under the `SQLSecurityAuditEvents` category. The schema includes everything you'd expect: `event_time`, `server_principal_name`, `database_name`, `statement`, `client_ip`, `application_name`, `affected_rows`, and `duration_milliseconds`.

<!-- Source: azure-sql-database-sql-db/concepts/security/azure-sql-auditing/auditing-analyze-audit-logs.md -->

Here's a KQL query that surfaces the top 10 users by query volume in the last 24 hours:

```kusto
AzureDiagnostics
| where Category == "SQLSecurityAuditEvents"
| where TimeGenerated > ago(24h)
| summarize QueryCount = count() by server_principal_name_s
| top 10 by QueryCount desc
```

And one that flags failed login attempts — a useful canary for brute-force attacks:

```kusto
AzureDiagnostics
| where Category == "SQLSecurityAuditEvents"
| where action_name_s == "DATABASE AUTHENTICATION FAILED"
| summarize FailedAttempts = count() by client_ip_s, bin(TimeGenerated, 1h)
| where FailedAttempts > 10
| order by FailedAttempts desc
```

For storage-based logs, you have several options: open `.xel` files directly in SSMS, use **Merge Audit Files** in SSMS to combine multiple files, query them programmatically with `sys.fn_get_audit_file`, or download and analyze in Power BI. The **View audit logs** button in the Azure portal provides a quick in-place view with filters for date and audit source.

> **Tip:** When you access audit records from a database-level Auditing page with database-level auditing enabled, the portal offers a **View dashboard** option with drill-downs into Security Insights and Access to Sensitive Data. This isn't available from server-level audit pages.

### Auditing Microsoft Support Operations

When a Microsoft support engineer accesses your server during a support request, you probably want to know exactly what they did. The **DevOps audit** feature records their activity — queries executed, successful logins, and failed authentication attempts — using three action groups: `BATCH_COMPLETED_GROUP`, `SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP`, and `FAILED_DATABASE_AUTHENTICATION_GROUP`.

<!-- Source: azure-sql-database-sql-db/concepts/security/azure-sql-auditing/auditing-microsoft-support-operations.md -->

Enable it in the portal under **Auditing → Enable Auditing of Microsoft support operations**. The logs can be sent to Storage, Log Analytics, or Event Hubs — the same destinations as your regular audit. In Log Analytics, query them with:

```kusto
AzureDiagnostics
| where Category == "DevOpsOperationsAudit"
```

> **Warning:** DevOps audit logs stored in Azure Storage may contain sensitive operational details. A malicious actor with access to these logs could gain insights into system operations. Secure them with RBAC, network controls, and regular access monitoring — treat them with the same care as your primary audit logs.

### Best Practices: Geo-Replication, Key Rotation, Encrypted Storage

**Geo-replication auditing.** For geo-replicated databases, the recommended approach is server-level auditing on both the primary and secondary servers. Each server audits independently, which avoids cross-regional traffic and ensures audit continuity during failover. If you use database-level auditing instead, the secondary inherits the primary's storage settings — which means cross-region writes and higher latency.

<!-- Source: azure-sql-database-sql-db/concepts/security/azure-sql-auditing/auditing-best-practices.md -->

**Storage key rotation.** If you're using storage access keys instead of managed identity, you need to rotate keys without dropping audit events. The process: switch your audit config to the secondary key, regenerate the primary key, switch back to the primary key, then regenerate the secondary. This is the same two-phase rotation dance you'd use for any Azure Storage integration.

**Key Vault-encrypted storage.** When your audit storage account is encrypted with an Azure Key Vault key behind a firewall, configure an access policy on the Key Vault. The storage account principal needs the **unwrap key** permission to decrypt the stored blobs.

> **Tip:** For immutable audit logs, configure Azure Storage with a time-based retention policy and set **Allow protected append writes** to either *Append blobs* or *Block and append blobs*. The *None* option isn't supported for audit blob writes. The storage retention interval must be shorter than your SQL Auditing retention setting.

### Auditing on Managed Instance

Managed Instance auditing uses the same underlying XEvent infrastructure as SQL Server — but with Azure-specific destinations. You configure it with T-SQL (`CREATE SERVER AUDIT`) or through the Azure portal, targeting Azure Blob Storage, Event Hubs, or Azure Monitor logs.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/security/auditing-configure.md -->

The key differences from SQL Database auditing:

- Managed Instance uses `CREATE SERVER AUDIT ... TO URL` for blob storage (not the portal-only configuration of SQL Database).
- You create a **Credential** with a SAS token to authenticate to the storage container.
- `TO EXTERNAL_MONITOR` sends events to Event Hubs or Azure Monitor logs via Diagnostic Settings.
- `TO FILE` isn't supported — there's no Windows file system access on Managed Instance, so blob storage is the only file-based option.
- `queue_delay` of 0 isn't supported — there's always a small delay between an event occurring and it being written to the log, so you can't get synchronous auditing on MI.
- XEvent auditing stores `.xel` files in Azure Blob Storage. File and Windows event logs aren't available.

```sql
-- Create a credential for the storage container
CREATE CREDENTIAL [https://auditlogs.blob.core.windows.net/sqlmiaudit]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
SECRET = '<your-sas-token>';
GO

-- Create the server audit targeting blob storage
CREATE SERVER AUDIT [AuditProduction]
TO URL (PATH = 'https://auditlogs.blob.core.windows.net/sqlmiaudit',
        RETENTION_DAYS = 90);
GO

-- Create the audit specification
CREATE SERVER AUDIT SPECIFICATION [AuditSpec_Production]
FOR SERVER AUDIT [AuditProduction]
ADD (SUCCESSFUL_LOGIN_GROUP),
ADD (FAILED_LOGIN_GROUP),
ADD (BATCH_COMPLETED_GROUP)
WITH (STATE = ON);
GO

-- Enable the audit
ALTER SERVER AUDIT [AuditProduction]
WITH (STATE = ON);
GO
```

For Microsoft support operations auditing on Managed Instance, you must create a **separate** server audit with `OPERATOR_AUDIT = ON`. You can't combine it with your regular audit — if you enable the operator audit flag on an existing audit, it overwrites the configuration and only logs support operations.

## Microsoft Defender for SQL

Microsoft Defender for SQL bundles two capabilities under a single plan: **Vulnerability Assessment** and **Advanced Threat Protection**. It's part of Microsoft Defender for Cloud, and you can enable it at the subscription level (recommended) or per-server.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/azure-defender-for-sql.md -->

The cost is per-node — one logical server or managed instance counts as one node regardless of how many databases it hosts. You pay once per server, not per database. Defender for Cloud includes a free trial period for evaluation.

### Vulnerability Assessment

Vulnerability Assessment scans your database for security misconfigurations, excessive permissions, and unprotected sensitive data. It runs periodic scans and stores results in Azure Storage. The **Express Configuration** option simplifies setup by using Microsoft-managed storage, so you don't need to configure your own storage account.

<!-- Source: azure-sql-database-sql-db/how-to/security/vulnerability-assessment/sql-database-vulnerability-assessment-storage.md -->

If you're using a customer-managed storage account behind a VNet or firewall:

- The SQL Server's managed identity needs **Storage Blob Data Contributor** on the storage account.
- Enable **Allow trusted Microsoft services access to this storage account** in the firewall settings.
- For Managed Instance, the story is different — MI isn't a trusted Microsoft service. You need to add the MI's VNet and subnet to the storage account's firewall rules explicitly.

The storage account must be **General Purpose v2** (or v1), **Standard performance**, and in the same region as your SQL server. User-assigned managed identities aren't supported for this scenario.

> **Gotcha:** Don't use Azure Storage lifecycle policies to move VA scan results to the archive access tier. Reading scan results from archive storage isn't supported, and your dashboard will show errors.

### Advanced Threat Protection

Advanced Threat Protection detects anomalous database activities in real time and fires security alerts. It covers four threat categories:

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/threat-detection-overview.md -->

| Threat type | What it detects |
|---|---|
| SQL injection | Exploitable SQL injection vulnerabilities and active injection attacks |
| Brute force | Repeated failed login attempts indicating credential stuffing |
| Anomalous access | Logins from unusual locations, data centers, or unfamiliar principals |
| Harmful application | Access from a potentially harmful application |

When a threat is detected, you get an email notification with details: the nature of the anomaly, database name, server name, application name, event time, possible causes, and recommended investigation steps. Alerts also appear in the Microsoft Defender for Cloud portal with full integration into the security incident workflow.

Advanced Threat Protection applies to Azure SQL Database, Managed Instance, Azure Synapse, SQL Server on Azure VMs, and SQL Server enabled by Azure Arc — it covers every deployment option in the Azure SQL family.

> **Tip:** Enable auditing alongside Threat Protection. Auditing writes the detailed event trail that Threat Protection needs for full investigation context. Without audit logs, you'll see the alert but won't have the forensic depth to investigate it thoroughly.

## Data Discovery and Classification

Data Discovery & Classification scans your columns for sensitive data — Social Security numbers, credit card numbers, email addresses, medical records — and lets you label them with sensitivity classifications. It's built into Azure SQL Database, Managed Instance, and Azure Synapse.

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/data-discovery-and-classification-overview.md -->

### Automated Sensitive-Data Discovery and Labeling

The classification engine scans your database and identifies columns containing potentially sensitive data. It presents recommendations that you can accept or dismiss in the Azure portal. Each classification has two metadata attributes:

- **Sensitivity labels** — the primary attribute, defining the sensitivity level (Confidential, Highly Confidential, etc.)
- **Information types** — finer-grained descriptors like "Credit Card Number," "National ID," or "Email Address"

#### How the Discovery Heuristics Work

The engine uses a combination of column name patterns and data-sampling heuristics. It examines column names against a built-in dictionary (columns named `SSN`, `CreditCardNumber`, `email`, `DateOfBirth`, etc.) and correlates with content patterns in the data itself. The built-in information types ship with predefined string patterns, and you can add custom patterns for domain-specific data.

This means discovery works best when your schema uses recognizable names. A column called `PatientSSN` gets flagged immediately; a column called `field_47` containing the same data might not. The engine is a starting point — not a substitute for human review.

#### Common False Positives and Negatives

Expect false positives on columns whose names overlap with sensitive-data keywords but hold non-sensitive data. A `Description` column in a product catalog might get flagged because the content occasionally matches a pattern. On the other side, obfuscated column names, generic field names, and custom data formats are common false negatives.

The practical impact: you'll spend more time dismissing bad recommendations on well-named schemas and more time manually classifying on poorly named ones.

#### Recommended Workflow for Initial Classification

For a large database you're classifying for the first time:

1. **Run the automated scan** and review the recommendations dashboard. Don't accept everything blindly — work through the list.
2. **Accept the high-confidence matches first.** Columns with clear names and matching content patterns are safe bets.
3. **Dismiss false positives** — columns that match a keyword but hold non-sensitive data. Use `Disable-AzSqlDatabaseSensitivityRecommendation` or the REST API to suppress specific recommendations so they don't reappear on the next scan.
4. **Manually classify the gaps.** Query `sys.sensitivity_classifications` against your full column list to find unclassified columns in tables that hold sensitive data. Focus on tables you know contain PII, financial data, or health records.
5. **Iterate after schema changes.** New tables and columns won't inherit classifications automatically — the engine rescans periodically, but verify after major schema migrations.

For organizations managing dozens of databases, the T-SQL approach scales better than portal clicks:

```sql
-- Add a classification
ADD SENSITIVITY CLASSIFICATION TO [dbo].[Patients].[SSN]
WITH (LABEL = 'Highly Confidential', LABEL_ID = '...',
      INFORMATION_TYPE = 'National ID', INFORMATION_TYPE_ID = '...');

-- View all classifications
SELECT * FROM sys.sensitivity_classifications;

-- Remove a classification
DROP SENSITIVITY CLASSIFICATION FROM [dbo].[Patients].[SSN];
```

#### SQL Information Protection vs. Purview at Scale

The built-in **SQL Information Protection policy** handles classification natively within Azure SQL. Customization happens in Defender for Cloud at the root management group level — you define labels and information types once, and they apply across the organization. This works well when Azure SQL is your primary data store and your classification taxonomy is straightforward.

**Microsoft Purview Information Protection** unifies labeling across Microsoft 365, Azure SQL, Power BI, and other Microsoft services. If your organization already manages sensitivity labels in Purview, adopting MIP mode avoids maintaining a parallel taxonomy. But there's a tradeoff: switching to MIP disables the built-in automatic discovery engine. Classification becomes manual or Purview-scan-driven — you register and scan databases in the Purview Data Map, and Purview applies labels based on its own scanning rules.

> **Tip:** If you're evaluating both approaches, start with SQL Information Protection for its zero-config discovery engine. Migrate to Purview MIP when your organization has a mature, centrally managed label taxonomy and you need cross-service consistency. Running both in parallel on the same database isn't supported — you pick one policy mode per logical server.

### Built-in and Custom Classification Labels

Azure SQL supports two information protection policy modes:

**SQL Information Protection policy** — the built-in default. Comes with a predefined set of sensitivity labels and information types, and you can customize the taxonomy in Microsoft Defender for Cloud. Customization applies organization-wide at the root management group level.

**Microsoft Purview Information Protection (MIP) policy** — uses sensitivity labels created and managed in the Microsoft Purview compliance portal. Switching to MIP requires a valid Microsoft 365 subscription, tenant-wide Security Admin permission, and published sensitivity labels. See the tradeoffs between these two approaches in the "SQL Information Protection vs. Purview at Scale" section above.

> **Note:** When you switch to Microsoft Purview Information Protection mode, automatic data discovery and recommendations are disabled. Classification becomes a manual or Purview-scan-driven process. Also, the Information Type field shows `[n/a]` in MIP mode.

### Compliance Reporting and Audit Integration

Classification integrates directly with SQL Auditing. The `data_sensitivity_information` field in audit logs records the sensitivity labels and information types of columns accessed by each query. This means your audit trail doesn't just show *what* was accessed — it shows the *sensitivity level* of the data that was touched.

Activities audited with sensitivity information include `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `BULK INSERT`, `BACKUP`, `TRUNCATE TABLE`, and several others. The classification state dashboard in the Azure portal gives you a visual summary, and you can export a classification report in Excel for auditors.

> **Tip:** Use the audit log's `data_sensitivity_information` field in your KQL queries to build alerts when highly sensitive data is accessed outside normal business patterns. Combine it with `client_ip_s` and `application_name_s` to flag unusual access vectors.

## Ledger Tables

Ledger brings blockchain-inspired tamper-evidence to relational data. It cryptographically hashes every transaction using SHA-256 and a Merkle tree structure, creating a verifiable chain of blocks. If anyone — including a DBA, system admin, or cloud admin — tampers with the data, verification will detect it.

<!-- Source: azure-sql-database-sql-db/concepts/security/ledger/ledger-overview.md -->

The feature is available in Azure SQL Database, Azure SQL Managed Instance, and SQL Server 2022. It doesn't require application changes — the hashing and history tracking happen transparently.

### Append-Only and Updatable Ledger Tables

Ledger offers two table types to match different data patterns:

**Updatable ledger tables** work like system-versioned temporal tables with cryptographic hashing. When you update or delete a row, the previous version is automatically stored in a companion history table. A system-generated ledger view joins the current and history tables, giving you a complete chronicle. Use these for standard application tables — orders, inventory, account balances — where updates and deletes are normal.

**Append-only ledger tables** block updates and deletes at the API level. Only inserts are allowed. There's no history table because there's no history to capture — rows are immutable once written. Use these for audit logs, event streams, SIEM data, or any insert-only workload where even the *possibility* of modification undermines trust.

```sql
-- Create an updatable ledger table
CREATE TABLE [dbo].[AccountBalance] (
    [AccountId]   INT NOT NULL PRIMARY KEY,
    [Balance]     DECIMAL(18,2) NOT NULL,
    [LastUpdated] DATETIME2 NOT NULL
)
WITH (SYSTEM_VERSIONING = ON, LEDGER = ON);
GO

-- Create an append-only ledger table
CREATE TABLE [dbo].[AuditEvents] (
    [EventId]     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    [EventType]   NVARCHAR(50) NOT NULL,
    [Details]     NVARCHAR(MAX),
    [RecordedAt]  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
)
WITH (LEDGER = ON (APPEND_ONLY = ON));
GO
```

Updatable ledger tables add four `GENERATED ALWAYS` columns (transaction ID, sequence number, and operation type for both the ledger and history tables). Append-only tables add two. These count toward the standard 1,024-column-per-table limit.
<!-- Source: azure-sql-database-sql-db/concepts/security/ledger/ledger-updatable-ledger-tables.md, azure-sql-database-sql-db/concepts/security/ledger/ledger-append-only-ledger-tables.md -->

### Database-Level Ledger Configuration

A **ledger database** goes all-in: every table created in the database is a ledger table by default (updatable, unless you specify `APPEND_ONLY = ON`). Regular non-ledger tables can't be created. You configure this at database creation, and it's irreversible — a ledger database can't be converted back to a regular database.

This is useful when your entire application needs tamper-evidence — a financial system, a compliance-heavy healthcare app, or a supply chain platform where all parties need to trust the data.

> **Gotcha:** Existing regular tables can't be converted to ledger tables. You need to migrate data using `sys.sp_copy_data_in_batches`. And once a table is a ledger table, it can't revert to a regular table. Plan your schema decisions carefully.

### Digest Management and Cryptographic Verification

The **database digest** is the root hash of the latest block in the database ledger. It represents the cryptographic state of all ledger tables at a point in time. Digests must be stored outside the database in tamper-proof storage — otherwise an attacker who compromises the database could also modify the digests.

Supported digest storage locations:

- **Azure Blob Storage** with immutability policies
- **Azure Confidential Ledger** — the strongest option, backed by hardware-protected enclaves
- On-premises WORM (Write Once Read Many) devices

Automatic digest storage can be configured so digests are periodically generated and uploaded without manual intervention.

<!-- Source: azure-sql-database-sql-db/concepts/security/ledger/ledger-limits.md -->

> **Important:** Automated digest management doesn't support locally redundant storage (LRS) accounts. Use ZRS, GRS, or RA-GRS for digest storage.

### Verification

Verification recomputes all hashes in the database ledger from the current state of the ledger tables and compares them against previously stored digests. If the computed hashes don't match, tampered data has been detected — and ledger reports exactly which inconsistencies were found.

```sql
-- Verify the database ledger against stored digests
EXECUTE sys.sp_verify_database_ledger_from_digest_storage;
```

You can also verify manually with `sys.sp_verify_database_ledger` by passing specific digest JSON values. This is useful for point-in-time verification or when integrating with external audit workflows.

### When to Use Ledger (and When It's Overkill)

Ledger earns its keep in specific scenarios:

- **Regulatory compliance** — auditors need proof that financial records or medical data haven't been altered
- **Multi-party trust** — supply chain or B2B systems where participants need to verify data integrity without trusting a single administrator
- **Blockchain off-chain storage** — when you replicate blockchain data into SQL for queryability but need to preserve integrity guarantees

Ledger is overkill when:

- You just need an audit trail — SQL Auditing or temporal tables handle that without the hashing overhead
- Your data is already append-only by nature and nobody questions its integrity
- You need features that ledger doesn't support: full-text indexes, XML columns, transactional replication, graph tables, FILESTREAM, or vector data types

<!-- Source: azure-sql-database-sql-db/concepts/security/ledger/ledger-limits.md -->

Other limitations to know:

- `TRUNCATE TABLE` isn't supported on ledger tables
- `SWITCH IN/OUT` partition operations aren't supported
- In-memory tables can't be ledger tables
- A single transaction can update at most 200 ledger tables
- Dropping a ledger table renames (not deletes) the table and its history — the data stays in the database for verification purposes

<!-- Source: azure-sql-database-sql-db/concepts/security/ledger/ledger-limits.md -->

## Azure Policy for Azure SQL

Azure Policy lets you enforce organizational standards on Azure resources at the ARM layer — before a resource is created, not after. For Azure SQL, this means you can require TDE, mandate Entra-only authentication, enforce minimum TLS versions, require private endpoints, and ensure auditing is enabled — all through policy definitions that audit or deny noncompliant configurations.

<!-- Source: reference/policy-reference.md -->

### Built-in Policy Definitions

Microsoft ships dozens of built-in policy definitions for Azure SQL. Here are the most impactful ones:

| Policy | Effect | What it enforces |
|---|---|---|
| Server auditing enabled | AuditIfNotExists | Server-level auditing |
| TDE enabled | Audit, Deny | Transparent Data Encryption |
| Entra-only auth (DB) | Audit, Deny | Blocks SQL auth |
| Entra-only auth (MI) | Audit, Deny | Blocks SQL auth |
| TLS ≥ 1.2 (DB) | Audit, Deny | Minimum TLS version |
| MI public access off | Audit, Deny | Private-only connectivity |
| Defender for SQL (DB) | DeployIfNotExists | Auto-enables Defender |
| Defender for SQL (MI) | DeployIfNotExists | Auto-enables Defender |
| Audit to Log Analytics | DeployIfNotExists | Enforces audit destination |
| Advanced Data Security | DeployIfNotExists | Threat detection + VA |

Policies can **Audit** (flag noncompliant resources without blocking), **Deny** (prevent creation of noncompliant resources), or **DeployIfNotExists** (automatically remediate by deploying the missing configuration). Choose the effect that matches your governance posture — `Audit` for visibility-first, `Deny` for hard enforcement.

### Regulatory Compliance Controls

Azure Policy includes built-in **regulatory compliance initiatives** that map policies to specific controls in compliance frameworks. The frameworks with Azure SQL coverage include:

- **NIST SP 800-53** — the foundational federal security control catalog
- **PCI DSS** — payment card industry requirements
- **ISO 27001** — international information security standard
- **FedRAMP High** — US federal cloud requirements
- **SOC 2** — service organization controls
- **CIS Benchmarks** — Center for Internet Security hardened configurations
- **Australian Government ISM PROTECTED**
- **Canada Federal PBMM**

Each framework maps specific control IDs to Azure Policy definitions. For example, NIST AU-12 (Audit Generation) maps to "Auditing on SQL server should be enabled" and "Azure Defender for SQL should be enabled." The compliance dashboard in the Azure portal shows you exactly which controls are met and which have gaps.

> **Note:** Compliance in Azure Policy is a partial view. Policy checks only what ARM can see — resource configurations. It can't assess application-level controls, operational procedures, or in-database settings that aren't exposed as ARM properties. Use it as one layer in a defense-in-depth compliance strategy.

### Blocking T-SQL CRUD for ARM-Only Governance

Some organizations want to ensure that certain database configurations — auditing policies, Defender settings, TDE — can only be changed through ARM and never through T-SQL or direct database connections. The ARM control plane includes the Azure portal, CLI, PowerShell, Bicep, and Terraform.

Azure Policy enables this by enforcing that configurations exist and match expected values at the ARM layer. Combined with Entra-only authentication and RBAC controls, you can create a governance model where infrastructure changes flow through your CI/CD pipeline and policy checks, not through ad-hoc T-SQL sessions.

This pattern works best when you:

1. Use **DeployIfNotExists** policies to auto-remediate drift
2. Enable **Entra-only authentication** so all access is identity-based
3. Assign **minimal RBAC roles** so developers can query data but can't change security settings
4. Audit all ARM operations through **Azure Activity Log**

The result is a layered governance model: ARM-level policies enforce the configuration, RBAC controls who can change it, and auditing proves what actually happened.

---

Chapter 10 shifts from keeping your data trustworthy to keeping it *available* — the Hyperscale service tier, with its distributed architecture of page servers, named replicas, and near-instant backups.
