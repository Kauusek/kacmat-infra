# Plik: iam.tf

resource "aws_iam_role" "ecs_instance_role" {
  name = "${var.project_name}-ec2-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ecs_instance_role.name
}

data "aws_iam_policy_document" "ec2_ssm_read" {
  statement {
    sid = "ReadAppParameters"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath"
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/kacmat/app/*"
    ]
  }
}

resource "aws_iam_policy" "ec2_ssm_read" {
  name        = "${var.project_name}-ec2-ssm-read"
  description = "EC2 can read app params from SSM"
  policy      = data.aws_iam_policy_document.ec2_ssm_read.json
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_read_attach" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = aws_iam_policy.ec2_ssm_read.arn
}

