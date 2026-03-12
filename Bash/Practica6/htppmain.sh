#!/bin/bash
# htppmain.sh - Script principal (solo llamadas a funciones)
# Practica 6 - Mageia Linux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ ! -f "$SCRIPT_DIR/htppfun.sh" ]] && { echo "[ERROR] No se encontro htppfun.sh"; exit 1; }
source "$SCRIPT_DIR/htppfun.sh"

menu_principal() {
    clear
    echo ""
    echo "=== Aprovisionamiento Web - Mageia Linux ==="
    echo "Sistema: $(uname -n)  |  Fecha: $(date '+%Y-%m-%d %H:%M')"
    verificar_HTTP
    echo "  [1] Instalar servidor HTTP"
    echo "  [2] Ver estado de servicios"
    echo "  [0] Salir"
    echo ""
    echo -n "Opcion: "
}

ejecutar_menu() {
    local op
    while true; do
        menu_principal
        read -r op; op="${op//[^0-9]/}"
        case "$op" in
            1) instalar_HTTP ;;
            2) verificar_HTTP; echo -n "Presiona ENTER..."; read -r ;;
            0) echo "Hasta luego."; exit 0 ;;
            *) print_error "Opcion invalida."; sleep 1 ;;
        esac
        echo -n "Presiona ENTER para continuar..."; read -r
    done
}

validar_root
detectar_entorno
ejecutar_menu