resource "random_password" "app_secret" {
  length  = 64
  special = false
}

# POPRAWKA: Dodajemy zasób generujący hasło dla bazy danych
resource "random_password" "db_pass" {
  length  = 40
  special = false # Używamy false, aby uniknąć problemów ze znakami specjalnymi w URI bazy danych
}

locals {
  ssm_path_prefix = "/kacmat/app"
}

resource "aws_ssm_parameter" "app_secret" {
  name        = "${local.ssm_path_prefix}/APP_SECRET"
  description = "Flask secret key for sessions"
  type        = "SecureString"
  value       = random_password.app_secret.result
}

resource "aws_ssm_parameter" "db_pass" {
  name        = "${local.ssm_path_prefix}/DB_PASS"
  description = "DB password"
  type        = "SecureString"
  # POPRAWKA: Przechowujemy hasło wygenerowane przez Terraform, a nie zmienną
  value       = random_password.db_pass.result 
}

resource "aws_ssm_parameter" "db_user" {
  name  = "${local.ssm_path_prefix}/DB_USER"
  type  = "String"
  value = "kacmat"
}

resource "aws_ssm_parameter" "db_name" {
  name  = "${local.ssm_path_prefix}/DB_NAME"
  type  = "String"
  value = "kacmatdb"
}