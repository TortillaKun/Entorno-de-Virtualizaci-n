param(
    [Parameter(Position=0)][string]$modulo,
    [Parameter(Position=1)][string]$accion,
    [Parameter(Position=2)][string]$param1,
    [Parameter(Position=3)][string]$param2
)

$ConfirmPreference = "None"

if (-not $modulo) {
    Write-Host "Uso general:"
    Write-Host ".\Main.ps1 dhcp instalar"
    Write-Host ".\Main.ps1 dns instalar"
    return
}

. "$PSScriptRoot\..\Funciones\FuncionesDHCP.ps1"
. "$PSScriptRoot\..\Funciones\FuncionesDNS.ps1"

switch ($modulo.ToLower()) {

    "dhcp" {
        if (-not $accion) {
            Write-Host "Parametros DHCP disponibles:"
            Write-Host ".\Main.ps1 dhcp verificar"
            Write-Host ".\Main.ps1 dhcp instalar"
            Write-Host ".\Main.ps1 dhcp configurar"
            Write-Host ".\Main.ps1 dhcp monitoreo"
            Write-Host ".\Main.ps1 dhcp reset"
            return
        }
        switch ($accion.ToLower()) {
            "verificar"  { Verificar-DHCP }
            "instalar"   { Instalar-DHCP }
            "configurar" { Configurar-DHCP }
            "monitoreo"  { Monitoreo }
            "reset"      { Reset-DHCP }
            default      { Write-Host "Accion DHCP no valida" }
        }
    }

    "dns" {
        if (-not $accion) {
            Write-Host "Parametros DNS disponibles:"
            Write-Host ".\Main.ps1 dns instalar"
            Write-Host ".\Main.ps1 dns estado"
            Write-Host ".\Main.ps1 dns agregar dominio.com IP"
            Write-Host ".\Main.ps1 dns listar"
            Write-Host ".\Main.ps1 dns eliminar dominio.com"
            Write-Host ".\Main.ps1 dns desinstalar"
            return
        }
        switch ($accion.ToLower()) {
            "instalar"    { instalar }
            "estado"      { estado }
            "agregar"     { agregar $param1 $param2 }
            "listar"      { listar }
            "eliminar"    { eliminar $param1 }
            "desinstalar" { desinstalar }
            default       { Write-Host "Accion DNS no valida" }
        }
    }

    default {
        Write-Host "Modulo no valido"
        Write-Host "Use: dhcp o dns"
    }
}