output "ecs_name" {
  value = "${aws_ecs_cluster.main.name}"
}

output "monitoring_url" {
  value = "http://${aws_instance.grab_monitor_server.public_ip}:3000"
}

output "alb_url" {
  value = "http://${aws_alb.main.dns_name}"
}

output "salt_master_server_ip" {
  value = "${aws_instance.grab_salt_master.public_ip}"
}

output "monitoring_server_ip" {
  value = "${aws_instance.grab_monitor_server.public_ip}"
}

output "db_master_private_ip" {
  value = "${aws_instance.grab_database_master.private_ip}"
}

output "db_slave_private_ip" {
  value = "${aws_instance.grab_database_slave.private_ip}"
}

output "salt_master_log_in" {
  value = "ssh -i ~/environment/${var.key_name}.pem ubuntu@${aws_instance.grab_salt_master.public_ip}"
}

output "update_slatstack_pillar1" {
  value = "sed -i 's/node01_ip/${aws_instance.grab_database_master.private_ip}/g' /srv/pillar/service/${var.service_name}/mariadb.sls"
}

output "update_slatstack_pillar2" {
  value = "sed -i 's/node02_ip/${aws_instance.grab_database_slave.private_ip}/g' /srv/pillar/service/${var.service_name}/mariadb.sls"
}