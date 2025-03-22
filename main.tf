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

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.lb_public_access.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create classic load balancer / Elastic Load Balancer
resource "aws_elb" "app" {
  name               = "app"
  # availability_zones = ["us-east-1a", "us-east-1b"]

  listener {
    instance_port     = 80
    instance_protocol = "HTTP"
    lb_port          = 80
    lb_protocol      = "HTTP"
  }

  security_groups = [aws_security_group.lb_public_access.id]
  subnets         = module.vpc.public_subnets

  health_check {
    target              = "HTTP:80/"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 10
  }
}

resource "aws_elb_attachment" "app" {
  count         = length(aws_instance.app)
  elb          = aws_elb.app.id
  instance     = aws_instance.app[count.index].id
}

resource "aws_instance" "app" {
  count                = var.instance_count
  ami                  = var.ami_id
  instance_type        = var.instance_type
  subnet_id            = module.vpc.private_subnets[count.index % length(module.vpc.private_subnets)]
  key_name             = var.key_name

  vpc_security_group_ids = [aws_security_group.ec2_lb_access.id]

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