# Appendix E: Azure CLI and PowerShell Quick Reference

Every task you can do in the Azure portal, you can automate from the command line. This appendix collects the commands you'll reach for most often — organized by deployment option so you can find what you need fast.

Both tools cover the same ground. Azure CLI (`az`) uses a verb-noun pattern with JSON output by default. Azure PowerShell (`Az` module) uses PowerShell's native `Verb-AzNoun` cmdlets and returns objects you can pipe. Pick whichever fits your workflow — the capabilities are equivalent.

> **Tip:** Update an existing Azure CLI installation with `az upgrade` to stay current. If you don't have it yet, see [Install the Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) first. For PowerShell, install or update the Az.Sql module with `Install-Module -Name Az.Sql -Force`.

## Common Setup Commands

Before managing any Azure SQL resource, you need to authenticate and target the right subscription.

### Azure CLI

```bash
# Log in interactively
az login

# Log in with a service principal (CI/CD pipelines)
az login --service-principal -u <app-id> -p <secret> --tenant <tenant-id>

# Set the active subscription
az account set --subscription <subscription-id>

# Verify your context
az account show --output table
```

### Azure PowerShell

```powershell
# Log in interactively
Connect-AzAccount

# Log in with a service principal
$cred = New-Object System.Management.Automation.PSCredential(
    "<app-id>",
    (ConvertTo-SecureString "<secret>" -AsPlainText -Force)
)
Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant "<tenant-id>"

# Set the active subscription
Set-AzContext -SubscriptionId "<subscription-id>"

# Verify your context
Get-AzContext
```

---

## Azure SQL Database

These commands target logical servers, single databases, and elastic pools — the fully managed PaaS option covered in depth throughout Parts I–VI.

### Logical Servers

| Task | Azure CLI | PowerShell |
|---|---|---|
| Create | `az sql server create` | `New-AzSqlServer` |
| List | `az sql server list` | `Get-AzSqlServer` |
| Show | `az sql server show` | `Get-AzSqlServer` |
| Update | `az sql server update` | `Set-AzSqlServer` |
| Delete | `az sql server delete` | `Remove-AzSqlServer` |

<!-- Source: azure-sql-database-sql-db/samples/azure-cli/create-databases/create-and-configure-database-cli.md -->

**Create a logical server (CLI):**

```bash
az sql server create \
  --resource-group myResourceGroup \
  --name myserver \
  --location eastus \
  --admin-user sqladmin \
  --admin-password '<strong-password>'
```

**Create a logical server (PowerShell):**

```powershell
$cred = Get-Credential  # prompts for admin username and password
New-AzSqlServer -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -Location "East US" `
  -SqlAdministratorCredentials $cred
```

### Firewall Rules

```bash
# Allow a specific IP range
az sql server firewall-rule create \
  --resource-group myResourceGroup \
  --server myserver \
  --name AllowMyIP \
  --start-ip-address 203.0.113.10 \
  --end-ip-address 203.0.113.10

# Allow Azure services (start and end both 0.0.0.0)
az sql server firewall-rule create \
  --resource-group myResourceGroup \
  --server myserver \
  --name AllowAzure \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0
```

```powershell
New-AzSqlServerFirewallRule -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -FirewallRuleName "AllowMyIP" `
  -StartIpAddress "203.0.113.10" `
  -EndIpAddress "203.0.113.10"
```

> **Gotcha:** Setting both start and end IP to `0.0.0.0` allows connections from *all* Azure services — not just yours. Use private endpoints or virtual network rules for tighter control (→ see Chapter 6).

### Single Databases

| Task | Azure CLI | PowerShell |
|---|---|---|
| Create | `az sql db create` | `New-AzSqlDatabase` |
| List | `az sql db list` | `Get-AzSqlDatabase` |
| Show | `az sql db show` | `Get-AzSqlDatabase` |
| Update/Scale | `az sql db update` | `Set-AzSqlDatabase` |
| Delete | `az sql db delete` | `Remove-AzSqlDatabase` |

<!-- Source: azure-sql-database-sql-db/samples/azure-cli/create-databases/create-and-configure-database-cli.md -->

**Create a General Purpose serverless database (CLI):**

```bash
az sql db create \
  --resource-group myResourceGroup \
  --server myserver \
  --name mydb \
  --edition GeneralPurpose \
  --compute-model Serverless \
  --family Gen5 \
  --capacity 2 \
  --min-capacity 0.5 \
  --auto-pause-delay 60
```

**Create the same database (PowerShell):**

```powershell
New-AzSqlDatabase -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -DatabaseName "mydb" `
  -Edition "GeneralPurpose" `
  -ComputeModel "Serverless" `
  -ComputeGeneration "Gen5" `
  -MaxVcore 2 `
  -MinVcore 0.5 `
  -AutoPauseDelayInMinutes 60
```

**Scale a database to a different service objective:**

```bash
az sql db update \
  --resource-group myResourceGroup \
  --server myserver \
  --name mydb \
  --service-objective GP_Gen5_4
```

```powershell
Set-AzSqlDatabase -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -DatabaseName "mydb" `
  -RequestedServiceObjectiveName "GP_Gen5_4"
```

**Create a Hyperscale database (CLI):**

```bash
az sql db create \
  --resource-group myResourceGroup \
  --server myserver \
  --name myhsdb \
  --edition Hyperscale \
  --compute-model Serverless \
  --family Gen5 \
  --capacity 2 \
  --min-capacity 0.5
```

### Elastic Pools

| Task | Azure CLI | PowerShell |
|---|---|---|
| Create | `az sql elastic-pool create` | `New-AzSqlElasticPool` |
| List | `az sql elastic-pool list` | `Get-AzSqlElasticPool` |
| Update | `az sql elastic-pool update` | `Set-AzSqlElasticPool` |
| Delete | `az sql elastic-pool delete` | `Remove-AzSqlElasticPool` |

```bash
# Create a General Purpose elastic pool
az sql elastic-pool create \
  --resource-group myResourceGroup \
  --server myserver \
  --name mypool \
  --edition GeneralPurpose \
  --family Gen5 \
  --capacity 4

# Add a database to the pool
az sql db create \
  --resource-group myResourceGroup \
  --server myserver \
  --name pooleddb \
  --elastic-pool mypool
```

```powershell
# Create a pool
New-AzSqlElasticPool -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -ElasticPoolName "mypool" `
  -Edition "GeneralPurpose" `
  -ComputeGeneration "Gen5" `
  -VCore 4

# Add a database to the pool
New-AzSqlDatabase -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -DatabaseName "pooleddb" `
  -ElasticPoolName "mypool"
```

### Backups and Restore

```bash
# Point-in-time restore
az sql db restore \
  --resource-group myResourceGroup \
  --server myserver \
  --name mydb \
  --dest-name mydb-restored \
  --time "2026-04-07T12:00:00Z"

# Configure long-term retention policy
az sql db ltr-policy set \
  --resource-group myResourceGroup \
  --server myserver \
  --name mydb \
  --weekly-retention P4W \
  --monthly-retention P12M \
  --yearly-retention P5Y \
  --week-of-year 1

# List long-term backups
az sql db ltr-backup list \
  --location eastus \
  --server myserver \
  --database mydb

# Change backup storage redundancy
az sql db update \
  --resource-group myResourceGroup \
  --server myserver \
  --name mydb \
  --backup-storage-redundancy Local
```

<!-- Source: azure-sql-database-sql-db/samples/azure-cli/database-back-up-restore-copy-and-import/restore-database-cli.md -->

```powershell
# Point-in-time restore
$db = Get-AzSqlDatabase -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" -DatabaseName "mydb"

Restore-AzSqlDatabase -FromPointInTimeBackup `
  -PointInTime (Get-Date).AddHours(-2) `
  -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -TargetDatabaseName "mydb-restored" `
  -ResourceId $db.ResourceID `
  -Edition "GeneralPurpose" `
  -ServiceObjectiveName "GP_Gen5_2"
```

> **Note:** Point-in-time restore creates a *new* database — it never overwrites the original. The source database must be at least five minutes old. For full backup and restore coverage, see Chapter 11.
<!-- Source: azure-sql-database-sql-db/samples/azure-powershell/database-back-up-restore-copy-and-import/restore-database-powershell.md -->

### Geo-Replication and Failover Groups

```bash
# Create a failover group
az sql failover-group create \
  --resource-group myResourceGroup \
  --server myserver \
  --partner-server myserver-secondary \
  --name myfailovergroup \
  --add-db mydb \
  --failover-policy Automatic \
  --grace-period 1

# Trigger manual failover
az sql failover-group set-primary \
  --resource-group myResourceGroup \
  --server myserver-secondary \
  --name myfailovergroup
```

```powershell
# Create a failover group
New-AzSqlDatabaseFailoverGroup -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -PartnerServerName "myserver-secondary" `
  -FailoverGroupName "myfailovergroup" `
  -FailoverPolicy "Automatic" `
  -GracePeriodWithDataLossHours 1

# Add a database to the group
$db = Get-AzSqlDatabase -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" -DatabaseName "mydb"
$db | Add-AzSqlDatabaseToFailoverGroup `
  -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" `
  -FailoverGroupName "myfailovergroup"
```

For more on failover groups and disaster recovery, see Chapter 13.

### Copy, Export, and Import

```bash
# Copy a database to another server
az sql db copy \
  --resource-group myResourceGroup \
  --server myserver \
  --name mydb \
  --dest-server myserver2 \
  --dest-name mydb-copy

# Export to BACPAC
az sql db export \
  --resource-group myResourceGroup \
  --server myserver \
  --name mydb \
  --admin-user sqladmin \
  --admin-password '<password>' \
  --storage-key-type StorageAccessKey \
  --storage-key '<storage-account-key>' \
  --storage-uri "https://mystorageaccount.blob.core.windows.net/backups/mydb.bacpac"

# Import from BACPAC
az sql db import \
  --resource-group myResourceGroup \
  --server myserver \
  --name mydb-imported \
  --admin-user sqladmin \
  --admin-password '<password>' \
  --storage-key-type StorageAccessKey \
  --storage-key '<storage-account-key>' \
  --storage-uri "https://mystorageaccount.blob.core.windows.net/backups/mydb.bacpac"
```

> **Tip:** For large databases, BACPAC export/import can be slow and prone to timeouts. Consider using `SqlPackage.exe` locally for more control, or use database copy for same-region cloning (→ see Chapter 18).

---

## Azure SQL Managed Instance

Managed Instance commands use a different noun group — `az sql mi` and `az sql midb` for CLI, `*-AzSqlInstance*` for PowerShell. Creating an instance is a long-running deployment — 95% of non-zone-redundant General Purpose creates finish within 30 minutes, but zone-redundant instances can take up to 4 hours.

<!-- Source: azure-sql-managed-instance-sql-mi/concepts/management-operations/management-operations-duration.md -->

### Instance Lifecycle

| Task | Azure CLI | PowerShell |
|---|---|---|
| Create | `az sql mi create` | `New-AzSqlInstance` |
| List | `az sql mi list` | `Get-AzSqlInstance` |
| Show | `az sql mi show` | `Get-AzSqlInstance` |
| Update | `az sql mi update` | `Set-AzSqlInstance` |
| Delete | `az sql mi delete` | `Remove-AzSqlInstance` |
| Start | `az sql mi start` | `Start-AzSqlInstance` |
| Stop | `az sql mi stop` | `Stop-AzSqlInstance` |

<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage/instance-stop-start-how-to.md -->

**Create a Managed Instance (CLI):**

```bash
az sql mi create \
  --resource-group myResourceGroup \
  --name mymanagedinstance \
  --location eastus \
  --admin-user sqladmin \
  --admin-password '<strong-password>' \
  --subnet /subscriptions/<sub-id>/resourceGroups/myResourceGroup/providers/Microsoft.Network/virtualNetworks/myVNet/subnets/ManagedInstanceSubnet \
  --capacity 4 \
  --tier GeneralPurpose \
  --family Gen5 \
  --storage 128 \
  --license-type LicenseIncluded
```

**Create a Managed Instance (PowerShell):**

```powershell
New-AzSqlInstance -ResourceGroupName "myResourceGroup" `
  -Name "mymanagedinstance" `
  -Location "East US" `
  -AdministratorCredential (Get-Credential) `
  -SubnetId "/subscriptions/<sub-id>/resourceGroups/myResourceGroup/providers/Microsoft.Network/virtualNetworks/myVNet/subnets/ManagedInstanceSubnet" `
  -VCore 4 `
  -Edition "GeneralPurpose" `
  -ComputeGeneration "Gen5" `
  -StorageSizeInGB 128 `
  -LicenseType "LicenseIncluded"
```

> **Important:** The `--subnet` parameter requires the full resource ID of a subnet that's been delegated to `Microsoft.Sql/managedInstances`. If you skip delegation, the deployment fails.

**Stop and start (cost savings):**

```bash
# Stop the instance (stops billing for compute)
az sql mi stop --mi mymanagedinstance -g myResourceGroup

# Start it back up
az sql mi start --mi mymanagedinstance -g myResourceGroup
```

```powershell
Stop-AzSqlInstance -Name "mymanagedinstance" -ResourceGroupName "myResourceGroup"
Start-AzSqlInstance -Name "mymanagedinstance" -ResourceGroupName "myResourceGroup"
```

> **Tip:** Stop/start is only available on the **General Purpose** service tier. Stopping suspends compute and license billing but retains storage charges — great for dev/test instances that sit idle overnight or on weekends (→ see Chapter 26).

### Managed Instance Databases

```bash
# Create a database
az sql midb create \
  --resource-group myResourceGroup \
  --managed-instance mymanagedinstance \
  --name mymidb

# List databases
az sql midb list \
  --resource-group myResourceGroup \
  --managed-instance mymanagedinstance

# Point-in-time restore
az sql midb restore \
  --resource-group myResourceGroup \
  --managed-instance mymanagedinstance \
  --name mymidb \
  --dest-name mymidb-restored \
  --time "2026-04-07T12:00:00Z"
```

```powershell
# Create a database
New-AzSqlInstanceDatabase -ResourceGroupName "myResourceGroup" `
  -InstanceName "mymanagedinstance" `
  -Name "mymidb"

# List databases
Get-AzSqlInstanceDatabase -ResourceGroupName "myResourceGroup" `
  -InstanceName "mymanagedinstance"
```

### Managed Instance Failover Groups

```bash
az sql instance-failover-group create \
  --resource-group myResourceGroup \
  --managed-instance mymanagedinstance \
  --partner-managed-instance mypartnermi \
  --partner-resource-group partnerRG \
  --name mymifailovergroup \
  --failover-policy Automatic \
  --grace-period 1
```

<!-- Source: azure-sql-managed-instance-sql-mi/how-to/manage-business-continuity/high-availability-disaster-recovery/failover-groups/failover-group-configure-sql-mi.md -->

For Managed Instance networking, Link feature, and advanced configuration, see Chapter 27.

---

## SQL Server on Azure VMs

SQL Server on Azure VMs uses two distinct command groups. The base VM is managed through `az vm` / `*-AzVM*`. SQL-specific features — licensing, automated backup, patching — are managed through the SQL IaaS Agent extension via `az sql vm` / `*-AzSqlVM*`.

### Register the Resource Provider

Before using `az sql vm` commands, register the provider in your subscription:

```bash
az provider register --namespace Microsoft.SqlVirtualMachine
```

```powershell
Register-AzResourceProvider -ProviderNamespace Microsoft.SqlVirtualMachine
```

<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/sql-iaas-agent-extension/sql-agent-extension-manually-register-single-vm.md -->

### Register a VM with the SQL IaaS Agent Extension

```bash
az sql vm create \
  --name mysqlvm \
  --resource-group myResourceGroup \
  --location eastus \
  --license-type PAYG
```

```powershell
$vm = Get-AzVM -Name "mysqlvm" -ResourceGroupName "myResourceGroup"

New-AzSqlVM -Name $vm.Name `
  -ResourceGroupName $vm.ResourceGroupName `
  -Location $vm.Location `
  -LicenseType "PAYG"
```

> **Note:** The `az sql vm create` command doesn't create a new VM — it registers an *existing* VM with the SQL IaaS Agent extension. The `--license-type` accepts `PAYG` (pay-as-you-go), `AHUB` (Azure Hybrid Benefit), or `DR` (free disaster-recovery replica license).

### Common SQL VM Operations

| Task | Azure CLI | PowerShell |
|---|---|---|
| Register | `az sql vm create` | `New-AzSqlVM` |
| Show | `az sql vm show` | `Get-AzSqlVM` |
| Update | `az sql vm update` | `Update-AzSqlVM` |
| Delete | `az sql vm delete` | `Remove-AzSqlVM` |
| List | `az sql vm list` | `Get-AzSqlVM` |

**Switch licensing model:**

```bash
az sql vm update \
  --name mysqlvm \
  --resource-group myResourceGroup \
  --license-type AHUB
```

```powershell
Update-AzSqlVM -Name "mysqlvm" `
  -ResourceGroupName "myResourceGroup" `
  -LicenseType "AHUB"
```

**Enable automated backup:**

```bash
az sql vm update \
  --name mysqlvm \
  --resource-group myResourceGroup \
  --backup-schedule-type Manual \
  --full-backup-frequency Weekly \
  --full-backup-start-hour 2 \
  --full-backup-window-hours 2 \
  --storage-account-url "https://mystorageaccount.blob.core.windows.net" \
  --sa-key '<storage-key>' \
  --retention-period 30
```

**Enable automated patching:**

```bash
az sql vm update \
  --name mysqlvm \
  --resource-group myResourceGroup \
  --day-of-week Sunday \
  --maintenance-window-duration 60 \
  --maintenance-window-start-hour 2
```

For full coverage of SQL Server on Azure VMs — including availability groups, storage configuration, and performance best practices — see Chapter 24.

---

## Output Formatting and Scripting Tips

### Azure CLI Output Modes

Azure CLI supports multiple output formats via the `--output` flag:

```bash
# Table format — human-readable
az sql db list --server myserver -g myResourceGroup --output table

# TSV — easy to parse in shell scripts
az sql db list --server myserver -g myResourceGroup \
  --query "[].name" --output tsv

# JSON — default, full detail
az sql db show --server myserver -g myResourceGroup \
  --name mydb --output json
```

The `--query` parameter uses JMESPath expressions to filter and reshape output:

```bash
# Get just the database names and service objectives
az sql db list --server myserver -g myResourceGroup \
  --query "[].{Name:name, SKU:currentServiceObjectiveName}" \
  --output table
```

### PowerShell Patterns

PowerShell returns objects natively, so you filter with standard pipeline operators:

```powershell
# List all databases on a server, formatted as a table
Get-AzSqlDatabase -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" |
  Select-Object DatabaseName, Edition, CurrentServiceObjectiveName |
  Format-Table

# Find databases larger than 10 GB
Get-AzSqlDatabase -ResourceGroupName "myResourceGroup" `
  -ServerName "myserver" |
  Where-Object { $_.MaxSizeBytes -gt 10GB } |
  Select-Object DatabaseName, MaxSizeBytes
```

### Useful Variables Pattern

Both tools benefit from defining variables up front to keep commands readable:

```bash
# Bash
rg="myResourceGroup"
server="myserver"
db="mydb"

az sql db show -g $rg -s $server -n $db --output table
```

```powershell
# PowerShell
$rg = "myResourceGroup"
$server = "myserver"
$db = "mydb"

Get-AzSqlDatabase -ResourceGroupName $rg -ServerName $server -DatabaseName $db
```

> **Tip:** Azure CLI supports shorthand parameters: `-g` for `--resource-group`, `-s` for `--server`, `-n` for `--name`. Use them in interactive sessions for speed, but prefer the long forms in scripts for readability.

For infrastructure-as-code approaches that go beyond imperative CLI commands — including Bicep, ARM templates, and Terraform — see Appendix F.
