locals {
  # Użycie .id zamiast .name, aby usunąć ostrzeżenie o deprecacji
  alb_logs_bucket_name = "${var.project_name}-alb-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.id}"
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = local.alb_logs_bucket_name
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  depends_on = [aws_s3_bucket.alb_logs]
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  depends_on = [aws_s3_bucket.alb_logs]
  rule {
    # Wymuszamy własność Bucketa i wyłączamy ACLs (Best Practice)
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  depends_on = [aws_s3_bucket.alb_logs]
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  depends_on = [aws_s3_bucket.alb_logs]
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# (opcjonalnie) retencja
resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  depends_on = [aws_s3_bucket.alb_logs]
  rule {
    id     = "expire-logs-90d"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
  }
}

# Polityka bucketa: nowe, zalecane service principals
data "aws_iam_policy_document" "alb_logs_bucket_policy" {
  statement {
    sid    = "AWSLogsBucketPerms"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.alb_logs.arn]
  }

  # AWS Logs / VPC Flow Logs – zapis obiektów
  statement {
    sid    = "AWSLogsWriteObjects"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    # ZMIANA: Dodano ścieżkę z prefiksem vpc-flow-logs oraz fallback
    resources = [
      "${aws_s3_bucket.alb_logs.arn}/vpc-flow-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
      "${aws_s3_bucket.alb_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # ALB access logs – zapis obiektów
  statement {
    sid    = "ALBLogDeliveryWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["elasticloadbalancing.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    # ZMIANA: Dodano ścieżkę z prefiksem alb oraz fallback
    resources = [
      "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
      "${aws_s3_bucket.alb_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  # VPC Flow Logs
  statement {
    sid    = "VPCFlowLogsWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    # ZMIANA: Dodano ścieżkę z prefiksem vpc-flow-logs oraz fallback
    resources = [
      "${aws_s3_bucket.alb_logs.arn}/vpc-flow-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
      "${aws_s3_bucket.alb_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  depends_on = [
    aws_s3_bucket_ownership_controls.alb_logs,
    aws_s3_bucket_public_access_block.alb_logs,
  ]
  policy = data.aws_iam_policy_document.alb_logs_bucket_policy.json
}