#!/bin/bash

verde="\e[32m"; rojo="\e[31m"; amarillo="\e[33m"
cyan="\e[36m";  negrita="\e[1m"; nc="\e[0m"

print_info()      { echo -e "${white}[INFO]  $*${nc}"; }
print_ok()        { echo -e "${white}[OK]    $*${nc}"; }
print_error()     { echo -e "${rojo}[ERROR] $*${nc}"; }
print_warn()      { echo -e "${white}[WARN]  $*${nc}"; }
print_titulo()    { echo -e "\n${negrita}${amarillo}=== $* ===${nc}\n"; }

readonly FTP_ROOT="/srv/ftp"
readonly GRUPO_REPROBADOS="reprobados"
readonly GRUPO_RECURSADORES="recursadores"
readonly VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
readonly VSFTPD_USER_DIR="/etc/vsftpd/users"
readonly FTP_USERLIST="/etc/vsftpd/ftp_users"
readonly FTPUSERS_BLACKLIST="/etc/vsftpd/ftpusers"
readonly FTP_HOMES="/home/ftp_users"

if [[ $EUID -ne 0 ]]; then
    print_error "Este script debe ejecutarse como root"
    exit 1
fi

fix_pam() {
    grep -qx "/sbin/nologin" /etc/shells || {
        echo "/sbin/nologin" >> /etc/shells
        print_ok "/sbin/nologin agregado a /etc/shells"
    }
    cat > /etc/pam.d/vsftpd << 'EOF'
#%PAM-1.0
auth     required    pam_unix.so     shadow nullok
account  required    pam_unix.so
session  required    pam_unix.so
EOF
    print_ok "PAM vsftpd configurado"
}

fix_blacklist() {
    local usuario="$1"
    [[ -f "$FTPUSERS_BLACKLIST" ]] && \
        grep -qx "$usuario" "$FTPUSERS_BLACKLIST" 2>/dev/null && {
        sed -i "/^${usuario}$/d" "$FTPUSERS_BLACKLIST"
        print_ok "'$usuario' quitado de ftpusers"
    }
}

verificar() {
    print_info "Verificando instalacion de vsftpd..."
    if rpm -q vsftpd &>/dev/null; then
        local ver
        ver=$(rpm -q vsftpd --queryformat '%{VERSION}')
        print_ok "vsftpd instalado (version: $ver)"
        return 0
    fi
    print_warn "vsftpd NO esta instalado"
    return 1
}

crear_grupos() {
    print_info "Verificando grupos..."
    for grupo in "$GRUPO_REPROBADOS" "$GRUPO_RECURSADORES"; do
        if ! getent group "$grupo" &>/dev/null; then
            groupadd "$grupo"
            print_ok "Grupo '$grupo' creado"
        else
            print_info "Grupo '$grupo' ya existe"
        fi
    done
}

crear_estructura() {
    print_info "Creando estructura de directorios..."

    local dirs=(
        "$FTP_ROOT"
        "$FTP_ROOT/general"
        "$FTP_ROOT/$GRUPO_REPROBADOS"
        "$FTP_ROOT/$GRUPO_RECURSADORES"
        "$FTP_ROOT/personal"
        "$FTP_HOMES"
        "$VSFTPD_USER_DIR"
    )

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || { mkdir -p "$dir" && print_ok "Creado: $dir"; }
    done

    # Raiz FTP: root la posee, no escribible por nadie externo
    chown root:root "$FTP_ROOT"          && chmod 755 "$FTP_ROOT"
    chown root:root "$FTP_HOMES"         && chmod 755 "$FTP_HOMES"

    # general: la jaula del anonimo
    # - Propiedad de root:root (vsftpd exige que la raiz de jaula sea de root)
    # - Permisos 755: el anonimo puede listar y descargar, nadie puede escribir
    chown root:root "$FTP_ROOT/general"
    chmod 755 "$FTP_ROOT/general"

    # Carpeta personal (montada en jaulas de usuarios autenticados)
    chown root:root "$FTP_ROOT/personal" && chmod 755 "$FTP_ROOT/personal"

    chown root:"$GRUPO_REPROBADOS"   "$FTP_ROOT/$GRUPO_REPROBADOS"
    chmod 770 "$FTP_ROOT/$GRUPO_REPROBADOS"
    chmod +t  "$FTP_ROOT/$GRUPO_REPROBADOS"

    chown root:"$GRUPO_RECURSADORES" "$FTP_ROOT/$GRUPO_RECURSADORES"
    chmod 770 "$FTP_ROOT/$GRUPO_RECURSADORES"
    chmod +t  "$FTP_ROOT/$GRUPO_RECURSADORES"

    print_ok "Estructura lista"
}

configurar_vsftpd() {
    print_info "Configurando vsftpd..."

    [[ -f "$VSFTPD_CONF" ]] && \
        cp "$VSFTPD_CONF" "${VSFTPD_CONF}.bak.$(date +%Y%m%d_%H%M%S)"

    mkdir -p "$VSFTPD_USER_DIR"

    # Lista blanca de usuarios autenticados (el anonimo NO va aqui)
    : > "$FTP_USERLIST"

    cat > "$VSFTPD_CONF" << EOF
listen=YES
listen_ipv6=NO

# --- Usuarios locales autenticados ---
local_enable=YES
write_enable=YES
local_umask=022

# --- Anonimo: entra sin usuario ni contrasena, solo ve /general ---
anonymous_enable=YES
ftp_username=ftp
anon_root=$FTP_ROOT/general
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO
anon_world_readable_only=YES

# --- Jaula (chroot) para usuarios autenticados ---
chroot_local_user=YES
allow_writeable_chroot=YES
user_sub_token=\$USER
local_root=$FTP_HOMES/\$USER
user_config_dir=$VSFTPD_USER_DIR

# --- Lista blanca: SOLO usuarios autenticados la usan ---
# El anonimo NO pasa por esta lista, vsftpd lo maneja aparte
userlist_enable=YES
userlist_file=$FTP_USERLIST
userlist_deny=NO

# --- PAM: solo para autenticados, el anonimo lo omite vsftpd ---
pam_service_name=vsftpd

# --- Seguridad y opciones generales ---
hide_ids=YES
use_localtime=YES
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
log_ftp_protocol=YES
xferlog_std_format=YES
connect_from_port_20=YES
idle_session_timeout=600
data_connection_timeout=120
dirmessage_enable=YES
ftpd_banner=Bienvenido al servidor FTP

# --- Modo pasivo ---
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100

# --- Compatibilidad Mageia / RHEL ---
seccomp_sandbox=NO
EOF

    # Sincronizar con /etc/vsftpd.conf si existe (Mageia lo puede usar tambien)
    cp "$VSFTPD_CONF" /etc/vsftpd.conf 2>/dev/null

    # Crear/ajustar usuario ftp del sistema (jaula del anonimo)
    if ! id ftp &>/dev/null; then
        useradd -r -d "$FTP_ROOT/general" -s /sbin/nologin ftp
        print_ok "Usuario 'ftp' del sistema creado"
    else
        usermod -d "$FTP_ROOT/general" ftp 2>/dev/null
    fi

    # La raiz de la jaula anonima debe ser propiedad de root
    chown root:root "$FTP_ROOT/general"
    chmod 755 "$FTP_ROOT/general"

    # Asegurarse de que ftp no este en la lista negra
    fix_blacklist "ftp"

    print_ok "vsftpd configurado"
}

configurar_firewall() {
    print_info "Configurando firewall..."
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=21/tcp          &>/dev/null
        firewall-cmd --permanent --add-port=40000-40100/tcp &>/dev/null
        firewall-cmd --permanent --add-service=ftp          &>/dev/null
        firewall-cmd --reload                               &>/dev/null
        print_ok "Firewall: puertos 21 y 40000-40100 abiertos"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport 21 -j ACCEPT
        iptables -I INPUT -p tcp --dport 40000:40100 -j ACCEPT
        print_ok "iptables: puertos abiertos"
    else
        print_warn "Sin firewall detectado - verifica el puerto 21 manualmente"
    fi
}

construir_jaula() {
    local usuario="$1"
    local grupo="$2"
    local jaula="$FTP_HOMES/$usuario"

    print_info "Construyendo jaula para '$usuario'..."

    mkdir -p "$jaula"
    chown root:root "$jaula"
    chmod 755 "$jaula"

    mkdir -p "$jaula/general"
    mkdir -p "$jaula/$grupo"
    mkdir -p "$jaula/$usuario"

    chown root:root "$jaula/general"  && chmod 755 "$jaula/general"
    chown root:root "$jaula/$grupo"   && chmod 755 "$jaula/$grupo"
    chown "$usuario":"$grupo" "$jaula/$usuario" && chmod 700 "$jaula/$usuario"

    mountpoint -q "$jaula/general" 2>/dev/null || {
        mount --bind "$FTP_ROOT/general" "$jaula/general"
        print_ok "Bind mount: general"
    }

    mountpoint -q "$jaula/$grupo" 2>/dev/null || {
        mount --bind "$FTP_ROOT/$grupo" "$jaula/$grupo"
        print_ok "Bind mount: $grupo"
    }

    local personal="$FTP_ROOT/personal/$usuario"
    [[ -d "$personal" ]] || {
        mkdir -p "$personal"
        chown "$usuario":"$grupo" "$personal"
        chmod 700 "$personal"
    }

    mountpoint -q "$jaula/$usuario" 2>/dev/null || {
        mount --bind "$personal" "$jaula/$usuario"
        print_ok "Bind mount: $usuario (personal)"
    }

    local entries=(
        "$FTP_ROOT/general $jaula/general none bind 0 0"
        "$FTP_ROOT/$grupo $jaula/$grupo none bind 0 0"
        "$FTP_ROOT/personal/$usuario $jaula/$usuario none bind 0 0"
    )
    for entry in "${entries[@]}"; do
        grep -Fx "$entry" /etc/fstab &>/dev/null || echo "$entry" >> /etc/fstab
    done

    echo "local_root=$jaula" > "$VSFTPD_USER_DIR/$usuario"
    print_ok "Jaula lista: $jaula"
}

destruir_jaula() {
    local usuario="$1"
    local jaula="$FTP_HOMES/$usuario"

    print_info "Desmontando jaula de '$usuario'..."

    for punto in "$jaula/$usuario" "$jaula/$GRUPO_REPROBADOS" \
                 "$jaula/$GRUPO_RECURSADORES" "$jaula/general"; do
        mountpoint -q "$punto" 2>/dev/null && {
            umount "$punto" && print_ok "Desmontado: $punto"
        }
    done

    sed -i "\| $jaula/|d" /etc/fstab 2>/dev/null
    rm -f "$VSFTPD_USER_DIR/$usuario"
    rm -rf "$jaula"
    print_ok "Jaula eliminada"
}

validar_usuario() {
    local u="$1"
    [[ -z "$u" ]]                       && print_error "Nombre vacio"                    && return 1
    [[ ${#u} -lt 3 || ${#u} -gt 20 ]]  && print_error "Entre 3 y 20 caracteres"         && return 1
    [[ ! "$u" =~ ^[a-z][a-z0-9_-]*$ ]] && print_error "Solo minusculas, numeros, - y _" && return 1
    id "$u" &>/dev/null                 && print_error "Usuario '$u' ya existe"          && return 1
    return 0
}

validar_contrasena() {
    local p="$1"
    [[ ${#p} -lt 8 ]]            && print_error "Minimo 8 caracteres"         && return 1
    [[ ! "$p" =~ [A-Z] ]]        && print_error "Necesita una mayuscula"      && return 1
    [[ ! "$p" =~ [0-9] ]]        && print_error "Necesita un numero"          && return 1
    [[ ! "$p" =~ [^a-zA-Z0-9] ]] && print_error "Necesita un simbolo (@#\$%)" && return 1
    return 0
}

crear_usuario() {
    local usuario="$1"
    local password="$2"
    local grupo="$3"

    useradd -M -s /sbin/nologin \
        -d "$FTP_HOMES/$usuario" \
        -g "$grupo" \
        -c "Usuario FTP - $grupo" \
        "$usuario" || {
        print_error "Error al crear '$usuario'"
        return 1
    }
    print_ok "Usuario del sistema creado"

    echo "$usuario:$password" | chpasswd || {
        print_error "Error al establecer contrasena"
        userdel "$usuario" 2>/dev/null
        return 1
    }
    print_ok "Contrasena establecida"

    fix_blacklist "$usuario"
    grep -qx "$usuario" "$FTP_USERLIST" 2>/dev/null || echo "$usuario" >> "$FTP_USERLIST"

    construir_jaula "$usuario" "$grupo"

    echo ""
    print_ok ""
    print_ok "  Usuario '$usuario' creado"
    print_ok ""
    print_info "  Grupo    : $grupo"
    print_info "  Al conectar ve:"
    print_info "    /general/"
    print_info "    /$grupo/"
    print_info "    /$usuario/"
    print_ok ""
    return 0
}

cambiar_grupo() {
    local usuario="$1"

    id "$usuario" &>/dev/null || {
        print_error "Usuario '$usuario' no existe"
        return 1
    }

    local grupo_actual
    grupo_actual=$(id -gn "$usuario")

    echo ""
    print_info "Usuario     : $usuario"
    print_info "Grupo actual: $grupo_actual"
    echo ""
    echo "1) $GRUPO_REPROBADOS"
    echo "2) $GRUPO_RECURSADORES"
    echo ""
    read -rp "Nuevo grupo: " op

    local nuevo_grupo
    case "$op" in
        1) nuevo_grupo="$GRUPO_REPROBADOS"   ;;
        2) nuevo_grupo="$GRUPO_RECURSADORES" ;;
        *) print_warn "Opcion invalida" && return 1 ;;
    esac

    [[ "$grupo_actual" == "$nuevo_grupo" ]] && {
        print_warn "Ya pertenece a '$nuevo_grupo'"
        return 0
    }

    destruir_jaula "$usuario"
    usermod -g "$nuevo_grupo" "$usuario" && print_ok "Grupo actualizado"

    local personal="$FTP_ROOT/personal/$usuario"
    [[ -d "$personal" ]] || {
        mkdir -p "$personal"
        chown "$usuario":"$nuevo_grupo" "$personal"
        chmod 700 "$personal"
    }

    construir_jaula "$usuario" "$nuevo_grupo"
    systemctl restart vsftpd
    print_ok "Usuario '$usuario' -> '$nuevo_grupo' - reconecta FileZilla"
}

listar() {
    print_titulo "UsuariosFTP"

    if [[ ! -s "$FTP_USERLIST" ]]; then
        print_info "No hay usuarios FTP configurados"
        return 0
    fi

    local n=0
    printf "%-20s %-15s %-8s %-8s\n" "USUARIO" "GRUPO" "JAULA" "MOUNTS"
    printf "%-20s %-15s %-8s %-8s\n" "-------" "-----" "-----" "------"

    while IFS= read -r u; do
        [[ -z "$u" || "$u" == "anonymous" || "$u" == "ftp" ]] && continue
        id "$u" &>/dev/null || continue

        local g m=0
        g=$(id -gn "$u")
        local jaula="$FTP_HOMES/$u"
        local st="FALTA"; [[ -d "$jaula" ]] && st="OK"

        mountpoint -q "$jaula/general" 2>/dev/null && m=$((m+1))
        mountpoint -q "$jaula/$g"      2>/dev/null && m=$((m+1))
        mountpoint -q "$jaula/$u"      2>/dev/null && m=$((m+1))

        printf "%-20s %-15s %-8s %-8s\n" "$u" "$g" "$st" "$m/3"
        n=$((n+1))
    done < "$FTP_USERLIST"

    [[ $n -eq 0 ]] && print_warn "No hay usuarios FTP"
    echo ""
}

estado() {
    print_titulo "Estado del Servidor FTP"

    echo -n "vsftpd : "
    systemctl is-active vsftpd

    echo ""
    echo "Puerto 21:"
    ss -tlnp | grep ":21" || echo "  (no escucha)"

    echo ""
    local ip
    ip=$(hostname -I | awk '{print $1}')
    print_info "IP servidor: $ip"

    echo ""
    print_info "Checks anonimo:"
    id ftp &>/dev/null \
        && print_ok "  Usuario 'ftp' existe" \
        || print_warn "  Usuario 'ftp' NO existe"
    [[ -d "$FTP_ROOT/general" ]] \
        && print_ok "  $FTP_ROOT/general existe" \
        || print_warn "  $FTP_ROOT/general NO existe"
    local perms
    perms=$(stat -c "%a" "$FTP_ROOT/general" 2>/dev/null)
    [[ "$perms" == "755" ]] \
        && print_ok "  Permisos de /general correctos (755)" \
        || print_warn "  Permisos de /general: $perms (se necesita 755)"
    grep -qx "ftp" "$FTPUSERS_BLACKLIST" 2>/dev/null \
        && print_warn "  'ftp' esta en la lista negra ftpusers (bloquea anonimo)" \
        || print_ok "  'ftp' NO esta en la lista negra"

    echo ""
    print_info "Checks PAM:"
    grep -qx "/sbin/nologin" /etc/shells \
        && print_ok "  /sbin/nologin en /etc/shells" \
        || print_warn "  /sbin/nologin NO en /etc/shells"
    grep -q "pam_unix" /etc/pam.d/vsftpd 2>/dev/null \
        && print_ok "  PAM vsftpd correcto" \
        || print_warn "  PAM vsftpd tiene problemas"

    echo ""
    listar
}

reiniciar() {
    print_info "Reiniciando vsftpd"
    systemctl restart vsftpd
    sleep 1
    systemctl is-active --quiet vsftpd \
        && print_ok "vsftpd reiniciado correctamente" \
        || print_error "Fallo al reiniciar vsftpd"
}

instalar() {
    print_titulo "Instalacion"

    if verificar 2>/dev/null; then
        echo ""
        read -rp "vsftpd ya instalado. Reconfigurar? (s/n): " r
        [[ "$r" != "s" ]] && print_info "Cancelado" && return
        systemctl stop vsftpd 2>/dev/null
    else
        print_info "Instalando vsftpd con urpmi..."
        urpmi --auto vsftpd
        rpm -q vsftpd &>/dev/null || {
            print_error "Fallo la instalacion de vsftpd"
            exit 1
        }
        print_ok "vsftpd instalado"
    fi

    echo ""
    fix_pam
    echo ""
    crear_grupos
    echo ""
    crear_estructura
    echo ""
    configurar_vsftpd
    echo ""
    configurar_firewall
    echo ""

    systemctl enable vsftpd &>/dev/null
    systemctl restart vsftpd

    systemctl is-active --quiet vsftpd || {
        print_error "vsftpd no pudo iniciar"
        print_error "Revisa: journalctl -xeu vsftpd.service"
        return 1
    }

    local ip
    ip=$(hostname -I | awk '{print $1}')

    echo ""
    print_ok ""
    print_ok "  Servidor FTP listo"
    print_ok ""
    print_info "  IP     : ftp://$ip"
    print_info "  Puerto : 21"
    print_info "  Anonimo  -> conecta sin usuario ni contrasena"
    print_info ""
    print_info "  Usuarios -> ./ftpl.sh users"
    print_ok ""
}

usuarios() {
    print_titulo "Gestion de Usuarios FTP"

    verificar &>/dev/null || {
        print_error "vsftpd no instalado. Ejecuta: ./ftpl.sh install"
        return 1
    }

    echo "1) Crear usuarios"
    echo "2) Cambiar grupo"
    echo "3) Eliminar usuario"
    echo ""
    read -rp "Opcion: " op

    case "$op" in
        1)
            read -rp "Cuantos usuarios?: " num
            [[ ! "$num" =~ ^[0-9]+$ || "$num" -lt 1 ]] && {
                print_error "Numero invalido"
                return 1
            }

            for ((i=1; i<=num; i++)); do
                print_titulo "Usuario $i de $num"

                while true; do
                    read -rp "Nombre de usuario : " usuario
                    validar_usuario "$usuario" && break
                done

                while true; do
                    read -rsp "Contrasena        : " password; echo ""
                    validar_contrasena "$password" || continue
                    read -rsp "Confirmar         : " password2; echo ""
                    [[ "$password" == "$password2" ]] && break
                    print_error "Las contrasenas no coinciden"
                done

                echo ""
                echo "  1) $GRUPO_REPROBADOS"
                echo "  2) $GRUPO_RECURSADORES"
                read -rp "Grupo: " g
                [[ "$g" == "1" ]] && grupo="$GRUPO_REPROBADOS" || grupo="$GRUPO_RECURSADORES"

                crear_usuario "$usuario" "$password" "$grupo"
            done

            systemctl restart vsftpd && print_ok "Servicio reiniciado"
            ;;
        2)
            listar
            read -rp "Usuario a cambiar de grupo: " u
            cambiar_grupo "$u"
            ;;
        3)
            listar
            read -rp "Usuario a eliminar: " u
            id "$u" &>/dev/null || {
                print_error "No existe '$u'"
                return 1
            }
            read -rp "Confirma eliminar '$u'? (s/n): " c
            if [[ "$c" == "s" ]]; then
                destruir_jaula "$u"
                rm -rf "$FTP_ROOT/personal/$u"
                sed -i "/^${u}$/d" "$FTP_USERLIST"       2>/dev/null
                sed -i "/^${u}$/d" "$FTPUSERS_BLACKLIST" 2>/dev/null
                rm -f "$VSFTPD_USER_DIR/$u"
                userdel "$u" 2>/dev/null
                print_ok "Usuario '$u' eliminado"
                systemctl restart vsftpd && print_ok "Servicio reiniciado"
            else
                print_info "Cancelado"
            fi
            ;;
        *) print_warn "Opcion invalida" ;;
    esac
}

case "${1:-}" in
    verify)   verificar  ;;
    install)  instalar   ;;
    users)    usuarios   ;;
    restart)  reiniciar  ;;
    status)   estado     ;;
    list)     listar     ;;
    *)        echo -e "\nUso: ./ftpl.sh [verify|install|users|restart|status|list]\n" ;;
esac
