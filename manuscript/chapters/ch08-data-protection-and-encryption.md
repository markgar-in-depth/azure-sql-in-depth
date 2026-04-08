# Chapter 8: Data Protection and Encryption

Your data sits on someone else's disks. That's the uncomfortable truth of every cloud database. Azure SQL encrypts everything at rest by default — but "default" only gets you so far. When your compliance team asks who holds the keys, when your SaaS customers demand isolated encryption, or when you need to guarantee that even your own DBAs can't read credit card numbers, you need to go deeper.

This chapter covers every encryption and data-protection layer Azure SQL offers, from the zero-config baseline to client-side column encryption that not even Microsoft can decrypt.

## Transparent Data Encryption (TDE)

TDE encrypts your database files, backups, and transaction logs at rest using AES-256. It operates at the page level: pages are decrypted when read into memory and re-encrypted when written to disk. Your application code doesn't change. Your queries don't change. It's transparent — that's the point.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-tde-overview.md -->

### Service-Managed Keys: The Default

Every newly created Azure SQL Database is encrypted by TDE out of the box. The **Database Encryption Key (DEK)** — a symmetric key that does the actual page-level encryption — is protected by a built-in server certificate unique to each logical server. Microsoft manages the certificate, rotates it annually, and stores the root key in an internal secret store.

For SQL Managed Instance, TDE is enabled at the instance level and inherited by every new database. Existing databases created before February 2019 on Managed Instance (or before May 2017 on SQL Database) aren't encrypted by default — you'd need to enable TDE manually on those.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-tde-overview.md -->

The encryption algorithm is AES-256 in CBC mode. When a database participates in geo-replication, both primary and secondary are protected by the primary's parent server key. Databases on the same logical server share the same built-in certificate.

> **Note:** TDE can't encrypt system databases (`master`, `model`, `msdb`) in SQL Database or Managed Instance. The `master` database holds objects needed for TDE operations. The exception is `tempdb`, which is always encrypted with a Microsoft-owned asymmetric key — temporary data is protected regardless of your TDE configuration.

For service-managed TDE, there's nothing to configure and nothing to maintain. That's its appeal. But it also means you don't control the key, you can't audit key access independently, and you can't revoke encryption on your own schedule. For many workloads, that's fine. For regulated workloads, you need more.

### Customer-Managed Keys (BYOK)

**Customer-managed TDE** — also called Bring Your Own Key (BYOK) — replaces the Microsoft-managed certificate with an asymmetric key you own. The key lives in **Azure Key Vault** or **Azure Key Vault Managed HSM**, and the DEK is wrapped (encrypted) by your key. Azure SQL never sees the raw key material; it sends the DEK to Key Vault for wrap/unwrap operations.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-overview.md -->

This gives you:

- **Full control** over key lifecycle — creation, rotation, deletion.
- **Separation of duties** — the Key Vault admin and the database admin are different roles.
- **Auditability** — Key Vault logs every operation, so you can prove who accessed the key and when.
- **Revocability** — revoke the server's access to Key Vault, and encrypted databases become inaccessible within 10 minutes.

The TDE protector must be an asymmetric RSA or RSA HSM key. Supported key lengths are 2,048 and 3,072 bits. Azure Key Vault backs these with FIPS 140-2 Level 2 validated HSMs; Managed HSM goes to FIPS 140-2 Level 3.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-overview.md -->

Switching from service-managed to customer-managed TDE involves no downtime. Only the DEK gets re-encrypted — a fast online operation. The database files themselves aren't re-encrypted.

> **Important:** Your Key Vault must have **soft-delete** and **purge protection** enabled. Azure SQL validates this during TDE protector setup and will reject the configuration if either is missing. Losing the key means losing the data — these safeguards prevent accidental or malicious deletion.

#### Key Vault Capacity Planning

Don't share your TDE Key Vault with other services. Key Vault enforces throttling limits, and during a server failover, every database on that server triggers key operations simultaneously. The official guidance:

| Database tier | Max per Key Vault |
|---|---|
| General Purpose | 500 databases |
| Business Critical | 200 databases |
| Hyperscale | 500 page servers |

For Hyperscale, each page server maps to a logical data file. You can check how many you have:

```sql
SELECT COUNT(*) AS page_server_count
FROM sys.database_files
WHERE type_desc = 'ROWS';
```

If you exceed these limits, use a dedicated Key Vault per database.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-overview.md -->

### Managed Identities for Key Vault Access

Your server or instance needs an identity to authenticate to Key Vault. Two options:

- **System-assigned managed identity** — created automatically with the server, tied to its lifecycle.
- **User-assigned managed identity (UMI)** — a standalone resource you create, grant Key Vault permissions to, and assign to one or more servers.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-identity.md -->

UMI is the better choice for customer-managed TDE. Because it exists before the server does, you can pre-authorize Key Vault access and enable CMK at server creation time — no chicken-and-egg problem. You can also assign the same UMI to multiple servers, centralizing identity management.

The identity needs the following Key Vault permissions:

| Access model | Required permissions |
|---|---|
| Azure RBAC | Key Vault Crypto Service Encryption User role |
| Vault access policy | `get`, `wrapKey`, `unwrapKey` |

Azure RBAC is the recommended approach for its flexibility. Either way, permission changes can take up to 10 minutes to propagate.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-overview.md -->

> **Warning:** Don't delete the primary UMI while it's in use for TDE. The server loses Key Vault access and your databases become inaccessible.

### Database-Level CMK for Multi-Tenant Isolation

Server-level TDE protectors have an inherent limitation: every database on the server shares the same key. For ISVs running multi-tenant workloads on a shared elastic pool, this means your customers can't each own their encryption key.

**Database-level CMK** solves this. Available on Azure SQL Database (all editions), it lets you assign a different customer-managed key and a different user-assigned managed identity to each individual database on the same logical server.
<!-- Source: azure-sql-database-sql-db/concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-database-level-overview.md -->

The model works like this:

- The server can use service-managed or customer-managed TDE as its default.
- Individual databases override the default with their own key and identity.
- Each database's UMI accesses its own Key Vault (which can live in the customer's tenant — more on that below).

> **Gotcha:** If the logical server is configured with a customer-managed key, individual databases can't opt back to service-managed encryption. They can only use a different CMK. If the server uses service-managed TDE, individual databases *can* use CMK.

> **Note:** Database-level CMK isn't available for Managed Instance, SQL Server on Azure VMs, or Azure Synapse Analytics. It's SQL Database only.

### Cross-Tenant Key Access

What if your SaaS customer wants their encryption key in *their* Azure Key Vault, in *their* Microsoft Entra tenant? That's cross-tenant CMK.

It works through **workload identity federation**. The ISV creates a multitenant application in Microsoft Entra ID and configures a federated identity credential using a user-assigned managed identity. The customer installs the ISV's app in their tenant, grants it Key Vault permissions, and shares the key identifier. The ISV's Azure SQL resource accesses the customer's Key Vault across tenant boundaries.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-cross-tenant.md -->

Cross-tenant CMK works at both server and database level. It requires a user-assigned managed identity — system-assigned identities don't support cross-tenant access.

This model works well for ISVs building compliance-sensitive products. Your customer keeps their key in their vault, in their tenant. If they revoke access, their data becomes unreadable — even to you.

### Key Rotation

Rotating the TDE protector is an online operation that takes seconds. It re-encrypts the DEK, not the entire database. You have two approaches:

**Automatic rotation** — enable it on the server or database, and Azure SQL continuously monitors Key Vault for new key versions. When a new version is detected, the TDE protector rotates to the latest version within 24 hours. Pair this with Azure Key Vault's own auto-rotation policy for end-to-end zero-touch key management.
<!-- Source: azure-sql-database-sql-db/how-to/security/transparent-data-encryption-tde/transparent-data-encryption-byok-key-rotation.md -->

**Manual rotation** — create a new key version in Key Vault, then update the TDE protector to point to it using the portal, PowerShell, or Azure CLI.

> **Important:** Old backups are encrypted with the old key. Never delete previous key versions from Key Vault. Keep them for as long as your backup retention period requires — including long-term retention backups, which can span up to 10 years.
<!-- Source: azure-sql-database-sql-db/how-to/security/transparent-data-encryption-tde/transparent-data-encryption-byok-key-rotation.md, shared-sql-db-sql-mi-docs/shared-concepts/business-continuity/backup-and-recovery/long-term-retention-overview.md -->

Old key versions must stay in Key Vault as long as the transaction log references them (the Important callout above covers backup retention, but the log is the other dependency). This query shows which key versions your transaction log still references — once a version no longer appears, nothing in the active log depends on it:

```sql
SELECT * FROM sys.dm_db_log_info(DB_ID());
```

And you can verify the current TDE protector:

```sql
SELECT [database_id],
       [encryption_state],
       [encryptor_type],
       [encryptor_thumbprint]
FROM [sys].[dm_database_encryption_keys];
```

#### Geo-Replication Considerations

When automatic rotation is enabled and you're using geo-replication, both the primary and secondary servers need access to the same Key Vault (or at least the same key material). Before establishing geo-replication, add the primary's TDE protector key to the secondary server, or ensure the secondary's managed identity has permissions on the primary's Key Vault.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-overview.md -->

### TDE Protector Inheritance

TDE settings propagate automatically across these operations:

- Geo-restore
- Point-in-time restore
- Deleted-database restore
- Active geo-replication
- Database copy

You don't need to decrypt before performing any of these. The target inherits the source's encryption configuration.

> **Gotcha:** When you export a TDE-protected database to a BACPAC, the exported content is *not* encrypted. The BACPAC is plaintext. Plan your export pipeline accordingly.

### Incident Response: Revoking a Compromised Key

If you suspect a key is compromised, you need to move fast — but carefully. Revoking access makes databases inaccessible. Here's the procedure:

1. **Create a new key** in a *separate* Key Vault (not the compromised one — access control is per-vault).
2. **Add the new key** to the server and set it as the TDE protector.
3. **Verify** the new protector has propagated to all databases and replicas.
4. **Back up the new key** to a secure location.
5. **Delete the compromised key** from the original Key Vault.

If you need to make databases inaccessible immediately (scorched-earth response), drop the databases first (they're automatically backed up), then delete the key. You can restore later when you've contained the incident.
<!-- Source: azure-sql-database-sql-db/how-to/security/transparent-data-encryption-tde/transparent-data-encryption-byok-remove-tde-protector.md -->

The behavior depends on *how* key access is lost — the docs describe three distinct scenarios:
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/transparent-data-encryption-tde/transparent-data-encryption-byok-overview.md, azure-sql-database-sql-db/how-to/security/transparent-data-encryption-tde/transparent-data-encryption-byok-remove-tde-protector.md -->

- **Key deleted from Key Vault** — encrypted databases start denying all connections within 10 minutes. Recovery depends on soft-delete: if the key is still in the soft-deleted state, restore it. If it's been purged, the data is gone.
- **Access lost (4XX errors — permissions revoked, Key Vault access policies changed)** — the database moves to an *Inaccessible* state after 30 minutes. If access is restored within that window, the database auto-heals within the subsequent hour. After 30 minutes, recovery requires manual intervention through the Azure portal. You may also lose server-level settings like failover group configurations and tags, plus database-level settings such as elastic pool configurations.
- **Intermittent networking outage (5XX errors)** — Azure SQL applies a 24-hour buffer before moving the database to inaccessible. No action is required if the outage resolves on its own. However, if a failover occurs during this buffer period, the database becomes unavailable because the new primary loses the cached encryption keys.

> **Tip:** Set up Azure Resource Health alerts and Activity Log alerts for TDE protector access failures. The 30-minute auto-recovery window for permission errors is tight — you want to know immediately when something goes wrong.

## Always Encrypted

TDE protects data at rest. It doesn't help when data is in memory on the server, in query results flying over the network, or visible to DBAs running ad-hoc queries. **Always Encrypted** fills that gap by encrypting data on the client side, before it ever reaches the database engine.

The server stores and processes ciphertext. It never sees the plaintext and never holds the keys. This protects sensitive columns — credit card numbers, national IDs, salary data — from anyone with server access, including DBAs, cloud operators, and attackers who compromise the server.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/always-encrypted-landing.md -->

### Key Management and Cryptography

Always Encrypted uses a two-tier key hierarchy:

- **Column Encryption Keys (CEKs)** — symmetric keys that encrypt the actual data. Each encrypted column uses one CEK. The CEK is stored in the database metadata, but only in encrypted form.
- **Column Master Keys (CMKs)** — asymmetric keys that protect the CEKs. The CMK never enters the database. It lives in an external key store: Azure Key Vault, Windows Certificate Store, or an HSM.

When the client driver needs to decrypt a column, it retrieves the encrypted CEK from database metadata, sends it to the CMK's key store for unwrapping, and uses the resulting plaintext CEK to decrypt the data locally. The server facilitates none of this.

Always Encrypted supports two encryption types:

| Type | Properties | Use when |
|---|---|---|
| **Deterministic** | Same plaintext always produces same ciphertext | You need equality comparisons, joins, `GROUP BY`, indexing |
| **Randomized** | Same plaintext produces different ciphertext each time | Maximum security; no query operations on the column |

Deterministic encryption enables point lookups and equi-joins but leaks frequency patterns. Randomized encryption reveals nothing but prevents all server-side operations on the column.

### Getting Started with Always Encrypted via SSMS

The fastest path to Always Encrypted is through SQL Server Management Studio's Always Encrypted Wizard:

1. Right-click your database → **Tasks** → **Encrypt Columns**.
2. Select the columns to encrypt and choose deterministic or randomized encryption for each.
3. Choose where to store the CMK — Azure Key Vault is the production-grade option.
4. SSMS generates the CEK, encrypts it with the CMK, creates the key metadata in the database, and re-encrypts the selected columns.

For production use, manage keys and encryption configuration through PowerShell or the Always Encrypted APIs in your application's client driver.

> **Gotcha:** Once a column is encrypted with Always Encrypted, you can't query it from the server side with ad-hoc T-SQL (unless you're using secure enclaves). Application code must use a client driver that supports Always Encrypted — .NET's `SqlConnection` with `Column Encryption Setting=Enabled`, for example. Plan for this before encrypting existing columns.

## Always Encrypted with Secure Enclaves

Plain Always Encrypted has a significant limitation: the server can't compute on encrypted data. No pattern matching, no range comparisons, no sorting. That's by design — but it's a dealbreaker for many queries.

**Always Encrypted with secure enclaves** extends the model by introducing a trusted execution environment (enclave) inside the database engine. The enclave receives the encryption key securely from the client, decrypts data *inside* the protected enclave memory, performs the computation, and returns encrypted results. The server's OS, hypervisor, and DBAs can't see the plaintext — it's isolated in the enclave.
<!-- Source: azure-sql-database-sql-db/concepts/security/always-encrypted-with-secure-enclaves/always-encrypted-enclaves-plan.md -->

### Intel SGX vs. VBS Enclaves

Azure SQL Database supports two enclave types:

| Property | Intel SGX | VBS |
|---|---|---|
| Technology | Hardware (CPU) | Software (hypervisor) |
| Hardware | DC-series only | Any hardware config |
| Purchasing model | vCore only | vCore or DTU |
| Max cores | 40 physical cores | No special limit |
| Serverless | Not supported | Supported |
| Attestation | Required (Azure Attestation) | Not supported |
| Availability | DC-series regions only | All regions except Jio India Central |

<!-- Source: azure-sql-database-sql-db/concepts/security/always-encrypted-with-secure-enclaves/always-encrypted-enclaves-plan.md -->

**SGX enclaves** offer the strongest isolation. The enclave runs in hardware-protected memory that the OS can't read, and attestation via Microsoft Azure Attestation cryptographically verifies that the enclave binary hasn't been tampered with. The tradeoff is hardware constraints: DC-series uses physical cores (not logical), maxes out at 40 cores, and has limited regional availability.

**VBS enclaves** are software-based, running inside Windows Virtualization-Based Security. They're available on any Azure SQL Database offering — any tier, any hardware, any region (almost). VBS protects data from high-privileged users like DBAs and prevents plaintext from appearing in memory dumps. But VBS doesn't support attestation, so you can't cryptographically prove the enclave binary is genuine.

> **Tip:** For most workloads, VBS enclaves are the pragmatic choice. They work everywhere, support elastic pools, and protect against the most common threat model (insider DBAs). Choose SGX only when you need attestation or protection against OS-level attacks from the host.

### Attestation via Azure Attestation

Attestation is mandatory for SGX enclaves and currently unsupported for VBS. To use it, you create an **attestation provider** in Azure Attestation and configure it with the Microsoft-recommended policy. The policy verifies:

- Debugging is disabled on the enclave.
- The product ID matches Always Encrypted (4639).
- The security version number (SVN) is at least 2.
- The enclave binary was signed with Microsoft's key.
<!-- Source: azure-sql-database-sql-db/concepts/security/always-encrypted-with-secure-enclaves/always-encrypted-enclaves-configure-attestation.md -->

In production, enforce role separation: the attestation administrator, the DBA, and the application administrator should be different people. The DBA shouldn't control attestation policies — that defeats the purpose of protecting data from the DBA.

### Rich Queries on Encrypted Data

With secure enclaves enabled, you unlock operations that plain Always Encrypted can't do:

- **Range comparisons** (`>`, `<`, `BETWEEN`, `>=`, `<=`)
- **Pattern matching** (`LIKE`)
- **Sorting** (`ORDER BY`)
- **In-place encryption** — encrypt existing columns without moving data off the server

These operations happen inside the enclave. The client sends the encryption key to the enclave over an encrypted channel, the enclave decrypts the data in protected memory, performs the computation, and returns encrypted results.

### When to Use Enclaves (and When Plain Always Encrypted Suffices)

| Scenario | Recommendation |
|---|---|
| Equality lookups only | Plain AE, deterministic |
| Range, sort, or `LIKE` queries | Secure enclaves required |
| Encrypt existing columns in place | Secure enclaves |
| Prevent DBA from reading data | Either works |
| Prove enclave integrity | SGX with attestation |
| Serverless or elastic pools | VBS enclaves only |

## Dynamic Data Masking

Dynamic Data Masking (DDM) applies policy-based obfuscation to query results so that non-privileged users see masked values while the underlying data stays intact.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/dynamic-data-masking-overview.md -->

DDM is useful for limiting exposure to support staff, contractors, or analytics queries that don't need the real values. A call center agent might see `aXX@XXXX.com` instead of a customer's full email — enough to verify identity, not enough to steal it.

### Masking Rules and Built-in Functions

You define masking rules per column. Azure SQL provides these built-in masking functions:

| Function | Behavior | Example output |
|---|---|---|
| Default | Full mask (type-appropriate) | `XXXX`, `0`, `1900-01-01` |
| Credit card | Last four digits visible | `XXXX-XXXX-XXXX-1234` |
| Email | First letter + masked domain | `aXX@XXXX.com` |
| Random number | Random value in a range | Varies |
| Custom text | Prefix + padding + suffix | `pre[XXX]fix` |
| Datetime | Mask specific components | Year, month, day, etc. |

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/dynamic-data-masking-overview.md -->

Applying a mask is straightforward T-SQL:

```sql
CREATE TABLE Customers (
    CustomerID   INT IDENTITY(1, 1) NOT NULL,
    FullName     NVARCHAR(100) NOT NULL,
    Email        NVARCHAR(100) MASKED WITH (FUNCTION = 'email()') NOT NULL,
    Phone        VARCHAR(12)   MASKED WITH (FUNCTION = 'default()') NULL,
    CreditCard   VARCHAR(19)   MASKED WITH (FUNCTION = 'partial(0, "XXXX-XXXX-XXXX-", 4)') NULL,
    BirthDate    DATE          MASKED WITH (FUNCTION = 'datetime("Y")') NULL
);
```

To add a mask to an existing column:

```sql
ALTER TABLE Customers
ALTER COLUMN Phone ADD MASKED WITH (FUNCTION = 'default()');
```

### Unmasking and Granular Permissions

Users with `db_owner`, server admin, or Microsoft Entra admin roles see unmasked data automatically. For everyone else, you control access with the `UNMASK` permission at four levels of granularity:

```sql
-- Column-level unmask
GRANT UNMASK ON dbo.Customers(Email) TO [SupportLead];

-- Table-level unmask
GRANT UNMASK ON dbo.Customers TO [SupportManager];

-- Schema-level unmask
GRANT UNMASK ON SCHEMA::dbo TO [ComplianceOfficer];

-- Database-level unmask
GRANT UNMASK TO [SecurityAdmin];
```

<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/dynamic-data-masking-overview.md -->

> **Gotcha:** DDM is obfuscation, not security. A determined user with sufficient query permissions can infer masked values through brute-force queries or inference attacks. Don't rely on DDM as your sole data protection mechanism for highly sensitive data — use it alongside encryption and proper access controls.

## Row-Level Security

Row-Level Security (RLS) lets you control which rows a user can access in a table, transparently and without application changes. The database engine applies a **security predicate** — an inline table-valued function — that filters rows on every query.

RLS is the foundation of tenant isolation in multi-tenant databases. Instead of managing separate schemas or databases per tenant, you add a `TenantID` column and an RLS policy that restricts each user to their own rows. We cover multi-tenant SaaS patterns in depth in Chapter 17, but the mechanism itself belongs here.

A minimal RLS setup:

```sql
-- Predicate function: return rows only for the current tenant
CREATE FUNCTION Security.fn_TenantFilter(@TenantID INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
    RETURN SELECT 1 AS fn_result
    WHERE @TenantID = CAST(SESSION_CONTEXT(N'TenantID') AS INT);
GO

-- Security policy: apply the filter to the Orders table
CREATE SECURITY POLICY Security.TenantPolicy
    ADD FILTER PREDICATE Security.fn_TenantFilter(TenantID) ON dbo.Orders,
    ADD BLOCK PREDICATE Security.fn_TenantFilter(TenantID) ON dbo.Orders
    WITH (STATE = ON);
```

The application sets `SESSION_CONTEXT` at connection time:

```sql
EXEC sp_set_session_context @key = N'TenantID', @value = 42;
```

From that point, every query against `dbo.Orders` silently filters to TenantID 42. The user can't bypass it — the filter is enforced by the engine.

RLS supports two predicate types:

- **Filter predicates** — silently exclude rows that don't match (used for `SELECT`, `UPDATE`, `DELETE`).
- **Block predicates** — raise an error if an operation would create or modify a row that violates the predicate (used for `INSERT`, `UPDATE`).

> **Tip:** Use `SCHEMABINDING` on your predicate function. Without it, someone could drop the referenced table and break the security policy. With it, the table can't be altered in ways that invalidate the function.

## Azure Key Vault Integration for SQL Server VMs

Everything above applies to Azure SQL Database and Managed Instance — the PaaS offerings. If you're running SQL Server on Azure VMs, you get a different integration path: the **Azure Key Vault Integration** feature of the SQL IaaS Agent extension.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/security/azure-key-vault-integration-configure.md -->

This feature automates the plumbing for SQL Server's **Extensible Key Management (EKM)** provider. When you enable it — during VM provisioning or afterward through the Azure portal — the extension:

1. Installs the SQL Server Connector for Azure Key Vault.
2. Configures the EKM provider.
3. Creates the SQL Server credential to access your vault.

You still need to create the Key Vault and grant the service principal access yourself. But the tedious EKM configuration steps are handled automatically.

> **Note:** For SQL Server 2017 and earlier, Azure Key Vault integration is limited to Enterprise, Developer, and Evaluation editions. SQL Server 2019 added Standard edition support.

Once configured, you can use the Key Vault key for TDE, column-level encryption (CLE), and backup encryption — just like you would with an on-premises HSM, but with Azure Key Vault managing the key lifecycle.

You can check the installed Connector version:

```sql
SELECT name, version FROM sys.cryptographic_providers;
```

The SQL IaaS Agent extension installs Connector version 1.0.5.0. If you need Azure Key Vault Managed HSM support, upgrade manually to at least version 15.0.2000.440.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/security/azure-key-vault-integration-configure.md -->

The road from here leads to auditing. TDE protects data at rest, Always Encrypted protects data from the server itself, DDM and RLS control who sees what — but none of these tell you *who did what and when*. That's Chapter 9: Auditing, Compliance, and Threat Detection.
