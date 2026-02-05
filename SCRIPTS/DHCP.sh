#!/bin/bash

#VALIDACIONES

validarip() {
 [[ $1 =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || return 1
 IFS='.' read -r oc1 oc2 oc3 oc4 <<< "$1"

 for o in $oc1 $oc2 $oc3 $oc4; do
 [[ $o -ge 0 && $o -le 255 ]] || return 1
done

 [[ "$1" == "0.0.0.0" ]] && return 1
 [[ $oc4 -eq 0 || $oc4 -eq 255 ]] && return 1

 return 0
}


ipnum() {
 IFS='.' read -r oc1 oc2 oc3 oc4 <<< "$1"
 echo &(( (oc1<<24) + (oc2<<16) + (oc3<<8) + oc4 ))
}


validar_rango() {
[[ $(ipnum "$2") -ge $(ipnum "$1") ]]
}

sumaruno() {
 num=$(ipnum "$1")
 nueva=$((num + 1))

 oc1=$(( (nueva >> 24) & 255 ))
 oc2=$(( (nueva >> 16) & 255 ))
 oc3=$(( (nueva >> 8) & 255 ))
 oc4=$(( nueva & 255 ))

 echo "$oc1.$oc2.$oc3.$oc4"
}

 misma_red() {
 IFS='.' read -r a1 a2 a3 _ <<< "$1"
 IFS='.' read -r b1 b2 b3 _ <<< "$2"

 [[ $a1 -eq $b1 && $a2 -eq $b2 && $a3 -eq $b3 ]]
}

obtener_mascara() {
 IFS='.' read -r oc1 _ <<< "$1"

 if (( oc1 <= 126 )); then
  echo "255.0.0.0"
 elif (( oc1 <= 191 )); then
  echo "255.255.0.0 "
 else
  echo "255.255.255.0"
fi
}


#FUNCIONES

verificar_dhcp() {
 rpm -q dhcp-server &>/dev/null \
 && echo "DHCP instalado :3 " \
 || echo "DHCP server no instalado :C"
}

instalar_dhcp() {
 if rpm -q dhcp-server &>/dev/null; then
 echo " "
 read -p "Quieres Reinstalar y sobrescribir ? (s\n): " opcion

 if [[ $opcion == "s" || $opcion == "S" ]]; then
  echo "Reinstalando DHCP"
 sudo urpmi --replacepkgs --auto dhcp-server &>/dev/null
  echo "Reinstalacion completa"
 else
  echo "Instalacion cancelada"
 fi
  else
  echo "Instalando DHCP"
  sudo urpmi --auto dhcp-server &>/dev/null
  echo "instalacion completa"
 fi
}


configurar_dhcp() {

 echo "Configuracion de ip inical y final"

 while true; do
 read -p "Ip inicial: " IP_INICIAL
 if validarip "$IP_INICIAL"; then
  break
 else
  echo "IP incial invalida ej.(192.168.50.50)"
 fi
 done

 while true; do
 read -p "Ip final: " IP_FINAL
 if validarip "$IP_FINAL"; then
  break
 else
  echo "IP final invalida ej.(192.168.50.60)"
 fi
 done

 if ! misma_red "$IP_INICIAL" "$IP_FINAL"; then
 echo "Error Ip no pertenecen a la misma red"
 exit 1
 fi

 if ! validar_rango "$IP_INICIAL" "$IP_FINAL"; then
 echo "Rango invalido"
 exit 1
 fi

 # ip fija del servidor
 IP_SERVIDOR="$IP_INICIAL"

 #dhcp empieza desde ip + 1
 IP_RANGO_INCIAL=$(sumaruno "$IP_INICIAL")

 if ! validar_rango "$IP_RANGO_INICIAL" "$IP_FINAL"; then
 echo "Error rango invalido Ip del servidor en uso"
 exit 1
 fi

 GATEWAY=${IP_SERVIDOR}
 DNS="1.1.1.1"
 LEASE="300"

 mascara=$(obtener_mascara "$IP_SERVIDOR")
 red=${IP_SERVIDOR%.*}.0

 #interfaz enp0s8 config
 sudo ip addr flush dev enp0s8
 sudo ip addr add $IP_SERVIDOR/24 dev enp0s8
 sudo ip link set enp0s8 up

  sudo tee /etc/dhcpd.conf >/dev/null <<EOF
 default-lease-time $LEASE;
 max-lease-time $LEASE;
 authoritative;

 subnet $red netmask $mascara {
 range $IP_RANGO_INICIAL $IP_FINAL;
 option routers $GATEWAY;
 option domain-name-servers $DNS;
}
EOF


 echo "DHCPD_INTERFACE=enp0s8" | sudo tee /etc/sysconfig/dhcpd >/dev/null

 echo "Rangos configurados"
 echo "IP fija servidor: $IP_SERVIDOR"
 echo "Rango dhcp desde: $IP_RANGO_INICIAL hasta $IP_FINAL"
}


guardaryreiniciar() {
 echo "Verificando la configuracion"

 if sudo dhcpd -t &>/dev/null; then
  sudo systemctl restart dhcpd &>/dev/null
  sudo systemctl enable dhcpd &>/dev/null
  echo "Configuracion guardada y reinicio aplicado"
 else
  echo "Error la configuracion no se aplico.No reinicio"
 fi
}


monitoreo() {
 echo "Estado del servidor DHCP"
 systemctl is-active dhcpd

 echo ""
 echo "Clientes conectados"
 grep "lease " /var/lib/dhcpd/dhcpd.leases 2>/dev/null
}


reset_dhcp() {
 sudo systemctl stop dhcpd
 sudo rm -f /var/lib/dhcpd/dhcpd.leases
 sudo touch /var/lib/dhcpd/dhcpd.leases
 sudo chown dhcpd:dhcpd /var/lib/dhcpd/dhcpd.leases
 sudo systemctl start dhcpd
 echo "Reset completo y clientes eliminados"
}



#CASE Y EJECUCION

case "$1" in
verificar)
 verificar_dhcp
  ;;
instalar)
 instalar_dhcp
  ;;
configurar)
 configurar_dhcp
  ;;
guardaryreiniciar)
 guardaryreiniciar
  ;;
monitoreo)
 monitoreo
  ;;
reset)
 reset_dhcp
  ;;
 *)
 echo "Parametros"
 echo " ./DHCP.sh verificar"
 echo " ./DHCP.sh instalar"
 echo " ./DHCP.sh configurar"
 echo " ./DHCP.sh guardaryreiniciar"
 echo " ./DHCP.sh monitoreo"
 echo " ./DHCP.sh reset"
 exit 1
 ;;
esac




