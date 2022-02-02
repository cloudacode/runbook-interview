variable "aws_region" {
  description = "region"
  default     = "ap-southeast-1"
}

variable "instance_count" {
  description = "Number of instance"
  default     = "2"
}

variable "az_count" {
  description = "Number of AZs to cover in a given AWS region"
  default     = "2"
}

variable "tag_name" {
  description = "AWS resource tag Name"
}

variable "service_name" {
  description = "AWS resource tag Service name"
  default     = "grab_kc"
}

variable "key_name" {
  description = "Name of AWS key pair"
  default = "grab-kc-key"
}

variable "asg_min" {
  description = "Min numbers of servers in ASG"
  default     = "2"
}

variable "asg_max" {
  description = "Max numbers of servers in ASG"
  default     = "3"
}

variable "asg_desired" {
  description = "Desired numbers of servers in ASG"
  default     = "2"
}

variable "admin_cidr_ingress" {
  description = "CIDR to allow tcp/22 ingress to EC2 instance"
  default     = "0.0.0.0/0"
}

variable "wordpress_password" {
  description = "Password of wordpress database"
  default = "wordpress"
}