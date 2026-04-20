resource "cloudflare_dns_record" "cluster" {
  for_each = toset(var.cluster_ipv4s)

  zone_id = var.cloudflare_zone_id
  type    = "A"
  name    = var.cluster_subdomain
  content = each.value
  ttl     = 1     # automatic
  proxied = false # must be disabled for ACME HTTP-01 challenges
  comment = "Managed by Terraform"
}
