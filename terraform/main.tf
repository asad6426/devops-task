locals {
  name = "devops-task-${var.environment}"
}

# Latest Amazon Linux 2023 AMI, resolved at plan time (no hard-coded AMI IDs per region).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# ------------------------------------------------------------------ network
resource "aws_security_group" "app" {
  name        = "${local.name}-sg"
  description = "devops-task ${var.environment}: HTTP in, all out. No SSH - access is via SSM Session Manager."
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.allowed_http_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "App HTTP"
  ip_protocol       = "tcp"
  from_port         = var.app_port
  to_port           = var.app_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound: image pulls (GHCR), SSM, CloudWatch, OS updates"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ------------------------------------------------------------------ logs
resource "aws_cloudwatch_log_group" "app" {
  name              = "/devops-task/${var.environment}/app"
  retention_in_days = var.log_retention_days
}

# ------------------------------------------------------------------ IAM (instance)
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM agent registration + Run Command + Session Manager (replaces SSH and key pairs).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Only what the Docker awslogs driver needs, only on this environment's log group.
data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "WriteContainerLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "logs" {
  name   = "cloudwatch-logs"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.logs.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# ------------------------------------------------------------------ EC2
resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region        = var.region
    log_group     = aws_cloudwatch_log_group.app.name
    host_port     = var.app_port
    app_image     = var.app_image
    environment   = var.environment
    deploy_script = file("${path.module}/../scripts/ec2-deploy.sh")
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach instance credentials
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  tags = {
    Name = local.name
  }

  lifecycle {
    ignore_changes = [ami] # don't replace the instance every time AWS publishes a new AMI
  }
}
