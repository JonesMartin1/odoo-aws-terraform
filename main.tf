# ─────────────────────────────────────────────────────────────────────────────
# BLOQUE TERRAFORM
# Acá le decimos a Terraform qué "plugins" (providers) necesita descargar.
# En este caso usamos el provider de AWS, versión 5.x.
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws" # Descarga el plugin oficial de AWS
      version = "~> 5.0"        # Usa cualquier versión 5.x (ej: 5.1, 5.20, etc.)
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# PROVEEDOR AWS
# Le indica a Terraform en qué región de AWS trabajar.
# Las credenciales (usuario y contraseña de AWS) NO van acá — se pasan
# como variables de entorno para no exponerlas en el código:
#   AWS_ACCESS_KEY_ID      → el "usuario"
#   AWS_SECRET_ACCESS_KEY  → la "contraseña"
# ─────────────────────────────────────────────────────────────────────────────
provider "aws" {
  region = "sa-east-1" # Región: São Paulo, Brasil (la más cercana a Argentina)
}

# ─────────────────────────────────────────────────────────────────────────────
# BÚSQUEDA DE AMI (imagen del sistema operativo)
# En AWS, las máquinas virtuales arrancan desde una "AMI" (Amazon Machine Image).
# En vez de hardcodear el ID de la imagen (que cambia con cada actualización),
# le pedimos a AWS que nos dé la más reciente de Ubuntu 22.04 LTS.
# ─────────────────────────────────────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true             # Queremos la versión más nueva disponible
  owners      = ["099720109477"] # ID oficial de Canonical (empresa que publica Ubuntu)

  # Filtro por nombre: busca imágenes de Ubuntu 22.04 (Jammy) de 64 bits
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  # Filtro por tipo de virtualización: HVM es el estándar moderno en AWS
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# RED VIRTUAL PRIVADA (VPC)
# Una VPC es como una "red privada propia" dentro de AWS.
# Todo lo que creemos (servidores, bases de datos, etc.) vivirá dentro de ella.
# El bloque CIDR define el rango de IPs disponibles: 10.0.0.0 → 10.0.255.255
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_vpc" "odoo_vpc" {
  cidr_block           = "10.0.0.0/16" # 65.536 IPs disponibles dentro de la VPC
  enable_dns_hostnames = true           # Permite usar nombres DNS en vez de solo IPs

  tags = {
    Name = "odoo-vpc" # Etiqueta para identificarla en la consola de AWS
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERNET GATEWAY (puerta de entrada a internet)
# Sin esto, la VPC está totalmente aislada del mundo exterior.
# El Internet Gateway es el "router" que conecta nuestra red privada con internet.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_internet_gateway" "odoo_igw" {
  vpc_id = aws_vpc.odoo_vpc.id # Lo asociamos a nuestra VPC

  tags = {
    Name = "odoo-igw"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# SUBRED (Subnet)
# Una subnet es una subdivisión de la VPC. Acá creamos una subred pública
# (con IPs visibles desde internet) dentro de la zona de disponibilidad "sa-east-1a".
# El bloque 10.0.1.0/24 da 256 IPs posibles (10.0.1.0 → 10.0.1.255).
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_subnet" "odoo_subnet" {
  vpc_id                  = aws_vpc.odoo_vpc.id  # Pertenece a nuestra VPC
  cidr_block              = "10.0.1.0/24"        # Rango de IPs de esta subred
  availability_zone       = "sa-east-1a"         # Zona física del datacenter en São Paulo
  map_public_ip_on_launch = true                 # Cada servidor que arranque acá recibe una IP pública

  tags = {
    Name = "odoo-subnet"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# TABLA DE RUTAS
# Define cómo se enrutan los paquetes de red dentro de la VPC.
# La regla "0.0.0.0/0" significa "todo el tráfico que no sea local
# salga por el Internet Gateway" → así los servidores tienen acceso a internet.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_route_table" "odoo_rt" {
  vpc_id = aws_vpc.odoo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"                      # Cualquier destino (internet)
    gateway_id = aws_internet_gateway.odoo_igw.id # Sale por el Internet Gateway
  }

  tags = {
    Name = "odoo-rt"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ASOCIACIÓN SUBRED ↔ TABLA DE RUTAS
# Conecta la tabla de rutas que creamos con la subred.
# Sin esto, la subred no sabe cómo enrutar el tráfico.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_route_table_association" "odoo_rta" {
  subnet_id      = aws_subnet.odoo_subnet.id
  route_table_id = aws_route_table.odoo_rt.id
}

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY GROUP (firewall)
# Un Security Group es un firewall virtual que controla qué tráfico
# puede entrar (ingress) y salir (egress) de nuestro servidor.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_security_group" "odoo_sg" {
  name        = "odoo-sg"
  description = "Permite trafico a Odoo y SSH"
  vpc_id      = aws_vpc.odoo_vpc.id

  # Regla de entrada: permite acceso a Odoo desde cualquier IP
  # Puerto 8069 es el puerto por defecto de Odoo
  ingress {
    from_port   = 8069
    to_port     = 8069
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Cualquier IP del mundo puede acceder
  }

  # Regla de entrada: permite SSH desde cualquier IP
  # Puerto 22 es el estándar para conexiones SSH (terminal remota)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Cualquier IP del mundo puede intentar conectarse
  }

  # Regla de salida: permite TODO el tráfico saliente
  # Sin esto el servidor no podría descargar paquetes, imágenes Docker, etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"           # -1 significa "todos los protocolos"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "odoo-sg"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# PAR DE CLAVES SSH
# Para conectarnos al servidor sin usar contraseña, usamos criptografía de clave
# pública/privada. Subimos la clave PÚBLICA a AWS (la que puede ver todo el mundo)
# y nos quedamos con la clave PRIVADA en nuestra máquina (nunca se comparte).
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_key_pair" "odoo_key" {
  key_name   = "odoo-key"                              # Nombre del par de claves en AWS
  public_key = file("${path.module}/odoo-key.pub")    # Lee la clave pública desde el archivo local
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTANCIA EC2 (el servidor virtual)
# EC2 es el servicio de máquinas virtuales de AWS.
# Acá creamos el servidor donde va a correr Odoo.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_instance" "odoo" {
  ami                    = data.aws_ami.ubuntu.id             # Usa la imagen de Ubuntu que buscamos arriba
  instance_type          = "t3.medium"                       # Tipo de servidor: 2 vCPU, 4 GB RAM
  subnet_id              = aws_subnet.odoo_subnet.id         # La pone dentro de nuestra subred
  vpc_security_group_ids = [aws_security_group.odoo_sg.id]   # Le aplica nuestro firewall
  key_name               = aws_key_pair.odoo_key.key_name    # Le asigna nuestro par de claves SSH

  # ───────────────────────────────────────────────────────────────────────────
  # USER DATA (script de arranque)
  # Este script bash se ejecuta automáticamente la PRIMERA VEZ que el servidor
  # enciende. Es como una "receta" de instalación automática.
  # ───────────────────────────────────────────────────────────────────────────
  user_data = <<EOF
#!/bin/bash
set -e  # Si cualquier comando falla, el script se detiene (evita errores silenciosos)

# ── Instalar Docker y Docker Compose ──────────────────────────────────────────
# Docker permite correr aplicaciones en contenedores (entornos aislados).
# Docker Compose orquesta múltiples contenedores como si fueran un solo sistema.
apt-get update -y
apt-get install -y docker.io docker-compose
systemctl start docker   # Inicia el servicio Docker ahora mismo
systemctl enable docker  # Hace que Docker arranque automáticamente al reiniciar

# ── Crear estructura de carpetas para Odoo ────────────────────────────────────
mkdir -p /opt/odoo/config  # Carpeta para el archivo de configuración de Odoo
mkdir -p /opt/odoo/addons  # Carpeta para módulos/extensiones personalizadas de Odoo

# ── Crear el Dockerfile para la base de datos ─────────────────────────────────
# Usamos una imagen personalizada de PostgreSQL 15 que incluye soporte de zonas
# horarias (tzdata), necesario para que Odoo maneje fechas correctamente.
cat > /opt/odoo/Dockerfile.db <<'DOCKERFILE'
FROM postgres:15
RUN apt-get update \
    && apt-get install -y tzdata tzdata-legacy \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE

# ── Crear el archivo de configuración de Odoo ─────────────────────────────────
# odoo.conf define parámetros básicos de funcionamiento de Odoo.
cat > /opt/odoo/config/odoo.conf <<'CONF'
[options]
addons_path = /mnt/extra-addons  # Carpeta donde buscar módulos adicionales
data_dir = /var/lib/odoo         # Carpeta donde Odoo guarda archivos (adjuntos, etc.)
admin_passwd = admin123          # Contraseña maestra del panel de administración de Odoo
db_host = db                     # Nombre del host de la base de datos (nombre del contenedor Docker)
db_port = 5432                   # Puerto estándar de PostgreSQL
db_user = odoo                   # Usuario de la base de datos
db_password = odoo_pass          # Contraseña de la base de datos
CONF

# ── Crear el archivo Docker Compose ───────────────────────────────────────────
# docker-compose.yml define los dos servicios que conforman nuestra app:
#   - db:  el contenedor de PostgreSQL (base de datos)
#   - web: el contenedor de Odoo (la aplicación web)
cat > /opt/odoo/docker-compose.yml <<'COMPOSE'
services:
  # Servicio de base de datos
  db:
    build:
      context: .
      dockerfile: Dockerfile.db   # Construye la imagen desde nuestro Dockerfile personalizado
    restart: unless-stopped       # Se reinicia automáticamente si falla (excepto si lo apagamos a mano)
    environment:
      POSTGRES_DB: postgres       # Nombre de la base de datos por defecto
      POSTGRES_USER: odoo         # Usuario administrador de PostgreSQL
      POSTGRES_PASSWORD: odoo_pass
    volumes:
      - odoo-db-data:/var/lib/postgresql/data  # Persiste los datos aunque el contenedor se destruya

  # Servicio de la aplicación Odoo
  web:
    image: odoo:17.0              # Imagen oficial de Odoo versión 17
    restart: unless-stopped
    depends_on:
      - db                        # Espera a que el contenedor "db" esté listo antes de arrancar
    ports:
      - "8069:8069"               # Expone el puerto 8069 del contenedor al puerto 8069 del servidor
    environment:
      HOST: db                    # Le dice a Odoo dónde está la base de datos
      USER: odoo
      PASSWORD: odoo_pass
    volumes:
      - odoo-web-data:/var/lib/odoo   # Persiste los datos de Odoo
      - ./config:/etc/odoo            # Monta nuestra carpeta de configuración dentro del contenedor
      - ./addons:/mnt/extra-addons    # Monta la carpeta de módulos adicionales

# Volúmenes nombrados: Docker los gestiona y persisten aunque los contenedores se borren
volumes:
  odoo-db-data:
  odoo-web-data:
COMPOSE

# ── Levantar los servicios ─────────────────────────────────────────────────────
# -d = modo "detached" (en segundo plano), el script no queda bloqueado esperando
cd /opt/odoo
docker-compose up -d
EOF

  tags = {
    Name = "odoo-server" # Nombre del servidor en la consola de AWS
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS (salidas)
# Terraform muestra estos valores al terminar el "apply".
# Son útiles para saber cómo conectarse al servidor recién creado.
# ─────────────────────────────────────────────────────────────────────────────

# ID único de la instancia EC2 (útil para referencia en AWS)
output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.odoo.id
}

# URL completa para acceder a Odoo desde el navegador
output "odoo_url" {
  description = "URL para acceder a Odoo"
  value       = "http://${aws_instance.odoo.public_ip}:8069"
}

# Comando listo para copiar y pegar en la terminal para conectarse por SSH
output "ssh_command" {
  description = "Comando para conectarse via SSH"
  value       = "ssh -i odoo-key ubuntu@${aws_instance.odoo.public_ip}"
}
