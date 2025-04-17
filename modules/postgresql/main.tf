/**
 * Copyright 2024 Google LLC
 * ... (rest of the license)
 */

locals {
  # Determine the project ID for the instance (existing or new)
  instance_project_id = coalesce(var.existing_instance_project_id, var.project_id)

  # Determine the instance name (newly generated or existing)
  # Note: local.instance_name is still used for the *creation* scenario name generation
  instance_creation_name = var.random_instance_name ? "${var.name}-${random_id.suffix[0].hex}" : var.name
  target_instance_name   = var.use_existing_instance ? var.existing_instance_name : local.instance_creation_name

  # --- Keep other locals as they were, they define configurations ---
  is_secondary_instance = var.master_instance_name != null
  ip_configuration_enabled = length(keys(var.ip_configuration)) > 0 ? true : false
  ip_configurations = {
    enabled  = var.ip_configuration
    disabled = {}
  }
  databases = { for db in var.additional_databases : db.name => db }
  users     = { for u in var.additional_users : u.name => u }
  iam_users = {
    for user in var.iam_users : user.id => {
      email = trimsuffix(user.email, ".gserviceaccount.com")
      type  = trimsuffix(user.email, "gserviceaccount.com") == user.email ? (user.type != null ? user.type : "CLOUD_IAM_USER") : "CLOUD_IAM_SERVICE_ACCOUNT"
    }
  }
  point_in_time_recovery_enabled = var.availability_type == "REGIONAL" ? lookup(var.backup_configuration, "point_in_time_recovery_enabled", true) : lookup(var.backup_configuration, "point_in_time_recovery_enabled", false)
  backups_enabled                = var.availability_type == "REGIONAL" ? lookup(var.backup_configuration, "enabled", true) : lookup(var.backup_configuration, "enabled", false)
  retained_backups               = lookup(var.backup_configuration, "retained_backups", null)
  retention_unit                 = lookup(var.backup_configuration, "retention_unit", null)
  connector_enforcement          = var.connector_enforcement ? "REQUIRED" : "NOT_REQUIRED"
  database_name                  = var.enable_default_db ? var.db_name : (length(var.additional_databases) > 0 ? var.additional_databases[0].name : "")
  encryption_key                 = var.encryption_key_name != null ? var.encryption_key_name : var.use_autokey ? google_kms_key_handle.default[0].kms_key : null

  # --- Unified instance data ---
  # This local will hold the attributes of the instance, whether created or existing
  instance_data = var.use_existing_instance ? data.google_sql_database_instance.existing[0] : google_sql_database_instance.default[0]

}

# --- Data source to fetch existing instance ---
data "google_sql_database_instance" "existing" {
  count   = var.use_existing_instance ? 1 : 0
  provider = google-beta # Ensure provider consistency if needed
  name    = var.existing_instance_name
  project = local.instance_project_id
}

resource "random_id" "suffix" {
  count = !var.use_existing_instance && var.random_instance_name ? 1 : 0 # Only needed if creating and random name is requested
  byte_length = 4
}

# --- Conditionally Create Instance ---
resource "google_sql_database_instance" "default" {
  count              = var.use_existing_instance ? 0 : 1 # Create only if not using existing
  provider           = google-beta
  project            = local.instance_project_id # Use the determined project ID
  name               = local.instance_creation_name # Use the generated name for creation
  database_version   = can(regex("\\d", substr(var.database_version, 0, 1))) ? format("POSTGRES_%s", var.database_version) : replace(var.database_version, substr(var.database_version, 0, 8), "POSTGRES")
  maintenance_version = var.maintenance_version
  region             = var.region # Region is fundamental, must match if using existing
  encryption_key_name = local.encryption_key
  deletion_protection = var.deletion_protection
  root_password       = var.root_password # Only applies at creation

  master_instance_name = var.master_instance_name
  instance_type        = local.is_secondary_instance ? "READ_REPLICA_INSTANCE" : var.instance_type

  # Settings are applied during creation. Modifying them on an existing instance
  # via this module when use_existing_instance=true might not work as expected
  # or might require specific 'terraform apply' targeting if the resource block is used differently.
  # For simplicity, assume settings are primarily for creation here.
  settings {
    tier                         = var.tier
    edition                      = var.edition
    activation_policy            = var.activation_policy
    availability_type            = var.availability_type
    deletion_protection_enabled  = var.deletion_protection_enabled
    connector_enforcement        = local.connector_enforcement
    enable_google_ml_integration = var.enable_google_ml_integration
    enable_dataplex_integration  = var.enable_dataplex_integration

    dynamic "backup_configuration" {
      for_each = local.is_secondary_instance ? [] : [var.backup_configuration]
      content {
        enabled                        = local.backups_enabled
        start_time                     = lookup(backup_configuration.value, "start_time", null)
        location                       = lookup(backup_configuration.value, "location", null)
        point_in_time_recovery_enabled = local.point_in_time_recovery_enabled
        transaction_log_retention_days = lookup(backup_configuration.value, "transaction_log_retention_days", null)

        dynamic "backup_retention_settings" {
          for_each = local.retained_backups != null || local.retention_unit != null ? [var.backup_configuration] : []
          content {
            retained_backups = local.retained_backups
            retention_unit   = local.retention_unit
          }
        }
      }
    }
    dynamic "data_cache_config" {
      for_each = var.edition == "ENTERPRISE_PLUS" && var.data_cache_enabled ? ["cache_enabled"] : []
      content {
        data_cache_enabled = var.data_cache_enabled
      }
    }
    dynamic "deny_maintenance_period" {
      for_each = local.is_secondary_instance ? [] : var.deny_maintenance_period
      content {
        end_date   = lookup(deny_maintenance_period.value, "end_date", null)
        start_date = lookup(deny_maintenance_period.value, "start_date", null)
        time       = lookup(deny_maintenance_period.value, "time", null)
      }
    }
    dynamic "ip_configuration" {
      for_each = [local.ip_configurations[local.ip_configuration_enabled ? "enabled" : "disabled"]]
      content {
        ipv4_enabled                                = lookup(ip_configuration.value, "ipv4_enabled", null)
        private_network                             = lookup(ip_configuration.value, "private_network", null)
        ssl_mode                                    = lookup(ip_configuration.value, "ssl_mode", null)
        allocated_ip_range                          = lookup(ip_configuration.value, "allocated_ip_range", null)
        enable_private_path_for_google_cloud_services = lookup(ip_configuration.value, "enable_private_path_for_google_cloud_services", false)

        dynamic "authorized_networks" {
          for_each = lookup(ip_configuration.value, "authorized_networks", [])
          content {
            expiration_time = lookup(authorized_networks.value, "expiration_time", null)
            name            = lookup(authorized_networks.value, "name", null)
            value           = lookup(authorized_networks.value, "value", null)
          }
        }

        dynamic "psc_config" {
          for_each = lookup(ip_configuration.value, "psc_enabled", false) ? ["psc_enabled"] : []
          content {
            psc_enabled                 = ip_configuration.value.psc_enabled
            allowed_consumer_projects = lookup(ip_configuration.value, "psc_allowed_consumer_projects", [])
          }
        }
      }
    }
    dynamic "insights_config" {
      for_each = var.insights_config != null ? [var.insights_config] : []
      content {
        query_insights_enabled  = true
        query_plans_per_minute  = lookup(insights_config.value, "query_plans_per_minute", 5)
        query_string_length     = lookup(insights_config.value, "query_string_length", 1024)
        record_application_tags = lookup(insights_config.value, "record_application_tags", false)
        record_client_address   = lookup(insights_config.value, "record_client_address", false)
      }
    }

    dynamic "password_validation_policy" {
      for_each = !local.is_secondary_instance && var.password_validation_policy_config != null ? [var.password_validation_policy_config] : []
      content {
        enable_password_policy    = true
        min_length                = lookup(password_validation_policy.value, "min_length", 8)
        complexity                = lookup(password_validation_policy.value, "complexity", "COMPLEXITY_DEFAULT")
        reuse_interval            = lookup(password_validation_policy.value, "reuse_interval", null)
        disallow_username_substring = lookup(password_validation_policy.value, "disallow_username_substring", true)
        password_change_interval  = lookup(password_validation_policy.value, "password_change_interval", null)
      }
    }

    disk_autoresize       = var.disk_autoresize
    disk_autoresize_limit = var.disk_autoresize_limit
    disk_size             = var.disk_size
    disk_type             = var.disk_type
    pricing_plan          = var.pricing_plan

    dynamic "database_flags" {
      for_each = var.database_flags
      content {
        name  = lookup(database_flags.value, "name", null)
        value = lookup(database_flags.value, "value", null)
      }
    }

    user_labels = var.user_labels

    dynamic "location_preference" {
      for_each = var.zone != null ? ["location_preference"] : []
      content {
        zone                   = var.zone
        secondary_zone         = local.is_secondary_instance ? null : var.secondary_zone
        follow_gae_application = local.is_secondary_instance ? null : var.follow_gae_application
      }
    }

    dynamic "maintenance_window" {
      for_each = local.is_secondary_instance ? [] : ["maintenance_window"]
      content {
        day          = var.maintenance_window_day
        hour         = var.maintenance_window_hour
        update_track = var.maintenance_window_update_track
      }
    }
  }

  lifecycle {
    ignore_changes = [
      settings[0].disk_size,
      # Potentially ignore more settings if managing an existing instance
      # where these shouldn't be changed by this module.
      # However, since this resource block *won't run* when use_existing_instance=true,
      # this ignore_changes block primarily affects updates when the instance *was* created by this module.
    ]
  }

  timeouts {
    create = var.create_timeout
    update = var.update_timeout
    delete = var.delete_timeout
  }

  depends_on = [null_resource.module_depends_on]
}

# --- KMS Key Handle (only if creating with autokey) ---
resource "google_kms_key_handle" "default" {
  count    = !var.use_existing_instance && var.use_autokey ? 1 : 0 # Only if creating and using autokey
  provider = google-beta
  project  = local.instance_project_id
  name     = local.instance_creation_name # Use the name being created
  location = coalesce(var.region, join("-", slice(split("-", var.zone), 0, 2)))
  resource_type_selector = "sqladmin.googleapis.com/Instance"
}

# --- Databases ---
# Reference the instance via local.instance_data
resource "google_sql_database" "default" {
  count    = var.enable_default_db ? 1 : 0
  name     = var.db_name
  project  = local.instance_data.project # Get project from the instance data
  instance = local.instance_data.name    # Get name from the instance data
  charset  = var.db_charset
  collation = var.db_collation
  # Implicit dependency on instance_data should be sufficient.
  # If explicit needed: depends_on = [var.use_existing_instance ? data.google_sql_database_instance.existing : google_sql_database_instance.default]
  depends_on = [null_resource.module_depends_on]
  deletion_policy = var.database_deletion_policy
}

resource "google_sql_database" "additional_databases" {
  for_each  = local.databases
  project   = local.instance_data.project # Get project from the instance data
  name      = each.value.name
  charset   = lookup(each.value, "charset", null)
  collation = lookup(each.value, "collation", null)
  instance  = local.instance_data.name    # Get name from the instance data
  depends_on = [null_resource.module_depends_on]
  deletion_policy = var.database_deletion_policy
}

# --- Passwords ---
# Reference the instance name via local.instance_data for keepers
resource "random_password" "user-password" {
  count = var.enable_default_user ? 1 : 0
  keepers = {
    # Use the actual name from the instance data as keeper
    instance_name = local.instance_data.name
  }
  min_lower   = 1
  min_numeric = 1
  min_upper   = 1
  length      = var.password_validation_policy_config != null ? (var.password_validation_policy_config.min_length != null ? var.password_validation_policy_config.min_length + 4 : 32) : 32
  special     = var.enable_random_password_special ? true : (var.password_validation_policy_config != null ? (var.password_validation_policy_config.complexity == "COMPLEXITY_DEFAULT" ? true : false) : false)
  min_special = var.enable_random_password_special ? 1 : (var.password_validation_policy_config != null ? (var.password_validation_policy_config.complexity == "COMPLEXITY_DEFAULT" ? 1 : 0) : 0)
  depends_on  = [null_resource.module_depends_on] # Dependency on instance established via keepers

  lifecycle {
    ignore_changes = [
      min_lower, min_upper, min_numeric, special, min_special, length
    ]
  }
}

resource "random_password" "additional_passwords" {
  for_each = local.users
  keepers = {
    # Use the actual name from the instance data as keeper
    instance_name = local.instance_data.name
  }
  min_lower   = 1
  min_numeric = 1
  min_upper   = 1
  length      = var.password_validation_policy_config != null ? (var.password_validation_policy_config.min_length != null ? var.password_validation_policy_config.min_length + 4 : 32) : 32
  special     = var.enable_random_password_special ? true : (var.password_validation_policy_config != null ? (var.password_validation_policy_config.complexity == "COMPLEXITY_DEFAULT" ? true : false) : false)
  min_special = var.enable_random_password_special ? 1 : (var.password_validation_policy_config != null ? (var.password_validation_policy_config.complexity == "COMPLEXITY_DEFAULT" ? 1 : 0) : 0)
  depends_on  = [null_resource.module_depends_on] # Dependency on instance established via keepers

  lifecycle {
    ignore_changes = [
      min_lower, min_upper, min_numeric, special, min_special, length
    ]
  }
}

# --- Users ---
# Reference the instance via local.instance_data
resource "google_sql_user" "default" {
  count    = var.enable_default_user ? 1 : 0
  name     = var.user_name
  project  = local.instance_data.project # Get project from the instance data
  instance = local.instance_data.name    # Get name from the instance data
  password = var.user_password == "" ? random_password.user-password[0].result : var.user_password
  depends_on = [
    null_resource.module_depends_on,
    # Replicas dependency removed as it complicates conditional logic unnecessarily here.
    # If replicas are created by this module, they depend on the primary implicitly.
  ]
  deletion_policy = var.user_deletion_policy
}

resource "google_sql_user" "additional_users" {
  for_each = local.users
  project  = local.instance_data.project # Get project from the instance data
  name     = each.value.name
  password = each.value.random_password ? random_password.additional_passwords[each.value.name].result : each.value.password
  instance = local.instance_data.name    # Get name from the instance data
  depends_on = [
    null_resource.module_depends_on,
  ]
  deletion_policy = var.user_deletion_policy
}

resource "google_sql_user" "iam_account" {
  for_each = local.iam_users
  project  = local.instance_data.project # Get project from the instance data
  name     = each.value.email
  instance = local.instance_data.name    # Get name from the instance data
  type     = each.value.type
  depends_on = [
    null_resource.module_depends_on,
  ]
  deletion_policy = var.user_deletion_policy
}

# --- IAM Binding ---
# Reference the instance service account via local.instance_data
resource "google_project_iam_member" "database_integration" {
  # This resource might behave unexpectedly if the instance is existing and in another project,
  # as it tries to grant roles in var.project_id to the service account of an instance
  # potentially in local.instance_project_id. Ensure var.project_id is the correct one for the IAM binding.
  for_each = toset(var.database_integration_roles)
  project  = local.instance_data.project # Bind role in the instance's project
  role     = each.value
  member   = "serviceAccount:${local.instance_data.service_account_email_address}"
  # Ensure dependency on the instance being available
  depends_on = [local.instance_data.id] # Explicit dependency using an attribute
}

# --- Module Depends On ---
resource "null_resource" "module_depends_on" {
  triggers = {
    value = length(var.module_depends_on)
  }
}
