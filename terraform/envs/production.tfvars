environment        = "production"
region             = "ap-southeast-1"
instance_type      = "t3.small"
log_retention_days = 30
# In production, restrict to your load balancer / office CIDRs.
allowed_http_cidrs = ["0.0.0.0/0"]
# The OIDC provider is account-wide; it was already created by the staging stack.
create_github_oidc_provider = false
