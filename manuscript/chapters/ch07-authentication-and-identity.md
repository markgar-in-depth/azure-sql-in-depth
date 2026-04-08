# Chapter 7: Authentication and Identity

Every connection to your database starts with a question: *who are you?* Get the answer wrong — or worse, skip asking — and nothing else in your security stack matters.

Firewalls, encryption, auditing — all of it assumes you've already nailed identity. This chapter walks you through the authentication landscape in Azure SQL, from the legacy approach you should be leaving behind to the modern, passwordless patterns that eliminate entire categories of credential leaks.

## Authentication Methods

Azure SQL supports two fundamental authentication mechanisms: SQL authentication and Microsoft Entra authentication. A third option — Windows Authentication for Entra principals — exists for Managed Instance. Let's break down each one, starting with the one you should stop using.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/logins-create-manage.md -->

### SQL Authentication: Logins, Passwords, and Why You Should Stop

SQL authentication is the classic username-and-password model. You create a login in the `master` database, assign it a password, and applications connect by sending those credentials over the wire. It works the same way it has since SQL Server's earliest days.

When you first provision an Azure SQL resource, you're asked to create a **Server admin** login. This account gets full administrative privileges — `db_owner` in every database, mapped to the `dbo` user, and on Managed Instance, membership in the `sysadmin` fixed server role. The account name can't be changed after creation, and it can't be limited.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/logins-create-manage.md -->

> **Gotcha:** The Server admin login name can't be changed after creation, and on Azure SQL Database, you can't create additional SQL logins with full administrative permissions. Only the Server admin and the Microsoft Entra admin can add logins to server roles.

SQL authentication has real problems:

- **Passwords live in connection strings.** They end up in config files, environment variables, source control, and deployment logs. Every copy is a potential leak.
- **No centralized lifecycle management.** Password rotation requires coordinated changes across every application and user that holds the credential.
- **No conditional access.** You can't enforce MFA, device compliance, or location-based restrictions on SQL logins.
- **No audit trail back to a real human.** Shared SQL logins obscure who actually ran a query.

SQL auth isn't going away — it's deeply embedded in legacy tooling and migration workflows. But for new workloads, Microsoft Entra authentication is the clear path forward.

### Microsoft Entra Authentication: The Modern Path

**Microsoft Entra ID** (formerly Azure Active Directory) centralizes identity management across your data estate. Instead of database-local passwords, identities live in your tenant — the same place your developers, service accounts, and groups already exist.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/microsoft-entra-authentication/authentication-aad-overview.md -->

The benefits over SQL auth are significant:

- **Centralized identity.** One place to manage users, rotate credentials, and revoke access.
- **Passwordless options.** Managed identities and `DefaultAzureCredential` eliminate stored secrets entirely.
- **MFA and Conditional Access.** Require strong authentication, compliant devices, or specific network locations.
- **Group-based access management.** Map Entra groups to database roles and manage membership outside SQL entirely.
- **Audit everything.** Every connection traces back to a specific identity in your tenant.

To use Entra authentication, you must set a **Microsoft Entra admin** on your logical server or managed instance. We'll cover that role in detail shortly.

> **Important:** Microsoft Entra authentication only supports access tokens originating from Microsoft Entra ID. Third-party tokens and redirecting Entra queries to third-party endpoints aren't supported.

### Windows Authentication for Entra Principals (Managed Instance)

Managed Instance supports a third option: Windows Authentication backed by Microsoft Entra Kerberos. This exists for a specific reason — legacy applications that can't change their authentication stack.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/security/windows-auth-for-microsoft-entra-principals/winauth-azuread-overview.md -->

If you're lifting and shifting on-premises SQL Servers to Managed Instance and your apps use Windows integrated auth, this feature lets those connections work without rewriting application code or deploying Microsoft Entra Domain Services. It supports devices joined to Active Directory, Microsoft Entra ID, or hybrid Microsoft Entra ID.

Key scenarios:

- **"Double hop" authentication** — web apps using IIS identity impersonation to run queries in the end user's security context.
- **Extended events and Profiler traces** — launched under Windows auth for developer convenience.
- **Infrastructure modernization** — a laptop joined to Microsoft Entra ID can use biometric credentials to authenticate to a managed instance, even from a mobile device.

> **Tip:** Windows Authentication for Entra principals is specifically a Managed Instance feature. If you're on Azure SQL Database, Entra authentication is your modern auth path — no Windows auth equivalent exists.

## Microsoft Entra Authentication Deep Dive

Now that you know *why* Entra authentication matters, let's dig into *how* it works — the identity types, auth flows, admin role, and supporting permissions.

### Identity Types

Azure SQL supports four categories of Microsoft Entra identities as principals:
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/microsoft-entra-authentication/authentication-aad-overview.md -->

| Identity Type | Description | Use Case |
|---|---|---|
| Users | Internal, external, guest, or federated | Human access |
| Groups | Security or Microsoft 365 groups | Simplify role assignment |
| Service principals | App registrations in Entra | App-to-database access |
| Managed identities | System- or user-assigned | Passwordless service auth |

**Managed identities** are the preferred choice for service-to-database connections. They're passwordless by design — Azure manages the credential lifecycle, and your code never touches a secret. Use service principals only when managed identities aren't an option (cross-tenant scenarios, non-Azure compute).

> **Gotcha:** Microsoft Entra principals that belong to more than 2,048 security groups can't log into the database. If you hit this limit, restructure your group hierarchy.

### Auth Flows

For *user identities*, Azure SQL supports these authentication methods:

| Flow | How It Works |
|---|---|
| Password | Credentials stored in Entra ID |
| MFA Interactive | Prompts for additional verification |
| Integrated | Federation with on-prem AD via ADFS for SSO |
| Default (Passwordless) | Scans credential caches on the machine — used by `DefaultAzureCredential` |

For *service and workload identities*:

| Flow | How It Works |
|---|---|
| Managed identity | Token-based, Azure validates the identity-to-resource relationship |
| Service principal + secret | App ID plus client secret — not recommended due to leak risk |
| Default | Scans application credential caches |

> **Tip:** Set connection timeout to 30 seconds when using Entra authentication. Token acquisition can take longer than SQL auth password validation.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/microsoft-entra-authentication/authentication-aad-overview.md -->

### The Microsoft Entra Admin Role

The Entra admin is the gateway to Entra authentication on your server or instance. Until you configure one, no Entra identities can connect.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/microsoft-entra-authentication/authentication-aad-overview.md -->

Key facts:

- **Exactly one identity.** You configure a single Entra admin — a user, group, service principal, or managed identity. Only one at a time.
- **db_owner everywhere.** The admin maps to `dbo` in every user database and gets `db_owner` in all of them, just like the SQL Server admin.
- **The bootstrap account.** The Entra admin is the first account that can create other Entra logins and users. No other identity can do this until the admin grants them `ALTER ANY USER`.
- **Remove it and Entra auth dies.** Removing the Entra admin disables all Entra-based connections, even for users who already have permissions.

> **Tip:** Set the Entra admin to a **security group** rather than an individual user. Group membership can be managed in Entra without touching the SQL server, and multiple people can share the admin role. This is the only way to have multiple identities act as the admin simultaneously.

For failover groups and geo-replication, you must configure the Entra admin on *both* the primary and secondary servers. If the secondary doesn't have an admin configured, Entra users get a `Cannot connect` error after failover.

### Directory Readers Role and Microsoft Graph Permissions

When Azure SQL creates Entra principals or validates identities, it needs to query Microsoft Graph. The mechanism for granting this access depends on *who* is issuing the command.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/microsoft-entra-authentication/authentication-aad-directory-readers-role.md, shared-sql-db-sql-mi-docs/shared-how-tos/security/microsoft-entra-authentication/create/authentication-azure-ad-user-assigned-managed-identity.md -->

- **When a user runs `CREATE USER` or `CREATE LOGIN`:** Azure SQL uses delegated permissions — it impersonates the signed-in user and queries Graph on their behalf. No extra server-level permissions needed.
- **When a service principal or managed identity runs those commands:** Delegation isn't possible. The SQL engine falls back to the server's own identity (its primary managed identity) and needs explicit Graph permissions.

The required Microsoft Graph application permissions are:

| Permission | Purpose |
|---|---|
| `User.Read.All` | Look up Entra users |
| `GroupMember.Read.All` | Look up Entra groups |
| `Application.Read.All` | Look up service principals |

Alternatively, you can assign the **Directory Readers** role to the server's managed identity. This role covers all three permissions and more, but it's broader than needed — the individual Graph permissions are the least-privilege approach.

> **Tip:** In production, create a role-assignable Entra group with the Directory Readers role, then add server identities to that group. This lets group owners manage permissions without requiring a Privileged Role Administrator for every new server.

For Managed Instance, the Directory Readers role (or equivalent Graph permissions) must be assigned *before* you can set the Entra admin. For SQL Database, it's only required when service principals need to create Entra users.

### Conditional Access Policies

Conditional Access lets you enforce tenant-level policies on connections to Azure SQL. You can require MFA, compliant devices, specific locations, or other conditions before granting access.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/security/microsoft-entra-authentication/configure/conditional-access-configure.md -->

Key details:

- Requires at least a **Microsoft Entra ID P1** license. Limited MFA works with the free tier, but full Conditional Access does not.
- The target resource in Entra is always **Azure SQL Database** — even when configuring policies for Managed Instance or Azure Synapse.
- Policies apply to **user connections only**. Service principals and managed identities are exempt.

To configure a policy, find the **Azure SQL Database** enterprise application in the Azure portal, then create Conditional Access rules targeting it. You can scope policies to specific users or groups and require whatever grant controls your organization needs — MFA, compliant devices, or approved client apps.

> **Gotcha:** Conditional Access doesn't apply to service principals or managed identities. If you need to restrict programmatic access, use network security controls (Chapter 6) and database-level permissions instead.

## Creating Entra Principals

With the Entra admin configured and Graph permissions in place, you can create Entra principals in your databases. There are several principal types, each with different characteristics.
<!-- Source: shared-sql-db-sql-mi-docs/shared-concepts/security/microsoft-entra-authentication/authentication-aad-overview.md, shared-sql-db-sql-mi-docs/shared-how-tos/security/microsoft-entra-authentication/create/authentication-azure-ad-logins.md -->

### Server-Level Logins (CREATE LOGIN)

Server-level Entra logins live in the virtual `master` database. They're the Entra equivalent of SQL logins and enable server-level role assignments.

```sql
CREATE LOGIN [anna@contoso.com] FROM EXTERNAL PROVIDER;
```

> **Note:** Entra server principals (logins) are generally available for Managed Instance and SQL Server 2022+. They're in **public preview** for Azure SQL Database.

Newly created Entra logins get the `VIEW ANY DATABASE` permission by default. You can assign them to server roles like `dbmanager` and `loginmanager` for delegated administration:

```sql
ALTER SERVER ROLE [dbmanager] ADD MEMBER [anna@contoso.com];
```

When creating a login for a service principal or managed identity whose display name isn't unique in your tenant, use the `WITH OBJECT_ID` clause to disambiguate:

```sql
CREATE LOGIN [myapp] FROM EXTERNAL PROVIDER
    WITH OBJECT_ID = '11111111-2222-3333-4444-555555555555';
```

### Contained Database Users

Contained database users exist only within a single database and have no connection to a server login. They're portable — the user travels with the database during copy, restore, or geo-replication.

```sql
CREATE USER [anna@contoso.com] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [anna@contoso.com];
ALTER ROLE db_datawriter ADD MEMBER [anna@contoso.com];
```

This is the most common approach for Azure SQL Database, where server-level logins for Entra are still in preview.

When server-level logins *are* available, you can also create database users mapped to them instead:

```sql
CREATE USER [anna@contoso.com] FROM LOGIN [anna@contoso.com];
```

Login-based users inherit server-level roles and permissions from their login. You can distinguish between contained and login-based users by checking the `SID` in `sys.database_principals` — login-based users have an `AADE` suffix and a SID length of 18:

```sql
SELECT CASE
    WHEN CONVERT(VARCHAR(100), sid, 2) LIKE '%AADE' AND LEN(sid) = 18
        THEN 'login-based user'
    ELSE 'contained database user'
    END AS user_type,
    name, type_desc
FROM sys.database_principals
WHERE type IN ('E', 'X');
```

> **Gotcha:** It's possible to create a contained user with the same name as a server login. The two principals aren't connected — they don't share permissions, and connections can produce undefined behavior when the engine can't determine which identity you meant.

### Guest Users (B2B)

Microsoft Entra B2B collaboration lets you invite users from external organizations as guest users in your tenant. These guest users can then be created as database principals just like internal users.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/security/microsoft-entra-authentication/create/authentication-aad-guest-users.md -->

```sql
-- SQL Database: contained user
CREATE USER [guest@partner.com] FROM EXTERNAL PROVIDER;

-- Managed Instance: login + user
CREATE LOGIN [guest@partner.com] FROM EXTERNAL PROVIDER;
CREATE USER [guest@partner.com] FROM LOGIN [guest@partner.com];
```

Guest users authenticate against their home identity provider but are represented in your tenant. They can also be set as the Entra admin if needed.

### Service Principal and Managed Identity Users

Service principals and managed identities are created the same way — with `FROM EXTERNAL PROVIDER`:

```sql
-- Managed identity
CREATE USER [my-app-identity] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [my-app-identity];
ALTER ROLE db_datawriter ADD MEMBER [my-app-identity];

-- Service principal (by app display name)
CREATE USER [my-api-app] FROM EXTERNAL PROVIDER;
```

For non-unique display names, use `OBJECT_ID`:

```sql
CREATE USER [my-api-app] FROM EXTERNAL PROVIDER
    WITH OBJECT_ID = '11111111-2222-3333-4444-555555555555';
```

The server's managed identity needs Graph permissions for these commands to succeed (see *Directory Readers Role and Microsoft Graph Permissions* above).

## Entra-Only Authentication

The strongest posture is to disable SQL authentication entirely. **Microsoft Entra-only authentication** does exactly this — it shuts down the SQL auth pathway at the server or instance level, so the only way in is through Entra.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/security/microsoft-entra-authentication/microsoft-entra-only-authentication/authentication-azure-ad-only-authentication.md -->

### Disabling SQL Auth Entirely

When you enable Entra-only authentication:

- All SQL authentication connections are rejected — including the Server admin account.
- Existing SQL logins and users remain in the database but can't connect.
- New SQL logins and users can still be *created* (by Entra accounts with permission), but they can't connect either.

Enable it via CLI:

```azurecli
# Azure SQL Database
az sql server ad-only-auth enable \
    --resource-group myresource --name myserver

# Managed Instance
az sql mi ad-only-auth enable \
    --resource-group myresource --name myinstance
```

Or PowerShell:

```powershell
Enable-AzSqlServerActiveDirectoryOnlyAuthentication `
    -ServerName myserver -ResourceGroupName myresource
```

> **Important:** The Microsoft Entra admin must be set *before* enabling Entra-only auth. If you enable it without an admin, you'll lock yourself out.

The toggle requires membership in high-privilege Azure RBAC roles: subscription Owner, Contributor, or **SQL Security Manager**. Notably, the SQL Server Contributor and SQL Managed Instance Contributor roles *cannot* toggle this setting — a deliberate separation of duties.

### Azure Policy Enforcement at Scale

For organizations managing hundreds of servers, toggling Entra-only auth manually doesn't scale. Azure Policy provides two built-in policy definitions:
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/security/microsoft-entra-authentication/microsoft-entra-only-authentication/authentication-azure-ad-only-authentication-policy.md -->

- *Azure SQL Database should have Azure Active Directory Only Authentication enabled*
- *Azure SQL Managed Instance should have Azure Active Directory Only Authentication enabled*

Each policy supports three effects:

| Effect | Behavior |
|---|---|
| Audit | Logs non-compliance; doesn't block |
| Deny | Blocks creation without Entra-only auth |
| Disabled | Policy inactive |

> **Gotcha:** Azure Policy enforces Entra-only auth only at *creation time*. An authorized user can disable it after the server exists. The server then shows as `Non-compliant` in the compliance dashboard, but the policy doesn't force it back on.

### What Happens to Existing SQL Logins

Enabling Entra-only auth doesn't *delete* SQL logins or users. They still exist in `sys.server_principals` and `sys.database_principals`. They just can't authenticate. This means:

- Your migration can be gradual. Create Entra identities, update connection strings, verify access, then flip the switch.
- If something goes wrong, disabling Entra-only auth immediately re-enables SQL auth. The logins are still there.
- You can clean up orphaned SQL logins on your own timeline after confirming everything works under Entra.

## Migrating to Passwordless Connections

The most impactful security improvement you can make to an existing application is eliminating passwords from connection strings. The `DefaultAzureCredential` pattern in the Azure Identity libraries makes this straightforward across languages.
<!-- Source: azure-sql-database-sql-db/how-to/migrate/migrate-to-passwordless/azure-sql-passwordless-migration.md -->

### .NET Walk-Through

The code change is minimal. Your existing `SqlConnection` code stays the same — only the connection string changes:

**Before (SQL auth):**

```
Server=tcp:myserver.database.windows.net,1433;Initial Catalog=mydb;
User ID=myuser;Password=S3cret!;Encrypt=True;
```

**After (passwordless):**

```
Server=tcp:myserver.database.windows.net,1433;Initial Catalog=mydb;
Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;
Authentication="Active Directory Default";
```

The `Authentication="Active Directory Default"` setting tells the Microsoft.Data.SqlClient driver to use `DefaultAzureCredential` under the hood. During local development, it picks up your Azure CLI or Visual Studio sign-in. In production, it uses the managed identity assigned to your compute resource. (See *DefaultAzureCredential and Managed Identity Patterns* below for important production guidance.)

```csharp
string connectionString = config.GetConnectionString("AZURE_SQL_CONNECTIONSTRING")!;

using var conn = new SqlConnection(connectionString);
conn.Open();

var command = new SqlCommand("SELECT * FROM Orders", conn);
using SqlDataReader reader = command.ExecuteReader();
```

No code changes to the data access layer at all. Just update the connection string and ensure the identity has a corresponding database user with appropriate roles.

### Node.js Walk-Through

With the `tedious` driver (via `mssql`), set the authentication type to `azure-active-directory-default`:
<!-- Source: azure-sql-database-sql-db/how-to/migrate/migrate-to-passwordless/azure-sql-passwordless-migration-nodejs.md -->

```javascript
import sql from 'mssql';

const config = {
    server: process.env.AZURE_SQL_SERVER,
    port: parseInt(process.env.AZURE_SQL_PORT),
    database: process.env.AZURE_SQL_DATABASE,
    authentication: {
        type: 'azure-active-directory-default',
    },
    options: {
        encrypt: true,
        // For user-assigned managed identity, set clientId:
        // clientId: process.env.AZURE_CLIENT_ID
    }
};

const pool = await sql.connect(config);
const result = await pool.request().query('SELECT * FROM Orders');
```

No passwords in the config. For user-assigned managed identities, pass the `clientId` in the options. For system-assigned, omit it. The same production caveat applies here — see *DefaultAzureCredential and Managed Identity Patterns* below.

### Python Walk-Through

With the `mssql-python` driver, the pattern is identical — change the connection string to use `ActiveDirectoryDefault`:
<!-- Source: azure-sql-database-sql-db/how-to/migrate/migrate-to-passwordless/azure-sql-passwordless-migration-python.md -->

```python
from mssql_python import connect

conn_str = (
    "Server=tcp:myserver.database.windows.net,1433;"
    "Database=mydb;"
    "Encrypt=yes;TrustServerCertificate=no;"
    "Connection Timeout=30;"
    "Authentication=ActiveDirectoryDefault"
)

with connect(conn_str) as conn:
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM Orders")
    rows = cursor.fetchall()
```

The same production-vs-development tradeoff applies to Python's `ActiveDirectoryDefault` — see the guidance in *DefaultAzureCredential and Managed Identity Patterns* below.

### DefaultAzureCredential and Managed Identity Patterns

The `DefaultAzureCredential` class from the Azure Identity SDK is the glue behind all the `Active Directory Default` connection strings. It probes for credentials in a defined order:

1. Environment variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`)
2. Workload identity (Kubernetes)
3. Managed identity
4. Azure CLI
5. Azure PowerShell
6. Azure Developer CLI
7. Interactive browser (if enabled)

In production on Azure compute (App Service, Container Apps, VMs, AKS), it finds the managed identity automatically. No secrets to store, rotate, or leak.

> **Important:** The `Default` credential chain is designed for development convenience — it probes multiple sources in sequence, which adds latency and ambiguity. In production, pin to the specific method for your environment:

| Language | Production Auth Type | Use Case |
|---|---|---|
| .NET | `Active Directory Managed Identity` | App Service, Container Apps, VMs |
| Node.js | `azure-active-directory-msi-app-service` | App Service |
| Node.js | `azure-active-directory-msi-vm` | VMs, VMSS |
| Python | `ActiveDirectoryMSI` | Any Azure compute |
| Any | `ActiveDirectoryServicePrincipal` | CI/CD pipelines |
| Any | `ActiveDirectoryInteractive` | User-facing tools |

The typical deployment pattern:

1. **Create a user-assigned managed identity** in your resource group.
2. **Assign the identity to your compute resource** (App Service, Container App, VM).
3. **Create a database user** mapped to that identity with appropriate roles.
4. **Deploy with a passwordless connection string** — no credentials in app settings.

```azurecli
# Create the managed identity
az identity create --name my-app-identity --resource-group myresource

# Assign to App Service
az webapp identity assign \
    --resource-group myresource --name myapp \
    --identities /subscriptions/<sub>/resourceGroups/myresource/providers/Microsoft.ManagedIdentity/userAssignedIdentities/my-app-identity
```

Then in the database:

```sql
CREATE USER [my-app-identity] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [my-app-identity];
ALTER ROLE db_datawriter ADD MEMBER [my-app-identity];
```

### Anti-Patterns to Leave Behind

With managed identities available on every Azure compute platform, there's no reason to keep passwords in the picture. Yet these patterns persist:

- **Passwords in app settings or environment variables.** The most common offender. Connection strings with `User ID` and `Password` sitting in App Service configuration, visible to anyone with portal access and logged in deployment history. One leaked config and the credential is in the wild.
- **Key Vault as a password proxy.** Storing a SQL password in Key Vault and fetching it at startup feels secure — you've moved the secret out of plain text. But you've just traded one credential for another: the app still needs a secret or certificate to access Key Vault. If you're already using managed identity to reach Key Vault, *skip Key Vault entirely* and connect to SQL directly.
- **Shared SQL logins across services.** A single `app_user` login used by three microservices, two batch jobs, and a reporting tool. When you need to rotate the password, every consumer has to update in lockstep. When one service misbehaves, the audit trail points to a generic account that tells you nothing.

Each of these fails for the same reason: they create secrets that must be stored, rotated, and protected — operational burden that managed identities eliminate entirely.

> **Warning:** If you're running on Azure compute and still using SQL auth connection strings, treat the migration to managed identities as a security incident waiting to happen, not a nice-to-have.

## Identity for SQL Server on Azure VMs

SQL Server on Azure VMs supports Microsoft Entra authentication starting with **SQL Server 2022**. The setup is different from SQL Database and Managed Instance because the VM is infrastructure you manage.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/security/configure-azure-ad-authentication-for-sql-vm.md -->

### Microsoft Entra Auth (SQL Server 2022+)

To enable Entra auth on a SQL Server VM:

1. **Register the VM** with the SQL Server IaaS Agent extension.
2. **Assign a managed identity** to the VM (system-assigned or user-assigned).
3. **Grant the managed identity** either the Directory Readers role or the individual Microsoft Graph permissions (`User.Read.All`, `GroupMember.Read.All`, `Application.Read.All`).
4. **Configure Entra authentication** through the Azure portal or Azure CLI.

Once configured, the same auth flows available in SQL Database and Managed Instance — password, MFA, integrated, service principal, managed identity — work on the VM.

The managed identity attached to the VM serves as the intermediary for Graph queries. When SQL Server processes a `CREATE LOGIN ... FROM EXTERNAL PROVIDER`, it uses this identity to validate the Entra principal. If the identity lacks Graph permissions, the command fails.

```powershell
# Grant Graph permissions via PowerShell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All" -TenantId "<tenant-id>"

$Graph_SP = Get-MgServicePrincipal -Filter "DisplayName eq 'Microsoft Graph'"
$MSI = Get-MgServicePrincipal -Filter "displayName eq '<vm-identity-name>'"

# Assign User.Read.All
$role = $Graph_SP.AppRoles | Where-Object { $_.Value -eq "User.Read.All" }
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MSI.Id `
    -BodyParameter @{
        principalId = $MSI.Id
        resourceId  = $Graph_SP.Id
        appRoleId   = $role.Id
    }
```

Repeat for `GroupMember.Read.All` and `Application.Read.All`.

### Managed Identity EKM for Key Vault Access

Starting with SQL Server 2022 CU17, SQL Server on Azure VMs supports managed identities for **Extensible Key Management (EKM)** with Azure Key Vault. This replaces the older credential-based approach where you stored a client secret in a SQL Server credential.
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/security/managed-identity-extensible-key-management.md -->

```sql
CREATE CREDENTIAL [mykeyvault.vault.azure.net]
    WITH IDENTITY = 'Managed Identity'
    FOR CRYPTOGRAPHIC PROVIDER AzureKeyVault_EKM_Prov;
```

The VM's managed identity needs the `Key Vault Crypto Service Encryption User` role (for RBAC) or the `Unwrap Key` and `Wrap Key` permissions (for vault access policies) on the Key Vault. This is primarily used for TDE with customer-managed keys — a topic covered in depth in Chapter 8.

> **Note:** Managed identity EKM is only supported for SQL Server on Azure VMs, not on-premises SQL Server instances.

Looking ahead to Chapter 8, we'll build on the identity foundation established here to cover how encryption features — TDE, Always Encrypted, and dynamic data masking — layer on top of authenticated connections to protect your data at rest and in transit.
