
# Create a  VPC
resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "igw_playground" {
  vpc_id = aws_vpc.main_vpc.id
}

resource "aws_route_table" "rtb_public_playground" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw_playground.id
  }
}

resource "aws_network_acl" "test_acl" {
  vpc_id = aws_vpc.main_vpc.id
}

resource "aws_network_acl_rule" "test" {
  network_acl_id = aws_network_acl.test_acl.id
  rule_number    = 200
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = aws_vpc.main_vpc.cidr_block
  from_port      = 22
  to_port        = 22
}

resource "aws_route_table_association" "rta_subnet_public_playground" {
  subnet_id      = aws_subnet.subnet_public_playground.id
  route_table_id = aws_route_table.rtb_public_playground.id
}

# Create a public IP enabled subnet
resource "aws_subnet" "subnet_public_playground" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = "true"

}


resource "aws_elb" "webapp_elb" {
  name                      = "not-secured"
  subnets                   = [aws_subnet.subnet_public_playground.id]
  security_groups           = [aws_security_group.http_security.id]
  cross_zone_load_balancing = true

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    target              = "HTTP:80/"
  }
  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }
}

# Create a private subnet
resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false
}

resource "aws_ebs_volume" "webapp_ebs" {
  availability_zone = "ap-south-1b"
  size              = 8

}

resource "aws_ebs_snapshot" "webapp_ebs_snapshot" {
  volume_id = aws_ebs_volume.webapp_ebs.id

  tags = {
    Name = "HelloWorld_snap"
  }
}
resource "aws_ami" "vmimage" {
  name                = "vmimage"
  virtualization_type = "hvm"
  root_device_name    = "/dev/xvda"

  ebs_block_device {
    device_name = "/dev/xvda"
    snapshot_id = aws_ebs_snapshot.webapp_ebs_snapshot.id
    volume_size = 8
  }
}


variable "ec2_device_names" {
  default = [
    "/dev/sdd1",
    "/dev/xvda"
  ]
}


resource "aws_instance" "ec2" {
  ami           = aws_ami.vmimage.id
  count         = 2
  instance_type = "t3.medium"
  subnet_id     = aws_subnet.private_subnet.id
}



resource "aws_security_group" "http_security" {
  name   = "allow http"
  vpc_id = aws_vpc.main_vpc.id

  # access from anywhere
  ingress {
    to_port     = 80
    from_port   = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_configuration" "agent-lc" {
  name_prefix                 = "agent-lc-"
  image_id                    = "ami-06a0b4e3b7eb7a300"
  instance_type               = "t2.micro"
  security_groups             = [aws_security_group.http_security.id]
  associate_public_ip_address = true
  user_data                   = <<-EOF
                  #!/bin/bash
                  mount /dev/xvda /var/log
                  yum -y install httpd
                  echo "<p> My Instance! </p>" >> /var/www/html/index.html
                  sudo systemctl enable httpd
                  sudo systemctl start httpd
                  EOF

  lifecycle {
    create_before_destroy = true
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = "50"
    encrypted   = true
  }
}
resource "aws_launch_template" "example" {
  name_prefix   = "example"
  image_id      = aws_ami.vmimage.id
  instance_type = "c5.large"
}


resource "aws_autoscaling_group" "agent" {
  availability_zones = ["us-east-1a"]
  desired_capacity   = 2
  max_size           = 5
  min_size           = 1
  health_check_type  = "EC2"
  force_delete       = true

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 25
      spot_allocation_strategy                 = "capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.example.id
      }
    }
  }
}
resource "aws_autoscaling_policy" "agents-scale-up" {
  name                   = "agents-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.agent.name
}

resource "aws_autoscaling_policy" "agents-scale-down" {
  name                   = "agents-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.agent.name
}

resource "aws_cloudwatch_metric_alarm" "memory-high" {
  alarm_name          = "mem-util-high-agents"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "MemoryUtilization"
  namespace           = "System/Linux"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 memory for high utilization on agent hosts"
  alarm_actions = [
    "${aws_autoscaling_policy.agents-scale-up.arn}"
  ]
  dimensions = {
    AutoScalingGroupName = "${aws_autoscaling_group.agent.name}"
  }
}

resource "aws_cloudwatch_metric_alarm" "memory-low" {
  alarm_name          = "mem-util-low-agents"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "MemoryUtilization"
  namespace           = "System/Linux"
  period              = "300"
  statistic           = "Average"
  threshold           = "40"
  alarm_description   = "This metric monitors ec2 memory for low utilization on agent hosts"
  alarm_actions = [
    "${aws_autoscaling_policy.agents-scale-down.arn}"
  ]
  dimensions = {
    AutoScalingGroupName = "${aws_autoscaling_group.agent.name}"
  }
}
