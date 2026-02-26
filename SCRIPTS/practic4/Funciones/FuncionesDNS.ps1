function validar_ip($ip) {
    if ($ip -notmatch "^([0-9]{1,3}\.){3}[0-9]{1,3}$") { return $false }
    $octetos = $ip.Split(".")
    foreach ($o in $octetos) { if ([int]$o -lt 0 -or [int]$o -gt 255) { return $false } }
    if ($ip -eq "0.0.0.0") { return $false }
    if ([int]$octetos[3] -eq 255) { return $false }
    if ([int]$octetos[0] -eq 127 -or [int]$octetos[0] -eq 0) { return $false }
    return $true
}

function instalar() {
    if (-not (Get-WindowsFeature -Name DNS | Where-Object Installed)) {
        Install-WindowsFeature -Name DNS -IncludeManagementTools
        Set-Service -Name DNS -StartupType Automatic
        Start-Service -Name DNS
    }
    $interfaz = "Ethernet 2"
    $ipServidor = (Get-NetIPAddress -InterfaceAlias $interfaz -AddressFamily IPv4).IPAddress
    Set-DnsClientServerAddress -InterfaceAlias $interfaz -ServerAddresses $ipServidor
}

function estado() {
    if (Get-WindowsFeature -Name DNS | Where-Object Installed) {
        $servicio = Get-Service -Name DNS
        Write-Host "Servicio:" $servicio.Status
        Write-Host "Inicio:" $servicio.StartType
    } else { Write-Host "DNS no esta instalado" }
}

function agregar($dominio, $ip) {
    if (-not $dominio -or -not $ip) { Write-Host "Uso: ./DNS.ps1 agregar dominio.com IP"; return }
    if (-not (validar_ip $ip)) { Write-Host "IP no valida"; return }
    $zona = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue
    if ($zona) { Write-Host "El dominio ya existe"; return }
    Add-DnsServerPrimaryZone -Name $dominio -ZoneFile "$dominio.dns" -DynamicUpdate None
    Add-DnsServerResourceRecordA -ZoneName $dominio -Name "@" -IPv4Address $ip
    Add-DnsServerResourceRecordA -ZoneName $dominio -Name "www" -IPv4Address $ip
    Write-Host "Dominio $dominio agregado correctamente"
}

function listar() {
    $zonas = Get-DnsServerZone | Where-Object {$_.ZoneType -eq "Primary"}
    foreach ($z in $zonas) {
        $registro = Get-DnsServerResourceRecord -ZoneName $z.ZoneName | Where-Object {$_.RecordType -eq "A" -and $_.HostName -eq "@"}
        if ($registro) { Write-Host "$($z.ZoneName) -> $($registro.RecordData.IPv4Address)" }
    }
}

function eliminar($dominio) {
    $zona = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue
    if ($zona) { Remove-DnsServerZone -Name $dominio -Force; Write-Host "Dominio eliminado correctamente" }
}

function desinstalar() { Remove-WindowsFeature -Name DNS; Write-Host "DNS desinstalado" }