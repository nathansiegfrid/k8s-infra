variable "cluster_ipv4s" {
  description = "IPv4 addresses of the cluster nodes."
  type        = list(string)
}

variable "cluster_subdomain" {
  description = "Subdomain for the cluster (e.g. k8s.example.com)."
  type        = string
}

variable "cloudflare_token" {
  description = "Cloudflare API Token."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID."
  type        = string
}
