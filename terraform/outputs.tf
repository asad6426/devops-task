output "instance_id" {
  description = "Set as GitHub variable EC2_INSTANCE_ID."
  value       = aws_instance.app.id
}

output "public_url" {
  value = "http://${aws_instance.app.public_dns}${var.app_port == 80 ? "" : ":${var.app_port}"}"
}

output "github_deploy_role_arn" {
  description = "Set as GitHub variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.github_deploy.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}
