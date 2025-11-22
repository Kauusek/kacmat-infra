# Plik: asg.tf (Poprawiony)

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = "ami-04e601abe3e1a910f"
  instance_type = "t3.micro"
  key_name      = aws_key_pair.this.key_name
  description   = "kacmat-app"

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2_sg.id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        instance_interruption_behavior = "terminate"
      }
    }
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tmpl", {
    repo_url        = "https://github.com/Kauusek/kacmat-infra.git"
    db_host         = aws_db_instance.rds.address
    db_name         = "kacmatdb"
    db_user         = "kacmat"
    app_dir         = "/home/app/kacmat-infra"
    AWS_REGION      = data.aws_region.current.name
    rollout_trigger = timestamp()
    APP_SECRET      = random_password.app_secret.result
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-ec2"
    }
  }
}


resource "aws_autoscaling_group" "app_asg" {
  name                = "${var.project_name}-asg"
  min_size            = 2
  max_size            = 2
  desired_capacity    = 2
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  target_group_arns = [aws_lb_target_group.tg.arn]

   enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  # DODANO JAWNY TAG WYMUSZAJĄCY ROLLOUT
  tag {
    key                 = "Name"
    value               = "${var.project_name}-ec2"
    propagate_at_launch = true
  }

  # DODAJEMY TAG Z WERSJĄ LT DO ZASOBU ASG
  tag {
    key                 = "LaunchTemplateVersion"
    value               = aws_launch_template.app.latest_version # KLUCZOWA ZMIANA
    propagate_at_launch = false                                  # Nie potrzebujemy tego taga na instancji, tylko na zasobie ASG
  }


  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
    # To jest teraz zbyteczne (ostrzeżenie w logu), ale nie szkodzi.
    triggers = ["launch_template"]
  }

  lifecycle {
    create_before_destroy = true
  }
}