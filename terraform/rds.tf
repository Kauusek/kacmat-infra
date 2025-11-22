resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "${var.project_name}-rds-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = {
    Name = "${var.project_name}-rds-subnet-group"
  }
}

resource "aws_db_instance" "rds" {
  identifier        = "${var.project_name}-rds"
  engine            = "postgres"
  engine_version    = "15.13"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_encrypted = true

  username = aws_ssm_parameter.db_user.value
  password = aws_ssm_parameter.db_pass.value

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot     = true
  publicly_accessible     = false
  multi_az                = false
  backup_retention_period = 1

  tags = {
    Name = "${var.project_name}-rds"
  }

  depends_on = [aws_ssm_parameter.db_pass]
}
