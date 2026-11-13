variable "environment" {
  type        = string
  description = "Deployment environment."
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "region" {
  type        = string
  description = "AWS region."
  default     = "ap-southeast-1"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type."
  default     = "t3.micro"
}

variable "root_volume_size_gb" {
  type    = number
  default = 20
}

variable "app_image" {
  type        = string
  description = "Initial container image deployed at boot. CI deploys newer tags via SSM afterwards."
  default     = "ghcr.io/asad6426/devops-task:1.0.0"
}

variable "app_port" {
  type        = number
  description = "Host port the app is published on."
  default     = 80
}

variable "allowed_http_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the app over HTTP. Restrict this in production (or front it with an ALB)."
  default     = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for container logs."
  default     = 14
}

variable "github_repository" {
  type        = string
  description = "owner/repo allowed to assume the deploy role via GitHub OIDC."
  default     = "asad6426/devops-task"
}

variable "create_github_oidc_provider" {
  type        = bool
  description = "Create the GitHub OIDC provider (only once per AWS account; set false if it already exists)."
  default     = true
}
