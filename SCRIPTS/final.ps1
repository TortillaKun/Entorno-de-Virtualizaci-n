param($accion)
$ConfirmPreference = "None"


# VALIDACIONES


function IPValidacion {
    param($ip)

    if ($ip -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$') { return $false }

º1    $partes = $ip -split '\.'
    foreach ($o in $partes) {
        if ([int]$o -lt 0 -or [int]$o -gt 255) { return $false }
    }

    if ($ip -eq "0.0.0.0") { return $false }
    if ([int]$partes[3] -eq 255) { return $false }
    if ([int]$partes[0] -eq 127 -or [int]$partes[0] -eq 0) { return $false }

    return $true
}

function IPaNumero {
    param($ip)
    $p = $ip -split '\.'
    return ([int64]$p[0] -shl 24) -bor ([int64]$p[1] -shl 16) -bor ([int64]$p[2] -shl 8) -bor [int64]$p[3]
}

function NumeroaIP {
    param($num)
    $o1 = ($num -shr 24) -band 255
    $o2 = ($num -shr 16) -band 255
    $o3 = ($num -shr 8)  -band 255
    $o4 = $num -band 255
    return "$o1.$o2.$o3.$o4"
}

function ValidarRango {
    param($ip1, $ip2)
    return (IPaNumero $ip2) -ge (IPaNumero $ip1)
}

function SumarUno {
    param($ip)
    $num = (IPaNumero $ip) + 1
    return NumeroaIP $num
}

function MismaRed {
    param($ip1, $ip2)
    $a = $ip1 -split '\.'
    $b = $ip2 -split '\.'
    return ($a[0] -eq $b[0] -and $a[1] -eq $b[1] -and $a[2] -eq $b[2])
}

function ObtenerMascara {
    param($ip)
    $o1 = ($ip -split '\.')[0]

    if ($o1 -le 126) { return "255.0.0.0" }
    elseif ($o1 -le 191) { return "255.255.0.0" }
    else { return "255.255.255.0" }
}


# VERIFICAR DHCP
function Verificar-DHCP {
    $feature = Get-WindowsFeature -Name DHCP
    if ($feature.Installed) { Write-Host "DHCP instalado" }
    else { Write-Host "DHCP no instalado" }
}

#INSTALAR DHCP


function Instalar-DHCP {
    $feature = Get-WindowsFeature -Name DHCP
    if ($feature.Installed) {
        $op = Read-Host "DHCP ya esta instalado. Reinstalar y sobrescribir? (s/n)"
        if ($op -eq "s" -or $op -eq "S") {
            Write-Host "Reinstalando DHCP..."
            Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools -Restart:$false
            Install-WindowsFeature -Name DHCP -IncludeManagementTools
            Write-Host "Reinstalacion completa"
        } else { Write-Host "Instalacion cancelada" }
    } else {
        Write-Host "instalando DHCP"
        Install-WindowsFeature -Name DHCP -IncludeManagementTools
        Write-Host "instalacion completa"
    }
}


# CONFIGURAR DHCP


function Configurar-DHCP {

    do {
        $IP_INICIAL = Read-Host "IP inicial (sera IP del servidor)"
        if (-not (IPValidacion $IP_INICIAL)) { Write-Host "IP invalida ejemplo 192.168.50.50" }
    } until (IPValidacion $IP_INICIAL)

    do {
        $IP_FINAL = Read-Host "IP final"
        if (-not (IPValidacion $IP_FINAL)) { Write-Host "IP invalida ejemplo 192.168.50.60" }
    } until (IPValidacion $IP_FINAL)

    if (-not (MismaRed $IP_INICIAL $IP_FINAL)) { Write-Host "Error no pertenecen a la misma red"; return }
    if (-not (ValidarRango $IP_INICIAL $IP_FINAL)) { Write-Host "Rango invalido"; return }

    $IP_SERVIDOR = $IP_INICIAL
    $IP_RANGO_INICIAL = SumarUno $IP_INICIAL
    if (-not (ValidarRango $IP_RANGO_INICIAL $IP_FINAL)) { Write-Host "Error ocupa todo el rango"; return }

    # Gateway
    $GATEWAY = Read-Host "Gateway (enter para usar autmotacio)"
    if ([string]::IsNullOrEmpty($GATEWAY)) { $GATEWAY = $IP_SERVIDOR }

    # DNS
    $DNS1 = Read-Host "DNS1 (automatico)"
    $DNS2 = Read-Host "DNS2 (opcional)"
    if ([string]::IsNullOrEmpty($DNS1)) { $DNS1 = "8.8.8.8" }
    $DNS_CONFIG = if ([string]::IsNullOrEmpty($DNS2)) { $DNS1 } else { "$DNS1,$DNS2" }

    # Lease times
    $LEASE_DEFAULT = Read-Host "Tiempo de conexion (enter para 300)"
    $LEASE_MAX = Read-Host "Tiempo maximo (enter para 300)"
    if ([string]::IsNullOrEmpty($LEASE_DEFAULT)) { $LEASE_DEFAULT = 300 }
    if ([string]::IsNullOrEmpty($LEASE_MAX)) { $LEASE_MAX = 300 }

    $mascara = ObtenerMascara $IP_SERVIDOR
    $partes = $IP_SERVIDOR -split '\.'
    $red = "$($partes[0]).$($partes[1]).$($partes[2]).0"

    $interfaz = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike "10.*" -and $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1).InterfaceAlias

    if (-not $interfaz) { Write-Host "No interfaz invalida esta no se detecto"; return }

    $ipActual = Get-NetIPAddress -InterfaceAlias $interfaz -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq "Manual"}
    if ($ipActual) { $ipActual | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }

    New-NetIPAddress -InterfaceAlias $interfaz -IPAddress $IP_SERVIDOR -PrefixLength 24 | Out-Null

    Remove-DhcpServerv4Scope -ScopeId $red -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

    Add-DhcpServerv4Scope -Name "RedDHCP" -StartRange $IP_RANGO_INICIAL -EndRange $IP_FINAL -SubnetMask $mascara | Out-Null

    Set-DhcpServerv4OptionValue -ScopeId $red -Router $GATEWAY -DnsServer $DNS_CONFIG | Out-Null

    # Lease duration
    Set-DhcpServerv4Scope -ScopeId $red -LeaseDuration ([TimeSpan]::FromSeconds($LEASE_DEFAULT)) | Out-Null

    Set-DhcpServerv4Scope -ScopeId $red -State Active | Out-Null

    Restart-Service DHCPServer

    Write-Host ""
    Write-Host "Configuracion aplicada"
    Write-Host "Servidor:" $IP_SERVIDOR
    Write-Host "Rango DHCP:" $IP_RANGO_INICIAL " - " $IP_FINAL
    Write-Host "Gateway:" $GATEWAY
    Write-Host "DNS:" $DNS_CONFIG
    Write-Host "Tiempo default (lease):" $LEASE_DEFAULT
    Write-Host "Tiempo maximo (lease):" $LEASE_MAX
}


# MONITOREO


function Monitoreo {
    Write-Host "Estado del servicio DHCP"
    Get-Service DHCPServer

    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host ""
            Write-Host "Rango detectado:" $scope.ScopeId
            Get-DhcpServerv4Lease -ScopeId $scope.ScopeId |
            Select-Object IPAddress, HostName, ClientId, AddressState
        }
    } else { Write-Host "No hay Rangos configurados" }
}

# RESET


function Reset-DHCP {
    Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
    Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue

    Restart-Service DHCPServer
    Write-Host "Reset completo"
}


# MENU


switch ($accion) {
    "verificar" { Verificar-DHCP }
    "instalar" { Instalar-DHCP }
    "configurar" { Configurar-DHCP }
    "monitoreo" { Monitoreo }
    "reset" { Reset-DHCP }
    default {
        Write-Host "Parametros disponibles:"
        Write-Host ".\fdhcp.ps1 verificar"
        Write-Host ".\fdhcp.ps1 instalar"
        Write-Host ".\fdhcp.ps1 configurar"
        Write-Host ".\fdhcp.ps1 monitoreo"
        Write-Host ".\fdhcp.ps1 reset"
    }
}
