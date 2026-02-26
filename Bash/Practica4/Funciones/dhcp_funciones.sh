#!/bin/bash
#scriptbueno
validarip() {
 [[ $1 =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || return 1
 IFS='.' read -r oc1 oc2 oc3 oc4 <<< "$1"

 for o in $oc1 $oc2 $oc3 $oc4; do
 [[ $o -ge 0 && $o -le 255 ]] || return 1
 done

 [[ "$1" == "0.0.0.0" ]] && return 1
 [[ $oc1 -eq 127 ]] && return 1
 [[ $oc1 -eq 0 ]] && return 1
 return 0
}

ipnum() {
 IFS='.' read -r oc1 oc2 oc3 oc4 <<< "$1"
 echo $(( (oc1<<24) + (oc2<<16) + (oc3<<8) + oc4 ))
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
 echo "255.255.255.0"
}

verificar_dhcp() {
 rpm -q dhcp-server &>/dev/null \
 && echo "DHCP instalado :3 " \
 || echo "DHCP server no instalado :C"
}

instalar_dhcp() {
 if rpm -q dhcp-server &>/dev/null; then
 echo " "
 read -p "Quieres Reinstalar y sobrescribir ? (s/n): " opcion

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
 return 1
 fi

 if ! validar_rango "$IP_INICIAL" "$IP_FINAL"; then
 echo "Rango invalido"
 return 1
 fi

 IP_SERVIDOR="$IP_INICIAL"
 IP_RANGO_INICIAL=$(sumaruno "$IP_INICIAL")

 if ! validar_rango "$IP_RANGO_INICIAL" "$IP_FINAL"; then
 echo "Error rango invalido Ip del servidor en uso"
 return 1
 fi

 GATEWAY=${IP_SERVIDOR}

 INTERFAZ_SSH=$(ip route | grep default | awk '{print $5}')
 INTERFAZ_DHCP=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | grep -v "$INTERFAZ_SSH" | head -n1)

 if [ -z "$INTERFAZ_DHCP" ]; then
  echo "No se encontro interfaz disponible"
  return 1
 fi

 echo "Interfaz ssh detectada: $INTERFAZ_SSH"
 echo "Interfaz dhcp usada: $INTERFAZ_DHCP"

 read -p "DNS1 O enter para uno automatico: " DNS1
 read -p "DNS2 opcional: " DNS2

 [ -z "$DNS1" ] && DNS1="$IP_SERVIDOR"
 [ -z "$DNS2" ] && DNS_CONFIG="option domain-name-servers $DNS1;" || DNS_CONFIG="option domain-name-servers $DNS1, $DNS2;"

 read -p  "Tiempo default 300 (enter): " LEASE_DEFAULT
 read -p "Tiempo maxima (300 Normalmente): " LEASE_MAX

 [ -z "$LEASE_DEFAULT" ] && LEASE_DEFAULT=300
 [ -z "$LEASE_MAX" ] && LEASE_MAX=300

 mascara=$(obtener_mascara "$IP_SERVIDOR")
 red=${IP_SERVIDOR%.*}.0

 sudo ip addr flush dev $INTERFAZ_DHCP
 sudo ip addr add $IP_SERVIDOR/24 dev $INTERFAZ_DHCP
 sudo ip link set $INTERFAZ_DHCP up

 sudo tee /etc/dhcpd.conf >/dev/null <<EOF
default-lease-time $LEASE_DEFAULT;
max-lease-time $LEASE_MAX;
authoritative;

subnet $red netmask $mascara {
 range $IP_RANGO_INICIAL $IP_FINAL;
 option routers $GATEWAY;
 $DNS_CONFIG
}
EOF

 echo "DHCPD_INTERFACE=$INTERFAZ_DHCP" | sudo tee /etc/sysconfig/dhcpd >/dev/null

 echo "Rangos configurados"
 echo "IP fija servidor: $IP_SERVIDOR"
 echo "Rango dhcp desde: $IP_RANGO_INICIAL hasta $IP_FINAL"

 echo "Configurando resolv.conf automatico"

 sudo chattr -i /etc/resolv.conf 2>/dev/null

 sudo tee /etc/resolv.conf >/dev/null <<EOF
nameserver $IP_SERVIDOR
nameserver 8.8.8.8
EOF
}

guardaryreiniciar() {
 echo "Verificando la configuracion"

 if sudo dhcpd -t &>/dev/null; then
  sudo systemctl enable dhcpd &>/dev/null
 if sudo systemctl restart dhcpd &>/dev/null; then
  echo "Configuracion guardada y reinicio aplicado"
 else
  echo "Error la configuracion no se aplico.No reinicio"
 fi
 else
   echo "ERROR"
 fi
}

monitoreo() {
 echo "Estado del servidor DHCP"
 if systemctl is-active --quiet dhcpd; then
  echo "Activado"
 else
  echo "Desactivado"
 fi
 echo ""
 echo "Clientes conectados"
 grep "lease " /var/lib/dhcpd/dhcpd.leases 2>/dev/null
}

reset_dhcp() {
 sudo systemctl stop dhcpd 2>/dev/null
 sudo systemctl disable dhcpd 2>/dev/null

 sudo rm -f /etc/dhcpd.conf >/dev/null 2>&1
 sudo rm -f /var/lib/dhcpd/dhcpd.leases >/dev/null 2>&1

 sudo dnf remove -y dhcp-server >/dev/null 2>&1

 echo "Reset completo, DHCP eliminado y clientes eliminados"
}
