# Appendix F: ARM Template, Bicep, and Terraform Samples

Chapter 3 introduced IaC and showed the minimum viable templates for Azure SQL Database (see Chapter 3). This appendix collects production-ready samples for all three deployment options — SQL Database, Managed Instance, and SQL Server on Azure VMs — in all three IaC languages. Copy, adapt, and check them into your repo.

> **Tip:** Bicep is the recommended starting point for Azure-native teams. It compiles to ARM JSON, so you get the full resource provider surface with a fraction of the syntax. Terraform is the better choice if you manage infrastructure across multiple clouds.

## Choosing Your IaC Tool

- **Bicep** — Declarative DSL. No state file (Azure is the source of truth). Deploy with `az deployment`. Azure-only.
- **ARM Templates** — JSON. No state file. Deploy with `az deployment`. Azure-only.
- **Terraform** — HCL. Requires a state file (enables drift detection but adds operational overhead). Deploy with `terraform apply`. Multi-cloud.

Bicep and ARM templates are **Azure-native** — they talk directly to Azure Resource Manager and don't maintain separate state. Terraform maintains a state file that tracks what it created, which means you need a remote backend and state locking in production.

All three target the same underlying resource providers. The resource types, API versions, and property names you see in Bicep and ARM map one-to-one. Terraform wraps them in its own resource schema (`azurerm_mssql_server` instead of `Microsoft.Sql/servers`), but the concepts are identical.

## Azure SQL Database

The simplest deployment: a logical server plus one or more databases. Two resource types do all the work.

### Bicep
<!-- Source: azure-sql-database-sql-db/quickstarts/create-database/single-database-create-bicep-quickstart.md -->

```bicep
@description('The name of the SQL logical server.')
param serverName string = uniqueString('sql', resourceGroup().id)

@description('The name of the SQL Database.')
param sqlDBName string = 'AppDb'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('The administrator username of the SQL logical server.')
param administratorLogin string

@description('The administrator password of the SQL logical server.')
@secure()
param administratorLoginPassword string

resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: serverName
  location: location
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
  }
}

resource sqlDB 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent: sqlServer
  name: sqlDBName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
}
```

Deploy it:

```bash
az group create --name myapp-rg --location eastus
az deployment group create \
  --resource-group myapp-rg \
  --template-file main.bicep \
  --parameters administratorLogin=appadmin
```

You'll be prompted for the password — the `@secure()` decorator keeps it out of logs and deployment history.

### ARM Template
<!-- Source: azure-sql-database-sql-db/quickstarts/create-database/single-database-create-arm-template-quickstart.md -->

The same deployment in raw JSON. This is what Bicep compiles to:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "serverName": {
      "type": "string",
      "defaultValue": "[uniqueString('sql', resourceGroup().id)]"
    },
    "sqlDBName": {
      "type": "string",
      "defaultValue": "AppDb"
    },
    "location": {
      "type": "string",
      "defaultValue": "[resourceGroup().location]"
    },
    "administratorLogin": {
      "type": "string"
    },
    "administratorLoginPassword": {
      "type": "secureString"
    }
  },
  "resources": [
    {
      "type": "Microsoft.Sql/servers",
      "apiVersion": "2022-05-01-preview",
      "name": "[parameters('serverName')]",
      "location": "[parameters('location')]",
      "properties": {
        "administratorLogin": "[parameters('administratorLogin')]",
        "administratorLoginPassword": "[parameters('administratorLoginPassword')]"
      }
    },
    {
      "type": "Microsoft.Sql/servers/databases",
      "apiVersion": "2022-05-01-preview",
      "name": "[format('{0}/{1}', parameters('serverName'), parameters('sqlDBName'))]",
      "location": "[parameters('location')]",
      "sku": {
        "name": "Standard",
        "tier": "Standard"
      },
      "dependsOn": [
        "[resourceId('Microsoft.Sql/servers', parameters('serverName'))]"
      ]
    }
  ]
}
```

Notice the `dependsOn` array — Bicep handles this automatically through the `parent` keyword, but ARM templates need you to declare it explicitly.

### Terraform
<!-- Source: azure-sql-database-sql-db/quickstarts/create-database/single-database-create-terraform-quickstart.md -->

```terraform
terraform {
  required_version = ">=1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "myapp-rg"
  location = "eastus"
}

resource "azurerm_mssql_server" "server" {
  name                         = "myapp-sqlserver"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  administrator_login          = var.admin_username
  administrator_login_password = var.admin_password
  version                      = "12.0"
}

resource "azurerm_mssql_database" "db" {
  name      = "AppDb"
  server_id = azurerm_mssql_server.server.id
}

variable "admin_username" {
  type    = string
  default = "appadmin"
}

variable "admin_password" {
  type      = string
  sensitive = true
}
```

Deploy it:

```bash
terraform init
terraform plan -out main.tfplan
terraform apply main.tfplan
```

> **Gotcha:** The `version = "12.0"` on the server resource is the Azure SQL *logical server version* — it's always `"12.0"` and has nothing to do with the SQL Server product version (2019, 2022, etc.). The `@@VERSION` output on Azure SQL returns `12.0.2000.8`, which refers to this same logical server version, not the SQL Server engine version. Don't change this value.

## Azure SQL Managed Instance

Managed Instance requires significantly more infrastructure than SQL Database. You need a virtual network, a dedicated subnet with delegation to `Microsoft.Sql/managedInstances`, a network security group, and a route table — all before the instance itself.

> **Warning:** First-time MI deployments into a new subnet typically finish within 30 minutes (95th percentile). Zone-redundant instances take significantly longer — up to 4 hours. Subsequent deployments into the same subnet reuse the existing virtual cluster and are faster.
<!-- Source: azure-sql-managed-instance-sql-mi/concepts/management-operations/management-operations-duration.md -->

### Bicep
<!-- Source: azure-sql-managed-instance-sql-mi/quickstarts/create-azure-sql-managed-instance/create-bicep-quickstart.md -->

```bicep
@description('Enter managed instance name.')
param managedInstanceName string

@description('Enter user name.')
param administratorLogin string

@description('Enter password.')
@secure()
param administratorLoginPassword string

param location string = resourceGroup().location
param virtualNetworkName string = 'SQLMI-VNET'
param addressPrefix string = '10.0.0.0/16'
param subnetName string = 'ManagedInstance'
param subnetPrefix string = '10.0.0.0/24'

@allowed(['GP_Gen5', 'BC_Gen5'])
param skuName string = 'GP_Gen5'

@allowed([4, 8, 16, 24, 32, 40, 64, 80])
param vCores int = 8

@minValue(32)
@maxValue(8192)
param storageSizeInGB int = 256

@allowed(['BasePrice', 'LicenseIncluded'])
param licenseType string = 'LicenseIncluded'

var nsgName = 'SQLMI-${managedInstanceName}-NSG'
var routeTableName = 'SQLMI-${managedInstanceName}-Route-Table'

resource nsg 'Microsoft.Network/networkSecurityGroups@2021-08-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow_tds_inbound'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'allow_redirect_inbound'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '11000-11999'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1100
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource routeTable 'Microsoft.Network/routeTables@2021-08-01' = {
  name: routeTableName
  location: location
  properties: {
    disableBgpRoutePropagation: false
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2021-08-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          routeTable: { id: routeTable.id }
          networkSecurityGroup: { id: nsg.id }
          delegations: [
            {
              name: 'managedInstanceDelegation'
              properties: {
                serviceName: 'Microsoft.Sql/managedInstances'
              }
            }
          ]
        }
      }
    ]
  }
}

resource mi 'Microsoft.Sql/managedInstances@2021-11-01-preview' = {
  name: managedInstanceName
  location: location
  sku: { name: skuName }
  identity: { type: 'SystemAssigned' }
  dependsOn: [vnet]
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    subnetId: resourceId(
      'Microsoft.Network/virtualNetworks/subnets',
      virtualNetworkName,
      subnetName
    )
    storageSizeInGB: storageSizeInGB
    vCores: vCores
    licenseType: licenseType
  }
}
```

Four resource types are in play: `Microsoft.Network/networkSecurityGroups`, `Microsoft.Network/routeTables`, `Microsoft.Network/virtualNetworks`, and `Microsoft.Sql/managedInstances`. The subnet delegation is the critical piece — without it, the deployment fails.

> **Tip:** Set `licenseType` to `'BasePrice'` if you have existing SQL Server licenses with Software Assurance. That's the Azure Hybrid Benefit — it can cut compute costs significantly.

### ARM Template
<!-- Source: azure-sql-managed-instance-sql-mi/quickstarts/create-azure-sql-managed-instance/create-template-quickstart.md -->

The ARM template for Managed Instance follows the same structure but in JSON. The key parameters:

| Parameter | Default | Description |
|---|---|---|
| `managedInstanceName` | — | Instance name |
| `skuName` | `GP_Gen5` | `GP_Gen5` or `BC_Gen5` |
| `vCores` | `8` | 4, 8, 16, 24, 32, 40, 64, 80 |
| `storageSizeInGB` | `256` | 32–8192 |
| `licenseType` | `LicenseIncluded` | Or `BasePrice` |

Deploy with PowerShell:

```powershell
$templateUri = "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.sql/sqlmi-new-vnet/azuredeploy.json"

New-AzResourceGroup -Name mymi-rg -Location eastus
New-AzResourceGroupDeployment `
  -ResourceGroupName mymi-rg `
  -TemplateUri $templateUri
```

Or Azure CLI:

```bash
az group create --name mymi-rg --location eastus
az deployment group create \
  --resource-group mymi-rg \
  --template-uri "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.sql/sqlmi-new-vnet/azuredeploy.json"
```

The full JSON template is available at the URI above. It defines the same four resources as the Bicep version — NSG, route table, VNet with delegated subnet, and the managed instance itself.

### Terraform
<!-- Source: azure-sql-managed-instance-sql-mi/quickstarts/create-azure-sql-managed-instance/instance-create-terraform.md -->

```terraform
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0, < 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false # See note below
    }
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "mymi-rg"
  location = "eastus"
}

resource "azurerm_network_security_group" "nsg" {
  name                = "mymi-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_virtual_network" "vnet" {
  name                = "mymi-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/24"]
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet" "subnet" {
  name                 = "ManagedInstance"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/27"]

  delegation {
    name = "managedinstancedelegation"
    service_delegation {
      name = "Microsoft.Sql/managedInstances"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action"
      ]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_route_table" "rt" {
  name                          = "mymi-rt"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  disable_bgp_route_propagation = false
}

resource "azurerm_subnet_route_table_association" "rt_assoc" {
  subnet_id      = azurerm_subnet.subnet.id
  route_table_id = azurerm_route_table.rt.id
  depends_on     = [azurerm_subnet_network_security_group_association.nsg_assoc]
}

resource "random_password" "admin_password" {
  length      = 20
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
  special     = true
}

resource "azurerm_mssql_managed_instance" "mi" {
  name                         = "mymi-instance"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  subnet_id                    = azurerm_subnet.subnet.id
  administrator_login          = "miadmin"
  administrator_login_password = random_password.admin_password.result
  license_type                 = var.license_type
  sku_name                     = var.sku_name
  vcores                       = var.vcores
  storage_size_in_gb           = var.storage_size_in_gb

  depends_on = [azurerm_subnet_route_table_association.rt_assoc]
}

variable "sku_name" {
  type    = string
  default = "GP_Gen5"
}

variable "license_type" {
  type    = string
  default = "BasePrice"
}

variable "vcores" {
  type    = number
  default = 8
}

variable "storage_size_in_gb" {
  type    = number
  default = 32
}
```

> **Gotcha:** The `depends_on` chain matters here. The managed instance must wait for the subnet-to-route-table association, which must wait for the subnet-to-NSG association. Without this ordering, Terraform may try to create the instance before the networking is ready, and the deployment fails with a cryptic error.

> **Warning:** The `prevent_deletion_if_contains_resources = false` setting lets `terraform destroy` delete resource groups that still contain resources. That's convenient for dev/test teardowns, but dangerous in production — it can wipe resources that Terraform doesn't manage. Remove this setting or set it to `true` for production configurations.

## SQL Server on Azure VMs

SQL Server on VMs involves the most infrastructure: the VM itself, disks, networking, and then the SQL IaaS Agent extension that registers it with Azure for automated patching, backups, and portal integration.

### Bicep
<!-- Source: sql-server-on-azure-vms/windows/quickstarts/create-sql-vm-bicep.md -->

This template assumes you already have a VNet and subnet. It creates the VM with dedicated data and log disks, then registers it with the SQL IaaS Agent extension:

```bicep
@description('The name of the VM')
param virtualMachineName string = 'myVM'

@description('The virtual machine size.')
param virtualMachineSize string = 'Standard_D8s_v3'

@description('Existing VNet name')
param existingVirtualNetworkName string

@description('Existing VNet resource group')
param existingVnetResourceGroup string = resourceGroup().name

@description('Existing subnet name')
param existingSubnetName string

@allowed([
  'sql2025-ws2025'
  'sql2022-ws2022'
  'sql2019-ws2022'
  'sql2019-ws2019'
])
param imageOffer string = 'sql2025-ws2025'

@allowed([
  'standard-gen2'
  'enterprise-gen2'
  'SQLDEV-gen2'
  'web-gen2'
])
param sqlSku string = 'standard-gen2'

param adminUsername string

@secure()
param adminPassword string

@allowed(['General', 'OLTP', 'DW'])
param storageWorkloadType string = 'General'

@minValue(1)
@maxValue(8)
param sqlDataDisksCount int = 1

param dataPath string = 'F:\\SQLData'

@minValue(1)
@maxValue(8)
param sqlLogDisksCount int = 1

param logPath string = 'G:\\SQLLog'

param location string = resourceGroup().location

var networkInterfaceName = '${virtualMachineName}-nic'
var networkSecurityGroupName = '${virtualMachineName}-nsg'
var subnetRef = resourceId(
  existingVnetResourceGroup,
  'Microsoft.Network/virtualNetWorks/subnets',
  existingVirtualNetworkName,
  existingSubnetName
)
var dataDisksLuns = range(0, sqlDataDisksCount)
var logDisksLuns = range(sqlDataDisksCount, sqlLogDisksCount)
var tempDbPath = 'D:\\SQLTemp'

resource nsg 'Microsoft.Network/networkSecurityGroups@2022-01-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: [
      {
        name: 'RDP'
        properties: {
          priority: 300
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2022-01-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetRef }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    enableAcceleratedNetworking: true
    networkSecurityGroup: { id: nsg.id }
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2022-03-01' = {
  name: virtualMachineName
  location: location
  properties: {
    hardwareProfile: { vmSize: virtualMachineSize }
    storageProfile: {
      dataDisks: [for i in range(0, sqlDataDisksCount + sqlLogDisksCount): {
        lun: i
        createOption: 'Empty'
        caching: (i >= sqlDataDisksCount) ? 'None' : 'ReadOnly'
        diskSizeGB: 1023
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }]
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: imageOffer
        sku: sqlSku
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
    osProfile: {
      computerName: virtualMachineName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
  }
}

resource sqlVm 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2022-07-01-preview' = {
  name: virtualMachineName
  location: location
  properties: {
    virtualMachineResourceId: vm.id
    sqlManagement: 'Full'
    sqlServerLicenseType: 'PAYG'
    storageConfigurationSettings: {
      diskConfigurationType: 'NEW'
      storageWorkloadType: storageWorkloadType
      sqlDataSettings: {
        luns: dataDisksLuns
        defaultFilePath: dataPath
      }
      sqlLogSettings: {
        luns: logDisksLuns
        defaultFilePath: logPath
      }
      sqlTempDbSettings: {
        defaultFilePath: tempDbPath
      }
    }
  }
}
```

Key details:

- **Data disk caching:** `ReadOnly` for data disks, `None` for log disks. This is critical for performance — log writes are sequential and don't benefit from read caching.
- **Premium_LRS:** Use Premium SSD for any production SQL Server workload. Standard HDD is a non-starter.
- **Accelerated networking:** Enabled on the NIC. Always do this for database VMs.
- **SQL IaaS Agent extension:** The `Microsoft.SqlVirtualMachine/sqlVirtualMachines` resource registers the VM with Azure, enabling automated backups, patching, and portal integration.
- **Tempdb on D:\:** The template sets `tempDbPath = 'D:\\SQLTemp'` — the local SSD on Azure VMs. This drive gets wiped on deallocation, which is fine for tempdb. You get fast I/O without paying for premium storage.

> **Important:** The `imageOffer` and `sqlSku` parameters together determine which SQL Server version and edition get installed. The naming convention is `sql{year}-ws{year}` for the offer and `{edition}-gen2` for the SKU. Always use `-gen2` SKUs for Gen2 VM images.

> **Gotcha:** The NSG in this template opens RDP (port 3389) to the entire internet (`sourceAddressPrefix: '*'`). For production, restrict the source to your corporate IP range or remove the rule entirely and use Azure Bastion or a VPN gateway. See the ARM template Gotcha below for more.

### ARM Template
<!-- Source: sql-server-on-azure-vms/windows/quickstarts/create-sql-vm-resource-manager-template.md -->

The ARM template for SQL Server VMs mirrors the Bicep version in JSON. It's available as an Azure Quickstart Template:

```bash
az deployment group create \
  --resource-group myvm-rg \
  --template-uri "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.sqlvirtualmachine/sql-vm-new-storage/azuredeploy.json" \
  --parameters existingVirtualNetworkName=myVnet \
               existingSubnetName=default \
               adminUsername=vmadmin
```

The quickstart template creates five resources: public IP, NSG, NIC, VM, and the SQL IaaS Agent extension registration. Note that it adds a public IP that the Bicep version above doesn't include — the Bicep template uses only a private IP on an existing subnet.

> **Gotcha:** The quickstart template opens RDP (port 3389) to the internet by default. For production, remove the public IP entirely and access the VM through Azure Bastion or a VPN gateway.

### Terraform

There's no official Microsoft quickstart for SQL Server VMs in Terraform, but the `azurerm` provider has full support. Here's the equivalent:

```terraform
resource "azurerm_resource_group" "rg" {
  name     = "myvm-rg"
  location = "eastus"
}

resource "azurerm_network_interface" "nic" {
  name                = "sqlvm-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }

  accelerated_networking_enabled = true
}

resource "azurerm_windows_virtual_machine" "vm" {
  name                = "sqlvm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_D8s_v3"
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  network_interface_ids = [azurerm_network_interface.nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2025-ws2025"
    sku       = "standard-gen2"
    version   = "latest"
  }
}

resource "azurerm_managed_disk" "data" {
  name                 = "sqlvm-data"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 1023
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  lun                = 0
  caching            = "ReadOnly"
}

resource "azurerm_managed_disk" "log" {
  name                 = "sqlvm-log"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 512
}

resource "azurerm_virtual_machine_data_disk_attachment" "log" {
  managed_disk_id    = azurerm_managed_disk.log.id
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  lun                = 1
  caching            = "None"
}

resource "azurerm_mssql_virtual_machine" "sqlvm" {
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  sql_license_type   = "PAYG"

  storage_configuration {
    disk_type             = "NEW"
    storage_workload_type = "OLTP"

    data_settings {
      default_file_path = "F:\\SQLData"
      luns              = [0]
    }

    log_settings {
      default_file_path = "G:\\SQLLog"
      luns              = [1]
    }

    temp_db_settings {
      default_file_path = "D:\\SQLTemp"
    }
  }
}

variable "subnet_id" {
  type        = string
  description = "Resource ID of the existing subnet."
}

variable "admin_username" {
  type    = string
  default = "vmadmin"
}

variable "admin_password" {
  type      = string
  sensitive = true
}
```

> **Tip:** The tempdb-on-D:\ pattern described in the Bicep section above applies here too. Set the tempdb path to the local SSD for fast I/O at no extra cost.

## Production Hardening Checklist

The templates above are starting points. Before using them in production, add:

- **Firewall rules.** For SQL Database, add `Microsoft.Sql/servers/firewallRules` to restrict access by IP, or use private endpoints (`Microsoft.Network/privateEndpoints`) to keep traffic off the internet entirely.
- **Microsoft Entra authentication.** Add `administrators` block to the server resource for Entra-only auth. Chapter 7 covers the details.
- **Diagnostic settings.** Send metrics and audit logs to Log Analytics with `Microsoft.Insights/diagnosticSettings`. See Chapter 14.
- **Tags.** Add `tags` to every resource for cost tracking and governance.
- **Secrets management.** Reference passwords from Azure Key Vault instead of passing them as parameters. In Bicep, use `getSecret()` on a Key Vault reference. In Terraform, use `azurerm_key_vault_secret` data source.
- **Lock resources.** Add `Microsoft.Authorization/locks` with `CanNotDelete` on production databases.

> **Important:** Never hard-code passwords in IaC files. Use `@secure()` parameters in Bicep, `secureString` in ARM templates, and `sensitive = true` in Terraform. Your CI/CD pipeline should inject secrets at deploy time.
