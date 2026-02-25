#!/bin/bash

LOCALCONF="/etc/named.conf"
ZONADIR="/var/named"

#validar ip
validar_ip() {
 local ip=$1

 if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
 return 1
fi

 IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

 for o in $o1 $o2 $o3 $o4; do
 if (( o < 0 || o > 255 )); then
  return 1
fi
done

if [[ "$ip" == "0.0.0.0" ]]; then
 return 1
fi

if (( o4 == 255 )); then
 return 1
fi

if (( o1 == 127 || o1 == 0 )); then
 return 1
fi

 return 0
}

#configurar dns local automatico
configurar_dns_local() {

if systemctl is-active --quiet named; then

 sudo tee /etc/resolv.conf >/dev/null <<EOF
nameserver 127.0.0.1
EOF

 echo "Servidor configurado para usar DNS local 127.0.0.1"

else
 echo "named no esta activo, no se modifico resolv.conf"
fi

}

#instalar dns
instalar() {

 if rpm -q bind &>/dev/null; then
 echo "BIND ya esta instalado"
else
 echo "Instalando Bind"
 dnf install -y bind bind-utils
 systemctl enable named
 systemctl start named
 echo "DNS instando correctamente"
fi

configurar_dns_local

}

#estado del servicio
estado() {
echo "Estado del DNS: "

if rpm -q bind &>/dev/null; then
 echo "BIND esta instalado."
else
 echo "BIND no esta intalado."
 return
fi

if systemctl is-active --quiet named; then
 echo "El servicio DNS esta en ejecucion"
else
 echo "El servicio DNS no esta activo"
fi

if systemctl is-enabled --quiet named; then
 echo "El servicio DNS esta habilitado al inciar "
else
 echo "El servicio DNS no esta habilitado al inciar"
fi

}

#agregar dns
agregar() {
DOMINIO=$1
IP=$2
ZONA="$ZONADIR/db.$DOMINIO"

if [ -z "$DOMINIO" ] || [ -z "$IP" ]; then
 echo "Uso ./DNS.sh agregar dominio IP"
 exit 1
fi

if ! validar_ip "$IP"; then
 echo "La IP ingresada no es valida"
exit 1
fi

if grep -q "zone \"$DOMINIO\"" $LOCALCONF; then
 echo "El dominio ya existe"
 exit 0
fi

echo "Creando zona para $DOMINIO"

cat <<EOF >> $LOCALCONF

zone "$DOMINIO" IN {
 type master;
 file "db.$DOMINIO";

};

EOF

 cat <<EOF > $ZONA
\$TTL 604800
@ IN SOA NS.$DOMINIO. admin.$DOMINIO. (
     1
     604800
     86400
     2419200
     604800 )

@	IN NS 	ns.$DOMINIO.
ns	IN A	$IP
@	IN A	$IP
WWW	IN CNAME @
EOF

chown named:named $ZONA
chmod 640 $ZONA

 systemctl restart named

configurar_dns_local

 echo "Dominio $DOMINIO agregado correctamente"
}

#listar dominios
listar() {
 echo "Dominios configurados:"

for ZONA in $ZONADIR/db.*; do
[ -f "$ZONA" ] || continue
DOMINIO=$(basename "$ZONA" | sed 's/^db\.//')
 IP=$(grep -E '^\s*@\s+IN\s+A\s+' "$ZONA" | awk '{print $4}')
echo "$DOMINIO -> $IP"
done
}

eliminar_dominio() {

DOMINIO="$1"

if [ -z "$DOMINIO" ]; then
 echo "Uso ./DNS.sh eliminar dominio.com"
exit 1
fi

ZONA_FILE="/var/named/db.$DOMINIO"
echo "Eliminando zona $DOMINIO"

sudo sed -i "/zone \"$DOMINIO\"/,/};/d" /etc/named.conf

if [ -f "$ZONA_FILE" ]; then
 sudo rm -f "$ZONA_FILE"
 echo "Archivo zona eliminado"
else
 echo "Archivo no econtrado"
fi

if sudo named-checkconf &>/dev/null; then
 sudo systemctl restart named
 echo "Dominio eliminado correctamente"
else
 echo "Error en configuracion"
fi
}

#desinstalar dns
desinstalar() {
 dnf remove -y bind bind-utils
 echo "DNS desinstalado"
}