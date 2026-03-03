#!/bin/bash

readonly PAQUETE="vsftpd"
readonly VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
readonly FTP_ROOT="/srv/ftp"
readonly GRUPO_REPROBADOS="reprobados"
readonly GRUPO_RECURSADORES="recursadores"
readonly INTERFAZ_RED="enp0s8"

ayuda() {
    echo "Uso: $0"
    echo " -verificar  Verificar"
    echo " -instalar  Instalar y configurar"
    echo " -usuarios  Gestionar usuarios"
    echo " -reinciar "
    echo " -estado "
    echo " -listar "
}

verificar_Instalacion() {
    if rpm -q $PAQUETE &>/dev/null; then
        echo "vsftpd instalado"
        return 0
    fi
    echo "vsftpd no instalado"
    return 1
}

crear_Grupos() {
    getent group $GRUPO_REPROBADOS &>/dev/null || groupadd $GRUPO_REPROBADOS
    getent group $GRUPO_RECURSADORES &>/dev/null || groupadd $GRUPO_RECURSADORES
}

crear_Estructura_Base() {

    mkdir -p $FTP_ROOT
    mkdir -p $FTP_ROOT/_users
    mkdir -p $FTP_ROOT/general
    mkdir -p $FTP_ROOT/$GRUPO_REPROBADOS
    mkdir -p $FTP_ROOT/$GRUPO_RECURSADORES
    mkdir -p /home/ftp_users

    chmod 755 $FTP_ROOT/general
    chmod 770 $FTP_ROOT/$GRUPO_REPROBADOS
    chmod 770 $FTP_ROOT/$GRUPO_RECURSADORES

    chgrp $GRUPO_REPROBADOS $FTP_ROOT/$GRUPO_REPROBADOS
    chgrp $GRUPO_RECURSADORES $FTP_ROOT/$GRUPO_RECURSADORES
}

configurar_Vsftpd() {

    grep -q "/sbin/nologin" /etc/shells || echo "/sbin/nologin" >> /etc/shells

    [ -f "$VSFTPD_CONF" ] && cp "$VSFTPD_CONF" "$VSFTPD_CONF.bak"

    tee $VSFTPD_CONF >/dev/null <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=YES
anon_root=$FTP_ROOT/general
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
user_sub_token=\$USER
local_root=/home/ftp_users/\$USER/ftp
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd.user_list
pam_service_name=login
EOF

    touch /etc/vsftpd.user_list
}

instalar_FTP() {

    if ! verificar_Instalacion; then
        urpmi --auto vsftpd
    fi

    crear_Grupos
    crear_Estructura_Base
    configurar_Vsftpd

    systemctl enable vsftpd
    systemctl restart vsftpd

    firewall-cmd --add-service=ftp --permanent 2>/dev/null
    firewall-cmd --add-port=40000-40100/tcp --permanent 2>/dev/null
    firewall-cmd --reload 2>/dev/null

    ip=$(ip addr show $INTERFAZ_RED | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)

    echo "Servidor listo"
    echo "IP: $ip"
    echo "Puerto: 21"
}

validar_Usuario() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{2,31}$ ]] || return 1
    id "$1" &>/dev/null && return 1
    return 0
}

crear_Usuario_FTP() {

    usuario=$1
    password=$2
    grupo=$3

    user_home="/home/ftp_users/$usuario"

    useradd -m -d "$user_home" -s /sbin/nologin -g "$grupo" "$usuario"
    echo "$usuario:$password" | chpasswd

    carpeta_personal="$FTP_ROOT/_users/$usuario"
    mkdir -p "$carpeta_personal"
    chown "$usuario:$grupo" "$carpeta_personal"
    chmod 700 "$carpeta_personal"

    mkdir -p "$user_home/ftp/$usuario"
    mkdir -p "$user_home/ftp/general"
    mkdir -p "$user_home/ftp/$grupo"

    mount --bind "$carpeta_personal" "$user_home/ftp/$usuario"
    mount --bind "$FTP_ROOT/general" "$user_home/ftp/general"
    mount --bind "$FTP_ROOT/$grupo" "$user_home/ftp/$grupo"

    echo "$carpeta_personal $user_home/ftp/$usuario none bind 0 0" >> /etc/fstab
    echo "$FTP_ROOT/general $user_home/ftp/general none bind 0 0" >> /etc/fstab
    echo "$FTP_ROOT/$grupo $user_home/ftp/$grupo none bind 0 0" >> /etc/fstab

    chown root:root "$user_home"
    chmod 755 "$user_home"
    chown root:root "$user_home/ftp"
    chmod 755 "$user_home/ftp"

    echo "$usuario" >> /etc/vsftpd.user_list

    systemctl restart vsftpd
}

gestionar_Usuarios() {

    echo "1 Crear usuario"
    echo "2 Eliminar usuario"
    read -p "Opcion: " op

    case $op in
        1)
            read -p "Usuario: " usuario
            read -s -p "Password: " password
            echo
            echo "1 $GRUPO_REPROBADOS"
            echo "2 $GRUPO_RECURSADORES"
            read -p "Grupo: " g

            [ "$g" = "1" ] && grupo=$GRUPO_REPROBADOS || grupo=$GRUPO_RECURSADORES

            validar_Usuario "$usuario" || { echo "Usuario invalido"; return; }

            crear_Usuario_FTP "$usuario" "$password" "$grupo"
        ;;
        2)
            read -p "Usuario a eliminar: " usuario
            userdel -r "$usuario"
            sed -i "/^$usuario$/d" /etc/vsftpd.user_list
            rm -rf "$FTP_ROOT/_users/$usuario"
            systemctl restart vsftpd
        ;;
    esac
}

listar_Estructura() {
    tree -L 2 $FTP_ROOT 2>/dev/null || ls -lR $FTP_ROOT
}

reiniciar_FTP() {
    systemctl restart vsftpd
}

ver_Estado() {
    systemctl status vsftpd --no-pager
    ss -tnlp | grep :21
}

if [[ $EUID -ne 0 ]]; then
    echo "Ejecuta como root"
    exit 1
fi

case $1 in
    -verificar | verificar)
 verificar_Instalacion
 ;;
    -instalar | instalar)
 instalar_FTP
 ;;
    -usuarios | usuarios)
 gestionar_Usuarios
 ;;
    -estado | estado)
 ver_Estado
 ;;
    -reiniciar | reiniciar)
 reiniciar_FTP
 ;;
    -listar | listar)
 listar_Estructura
 ;;
 *)
    ayuda
 ;;
esac
