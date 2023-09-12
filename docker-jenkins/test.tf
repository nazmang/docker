terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
      version = "2.3.0"
    }
    null = {
      version = ">= 3.0"
    }
  }
  backend "etcdv3" {
    endpoints = ["192.168.2.58:2379"]
    lock      = true
    prefix    = "terraform-state/"
  }
}

data "terraform_remote_state" "foo" {
  backend = "etcdv3"
  config = {
    endpoints = ["192.168.2.58:2379"]
    lock      = true
    prefix    = "terraform-state/"
  }
}

resource "random_string" "resource_code" {
  length  = 5
  special = false
  upper   = false
}

resource "null_resource" "default" {
  provisioner "local-exec" {
    command = "echo ${random_string.resource_code.result}"
  }
}

output "resource_code" {
  value = random_string.resource_code.result
}
