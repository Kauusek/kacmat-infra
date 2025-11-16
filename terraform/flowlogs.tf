resource "aws_flow_log" "vpc_to_s3" {
  log_destination_type = "s3"
  # Używamy tylko ARN Bucketa + prefiks, który nie koliduje z AWSLogs/
  # AWS doda: <bucket-arn>/AWSLogs/<account-id>/vpcflowlogs/<region>/...
  log_destination = "${aws_s3_bucket.alb_logs.arn}/vpc-flow-logs"
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id

  # Opcjonalnie, bardziej szczegółowy format:
  # flowlogs.tf - Poprawiony log_format
  # Zmieniono ${...} na $${...}
  log_format = (join(" ", [
    "$${version}", "$${account-id}", "$${interface-id}", "$${srcaddr}", "$${dstaddr}",
    "$${srcport}", "$${dstport}", "$${protocol}", "$${packets}", "$${bytes}",
    "$${start}", "$${end}", "$${action}", "$${log-status}", "$${vpc-id}", "$${subnet-id}", "$${instance-id}"
  ]))
}