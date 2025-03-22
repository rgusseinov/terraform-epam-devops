provider "aws" {
  region = var.region
}

terraform {
  required_version = ">= 1.5"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my_vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_vpn_gateway = false
  enable_ipv6 = false
}

/* module "ec2-instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "5.7.1"

  for_each = toset(["dev", "staging"])

  vpc_security_group_ids = [module.vpc.default_security_group_id]
  subnet_id = module.vpc.public_subnets[each.key == "dev" ? 0 : 1]

  tags = {
    Name = each.value
  }
} */

resource "aws_security_group" "lb_public_access" {
  name   = "lb-public-access"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }
}

resource "aws_security_group" "ec2_lb_access" {
  name   = "ec2-lb-access"
  vpc_id = module.vpc.vpc_id
}


resource "aws_vpc_security_group_ingress_rule" "ec2_lb_access" {
  security_group_id = aws_security_group.ec2_lb_access.id

  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"

  referenced_security_group_id = aws_security_group.lb_public_access.id
}


resource "aws_vpc_security_group_egress_rule" "ec2_internet_access" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.ec2_lb_access.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = each.value
  ip_protocol = "tcp"
  to_port     = each.value

  tags = {
    Name = "internet access port ${each.value}"
  }
}

resource "aws_instance" "app" {
  count                = var.instance_count
  ami                  = var.ami_id
  instance_type        = var.instance_type
  subnet_id            = module.vpc.private_subnets[count.index % length(module.vpc.private_subnets)]
  key_name = var.key_name

  vpc_security_group_ids = [
    aws_security_group.ec2_lb_access.id
  ]

  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = <<-EOF
                  #!/bin/bash
                  sudo dnf install -y httpd php
                  sudo systemctl enable httpd
                  sudo systemctl start httpd
                  echo "<?php echo 'Hello from instance ${count.index}'; ?>" | sudo tee /var/www/html/index.php > /dev/null

                  sudo systemctl restart httpd
                  EOF

  tags = {
    Name = "app - ${count.index}"
    role = "app"
  }
}

resource "aws_lb" "app" {
  name               = "app"
  internal           = false
  load_balancer_type = "application"
  enable_http2       = true
  ip_address_type    = "ipv4"
  security_groups = [
    aws_security_group.lb_public_access.id
  ]
  subnets = module.vpc.public_subnets
}


resource "aws_lb_target_group" "app" {
  name     = "app"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
    path                = "/"
    port                = "80"
  }
}


resource "aws_lb_target_group_attachment" "app" {
  count            = length(aws_instance.app)
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app[count.index].id
}


resource "aws_lb_listener" "app-http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}