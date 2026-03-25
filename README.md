# Odoo 17 en AWS con Terraform

Guía paso a paso para desplegar Odoo 17 en AWS usando Terraform.

---

## Requisitos previos

### 1. Instalar Terraform
1. Ve a https://developer.hashicorp.com/terraform/install
2. Descarga la versión para **Windows AMD64**
3. Descomprime el archivo `.zip`
4. Mueve el archivo `terraform.exe` a `C:\Windows\System32\` (así funciona desde cualquier terminal)
5. Abre una terminal nueva y verifica:
   ```
   terraform --version
   ```

### 2. Instalar Git (opcional, para clonar el repo)
1. Ve a https://git-scm.com/download/win
2. Descarga e instala con las opciones por defecto

---

## Configurar AWS

### 3. Crear una cuenta AWS
1. Ve a https://aws.amazon.com
2. Click en **Create an AWS Account**
3. Sigue los pasos (requiere tarjeta de crédito)

### 4. Crear usuario IAM con credenciales
1. Entra a la consola AWS: https://console.aws.amazon.com
2. Busca **IAM** en el buscador
3. Click en **Users** → **Create user**
4. Nombre: `terraform-odoo`
5. Click en **Next**
6. Selecciona **Attach policies directly**
7. Busca y selecciona estas dos políticas:
   - `AmazonEC2FullAccess`
   - `AmazonVPCFullAccess`
8. Click en **Next** → **Create user**
9. Click en el usuario recién creado → **Security credentials**
10. Scroll hasta **Access keys** → **Create access key**
11. Selecciona **Command Line Interface (CLI)** → **Next** → **Create access key**
12. **Copia y guarda** el `Access Key ID` y el `Secret Access Key` — solo se muestran una vez

---

## Preparar los archivos

### 5. Descargar o clonar este proyecto
Asegúrate de tener estos archivos en una carpeta (ejemplo: `C:\Odoo`):
```
main.tf
docker-compose.yml
Dockerfile.db
configodoo.conf
```

### 6. Crear el SSH Key Pair
Abre una terminal en la carpeta del proyecto y corre:
```bash
ssh-keygen -t rsa -b 2048 -f odoo-key -N ""
```
Esto crea dos archivos:
- `odoo-key` → clave privada (para conectarte al servidor)
- `odoo-key.pub` → clave pública (usada por Terraform)

---

## Desplegar Odoo

### 7. Configurar credenciales AWS
Reemplazá `TU_ACCESS_KEY_ID` y `TU_SECRET_ACCESS_KEY` con los valores que copiaste en el paso 4.

Elegí el bloque según la terminal que estés usando:

**Si usás CMD (símbolo del sistema):**
```cmd
set AWS_ACCESS_KEY_ID=TU_ACCESS_KEY_ID
set AWS_SECRET_ACCESS_KEY=TU_SECRET_ACCESS_KEY
set AWS_DEFAULT_REGION=sa-east-1
```

**Si usás PowerShell:**
```powershell
$env:AWS_ACCESS_KEY_ID="TU_ACCESS_KEY_ID"
$env:AWS_SECRET_ACCESS_KEY="TU_SECRET_ACCESS_KEY"
$env:AWS_DEFAULT_REGION="sa-east-1"
```

> ⚠️ Estas variables duran solo mientras la terminal esté abierta. Si la cerrás, tenés que correrlos de nuevo antes de usar Terraform.

### 8. Inicializar Terraform
```bash
terraform init
```

### 9. Ver qué va a crear
```bash
terraform plan
```

### 10. Crear la infraestructura
```bash
terraform apply
```
Escribe `yes` cuando pregunte confirmación.

Espera que termine. Al final verás algo así:
```
Outputs:
instance_id = "i-xxxxxxxxxxxxxxxxx"
odoo_url    = "http://XX.XX.XX.XX:8069"
ssh_command = "ssh -i odoo-key ubuntu@XX.XX.XX.XX"
```

### 11. Esperar que Odoo inicie
Terraform crea el servidor y automáticamente instala Docker y levanta Odoo.
**Espera 5 minutos** y luego abre la URL del output en el browser:
```
http://XX.XX.XX.XX:8069
```

---

## Usar Odoo

### 12. Crear la base de datos
Al abrir la URL verás el formulario de creación de base de datos:

| Campo | Valor |
|---|---|
| Master Password | `admin123` |
| Database Name | el nombre que quieras |
| Email | tu email de acceso |
| Password | tu contraseña de acceso |

Click en **Create database** y listo.

---

## Comandos útiles

### Conectarse al servidor por SSH
```bash
ssh -i odoo-key ubuntu@XX.XX.XX.XX
```

### Ver logs de Odoo
```bash
ssh -i odoo-key ubuntu@XX.XX.XX.XX
sudo docker logs odoo_web_1 -f
```

### Apagar todo y eliminar recursos AWS
```bash
terraform destroy
```
Escribe `yes`. Esto elimina todos los recursos para que no generen costos.

---

## Advertencias

- **Costo:** Una instancia `t3a.medium` en sa-east-1 cuesta aproximadamente **$0.0605 USD/hora** (~$44/mes). Recuerda hacer `terraform destroy` cuando no la necesites.
- **Credenciales:** Nunca compartas tu `Access Key ID` ni `Secret Access Key`. Si lo haces accidentalmente, ve a IAM y elimínalas inmediatamente.
- **SSH Key:** Guarda el archivo `odoo-key` en un lugar seguro. Sin él no puedes conectarte al servidor.
