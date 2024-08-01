provider "azurerm" {
  features {}

  subscription_id = "your_subscription_id"
  client_id       = "your_client_id"
  client_secret   = "your_client_secret"
  tenant_id       = "your_tenant_id"
}

# Resource group
resource "azurerm_resource_group" "aks_rg" {
  name     = "nexus-rg"
  location = "East US 2"
}

# Virtual network
resource "azurerm_virtual_network" "vnet" {
  name                = "nexus-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
}

# Subnet
resource "azurerm_subnet" "aks_subnet" {
  name                 = "nexus-subnet"
  resource_group_name  = azurerm_resource_group.aks_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "private_endpoint_subnet" {
  name                 = "private-endpoint-subnet"
  resource_group_name  = azurerm_resource_group.aks_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
  enforce_private_link_endpoint_network_policies = true
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "app_gateway_public_ip" {
  name                = "appGatewayPublicIP"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Application Gateway
resource "azurerm_application_gateway" "app_gateway" {
  name                = "nexusAppGateway"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.aks_subnet.id
  }
  frontend_port {
    name = "frontendPort"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontendIpConfig"
    public_ip_address_id = azurerm_public_ip.app_gateway_public_ip.id
  }

  backend_address_pool {
    name = "backendAddressPool"
  }

  backend_http_settings {
    name                  = "appGatewayBackendHttpSettings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "appGatewayHttpListener"
    frontend_ip_configuration_name = "frontendIpConfig"
    frontend_port_name             = "frontendPort"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "appGatewayRule"
    rule_type                  = "Basic"
    http_listener_name         = "appGatewayHttpListener"
    backend_address_pool_name  = "backendAddressPool"
    backend_http_settings_name = "appGatewayBackendHttpSettings"
  }

  tags = {
    environment = "production"
  }
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "nexus-cluster"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  dns_prefix          = "aksdns"

  default_node_pool {
    name       = "agentpool"
    node_count = 1
    vm_size    = "Standard_DS2_v2"
    vnet_subnet_id = azurerm_subnet.aks_subnet.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
    network_policy    = "azure"
  }
}

# Additional Node Pool
resource "azurerm_kubernetes_cluster_node_pool" "node_pool" {
  name                  = "nodepool2"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = "Standard_DS2_v2"
  node_count            = 1
  vnet_subnet_id        = azurerm_subnet.aks_subnet.id
}

# Key Vault
resource "azurerm_key_vault" "kv" {
  name                        = "nexusKv"
  location                    = azurerm_resource_group.aks_rg.location
  resource_group_name         = azurerm_resource_group.aks_rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  purge_protection_enabled    = true
  soft_delete_retention_days  = 90

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"

    ip_rules = []

    virtual_network_subnet_ids = [
      azurerm_subnet.aks_subnet.id
    ]
  }
}

# Storage Account
resource "azurerm_storage_account" "storage" {
  name                     = "nexusstgacc"
  resource_group_name      = azurerm_resource_group.aks_rg.name
  location                 = azurerm_resource_group.aks_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Azure Database for PostgreSQL
resource "azurerm_postgresql_flexible_server" "postgresql" {
  name                = "nexus-pgsql"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  sku_name            = "GP_Standard_D4s_v3"
  storage_mb          = 32768
  storage_tier        = "P30"
  version             = "12"

  administrator_login    = "repoadmin"
  administrator_password = "nexuspw@123"
  delegated_subnet_id    = azurerm_subnet.private_endpoint_subnet.id

  depends_on = [
    azurerm_subnet.private_endpoint_subnet
  ]
}

# PostgreSQL Databases
resource "azurerm_postgresql_flexible_database" "postgres" {
  name                = "postgres"
  resource_group_name = azurerm_resource_group.aks_rg.name
  server_name         = azurerm_postgresql_flexible_server.postgresql.name
  charset             = "UTF8"
  collation           = "English_United States.1252"
}

resource "azurerm_postgresql_flexible_database" "nexus_postgresql" {
  name                = "nexus-postgresql"
  resource_group_name = azurerm_resource_group.aks_rg.name
  server_name         = azurerm_postgresql_flexible_server.postgresql.name
  charset             = "UTF8"
  collation           = "English_United States.1252"
}

# Private Endpoint for PostgreSQL
resource "azurerm_private_endpoint" "postgresql_private_endpoint" {
  name                = "postgresql-private-endpoint"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  subnet_id           = azurerm_subnet.private_endpoint_subnet.id

  private_service_connection {
    name                           = "postgresqlConnection"
    private_connection_resource_id = azurerm_postgresql_flexible_server.postgresql.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }
}

# Private DNS Zone for PostgreSQL
resource "azurerm_private_dns_zone" "private_dns_zone" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.aks_rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "dnsLink"
  resource_group_name   = azurerm_resource_group.aks_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.private_dns_zone.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_dns_a_record" "dns_record" {
  name                = "postgresql"
  resource_group_name = azurerm_resource_group.aks_rg.name
  zone_name           = azurerm_private_dns_zone.private_dns_zone.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.postgresql_private_endpoint.private_ip_address]
}

# RBAC for Key Vault
resource "azurerm_role_assignment" "kv_role" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

data "azurerm_client_config" "current" {}
