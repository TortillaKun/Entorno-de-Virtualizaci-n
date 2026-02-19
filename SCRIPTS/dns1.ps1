function validar_ip($ip) {
    if ($ip -notmatch "^([0-9]{1,3}\.){3}[0-9]{1,3}$") { return $false }

    $octetos = $ip.Split(".")
    foreach ($o in $octetos) {
        if ([int]$o -lt 0 -or [int]$o -gt 255) { return $false }
    }

    if ($ip -eq "0.0.0.0") { return $false }
    if ([int]$octetos[3] -eq 255) { return $false }
    if ([int]$octetos[0] -eq 127 -or [int]$octetos[0] -eq 0) { return $false }

    return $true
}

function instalar() {
    if (Get-WindowsFeature -Name DNS | Where-Object Installed) {
        Write-Host "DNS ya esta instalado"
    } else {
        Write-Host "Instalando DNS..."
        Install-WindowsFeature -Name DNS -IncludeManagementTools
        Set-Service -Name DNS -StartupType Automatic
        Start-Service -Name DNS
        Write-Host "DNS instalado correctamente"
    }
}

function estado() {
    Write-Host "Estado del DNS:"

    if (Get-WindowsFeature -Name DNS | Where-Object Installed) {
        Write-Host "DNS esta instalado"
    } else {
        Write-Host "DNS no esta instalado"
        return
    }

    $servicio = Get-Service -Name DNS

    Write-Host "Servicio:" $servicio.Status
    Write-Host "Inicio:" $servicio.StartType
}

function agregar($dominio, $ip) {

    if (-not $dominio -or -not $ip) {
        Write-Host "Uso: ./DNS.ps1 agregar dominio.com IP"
        return
    }

    if (-not (validar_ip $ip)) {
        Write-Host "IP no valida"
        return
    }

    $zona = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue

    if ($zona) {
        Write-Host "El dominio ya existe"
        return
    }

    # Crear zona primaria
    Add-DnsServerPrimaryZone -Name $dominio -ZoneFile "$dominio.dns" -DynamicUpdate None

    # Registro A principal
    Add-DnsServerResourceRecordA -ZoneName $dominio -Name "@" -IPv4Address $ip

    # Registro www
    Add-DnsServerResourceRecordA -ZoneName $dominio -Name "www" -IPv4Address $ip

    Write-Host "Dominio $dominio agregado correctamente"
}

function listar() {
    Write-Host "Dominios configurados:"

    $zonas = Get-DnsServerZone | Where-Object {$_.ZoneType -eq "Primary"}

    foreach ($z in $zonas) {

        $registro = Get-DnsServerResourceRecord -ZoneName $z.ZoneName |
                    Where-Object {$_.RecordType -eq "A" -and $_.HostName -eq "@"}

        if ($registro) {
            $ip = $registro.RecordData.IPv4Address
            Write-Host "$($z.ZoneName) -> $ip"
        }
    }
}

function eliminar($dominio) {

    if (-not $dominio) {
        Write-Host "Uso: ./DNS.ps1 eliminar dominio.com"
        return
    }

    $zona = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue

    if (-not $zona) {
        Write-Host "El dominio no existe"
        return
    }

    Remove-DnsServerZone -Name $dominio -Force
    Write-Host "Dominio eliminado correctamente"
}

function desinstalar() {
    Remove-WindowsFeature -Name DNS
    Write-Host "DNS desinstalado"
}

switch ($args[0]) {
    "instalar" { instalar }
    "estado" { estado }
    "agregar" { agregar $args[1] $args[2] }
    "listar" { listar }
    "eliminar" { eliminar $args[1] }
    "desinstalar" { desinstalar }
    default {
        Write-Host "Parametros DNS"
        Write-Host "./DNS.ps1 instalar"
        Write-Host "./DNS.ps1 estado"
        Write-Host "./DNS.ps1 agregar dominio.com IP"
        Write-Host "./DNS.ps1 listar"
        Write-Host "./DNS.ps1 eliminar dominio.com"
        Write-Host "./DNS.ps1 desinstalar"
    }
}
