output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnets" {
  value = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "private_subnets" {
  value = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "rds_endpoint" {
  value = aws_db_instance.rds.endpoint
}

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}