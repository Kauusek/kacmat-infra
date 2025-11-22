resource "random_password" "app_secret" {
  length  = 64
  special = false
}

resource "random_password" "db_pass" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "app_secret" {
  name        = "/kacmat/app/APP_SECRET"
  description = "Flask secret key for sessions"
  type        = "SecureString"
  value       = random_password.app_secret.result
}

resource "aws_ssm_parameter" "db_pass" {
  name        = "/kacmat/app/DB_PASS"
  description = "DB password"
  type        = "SecureString"
  value       = random_password.db_pass.result
}

# DODANO: Nowy parametr SSM dla hasła admina w panelu webowym
resource "aws_ssm_parameter" "admin_pass" {
  name        = "/kacmat/app/ADMIN_PASS"
  description = "Initial admin user password (generated)"
  type        = "SecureString"
  value       = random_password.db_pass.result # Używamy tego samego generatora
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/kacmat/app/DB_USER"
  type  = "String"
  value = "kacmat"
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/kacmat/app/DB_NAME"
  type  = "String"
  value = "kacmatdb"
}