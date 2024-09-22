variable "region" {
  description = "Value of the aws region"
  type        = string
  default     = "us-east-2"
}

locals {
  envs = { for tuple in regexall("(.*)=(.*)", file(".env")) : tuple[0] => sensitive(tuple[1]) }
}

variable "env" {
  description = "the environment the resource is being created in"
  type = string
}

variable "aws_account_url" {
  description = "my aws account url"
  type = string
  sensitive = true
}

variable "access_key" {
  description = "terraform user aws access key"
  type = string
  sensitive = true
}

variable "secret_key" {
  description = "terraform user aws secret key"
  type = string
  sensitive = true
}


