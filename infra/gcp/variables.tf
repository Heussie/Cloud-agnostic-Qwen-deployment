variable "GCP_ACCESS_KEY"{

}
variable "GCP_SECRET_KEY"{

}
variable "GCP_REGION"{

}
# variables.tf

variable "org_id" {
  description = "Google Cloud Organization ID"
  type        = string
}

variable "org_id" {
  type = string
}

variable "billing_account" {
  type = string
}

variable "project_id" {
  type = string
}

variable "project_name" {
  type = string
}

variable "region" {
  default = "europe-west4"
}

variable "bootstrap_project" {
  type = string
}