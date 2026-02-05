#!/bin/bash

#VALIDIACION
validarip() {
 [[ $1 =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || return 1
 IFS='.' read -r oc1 oc2 oc3 oc4 <<< "$1"

 for o in $oc1 $oc2 $oc3 $oc4; do
 [[ $o -ge 0 && $o -le 255 ]] || return 1
done

[[ "$1" == "0.0.0.0" ]] && return 1
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
num=$(ip_a_num "$1")
nueva=$((num + 1))

oc1=$(( (nueva >> 24) & 255 ))
oc2=$(( (nueva >> 16) & 255 ))
oc3=$(( (nueva >> 8) & 255 ))
oc4=$(( nueva & 255 ))

echo "$oc1.$oc2.$oc3.$oc4"
}

obtener_mascara() {
 IFS='.' read -r oc1 _ <<< "$1"

 if (( oc1 <= 126 )); then
 echo "255.0.0.0"
 elif (( oc1 <= 191 )); then
 echo "255.255.0.0"
 else
 echo "255.255.255.0"
 fi
}

#FUNCIONES
verificar_dhcp() {
rpm -q dhcp-server &>/dev/null \
 && echo "DHCP instalado :3 " \
 || echo "DHCP Server no instalado :C "
}

instalar_dhcp() {
if rpm -q dhcp-server &>/dev/null; then
echo " "
read -p "Quieres Reinstalar y sobrescribir ? (s/n): " opcion

if [[ $opcion == "s" || $opcion == "S" ]]; then
echo "Reinstalando DHCP"
sudo urpmi --replacepkgs --auto dhcp-server &>/dev/null
echo "Reinstalacion Completa"
else
 echo "Instalacion cancelada"
fi
else
 echo "Instaladno DHCP"
sudo urpmi --auto dhcp-server &>/dev/null
echo "Instalacion completa"
fi
}

configurar_dhcp() {
echo "Configuracion de ip inical y final"

while true; do
 read -p "Ip inicial: " IP_INICIAL
 if validarip "$IP_INICIAL"; then
break
else
 echo "IP inicial invalida intenta ej.(192.168.50.50) "
fi
done

while true; do
 read -p "ip final: " IP_FINAL
 if validarip "$IP_FINAL"; then
break
else
 echo "IP final invalida"
fi
done

#detectar la ip del servidor
IP_SERVIDOR=$(hostname -I | awk '{print $1}')
#si coinciden con ip inicial, hara un salto
if [[ "$IP_INICIAL" == "IP_SERVIDOR" ]]; then
 echo "La ip inicial coincide con la ip fija Error ($IP_SERVIDOR)"
IP_INICIAL=$(sumaruno "$IP_INICIAL")
 echo "Nueva Ip inicial: $IP_INCIAL"
fi

#automatico si no pone nada
GATEWAY=${GATEWAY:-${IP_INICIAL%.*}.1}
DNS=${DNS:-1.1.1.1}
LEASE=${LEASE:-300}


#validaciones
validarip "$IP_INICIAL" || { echo "Ip incial invalida"; exit 1; }
validarip "$IP_FINAL" || { echo "Ip final invalida"; exit 1; }
validar_rango "$IP_INICIAL" "$IP_FINAL" || { echo "Rango invalido"; exit 1; }
validarip "$GATEWAY" || { echo "Gateway invalido"; exit 1; }
validarip "$DNS" || { echo "DNS invalido"; exit 1; }

 mascara=$(obtener_mascara "$IP_INICIAL")
 red=${IP_INICIAL%.*}.0

 sudo tee /etc/dhcpd.conf >/dev/null <<EOF
 default-lease-time $LEASE;
 max-lease-time $LEASE;
 authoritative;

 subnet $red netmask $mascara {
 range $IP_INICIAL $IP_FINAL;
 option routers $GATEWAY;
 option domain-name-servers $DNS;
}

EOF

 echo "DHCPD_INTERFACE=enp0s8" | sudo tee /etc/sysconfig/dhcpd >/dev/null
 sudo dhcpd -t >/dev/null 2>&1 && sudo systemctl restart dhcpd >/dev/null 2>&1
 echo "Rangos Configurados :D "
}

guardaryreiniciar() {
echo "Verificando su configuracion"

if sudo dhcpd -t &>/dev/null; then
 sudo systemctl restart dhcpd &>/dev/null
 sudo systemctl enable dhcpd &>/dev/null
echo "Configuracion guardada y reinicio del server correctos"
else
 echo "Error en la configuracion.No reinicio"
fi
}

monitoreo() {
 echo "Estado del servidor DHCP"

systemctl is-active dhcpd

echo ""
echo "Clientes conectados"

grep "lease " /var/lib/dhcpd/dhcpd.leases

}

reset_dhcp() {
 sudo systemctl stop dhcpd
 sudo rm -f /var/lib/dhcpd/dhcpd.leases
 sudo touch /var/lib/dhcpd/dhcpd.leases
 sudo chown dhcpd:dhcpd /var/lib/dhcpd/dhcpd.leases
 sudo systemctl start dhcpd
 echo "Reset completo y clientes eliminados "
}

#ARGUMENTOS

 ACCION=$1
 shift

 while [[ $# -gt 0 ]]; do
 case "$1" in
 --ip-inicial) IP_INICIAL=$2; shift 2;;
 --ip-final) IP_FINAL=$2; shift 2;;
 --gateway) GATEWAY=$2; shift 2;;
 --dns) DNS=$2; shift 2;;
 --lease) LEASE=$2; shift 2;;
*) echo "Parametro erronio: $1"; exit 1 ;;
 esac
done

#Ejecutar funciones

case "$ACCION" in
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
 echo "Uso:"
 echo " ./dhcp.sh verificar"
 echo " ./dhcp.sh instalar"
 echo " ./dhcp.sh configurar"
 echo " ./dhcp.sh guardaryreiniciar"
 echo " ./dhcp.sh monitoreo"
 echo " ./dhcp.sh reset"
 exit 1
 ;;
esac
