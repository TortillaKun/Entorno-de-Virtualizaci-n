#!/bin/bash

# ============================================================
# ftpl.sh - Servidor FTP para Mageia 9
# Uso: ./ftpl.sh [verificar|instalar|usuarios|reiniciar|estado|listar|ayuda]
# ============================================================

# --- Colores ---
verde="\e[32m"; rojo="\e[31m"; amarillo="\e[33m"
cyan="\e[36m";  negrita="\e[1m"; nc="\e[0m"

print_info()      { echo -e "${cyan}[INFO]  $*${nc}"; }
print_ok()        { echo -e "${verde}[OK]    $*${nc}"; }
print_error()     { echo -e "${rojo}[ERROR] $*${nc}"; }
print_warn()      { echo -e "${amarillo}[WARN]  $*${nc}"; }
print_titulo()    { echo -e "\n${negrita}${amarillo}=== $* ===${nc}\n"; }

# --- Variables globales ---
readonly FTP_ROOT="/srv/ftp"
readonly GRUPO_REPROBADOS="reprobados"
readonly GRUPO_RECURSADORES="recursadores"
readonly VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
readonly VSFTPD_USER_DIR="/etc/vsftpd/users"
readonly FTP_USERLIST="/etc/vsftpd/ftp_users"
readonly FTPUSERS_BLACKLIST="/etc/vsftpd/ftpusers"
readonly FTP_HOMES="/home/ftp_users"

# --- Verificar root ---
if [[ $EUID -ne 0 ]]; then
    print_error "Este script debe ejecutarse como root"
    exit 1
fi

# ============================================================
# AYUDA
# ============================================================
ayuda() {
    echo ""
    echo -e "${negrita}Uso: ./ftpl.sh [comando]${nc}"
    echo ""
    echo "  verificar   Verifica si vsftpd esta instalado"
    echo "  instalar    Instala y configura el servidor FTP"
    echo "  usuarios    Gestionar usuarios FTP"
    echo "  reiniciar   Reiniciar servidor FTP"
    echo "  estado      Ver estado del servidor FTP"
    echo "  listar      Listar usuarios y estructura FTP"
    echo "  ayuda       Muestra esta ayuda"
    echo ""
}

# ============================================================
# FIX PAM - Mageia 9 requiere estas dos cosas:
#   1. /sbin/nologin en /etc/shells
#   2. PAM sin pam_shells ni pam_listfile
# ============================================================
fix_pam() {
    # /sbin/nologin debe estar en /etc/shells
    grep -qx "/sbin/nologin" /etc/shells || {
        echo "/sbin/nologin" >> /etc/shells
        print_ok "/sbin/nologin agregado a /etc/shells"
    }

    # PAM minimo sin modulos que bloqueen nologin
    cat > /etc/pam.d/vsftpd << 'EOF'
#%PAM-1.0
auth     required    pam_unix.so     shadow nullok
account  required    pam_unix.so
session  required    pam_unix.so
EOF
    print_ok "PAM vsftpd configurado"
}

# ============================================================
# QUITAR USUARIO DE LISTA NEGRA
# ============================================================
fix_blacklist() {
    local usuario="$1"
    [[ -f "$FTPUSERS_BLACKLIST" ]] && \
        grep -qx "$usuario" "$FTPUSERS_BLACKLIST" 2>/dev/null && {
        sed -i "/^${usuario}$/d" "$FTPUSERS_BLACKLIST"
        print_ok "'$usuario' quitado de ftpusers"
    }
}

# ============================================================
# VERIFICAR INSTALACION
# ============================================================
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

# ============================================================
# CREAR GRUPOS
# ============================================================
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

# ============================================================
# CREAR ESTRUCTURA DE DIRECTORIOS
# ============================================================
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

    # Permisos base
    chown root:root "$FTP_ROOT"         && chmod 755 "$FTP_ROOT"
    chown root:root "$FTP_ROOT/personal" && chmod 755 "$FTP_ROOT/personal"
    chown root:root "$FTP_HOMES"         && chmod 755 "$FTP_HOMES"

    # general: lectura/escritura para todos, sticky bit
    chown root:root "$FTP_ROOT/general"
    chmod 777 "$FTP_ROOT/general"
    chmod +t  "$FTP_ROOT/general"

    # grupos: solo miembros + sticky bit
    chown root:"$GRUPO_REPROBADOS"  "$FTP_ROOT/$GRUPO_REPROBADOS"
    chmod 770 "$FTP_ROOT/$GRUPO_REPROBADOS"
    chmod +t  "$FTP_ROOT/$GRUPO_REPROBADOS"

    chown root:"$GRUPO_RECURSADORES" "$FTP_ROOT/$GRUPO_RECURSADORES"
    chmod 770 "$FTP_ROOT/$GRUPO_RECURSADORES"
    chmod +t  "$FTP_ROOT/$GRUPO_RECURSADORES"

    print_ok "Estructura lista"
}

# ============================================================
# CONFIGURAR VSFTPD
# NOTAS MAGEIA 9:
#   - systemd usa /etc/vsftpd/vsftpd.conf (hardcodeado)
#   - pam_service_name=vsftpd es OBLIGATORIO en Mageia
#   - local_root apunta a la carpeta personal del usuario
# ============================================================
configurar_vsftpd() {
    print_info "Configurando vsftpd..."

    [[ -f "$VSFTPD_CONF" ]] && \
        cp "$VSFTPD_CONF" "${VSFTPD_CONF}.bak.$(date +%Y%m%d_%H%M%S)"

    mkdir -p "$VSFTPD_USER_DIR"

    # Lista blanca limpia
    printf "anonymous\nftp\n" > "$FTP_USERLIST"

    cat > "$VSFTPD_CONF" << EOF
# vsftpd.conf - Mageia 9
# Generado por ftpl.sh

listen=YES
listen_ipv6=NO

# --- Usuarios locales ---
local_enable=YES
write_enable=YES
local_umask=022

# --- Anonimo: solo lectura en /general ---
anonymous_enable=YES
anon_root=$FTP_ROOT/general
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# --- Chroot: jaula por usuario ---
# El usuario entra directamente a su carpeta personal
chroot_local_user=YES
allow_writeable_chroot=YES
user_sub_token=\$USER
local_root=$FTP_HOMES/\$USER
user_config_dir=$VSFTPD_USER_DIR

# --- Seguridad ---
hide_ids=YES
use_localtime=YES

# --- Logs ---
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
log_ftp_protocol=YES
xferlog_std_format=YES

# --- Conexion ---
connect_from_port_20=YES
idle_session_timeout=600
data_connection_timeout=120

# --- Mensajes ---
dirmessage_enable=YES
ftpd_banner=Bienvenido al servidor FTP

# --- Modo pasivo ---
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100

# --- Lista blanca de usuarios ---
userlist_enable=YES
userlist_file=$FTP_USERLIST
userlist_deny=NO

# --- PAM: OBLIGATORIO en Mageia 9 ---
pam_service_name=vsftpd
EOF

    # Sincronizar con /etc/vsftpd.conf por si acaso
    cp "$VSFTPD_CONF" /etc/vsftpd.conf 2>/dev/null

    # Usuario ftp para acceso anonimo
    if ! id ftp &>/dev/null; then
        useradd -r -d "$FTP_ROOT/general" -s /sbin/nologin ftp
        print_ok "Usuario 'ftp' creado"
    fi
    fix_blacklist "ftp"

    print_ok "vsftpd configurado"
}

# ============================================================
# CONFIGURAR FIREWALL
# ============================================================
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

# ============================================================
# CONSTRUIR JAULA CON BIND MOUNTS
#
# Estructura que ve el usuario al conectar:
#   /                    <- raiz de la jaula (root:root 755)
#   /general/            <- bind mount a /srv/ftp/general
#   /<grupo>/            <- bind mount a /srv/ftp/<grupo>
#   /<usuario>/          <- carpeta personal (bind mount a /srv/ftp/personal/<usuario>)
#
# El local_root apunta a /home/ftp_users/<usuario>
# que es la raiz de la jaula (root:root 755)
# ============================================================
construir_jaula() {
    local usuario="$1"
    local grupo="$2"
    local jaula="$FTP_HOMES/$usuario"

    print_info "Construyendo jaula para '$usuario'..."

    # Raiz de la jaula: root:root 755 (vsftpd lo exige)
    mkdir -p "$jaula"
    chown root:root "$jaula"
    chmod 755 "$jaula"

    # Puntos de montaje dentro de la jaula
    mkdir -p "$jaula/general"
    mkdir -p "$jaula/$grupo"
    mkdir -p "$jaula/$usuario"

    chown root:root "$jaula/general"  && chmod 755 "$jaula/general"
    chown root:root "$jaula/$grupo"   && chmod 755 "$jaula/$grupo"
    chown "$usuario":"$grupo" "$jaula/$usuario" && chmod 700 "$jaula/$usuario"

    # Bind mounts
    mountpoint -q "$jaula/general" 2>/dev/null || {
        mount --bind "$FTP_ROOT/general" "$jaula/general"
        print_ok "Bind mount: general"
    }

    mountpoint -q "$jaula/$grupo" 2>/dev/null || {
        mount --bind "$FTP_ROOT/$grupo" "$jaula/$grupo"
        print_ok "Bind mount: $grupo"
    }

    mountpoint -q "$jaula/$usuario" 2>/dev/null || {
        mount --bind "$FTP_ROOT/personal/$usuario" "$jaula/$usuario"
        print_ok "Bind mount: $usuario (personal)"
    }

    # Persistencia en fstab
    local entries=(
        "$FTP_ROOT/general $jaula/general none bind 0 0"
        "$FTP_ROOT/$grupo $jaula/$grupo none bind 0 0"
        "$FTP_ROOT/personal/$usuario $jaula/$usuario none bind 0 0"
    )
    for entry in "${entries[@]}"; do
        grep -Fx "$entry" /etc/fstab &>/dev/null || echo "$entry" >> /etc/fstab
    done

    # Config individual: local_root apunta a la jaula
    echo "local_root=$jaula" > "$VSFTPD_USER_DIR/$usuario"

    print_ok "Jaula lista: $jaula"
}

# ============================================================
# DESTRUIR JAULA
# ============================================================
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

# ============================================================
# VALIDAR NOMBRE DE USUARIO
# ============================================================
validar_usuario() {
    local u="$1"
    [[ -z "$u" ]]                       && print_error "Nombre vacio"                    && return 1
    [[ ${#u} -lt 3 || ${#u} -gt 20 ]]  && print_error "Entre 3 y 20 caracteres"         && return 1
    [[ ! "$u" =~ ^[a-z][a-z0-9_-]*$ ]] && print_error "Solo minusculas, numeros, - y _" && return 1
    id "$u" &>/dev/null                 && print_error "Usuario '$u' ya existe"          && return 1
    return 0
}

# ============================================================
# VALIDAR CONTRASENA
# ============================================================
validar_contrasena() {
    local p="$1"
    [[ ${#p} -lt 8 ]]            && print_error "Minimo 8 caracteres"      && return 1
    [[ ! "$p" =~ [A-Z] ]]        && print_error "Necesita una mayuscula"   && return 1
    [[ ! "$p" =~ [0-9] ]]        && print_error "Necesita un numero"       && return 1
    [[ ! "$p" =~ [^a-zA-Z0-9] ]] && print_error "Necesita un simbolo (@#\$%)" && return 1
    return 0
}

# ============================================================
# CREAR USUARIO FTP
# ============================================================
crear_usuario() {
    local usuario="$1"
    local password="$2"
    local grupo="$3"

    # Crear usuario del sistema
    useradd -M -s /sbin/nologin \
        -d "$FTP_HOMES/$usuario" \
        -g "$grupo" \
        -c "Usuario FTP - $grupo" \
        "$usuario" || {
        print_error "Error al crear '$usuario'"
        return 1
    }
    print_ok "Usuario del sistema creado"

    # Establecer contrasena
    echo "$usuario:$password" | chpasswd || {
        print_error "Error al establecer contrasena"
        userdel "$usuario" 2>/dev/null
        return 1
    }
    print_ok "Contrasena establecida"

    # Quitar de lista negra y agregar a lista blanca
    fix_blacklist "$usuario"
    grep -qx "$usuario" "$FTP_USERLIST" 2>/dev/null || echo "$usuario" >> "$FTP_USERLIST"

    # Crear carpeta personal real en /srv/ftp/personal/
    local personal="$FTP_ROOT/personal/$usuario"
    [[ -d "$personal" ]] || {
        mkdir -p "$personal"
        chown "$usuario":"$grupo" "$personal"
        chmod 700 "$personal"
        print_ok "Carpeta personal: $personal"
    }

    # Construir jaula
    construir_jaula "$usuario" "$grupo"

    echo ""
    print_ok "════════════════════════════════════════"
    print_ok "  Usuario '$usuario' creado"
    print_ok "════════════════════════════════════════"
    print_info "  Grupo    : $grupo"
    print_info "  Al conectar ve:"
    print_info "    /general/   (compartida)"
    print_info "    /$grupo/    (su grupo)"
    print_info "    /$usuario/  (personal)"
    print_ok "════════════════════════════════════════"
    return 0
}

# ============================================================
# CAMBIAR GRUPO DE USUARIO
# ============================================================
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

# ============================================================
# LISTAR USUARIOS FTP
# ============================================================
listar() {
    print_titulo "Usuarios FTP"

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

# ============================================================
# ESTADO DEL SERVIDOR
# ============================================================
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
    print_info "Checks PAM:"
    grep -qx "/sbin/nologin" /etc/shells \
        && print_ok "  /sbin/nologin en /etc/shells" \
        || print_warn "  /sbin/nologin NO en /etc/shells"
    grep -q "pam_unix" /etc/pam.d/vsftpd 2>/dev/null \
        && print_ok "  PAM vsftpd correcto" \
        || print_warn "  PAM vsftpd tiene problemas"
    grep -q "pam_service_name" "$VSFTPD_CONF" 2>/dev/null \
        && print_ok "  pam_service_name configurado" \
        || print_warn "  pam_service_name FALTA en vsftpd.conf"

    echo ""
    listar
}

# ============================================================
# REINICIAR
# ============================================================
reiniciar() {
    print_info "Reiniciando vsftpd..."
    systemctl restart vsftpd
    sleep 1
    systemctl is-active --quiet vsftpd \
        && print_ok "vsftpd reiniciado correctamente" \
        || print_error "Fallo al reiniciar vsftpd"
}

# ============================================================
# INSTALAR
# ============================================================
instalar() {
    print_titulo "Instalacion del Servidor FTP - Mageia 9"

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
    print_ok "════════════════════════════════════════"
    print_ok "  Servidor FTP listo"
    print_ok "════════════════════════════════════════"
    print_info "  IP     : ftp://$ip"
    print_info "  Puerto : 21"
    print_info "  Anonimo  -> /general (solo lectura)"
    print_info "  Usuarios -> ./ftpl.sh usuarios"
    print_ok "════════════════════════════════════════"
}

# ============================================================
# GESTIONAR USUARIOS
# ============================================================
usuarios() {
    print_titulo "Gestion de Usuarios FTP"

    verificar &>/dev/null || {
        print_error "vsftpd no instalado. Ejecuta: ./ftpl.sh instalar"
        return 1
    }

    echo "1) Crear usuario(s)"
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

# ============================================================
# MAIN
# ============================================================
case "${1:-}" in
    verificar)  verificar  ;;
    instalar)   instalar   ;;
    usuarios)   usuarios   ;;
    reiniciar)  reiniciar  ;;
    estado)     estado     ;;
    listar)     listar     ;;
    ayuda)      ayuda      ;;
    *)          ayuda      ;;
esac