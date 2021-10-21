# Use terraform to create the following                                                                                                                                                                                                  
#  - EC2 hosting a plain vanilla apache website                                                                                                                                                                                             
#  - Autoscaling Group under which the EC2 will run                                                                                                                                                                                         
#  - Load balancer public facing                                                                                                                                                                                                            

# https://twitter.com/fesshole/status/1451117312673714185

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0" # TODO: tighten version?
    }
  }

  # semantic versioning must count for something, right?
  required_version = ">= 1.0"
}

provider "aws" {
  profile = "default"
  region  = "ap-southeast-2"
}

#################

resource "aws_vpc" "ex_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "example VPC"
  }
}

# backend subnets
resource "aws_subnet" "ex_public_apse2a" {
  vpc_id            = aws_vpc.ex_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-southeast-2a"

  tags = {
    Name = "example subnet (a)"
  }
}
resource "aws_subnet" "ex_public_apse2b" {
  vpc_id            = aws_vpc.ex_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-southeast-2b"

  tags = {
    Name = "example subnet (b)"
  }
}

resource "aws_internet_gateway" "ex_igw" {
  vpc_id = aws_vpc.ex_vpc.id

  tags = {
    Name = "example GW"
  }
}

resource "aws_route_table" "ex_routes" {
  vpc_id = aws_vpc.ex_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ex_igw.id
  }

  tags = {
    Name = "example route table"
  }
}
resource "aws_route_table_association" "ex_route_assoc_apse2a" {
  subnet_id      = aws_subnet.ex_public_apse2a.id
  route_table_id = aws_route_table.ex_routes.id
}
resource "aws_route_table_association" "ex_route_assoc_apse2b" {
  subnet_id      = aws_subnet.ex_public_apse2b.id
  route_table_id = aws_route_table.ex_routes.id
}

resource "aws_security_group" "ex_webserver" {
  name        = "ex-webserver"
  description = "network security policy for webserver backends (allow inbound SSH & HTTP)"
  vpc_id      = aws_vpc.ex_vpc.id

  # let SSH in
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # and HTTP too
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # let it all out
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "example webserver SG"
  }
}

resource "aws_launch_configuration" "ex_webserver" {
  name_prefix = "ex-web-"

  #  image_id = "ami-0947d2ba12ee1ff75" # Amazon Linux 2 AMI (HVM), SSD Volume Type
  image_id      = "ami-0d2f34c92aa48cd95" # Debian 10 @sydney
  instance_type = "t2.micro"
  key_name      = "miiichael"

  security_groups             = [aws_security_group.ex_webserver.id]
  associate_public_ip_address = true

  # should there be a 'set -e' in here somewhere? 🤔
  user_data = <<-EOF
    #! /bin/bash
    sudo apt-get update
    sudo apt-get install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2
    echo "<h1>Deployed via Terraform</h1>" | sudo tee /var/www/html/index.html
  EOF

  lifecycle {
    create_before_destroy = true
  }
}

# I'm gonna pretend ALB doesn't exist yet (my brain can only take in so much...) so ELB it is.

resource "aws_security_group" "ex_elb_http" {
  name        = "ex-elb"
  description = "network security policy for ELB frontend (allow inbound HTTP)"
  vpc_id      = aws_vpc.ex_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "example ELB frontend"
  }
}

resource "aws_elb" "ex_frontend" {
  name = "web-elb"
  security_groups = [
    aws_security_group.ex_elb_http.id
  ]
  subnets = [
    aws_subnet.ex_public_apse2a.id,
    aws_subnet.ex_public_apse2a.id
  ]

  # enabled by default in terraform...
  # cross_zone_load_balancing   = true

  #  health_check {
  #    healthy_threshold = 2
  #    unhealthy_threshold = 2
  #    timeout = 3
  #    interval = 30
  #    target = "HTTP:80/"
  #  }

  listener {
    # SSL? What's that? <_< >_>
    lb_port           = 80
    lb_protocol       = "http"
    instance_port     = "80"
    instance_protocol = "http"
  }
}

resource "aws_autoscaling_group" "ex_frontent_asg" {
  # this strikes me as a little bit sneaky
  name = "${aws_launch_configuration.ex_webserver.name}-asg"

  min_size         = 1
  desired_capacity = 2
  max_size         = 4

  health_check_type = "ELB"
  load_balancers = [ aws_elb.ex_frontend.id ]

  launch_configuration = aws_launch_configuration.ex_webserver.name

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  metrics_granularity = "1Minute"

  vpc_zone_identifier = [
    aws_subnet.ex_public_apse2a.id,
    aws_subnet.ex_public_apse2b.id
  ]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "example webserver"
    propagate_at_launch = true
  }
}

########

output "elb_dns_name" {
  value = aws_elb.ex_frontend.dns_name
}

