
param(
    [string]$Accion
)

function Instalar-SSH {

    Write-Host "Verificando si OpenSSH esta instalado..."

    $cap = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"

    if ($cap.State -eq "Installed") {
        Write-Host "OpenSSH ya esta instalado."
    }
    else {
        Write-Host "Instalando OpenSSH Server..."
        Add-WindowsCapability -Online -Name $cap.Name
        Write-Host "Instalacion completa."
    }

    Write-Host "Habilitando y arrancando el servicio SSH..."

    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    Write-Host "Servicio SSH habilitado y en ejecucion."
}


function Verificar-SSH {

    $cap = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"

    if ($cap.State -eq "Installed") {
        Write-Host "OpenSSH esta instalado."
    }
    else {
        Write-Host "OpenSSH NO esta instalado."
        return
    }

    $servicio = Get-Service sshd

    if ($servicio.Status -eq "Running") {
        Write-Host "El servicio SSH esta ACTIVO."
    }
    else {
        Write-Host "El servicio SSH NO esta activo."
    }

    if ($servicio.StartType -eq "Automatic") {
        Write-Host "El servicio SSH esta HABILITADO al inicio."
    }
    else {
        Write-Host "El servicio SSH NO esta habilitado al inicio."
    }
}


switch ($Accion) {

    "instalar" { Instalar-SSH }

    "verificar" { Verificar-SSH }

    default {
        Write-Host "Uso:"
        Write-Host ".\ssh.ps1 instalar"
        Write-Host ".\ssh.ps1 verificar"
    }
}