#!/bin/bash

 if [ "$EUID" -ne 0 ]; then
 echo "Ejecutando como root"
 exit
 fi

 source ../Funciones/dhcp_funciones.sh
 source ../Funciones/dns_funciones.sh

 case "$1" in

 dhcp)
 case "$2" in
	verificar) verificar_dhcp ;;
	instalar) instalar_dhcp ;;
	configurar) configurar_dhcp ;;
	reiniciar) guardaryreiniciar ;;
	monitoreo) monitoreo ;;
	reset) reset_dhcp ;;
	*) echo "Uso de Parametros ./main.sh dhcp {verifiacr,instalar,configurar,reinciar,monitoreo,reset}" ;;
	esac
 ;;

 dns)
 case "$2" in
	instalar) instalar ;;
	estado) estado ;;
	agregar) agregar "$3" "$4" ;;
	listar) listar ;;
	eliminar) eliminar_dominio "$3" ;;
	desinstalar) desinstalar ;;
	*) echo "Uso de Parametros ./main.sh dns {instalar|estado|agregar|listar|eliminar|desinstalar}" ;;
	esac
 ;;

 *)
 echo "Uso general:"
 echo "./main.sh dhcp instalar"
 echo "./main.sh dns instalar"
 ;;

 esac
