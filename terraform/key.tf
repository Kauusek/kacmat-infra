variable "ssh_public_key_path" {
  description = "Ścieżka do lokalnego pliku ssh .pub"
  type        = string
  default     = "./kacmat.pub" # podmień, jeśli masz inny
}

resource "aws_key_pair" "this" {
  key_name   = var.ec2_key_pair # np. "kacmat"
  public_key = file(var.ssh_public_key_path)
}

# w launch template użyj nazwy utworzonej pary
# (podmień w aws_launch_template.app)
# key_name = aws_key_pair.this.key_name
