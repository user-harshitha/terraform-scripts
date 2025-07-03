# ------------------------- VARIABLES.TF -------------------------

variable "ami_id" {
  description = "Ubuntu 22.04 AMI ID"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the instance"
  type = string
}

variable "subnet_id" {
  description = "Subnet ID for the instance"
  type        = string
}

variable "key_pair" {
  description = "SSH key pair name"
  type        = string
}

variable "perdix_url" {
  description = "Perdix URL"
  type = string
}

variable "env" {
  description = "Environment"
  type = string
}

variable "route53_zone_id" {
  description = "Route53 Zone ID"
  type = string
}

variable "alb_https_listener_arn" {
  type = string
}

variable "base_volume_id_app" {
  description = "Volume ID of base server's /app volume"
  type        = string
}

variable "base_volume_id_appdata" {
  description = "Volume ID of base server's /appdata volume"
  type        = string
}

variable "base_volume_id_database" {
  description = "Volume ID of base server's /database volume"
  type        = string
}

variable "availability_zone" {
  description = "AZ where volumes will be created"
  type        = string
}

variable "ebs_volume_tags" {
  description = "Tags to assign to the EBS volumes"
  type        = map(string)
}

variable "instance_tags" {
    type = map(string)
}

variable "existing_server_instance_id" {
  type = string
}

variable "deregister_old_targets" {
  description = "Whether to deregister old targets"
  type        = bool
  default     = false
}

# ------------------------- MAIN.TF (OPTIMIZED) -------------------------

# Providers.tf
# Configure AWS provider directly in this environment
provider "aws" {
  region = "ap-south-1"  # Explicit region for this environment
}

# Add these data sources to fetch existing instance details
data "aws_instance" "existing" {
  instance_id = var.existing_server_instance_id
}

# Create snapshots of base server volumes
resource "aws_ebs_snapshot" "app" {
  volume_id   = var.base_volume_id_app     
  description = "Snapshot of /app volume"
  timeouts {
    create = "5h"
    delete = "5h"
  }  
  tags = {Name = "${var.instance_tags.Name}-app-snapshot"}
}

resource "aws_ebs_snapshot" "appdata" {
  volume_id   = var.base_volume_id_appdata      
  description = "Snapshot of /appdata volume"
  timeouts {
    create = "5h"
    delete = "5h"
  }
  tags = {Name = "${var.instance_tags.Name}-appdata-snapshot"}
}

resource "aws_ebs_snapshot" "database" {
  volume_id   = var.base_volume_id_database     
  description = "Snapshot of /database volume"
  timeouts {
    create = "5h"
    delete = "5h"
  }
  tags = {Name = "${var.instance_tags.Name}-database-snapshot"}
}


# Create volumes from snapshots (standard/magnetic type)
resource "aws_ebs_volume" "app" {
  snapshot_id = aws_ebs_snapshot.app.id
  availability_zone = var.availability_zone
  # Size is NOT specified - inherits from snapshot!
  type              = "standard"  # Magnetic
  tags = merge(var.ebs_volume_tags, {
    VolumeType = "PerdixApp"
  })
}

resource "aws_ebs_volume" "appdata" {
  snapshot_id = aws_ebs_snapshot.appdata.id
  availability_zone = var.availability_zone
  type              = "standard"
  tags = merge(var.ebs_volume_tags, {
      VolumeType = "PerdixAppData"
    })
}

resource "aws_ebs_volume" "database" {
  snapshot_id = aws_ebs_snapshot.database.id
  availability_zone = var.availability_zone
  type              = "standard"
  tags = merge(var.ebs_volume_tags, {
      VolumeType = "PerdixDatabase"
    })
}

# EC2 Instance
resource "aws_instance" "server" {
  ami                    = var.ami_id
  instance_type          = data.aws_instance.existing.instance_type
  subnet_id              = var.subnet_id
  ebs_optimized = true
  vpc_security_group_ids = data.aws_instance.existing.vpc_security_group_ids
  key_name               = var.key_pair
  disable_api_termination = true
  user_data              = file("./setup.sh")

  # Disable public IP
  #associate_public_ip_address = true
  root_block_device {
    volume_size = 15
    volume_type = "standard"
    tags        = merge(var.ebs_volume_tags, { VolumeType = "Root" })
  }

  tags = var.instance_tags
}

# Attach volumes to the instance
resource "aws_volume_attachment" "app" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.app.id
  instance_id = aws_instance.server.id
}

resource "time_sleep" "wait_30_seconds_after_app" {
  depends_on = [aws_volume_attachment.app]
  
  create_duration = "30s"
}

resource "aws_volume_attachment" "appdata" {
  device_name = "/dev/sdg"
  volume_id   = aws_ebs_volume.appdata.id
  instance_id = aws_instance.server.id
  depends_on = [time_sleep.wait_30_seconds_after_app]
}

resource "time_sleep" "wait_30_seconds_after_appdata" {
  depends_on = [aws_volume_attachment.appdata]
  
  create_duration = "30s"
}

resource "aws_volume_attachment" "database" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.database.id
  instance_id = aws_instance.server.id
  depends_on = [time_sleep.wait_30_seconds_after_appdata]
}


resource "time_sleep" "wait_30_seconds_after_database" {
  depends_on = [aws_volume_attachment.database]
  
  create_duration = "30s"
}

resource "null_resource" "update_r53_record" {
  depends_on = [aws_instance.server]

  provisioner "local-exec" {
    command = <<EOT
      aws route53 change-resource-record-sets \
        --hosted-zone-id ${var.route53_zone_id} \
        --change-batch '{
          "Changes": [{
            "Action": "UPSERT",
            "ResourceRecordSet": {
              "Name": "${var.instance_tags.DNS_Name}",
              "Type": "A",
              "TTL": 300,
              "ResourceRecords": [{"Value": "${aws_instance.server.private_ip}"}]
            }
          }]
        }'
    EOT
  }
}

# 3. Create new target group
resource "aws_lb_target_group" "target_group" {
  name        = "${var.env}-${var.instance_tags.BillableParty}-mmb-80tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/perdix-client"
    interval            = 60
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
  }
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = replace(var.instance_tags.Name, "/[^\\p{L}\\p{Z}\\p{N}_.:/=+\\-@]/", "")
  }
}

# 4. Attach new instance to target group
resource "aws_lb_target_group_attachment" "target_group" {
  target_group_arn = aws_lb_target_group.target_group.arn
  target_id        = aws_instance.server.id
  port             = 80
}
# ------------------------- OUTPUTS.TF -------------------------

output "instance_details" {
  description = "Detailed information about the EC2 instance"
  value = {
    id               = aws_instance.server.id
    ami              = aws_instance.server.ami
    instance_type    = aws_instance.server.instance_type
    private_ip       = aws_instance.server.private_ip
    public_ip        = aws_instance.server.public_ip
    key_name         = aws_instance.server.key_name
    availability_zone = aws_instance.server.availability_zone
    subnet_id        = aws_instance.server.subnet_id
    vpc_security_group_ids = aws_instance.server.vpc_security_group_ids
    tags             = aws_instance.server.tags
  }
}

output "attached_volumes_details" {
  description = "Details of attached EBS volumes"
  value = {
    app_volume = {
      id     = aws_ebs_volume.app.id
      size   = aws_ebs_volume.app.size
      type   = aws_ebs_volume.app.type
      device = aws_volume_attachment.app.device_name
    }
    appdata_volume = {
      id     = aws_ebs_volume.appdata.id
      size   = aws_ebs_volume.appdata.size
      type   = aws_ebs_volume.appdata.type
      device = aws_volume_attachment.appdata.device_name
    }
    database_volume = {
      id     = aws_ebs_volume.database.id
      size   = aws_ebs_volume.database.size
      type   = aws_ebs_volume.database.type
      device = aws_volume_attachment.database.device_name
    }
  }
}

output "target_group_info" {
  description = "Target group info"
  value = {
    arn     = aws_lb_target_group.target_group.arn
    name    = aws_lb_target_group.target_group.name
    port    = aws_lb_target_group.target_group.port
    vpc_id  = aws_lb_target_group.target_group.vpc_id
    target_type = aws_lb_target_group.target_group.target_type
  }
}



