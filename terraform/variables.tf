variable "aws_region" {
  default = "eu-central-1"
}

variable "aws_profile" {
  default = "default"
}

variable "project_name" {
  default = "kacmat-app"
}

variable "ec2_key_pair" {
  description = "Nazwa istniejącej pary kluczy SSH w AWS"
  type        = string
}

variable "alert_email" {
  description = "Adres email do powiadomień SNS/CloudWatch"
  type        = string
  default     = "kacperkalusek@gmail.com" # ustaw w tfvars lub tutaj
}

variable "use_spot" {
  description = "Czy używać instancji Spot"
  type        = bool
  default     = true
}

variable "spot_max_price" {
  description = "Maksymalna cena Spot (opcjonalnie). Pusta = bez limitu"
  type        = string
  default     = "" # przykład: "0.04"
}
