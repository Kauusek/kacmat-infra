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
  engine_version    = "15.13" # Używasz 15.13, upewnij się, że to poprawna wersja
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_encrypted = true
  # name (dbname) jest teraz pobierane z SSM przez aplikację
  username                = aws_ssm_parameter.db_user.value # Pobieramy nazwę użytkownika z SSM
  
  # POPRAWKA: Hasło jest teraz pobierane z zasobu random_password.
  # Gwarantuje to, że hasło nigdy nie jest zapisane w kodzie.
  password                = random_password.db_pass.result 

  db_subnet_group_name    = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true
  publicly_accessible     = false
  multi_az                = false
  backup_retention_period = 1 # Ustaw na 0, jeśli to tylko dev, lub 7+ dla prod

  tags = {
    Name = "${var.project_name}-rds"
  }
}