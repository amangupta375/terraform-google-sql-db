# read_replicas.tf (Modified for conditional create/reference approach)

/**
 * Copyright 2024 Google LLC
 * (License text)
 */

locals {
  # Keep processing the input variable for replicas
  replicas = {
    # The key generation here uses var.name, which might be confusing if using existing.
    # However, the actual resource name uses local.instance_data.name, which is correct.
    # This local is just for the for_each loop key.
    for x in var.read_replicas : "${var.name}-replica${var.read_replica_name_suffix}${x.name}" => x
  }

  # --- Zone Calculation ---
  # Calculate a potential default zone for replicas if not specified.
  # Uses var.region as the context, which should be set correctly regardless of create/existing.
  # Needs the data source defined here if used.
  replica_default_zone_lookup_needed = anytrue([for r in var.read_replicas : lookup(r, "zone", null) == null]) && var.zone == null
  replica_default_zone = local.replica_default_zone_lookup_needed ? (
    length(data.google_compute_zones.available_for_replicas) > 0 ? data.google_compute_zones.available_for_replicas[0].names[0] : null
    ) : var.zone # Fallback to primary's zone preference if set

  # Helper local for primary's data cache status (handles empty list case)
  primary_data_cache_enabled = try(local.instance_data.settings[0].data_cache_config[0].data_cache_enabled, false)

}

# Data source to find available zones in the primary's region if needed for replica default zone
data "google_compute_zones" "available_for_replicas" {
  count   = local.replica_default_zone_lookup_needed ? 1 : 0
  project = var.project_id # Use the main project context
  region  = var.region     # Use the main region context
}

# --- Read Replica Instances ---
resource "google_sql_database_instance" "replicas" {
  provider           = google-beta
  for_each           = local.replicas
  # Use the primary's actual project ID
  project            = local.instance_data.project
  # Generate name based on the primary's actual name from local.instance_data
  name               = coalesce(each.value.name_override, "${local.instance_data.name}-replica${var.read_replica_name_suffix}${each.value.name}")
  # Match the primary's database version
  database_version   = local.instance_data.database_version
  # Determine replica region from its zone (specified or default)
  # Use local.replica_default_zone which handles lookup or var.zone fallback
  region             = join("-", slice(split("-", lookup(each.value, "zone", local.replica_default_zone)), 0, 2))
  # Point to the primary's actual name
  master_instance_name = local.instance_data.name
  deletion_protection  = var.read_replica_deletion_protection
  # Determine encryption key based on replica region vs primary's actual region
  encryption_key_name = (join("-", slice(split("-", lookup(each.value, "zone", local.replica_default_zone)), 0, 2))) == local.instance_data.region ? null : each.value.encryption_key_name

  settings {
    # Inherit tier/edition from primary's actual settings if not overridden
    tier                         = coalesce(each.value.tier, local.instance_data.settings[0].tier)
    edition                      = coalesce(each.value.edition, local.instance_data.settings[0].edition)
    activation_policy            = "ALWAYS" # Replicas usually always on
    # Default replica availability to ZONAL unless overridden
    availability_type            = coalesce(each.value.availability_type, "ZONAL")
    deletion_protection_enabled  = var.read_replica_deletion_protection_enabled

    dynamic "ip_configuration" {
      # Use replica specific config, default to empty map if not provided
      for_each = [lookup(each.value, "ip_configuration", {})]
      content {
        ipv4_enabled                                = lookup(ip_configuration.value, "ipv4_enabled", true) # Replicas often need IPv4
        private_network                             = lookup(ip_configuration.value, "private_network", null)
        ssl_mode                                    = lookup(ip_configuration.value, "ssl_mode", null) # Inherit? Usually set explicitly.
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
        # Corrected PSC config logic
        dynamic "psc_config" {
          for_each = lookup(ip_configuration.value, "psc_enabled", false) ? ["psc_enabled"] : []
          content {
            psc_enabled                 = lookup(ip_configuration.value, "psc_enabled", false)
            allowed_consumer_projects = lookup(ip_configuration.value, "psc_allowed_consumer_projects", [])
          }
        }
      }
    }
    # Inherit insights config from primary if not set on replica
    dynamic "insights_config" {
      for_each = lookup(each.value, "insights_config", null) != null ? [each.value.insights_config] : (var.insights_config != null ? [var.insights_config] : [])
      content {
        query_insights_enabled  = true # Assuming always true if block is present
        query_plans_per_minute  = lookup(insights_config.value, "query_plans_per_minute", 5)
        query_string_length     = lookup(insights_config.value, "query_string_length", 1024)
        record_application_tags = lookup(insights_config.value, "record_application_tags", false)
        record_client_address   = lookup(insights_config.value, "record_client_address", false)
      }
    }

    # Inherit disk settings from primary's actual settings if not overridden
    disk_autoresize       = coalesce(each.value.disk_autoresize, local.instance_data.settings[0].disk_autoresize)
    disk_autoresize_limit = coalesce(each.value.disk_autoresize_limit, local.instance_data.settings[0].disk_autoresize_limit)
    disk_size             = coalesce(each.value.disk_size, local.instance_data.settings[0].disk_size)
    disk_type             = coalesce(each.value.disk_type, local.instance_data.settings[0].disk_type)
    pricing_plan          = "PER_USE" # Replicas often default to this
    # Inherit user labels from primary if not set on replica
    user_labels           = lookup(each.value, "user_labels", local.instance_data.settings[0].user_labels)

    dynamic "database_flags" {
      # Use replica specific flags only
      for_each = lookup(each.value, "database_flags", [])
      content {
        name  = lookup(database_flags.value, "name", null)
        value = lookup(database_flags.value, "value", null)
      }
    }

    location_preference {
      zone = lookup(each.value, "zone", local.replica_default_zone)
    }

    # Inherit data cache config from primary if not set on replica, checking edition
    dynamic "data_cache_config" {
       for_each = coalesce(each.value.edition, local.instance_data.settings[0].edition) == "ENTERPRISE_PLUS" && coalesce(each.value.data_cache_enabled, local.primary_data_cache_enabled) ? ["cache_enabled"] : []
       content {
         data_cache_enabled = coalesce(each.value.data_cache_enabled, local.primary_data_cache_enabled)
       }
     }
  }

  # Remove explicit depends_on, rely on Terraform's dependency graph
  # built from using local.instance_data attributes.
  # depends_on = [google_sql_database_instance.default] # REMOVED

  lifecycle {
    ignore_changes = [
      settings[0].disk_size,
      # Replicas don't have maintenance windows managed this way
      # settings[0].maintenance_window, # REMOVED
      encryption_key_name, # Keep ignoring this if managed externally
    ]
  }

  timeouts {
    create = var.create_timeout
    update = var.update_timeout
    delete = var.delete_timeout
  }
}