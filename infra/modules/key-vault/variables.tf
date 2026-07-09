variable "prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vm_identity_principal_id" {
  type = string
}

variable "ssh_private_key_pem" {
  type      = string
  sensitive = true
}