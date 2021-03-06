# Specify the provider and access details
provider "aws" {
  region = "ap-southeast-1"
}

### Network

data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block = "10.200.0.0/16"
  tags {
    Name = "${var.tag_name}-vpc"
 }
}

resource "aws_subnet" "public" {
  count             = "${var.az_count}"
  cidr_block        = "${cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  vpc_id            = "${aws_vpc.main.id}"
  
  tags {
    Name = "${var.tag_name}-pub-subnet"
  }
}

resource "aws_subnet" "private" {
  count             = "${var.az_count}"
  cidr_block        = "${cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + var.az_count)}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  vpc_id            = "${aws_vpc.main.id}"
  
  tags {
    Name = "${var.tag_name}-priv-subnet"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"
  
  tags {
    Name = "${var.tag_name}-igw"
  }
}

resource "aws_eip" "nat_eip" {
  vpc      = true
  depends_on = ["aws_internet_gateway.gw"]
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = "${aws_eip.nat_eip.id}"
  subnet_id = "${element(aws_subnet.public.*.id, 0)}"
  depends_on = ["aws_internet_gateway.gw"]
}

resource "aws_route_table" "r" {
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }
}

resource "aws_default_route_table" "main" {
  default_route_table_id = "${aws_vpc.main.default_route_table_id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_nat_gateway.nat_gw.id}"
  }
  
  tags {
    Name = "${var.tag_name}-rt"
  }
}

resource "aws_route_table_association" "a" {
  count          = "${var.az_count}"
  subnet_id      = "${element(aws_subnet.public.*.id, count.index)}"
  route_table_id = "${aws_route_table.r.id}"
}

resource "aws_route_table_association" "prta" {
  count          = "${var.az_count}"
  subnet_id      = "${element(aws_subnet.private.*.id, count.index, )}"
  route_table_id = "${aws_vpc.main.main_route_table_id}"
}

### Security

resource "aws_security_group" "lb_sg" {
  description = "controls access to the application LB"

  vpc_id = "${aws_vpc.main.id}"
  name   = "${var.tag_name}-lbsg"

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}

resource "aws_security_group" "ecs_instance_sg" {
  description = "controls direct access to application instances"
  vpc_id      = "${aws_vpc.main.id}"
  name        = "${var.tag_name}-instsg"

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [
      "${aws_vpc.main.cidr_block}",
    ]
  }
  
  ingress {
    protocol  = "-1"
    from_port = 0
    to_port   = 0
    cidr_blocks = [
      "${aws_vpc.main.cidr_block}",
    ]
  }
  
  ingress {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

### Compute

resource "aws_autoscaling_group" "app" {
  name                 = "${var.tag_name}-asg"
  vpc_zone_identifier  = ["${aws_subnet.public.*.id}"]
  min_size             = "${var.asg_min}"
  max_size             = "${var.asg_max}"
  desired_capacity     = "${var.asg_desired}"
  launch_configuration = "${aws_launch_configuration.app.name}"
}

data "template_file" "user_data" {
  template = "${file("${path.module}/user_data")}"
  vars {
    ecs_cluster_name   = "${aws_ecs_cluster.main.name}"
  }
}

data "aws_ami" "ecs_optimized" {
  most_recent = true

  filter {
    name   = "name"
    values = ["*ecs-optimized"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["591542846629"] # AMZN
}

resource "aws_launch_configuration" "app" {
  security_groups = [
    "${aws_security_group.ecs_instance_sg.id}",
  ]

  key_name                    = "${var.key_name}"
  image_id                    = "${data.aws_ami.ecs_optimized.id}"
  instance_type               = "t2.medium"
  iam_instance_profile        = "${aws_iam_instance_profile.app.name}"
  user_data                   = "${data.template_file.user_data.rendered}"
  associate_public_ip_address = true

  lifecycle {
    create_before_destroy = true
  }
}

## ECS

resource "aws_ecs_cluster" "main" {
  name = "${var.tag_name}-cluster"
}

data "template_file" "task_definition" {
  template = "${file("${path.module}/wp-task-definition.json")}"

  vars {
    wordpress_image_url        = "wordpress:latest"
    wordpress_container_name   = "${var.tag_name}-wp"
    wordpress_password   = "${var.wordpress_password}"
    telegraf_image_url        = "kcfigaro/fast-telegraf:latest"
    telegraf_container_name   = "${var.tag_name}-telegraf"
    mariadb_server_ip        = "${aws_instance.grab_database_master.private_ip}"
    influxdb_server_ip        = "${aws_instance.grab_monitor_server.private_ip}"
    log_group_region = "${var.aws_region}"
    log_group_name   = "${aws_cloudwatch_log_group.app.name}"
  }
}

resource "aws_ecs_task_definition" "grab-wordpress-td" {
  family                = "${var.tag_name}-td"
  container_definitions = "${data.template_file.task_definition.rendered}"
  
  volume {
    name      = "dockersocket"
    host_path = "/var/run/docker.sock"
  }
  
  cpu                   = "512"
  memory                = "1024"
}

resource "aws_ecs_service" "grab-service" {
  name            = "${var.tag_name}-service"
  cluster         = "${aws_ecs_cluster.main.id}"
  task_definition = "${aws_ecs_task_definition.grab-wordpress-td.arn}"
  desired_count   = 2
  iam_role        = "${aws_iam_role.ecs_service.name}"
  deployment_minimum_healthy_percent   =  50
  deployment_maximum_percent   =  200

  load_balancer {
    target_group_arn = "${aws_alb_target_group.grab-alb-tg.id}"
    container_name   = "${var.tag_name}-wp"
    container_port   = "80"
  }

  depends_on = [
    "aws_iam_role_policy.ecs_service",
    "aws_alb_listener.front_end",
  ]
}

## SALTMASTER

resource "aws_security_group" "salt_sg" {
  description = "controls access to the application server"
  vpc_id      = "${aws_vpc.main.id}"
  name   = "${var.tag_name}-salt-sg"

  ingress {
    protocol  = "tcp"
    from_port = 0
    to_port   = 65535

    cidr_blocks = [
      "${aws_vpc.main.cidr_block}",
    ]
  }
  
  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = [
      "${var.admin_cidr_ingress}",
    ]
  }
}

data "template_file" "salt_master_user_data" {
  template = "${file("${path.module}/salt_master_user_data")}"
  vars {
    service_name   = "${var.service_name}"
  }
}

resource "aws_instance" "grab_salt_master" {
  vpc_security_group_ids = ["${aws_security_group.salt_sg.id}"]

  key_name                    = "${var.key_name}"
  ami                    = "ami-52d4802e"  #Ubuntu 16.04 64bit ap-southeast-1
  instance_type               = "t2.medium"
  associate_public_ip_address = true
  subnet_id = "${element(aws_subnet.public.*.id, 0)}"
  user_data                   = "${data.template_file.salt_master_user_data.rendered}"
  
  lifecycle {
    create_before_destroy = true
  }
  
  tags {
    Name = "${var.tag_name}-salt-master"
 }
}

## SALT MINION Userdata

data "template_file" "salt_minion_user_data" {
  template = "${file("${path.module}/salt_minion_user_data")}"
  vars {
    salt_master_ip   = "${aws_instance.grab_salt_master.private_ip}"
  }
}

## MARIADB

resource "aws_security_group" "database_sg" {
  description = "controls access to the database server"
  vpc_id      = "${aws_vpc.main.id}"
  name   = "${var.tag_name}-db-sg"

  ingress {
    protocol  = "-1"
    from_port = 0
    to_port   = 0

    cidr_blocks = [
      "${aws_vpc.main.cidr_block}",
    ]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 3306
    to_port     = 3306
    cidr_blocks = [
      "${aws_vpc.main.cidr_block}",
    ]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}

resource "aws_instance" "grab_database_master" {
  vpc_security_group_ids = ["${aws_security_group.database_sg.id}"]

  key_name                    = "${var.key_name}"
  ami                    = "ami-52d4802e"  #Ubuntu 16.04 64bit ap-southeast-1
  instance_type               = "t2.medium"
  associate_public_ip_address = false
  subnet_id = "${element(aws_subnet.private.*.id, 1)}"
  user_data                   = "${data.template_file.salt_minion_user_data.rendered}"
  
  lifecycle {
    create_before_destroy = true
  }
  
  tags {
    Name = "${var.tag_name}-db-m"
  }
  
  depends_on = ["aws_nat_gateway.nat_gw"]
}

resource "aws_instance" "grab_database_slave" {
  vpc_security_group_ids = ["${aws_security_group.database_sg.id}"]

  key_name                    = "${var.key_name}"
  ami                    = "ami-52d4802e"  #Ubuntu 16.04 64bit ap-southeast-1
  instance_type               = "t2.medium"
  associate_public_ip_address = false
  subnet_id = "${element(aws_subnet.private.*.id, 2)}"
  user_data                   = "${data.template_file.salt_minion_user_data.rendered}"
  
  lifecycle {
    create_before_destroy = true
  }
  
  tags {
    Name = "${var.tag_name}-db-s"
  }
  
  depends_on = ["aws_nat_gateway.nat_gw"]
}

## INFLUX, GRAFANA

resource "aws_security_group" "monitor_sg" {
  description = "controls access to the application server"
  vpc_id      = "${aws_vpc.main.id}"
  name   = "${var.tag_name}-monitor-sg"

  ingress {
    protocol  = "-1"
    from_port = 0
    to_port   = 0

    cidr_blocks = [
      "${aws_vpc.main.cidr_block}",
    ]
  }
  
  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [
      "${var.admin_cidr_ingress}",
    ]
  }
  
  ingress {
    protocol    = "tcp"
    from_port   = 3000
    to_port     = 3000
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}

resource "aws_instance" "grab_monitor_server" {
  vpc_security_group_ids = ["${aws_security_group.monitor_sg.id}"]

  key_name                    = "${var.key_name}"
  ami                    = "ami-52d4802e"  #Ubuntu 16.04 64bit ap-southeast-1
  instance_type               = "t2.medium"
  associate_public_ip_address = true
  subnet_id = "${element(aws_subnet.public.*.id, 1)}"
  user_data                   = "${data.template_file.salt_minion_user_data.rendered}"
  
  lifecycle {
    create_before_destroy = true
  }
  
  tags {
    Name = "${var.tag_name}-monitor"
 }
}

## IAM

resource "aws_iam_role" "ecs_service" {
  name = "${var.tag_name}-ecs-role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "ecs_service" {
  name = "${var.tag_name}-ecs-policy"
  role = "${aws_iam_role.ecs_service.name}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:Describe*",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:RegisterTargets"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.tag_name}-instprofile"
  role = "${aws_iam_role.app_instance.name}"
}

resource "aws_iam_role" "app_instance" {
  name = "${var.tag_name}-instance-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

data "template_file" "instance_profile" {
  template = "${file("${path.module}/instance-profile-policy.json")}"

  vars {
    app_log_group_arn = "${aws_cloudwatch_log_group.app.arn}"
    ecs_log_group_arn = "${aws_cloudwatch_log_group.ecs.arn}"
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.tag_name}-instprofile"
  role   = "${aws_iam_role.app_instance.name}"
  policy = "${data.template_file.instance_profile.rendered}"
}

## ALB

resource "aws_alb_target_group" "grab-alb-tg" {
  name     = "${var.tag_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${aws_vpc.main.id}"
  
  health_check = {
    protocol = "HTTP"
    path     = "/wp-admin/install.php"
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

resource "aws_alb" "main" {
  name            = "${var.tag_name}-alb"
  subnets         = ["${aws_subnet.public.*.id}"]
  security_groups = ["${aws_security_group.lb_sg.id}"]
}

resource "aws_alb_listener" "front_end" {
  load_balancer_arn = "${aws_alb.main.id}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.grab-alb-tg.id}"
    type             = "forward"
  }
}

## CloudWatch Logs

resource "aws_cloudwatch_log_group" "ecs" {
  name = "${var.tag_name}-ecs-group/ecs-agent"
}

resource "aws_cloudwatch_log_group" "app" {
  name = "${var.tag_name}-ecs-group/${var.tag_name}"
}
