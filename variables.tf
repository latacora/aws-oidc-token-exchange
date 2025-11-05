
variable "name" {
  type = string
}

variable "key_administrator_patterns" {
  type    = list(string)
  default = []
}

variable "default_audience" {
  type = string
}

variable "log_retention" {
  type    = number
  default = 365
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "hosted_zone_id" {
  type        = string
  description = "Route53 hosted zone ID for the custom domain"
}

variable "domain" {
  type        = string
  description = "Subdomain for the OIDC provider (e.g., 'oidc' for oidc.example.com)"
}

variable "principal_org_id" {
  type        = string
  description = "Organization ID for the AWS org that should be able to use this OIDC provider."
}
