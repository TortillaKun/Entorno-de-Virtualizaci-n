param($accion)
$ConfirmPreference = "None"

# VALIDACIONES

function Validar-IP {
    param($ip)

    if ($ip -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$') { return $false }

    $partes = $ip -split '\.'
    foreach ($o in $partes) {
        if ([int]$o -lt 0 -or [int]$o -gt 255) { return $false }
    }

    if ($ip -eq "0.0.0.0") { return $false }
    if ([int]$partes[3] -eq 0 -or [int]$partes[3] -eq 255) { return $false }

    return $true
}

function IP-a-Numero {
    param($ip)
    $p = $ip -split '\.'
    return ([int64]$p[0] -shl 24) -bor `
           ([int64]$p[1] -shl 16) -bor `
           ([int64]$p[2] -shl 8)  -bor `
           [int64]$p[3]
}

function Numero-a-IP {
    param($num)
    $o1 = ($num -shr 24) -band 255
    $o2 = ($num -shr 16) -band 255
    $o3 = ($num -shr 8)  -band 255
    $o4 = $num -band 255
    return "$o1.$o2.$o3.$o4"
}

function Validar-Rango {
    param($ip1, $ip2)
    return (IP-a-Numero $ip2) -ge (IP-a-Numero $ip1)
}

function Sumar-Uno {
    param($ip)
    $num = (IP-a-Numero $ip) + 1
    return Numero-a-IP $num
}

function Misma-Red {
    param($ip1, $ip2)
    $a = $ip1 -split '\.'
    $b = $ip2 -split '\.'
    return ($a[0] -eq $b[0] -and $a[1] -eq $b[1] -and $a[2] -eq $b[2])
}

function Obtener-Mascara {
    param($ip)
    $o1 = ($ip -split '\.')[0]

    if ($o1 -le 126) { return "255.0.0.0" }
    elseif ($o1 -le 191) { return "255.255.0.0" }
    else { return "255.255.255.0" }
}

# VERIFICAR DHCP

function Verificar-DHCP {

    $feature = Get-WindowsFeature -Name DHCP

    if ($feature.Installed) {
        Write-Host "DHCP instalado"
    } else {
        Write-Host "DHCP no instalado"
    }
}


# INSTALAR DHCP
 

function Instalar-DHCP {

    $feature = Get-WindowsFeature -Name DHCP

    if ($feature.Installed) {

        $op = Read-Host "DHCP ya esta instalado. Reinstalar y sobrescribir? (s/n)"

        if ($op -eq "s" -or $op -eq "S") {

            Write-Host "Reinstalando DHCP..."

            Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools -Restart:$false
            Install-WindowsFeature -Name DHCP -IncludeManagementTools

            Write-Host "Reinstalacion completa"

        } else {
            Write-Host "Instalacion cancelada"
        }

    } else {

        Write-Host "Instalando DHCP..."
        Install-WindowsFeature -Name DHCP -IncludeManagementTools
        Write-Host "Instalacion completa"
    }
}


# CONFIGURAR DHCP

function Configurar-DHCP {

    do {
        $IP_INICIAL = Read-Host "IP inicial (sera IP del servidor)"
        if (-not (Validar-IP $IP_INICIAL)) {
            Write-Host "IP invalida ejemplo 192.168.50.50"
        }
    } until (Validar-IP $IP_INICIAL)

    do {
        $IP_FINAL = Read-Host "IP final"
        if (-not (Validar-IP $IP_FINAL)) {
            Write-Host "IP invalida ejemplo 192.168.50.60"
        }
    } until (Validar-IP $IP_FINAL)

    if (-not (Misma-Red $IP_INICIAL $IP_FINAL)) {
        Write-Host "Error no pertenecen a la misma red"
        return
    }

    if (-not (Validar-Rango $IP_INICIAL $IP_FINAL)) {
        Write-Host "Rango invalido"
        return
    }

    $IP_SERVIDOR = $IP_INICIAL
    $IP_RANGO_INICIAL = Sumar-Uno $IP_INICIAL

    if (-not (Validar-Rango $IP_RANGO_INICIAL $IP_FINAL)) {
        Write-Host "Error el servidor ocupa todo el rango"
        return
    }

    $mascara = Obtener-Mascara $IP_SERVIDOR
    $partes = $IP_SERVIDOR -split '\.'
    $red = "$($partes[0]).$($partes[1]).$($partes[2]).0"
 
    $interfaz = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike "10.*" -and $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1).InterfaceAlias

    if (-not $interfaz) {
        Write-Host "No se detecto interfaz valida"
        return
    }

   $ipActual = Get-NetIPAddress -InterfaceAlias $interfaz -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq "Manual"}

if ($ipActual) {
    $ipActual | Remove-NetIPAddress  -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

    New-NetIPAddress `
        -InterfaceAlias $interfaz `
        -IPAddress $IP_SERVIDOR `
        -PrefixLength 24 | Out-Null

    Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Out-Null
     Remove-DhcpServerv4Scope `
    -ScopeId $red `
    -Force `
    -Confirm:$false `
    -ErrorAction SilentlyContinue | Out-Null

    Add-DhcpServerv4Scope `
        -Name "RedDHCP" `
        -StartRange $IP_RANGO_INICIAL `
        -EndRange $IP_FINAL `
        -SubnetMask $mascara | Out-Null

    Set-DhcpServerv4OptionValue `
        -ScopeId $red `
        -Router $IP_SERVIDOR `
        -DnsServer 1.1.1.1 | Out-Null

    Set-DhcpServerv4Scope `
        -ScopeId $red `
        -State Active | Out-Null

    Restart-Service DHCPServer

    Write-Host ""
    Write-Host "Configuracion aplicada"
    Write-Host "Servidor:" $IP_SERVIDOR
    Write-Host "Rango DHCP:" $IP_RANGO_INICIAL " - " $IP_FINAL
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
    } else {
        Write-Host "No hay Rangos configurados"
    }
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
