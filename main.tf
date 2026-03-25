terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "sa-east-1"
  # Credenciales via variables de entorno:
  # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
}

# ─── AMI: Ubuntu 22.04 LTS en sa-east-1 ──────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── Red ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "odoo_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "odoo-vpc"
  }
}

resource "aws_internet_gateway" "odoo_igw" {
  vpc_id = aws_vpc.odoo_vpc.id

  tags = {
    Name = "odoo-igw"
  }
}

resource "aws_subnet" "odoo_subnet" {
  vpc_id                  = aws_vpc.odoo_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "sa-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "odoo-subnet"
  }
}

resource "aws_route_table" "odoo_rt" {
  vpc_id = aws_vpc.odoo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.odoo_igw.id
  }

  tags = {
    Name = "odoo-rt"
  }
}

resource "aws_route_table_association" "odoo_rta" {
  subnet_id      = aws_subnet.odoo_subnet.id
  route_table_id = aws_route_table.odoo_rt.id
}

resource "aws_security_group" "odoo_sg" {
  name        = "odoo-sg"
  description = "Permite trafico a Odoo y SSH"
  vpc_id      = aws_vpc.odoo_vpc.id

  ingress {
    from_port   = 8069
    to_port     = 8069
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "odoo-sg"
  }
}

# ─── Key Pair ─────────────────────────────────────────────────────────────────

resource "aws_key_pair" "odoo_key" {
  key_name   = "odoo-key"
  public_key = file("${path.module}/odoo-key.pub")
}

# ─── EC2 ──────────────────────────────────────────────────────────────────────

resource "aws_instance" "odoo" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3a.medium"
  subnet_id              = aws_subnet.odoo_subnet.id
  vpc_security_group_ids = [aws_security_group.odoo_sg.id]
  key_name               = aws_key_pair.odoo_key.key_name

  user_data = <<EOF
#!/bin/bash
set -e

# Instalar Docker y Docker Compose
apt-get update -y
apt-get install -y docker.io docker-compose
systemctl start docker
systemctl enable docker

# Crear estructura de directorios
mkdir -p /opt/odoo/config
mkdir -p /opt/odoo/addons

# Dockerfile.db
cat > /opt/odoo/Dockerfile.db <<'DOCKERFILE'
FROM postgres:15
RUN apt-get update \
    && apt-get install -y tzdata tzdata-legacy \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE

# Configuracion de Odoo
cat > /opt/odoo/config/odoo.conf <<'CONF'
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
admin_passwd = admin123
db_host = db
db_port = 5432
db_user = odoo
db_password = odoo_pass
CONF

# Docker Compose
cat > /opt/odoo/docker-compose.yml <<'COMPOSE'
services:
  db:
    build:
      context: .
      dockerfile: Dockerfile.db
    restart: unless-stopped
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: odoo_pass
    volumes:
      - odoo-db-data:/var/lib/postgresql/data

  web:
    image: odoo:17.0
    restart: unless-stopped
    depends_on:
      - db
    ports:
      - "8069:8069"
    environment:
      HOST: db
      USER: odoo
      PASSWORD: odoo_pass
    volumes:
      - odoo-web-data:/var/lib/odoo
      - ./config:/etc/odoo
      - ./addons:/mnt/extra-addons

volumes:
  odoo-db-data:
  odoo-web-data:
COMPOSE

# Levantar servicios
cd /opt/odoo
docker-compose up -d
EOF

  tags = {
    Name = "odoo-server"
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.odoo.id
}

output "odoo_url" {
  description = "URL para acceder a Odoo"
  value       = "http://${aws_instance.odoo.public_ip}:8069"
}

output "ssh_command" {
  description = "Comando para conectarse via SSH"
  value       = "ssh -i odoo-key ubuntu@${aws_instance.odoo.public_ip}"
}
