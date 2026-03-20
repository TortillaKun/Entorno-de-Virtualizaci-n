#!/bin/bash

verde="\e[32m"
rojo="\e[31m"
amarillo="\e[33m"
cyan="\e[36m"
negrita="\e[1m"
nc="\e[0m"

print_info()   { echo -e "${cyan}[INFO]  $*${nc}"; }
print_ok()     { echo -e "${verde}[OK]    $*${nc}"; }
print_error()  { echo -e "${rojo}[ERROR] $*${nc}"; }
print_warn()   { echo -e "${amarillo}[WARN]  $*${nc}"; }
print_titulo() { echo -e "\n${negrita}${amarillo}>> $*${nc}\n"; }

SSL_DIR="/etc/ssl/reprobados"
DOMINIO="www.reprobados.com"
CERT_FILE="$SSL_DIR/reprobados.crt"
KEY_FILE="$SSL_DIR/reprobados.key"
VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
RESUMEN_LOG="/var/log/p7_resumen.log"
FTP_IP=""
FTP_USER=""
FTP_PASS=""
FTP_BASE_PATH="/http"
FTP_ARCHIVO_SELECCIONADO=""
FTP_HASH_SELECCIONADO=""
PKG_MANAGER=""
PKG_INSTALL=""
INTERFAZ_RED=""
IP_SERVIDOR=""
VERSION_ELEGIDA=""
PUERTO_ELEGIDO=""
PUERTO_INTERNO=""

PUERTOS_RESERVADOS=(22 21 23 25 53 443 3306 5432 6379 27017)
APACHE_WEBROOT="/var/www/html/apache"
NGINX_WEBROOT="/var/www/html/nginx"
TOMCAT_WEBROOT="/opt/tomcat/webapps/ROOT"

validar_root() {
    [[ $EUID -ne 0 ]] && { echo "[ERROR] Ejecuta como root."; exit 1; }
}

detectar_entorno() {
    if command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"; PKG_INSTALL="dnf install -y"
    elif command -v urpmi &>/dev/null; then
        PKG_MANAGER="urpmi"; PKG_INSTALL="urpmi --auto"
    else
        print_error "No se detecto dnf ni urpmi."; exit 1
    fi
    print_ok "Gestor de paquetes: $PKG_MANAGER"
    # Usar siempre la interfaz enp0s9 (172.20.10.2)
    INTERFAZ_RED="enp0s9"
    IP_SERVIDOR=$(ip addr show "$INTERFAZ_RED" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    [[ -z "$IP_SERVIDOR" ]] && IP_SERVIDOR=$(hostname -I | awk '{print $1}')
    print_ok "Interfaz: $INTERFAZ_RED ($IP_SERVIDOR)"
}

abrir_puerto_firewall() {
    local puerto="$1"
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null
        firewall-cmd --reload &>/dev/null
        print_ok "Firewall: puerto $puerto abierto"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$puerto" -j ACCEPT 2>/dev/null
        print_ok "iptables: puerto $puerto abierto"
    else
        print_warn "Sin firewall. Verifica puerto $puerto manualmente."
    fi
}

registrar_resumen() {
    local servicio="$1" protocolo="$2" estado="$3"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $servicio | $protocolo | $estado" >> "$RESUMEN_LOG"
}

generar_certificado_ssl() {
    print_titulo "Generando Certificado SSL Autofirmado"
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_warn "Ya existe certificado en $SSL_DIR"
        echo -n "Regenerar? [s/N]: "
        read -r resp; resp="${resp,,}"
        [[ "$resp" != "s" ]] && { print_info "Usando certificado existente."; return 0; }
    fi
    mkdir -p "$SSL_DIR"
    chmod 700 "$SSL_DIR"
    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out    "$CERT_FILE" \
        -subj "/C=MX/ST=Sinaloa/L=LosMochis/O=Reprobados/OU=TI/CN=${DOMINIO}" \
        2>/dev/null
    if [[ $? -ne 0 ]]; then
        print_error "Fallo la generacion del certificado."
        return 1
    fi
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    print_ok "Cert : $CERT_FILE"
    print_ok "Key  : $KEY_FILE"
    print_ok "CN   : $DOMINIO  |  Dias: 365"
    local fp
    fp=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null)
    print_info "Fingerprint: $fp"
}

verificar_cert_existe() {
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        print_warn "No hay certificado. Generando ahora..."
        generar_certificado_ssl || return 1
    fi
    return 0
}

activar_ssl_apache() {
    print_titulo "SSL/TLS en Apache"
    verificar_cert_existe || return 1
    if [[ ! -f /opt/apache/bin/apachectl ]]; then
        print_error "Apache no instalado en /opt/apache"; return 1
    fi
    local puerto_http
    puerto_http=$(ss -tlnp 2>/dev/null | grep httpd | grep -oP ':\K[0-9]+' | head -1)
    puerto_http="${puerto_http:-80}"
    local conf_ssl="/opt/apache/conf/extra/httpd-ssl.conf"
    local conf_main="/opt/apache/conf/httpd.conf"
    for modulo in ssl socache_shmcb rewrite headers; do
        sed -i "s|^#LoadModule ${modulo}_module|LoadModule ${modulo}_module|" "$conf_main" 2>/dev/null
    done
    sed -i '/^Listen 443/d' "$conf_main" 2>/dev/null
    sed -i 's|^#Include conf/extra/httpd-ssl.conf|Include conf/extra/httpd-ssl.conf|' "$conf_main" 2>/dev/null
    cat > "$conf_ssl" << EOF
Listen 443
SSLPassPhraseDialog builtin
SSLSessionCache shmcb:/opt/apache/logs/ssl_scache(512000)
SSLSessionCacheTimeout 300
<VirtualHost *:443>
    ServerName ${DOMINIO}
    DocumentRoot /var/www/html/apache
    SSLEngine on
    SSLCertificateFile    ${CERT_FILE}
    SSLCertificateKeyFile ${KEY_FILE}
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite HIGH:!aNULL:!MD5
    SSLHonorCipherOrder on
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    <Directory /var/www/html/apache>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog  /opt/apache/logs/ssl_error.log
    CustomLog /opt/apache/logs/ssl_access.log combined
</VirtualHost>
<VirtualHost *:${puerto_http}>
    ServerName ${DOMINIO}
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]
</VirtualHost>
EOF
    local syntax
    syntax=$(/opt/apache/bin/apachectl -t 2>&1)
    if echo "$syntax" | grep -qi "syntax ok"; then
        print_ok "Configuracion Apache valida"
        systemctl restart apache-web 2>/dev/null
        sleep 2
        abrir_puerto_firewall 443
        if ss -tlnp 2>/dev/null | grep -q ":443 "; then
            print_ok "Apache HTTPS activo en puerto 443"
            registrar_resumen "Apache" "HTTPS/443" "OK"
        else
            print_warn "Apache reiniciado pero 443 no detectado"
            registrar_resumen "Apache" "HTTPS/443" "WARN"
        fi
    else
        print_error "Error de sintaxis en Apache:"
        echo "$syntax"
        registrar_resumen "Apache" "HTTPS/443" "ERROR"
        return 1
    fi
}

activar_ssl_nginx() {
    print_titulo "SSL/TLS en Nginx"
    verificar_cert_existe || return 1
    if [[ ! -f /opt/nginx/sbin/nginx ]]; then
        print_error "Nginx no instalado en /opt/nginx"; return 1
    fi
    local puerto_http
    puerto_http=$(ss -tlnp 2>/dev/null | grep nginx | grep -oP ':\K[0-9]+' | head -1)
    puerto_http="${puerto_http:-80}"
    local conf_nginx="/opt/nginx/conf/nginx.conf"
    local conf_ssl="/opt/nginx/conf/conf.d/ssl.conf"
    mkdir -p "/opt/nginx/conf/conf.d"
    grep -q "conf.d/\*.conf" "$conf_nginx" 2>/dev/null || \
        sed -i '/^http {/a\    include conf.d/*.conf;' "$conf_nginx"
    cat > "$conf_ssl" << EOF
server {
    listen      ${puerto_http};
    server_name ${DOMINIO};
    return 301  https://\$host\$request_uri;
}
server {
    listen              443 ssl;
    server_name         ${DOMINIO};
    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    root  /var/www/html/nginx;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
    access_log /opt/nginx/logs/ssl_access.log;
    error_log  /opt/nginx/logs/ssl_error.log;
}
EOF
    local syntax
    syntax=$(/opt/nginx/sbin/nginx -t 2>&1)
    if echo "$syntax" | grep -qi "syntax is ok"; then
        print_ok "Configuracion Nginx valida"
        systemctl restart nginx-web 2>/dev/null
        sleep 2
        abrir_puerto_firewall 443
        if ss -tlnp 2>/dev/null | grep -q ":443 "; then
            print_ok "Nginx HTTPS activo en puerto 443"
            registrar_resumen "Nginx" "HTTPS/443" "OK"
        else
            print_warn "Nginx reiniciado pero 443 no detectado"
            registrar_resumen "Nginx" "HTTPS/443" "WARN"
        fi
    else
        print_error "Error de sintaxis en Nginx:"
        echo "$syntax"
        registrar_resumen "Nginx" "HTTPS/443" "ERROR"
        return 1
    fi
}

activar_ssl_tomcat() {
    print_titulo "SSL/TLS en Apache Tomcat"
    verificar_cert_existe || return 1
    if [[ ! -f /opt/tomcat/bin/startup.sh ]]; then
        print_error "Tomcat no instalado en /opt/tomcat"; return 1
    fi
    local server_xml="/opt/tomcat/conf/server.xml"
    local keystore="/opt/tomcat/conf/reprobados.p12"
    openssl pkcs12 -export \
        -in    "$CERT_FILE" \
        -inkey "$KEY_FILE" \
        -out   "$keystore" \
        -name  reprobados \
        -passout pass:reprobados123 2>/dev/null
    if [[ $? -ne 0 ]]; then
        print_error "Fallo conversion PKCS12"; return 1
    fi
    chown tomcat:tomcat "$keystore"
    chmod 640 "$keystore"
    print_ok "Keystore PKCS12: $keystore"
    cp "$server_xml" "${server_xml}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 - "$server_xml" "$keystore" << 'PYEOF'
import sys, re
server_xml = sys.argv[1]
keystore   = sys.argv[2]
with open(server_xml, 'r') as f:
    content = f.read()
content = re.sub(r'<!-- P7-SSL-START -->.*?<!-- P7-SSL-END -->', '', content, flags=re.DOTALL)
ssl_connector = """
    <!-- P7-SSL-START -->
    <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="{ks}"
                         certificateKeystorePassword="reprobados123"
                         type="RSA" />
        </SSLHostConfig>
    </Connector>
    <!-- P7-SSL-END -->
""".format(ks=keystore)
content = content.replace('</Service>', ssl_connector + '</Service>')
with open(server_xml, 'w') as f:
    f.write(content)
print("server.xml actualizado")
PYEOF
    if [[ $? -ne 0 ]]; then
        print_error "Fallo modificacion de server.xml"; return 1
    fi
    chown tomcat:tomcat "$server_xml"
    systemctl restart tomcat 2>/dev/null
    print_info "Esperando que Tomcat reinicie (15 seg)..."
    sleep 15
    abrir_puerto_firewall 8443
    if ss -tlnp 2>/dev/null | grep -q ":8443 "; then
        print_ok "Tomcat HTTPS activo en puerto 8443"
        registrar_resumen "Tomcat" "HTTPS/8443" "OK"
    else
        print_warn "Tomcat reiniciado pero 8443 no detectado"
        print_info "Revisa: tail -30 /opt/tomcat/logs/catalina.out"
        registrar_resumen "Tomcat" "HTTPS/8443" "WARN"
    fi
}

activar_ssl_vsftpd() {
    print_titulo "FTPS en vsftpd"
    verificar_cert_existe || return 1
    if ! rpm -q vsftpd &>/dev/null; then
        print_error "vsftpd no instalado"; return 1
    fi
    cp "$VSFTPD_CONF" "${VSFTPD_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    sed -i '/# P7-SSL-START/,/# P7-SSL-END/d' "$VSFTPD_CONF"
    sed -i '/^ssl_enable/d;/^allow_anon_ssl/d;/^force_local_data_ssl/d;/^force_local_logins_ssl/d;/^ssl_tlsv/d;/^ssl_sslv/d;/^rsa_cert_file/d;/^rsa_private_key_file/d;/^require_ssl_reuse/d;/^ssl_ciphers/d;/^implicit_ssl/d' "$VSFTPD_CONF"
    cat >> "$VSFTPD_CONF" << EOF

# P7-SSL-START
ssl_enable=YES
implicit_ssl=NO
allow_anon_ssl=NO
force_local_data_ssl=NO
force_local_logins_ssl=NO
ssl_tlsv1=YES
ssl_tlsv1_1=NO
ssl_tlsv1_2=YES
ssl_sslv2=NO
ssl_sslv3=NO
rsa_cert_file=${CERT_FILE}
rsa_private_key_file=${KEY_FILE}
require_ssl_reuse=NO
ssl_ciphers=HIGH
# P7-SSL-END
EOF
    print_ok "Directivas FTPS agregadas a vsftpd.conf"
    print_info "Reiniciando vsftpd con FTPS..."
    systemctl restart vsftpd
    sleep 2
    if systemctl is-active --quiet vsftpd; then
        print_ok "vsftpd activo con FTPS habilitado"
        print_info "Conecta con FileZilla usando: FTP over TLS explicit (puerto 21)"
        abrir_puerto_firewall 990
        registrar_resumen "vsftpd" "FTPS/21" "OK"
    else
        print_error "vsftpd no pudo reiniciar. Mostrando log:"
        journalctl -xeu vsftpd.service --no-pager 2>/dev/null | tail -15
        print_warn "Revirtiendo a configuracion sin SSL..."
        local bak
        bak=$(ls -t ${VSFTPD_CONF}.bak.* 2>/dev/null | head -1)
        [[ -n "$bak" ]] && cp "$bak" "$VSFTPD_CONF" || sed -i '/# P7-SSL-START/,/# P7-SSL-END/d' "$VSFTPD_CONF"
        systemctl restart vsftpd && print_ok "vsftpd revertido OK" || print_error "vsftpd sigue fallando - revisa con: journalctl -xeu vsftpd.service"
        registrar_resumen "vsftpd" "FTPS/21" "ERROR"
        return 1
    fi
}

ftp_listar_dir() {
    local ruta="$1"
    curl -s --connect-timeout 10 \
         -u "${FTP_USER}:${FTP_PASS}" \
         "ftp://${FTP_IP}${ruta}/" 2>/dev/null \
    | awk '{print $NF}' \
    | grep -v "^\.$\|^\.\.$\|^$"
}

ftp_descargar() {
    local ruta_remota="$1"
    local destino="$2"
    print_info "Descargando: ftp://${FTP_IP}${ruta_remota}"
    curl -s --progress-bar --connect-timeout 15 \
         -u "${FTP_USER}:${FTP_PASS}" \
         "ftp://${FTP_IP}${ruta_remota}" \
         -o "$destino" 2>&1
}

configurar_conexion_ftp() {
    print_titulo "Conexion al Servidor FTP Repositorio"
    echo -n "  IP del servidor FTP: "
    read -r FTP_IP
    echo -n "  Usuario FTP        : "
    read -r FTP_USER
    echo -n "  Contrasena FTP     : "
    read -rs FTP_PASS; echo ""
    print_info "Probando conexion a ftp://$FTP_IP ..."
    local test
    test=$(ftp_listar_dir "$FTP_BASE_PATH")
    if [[ -z "$test" ]]; then
        print_warn "No se pudo listar $FTP_BASE_PATH — verifica credenciales"
    else
        print_ok "Conexion exitosa. Contenido de $FTP_BASE_PATH:"
        echo "$test" | sed 's/^/    /'
    fi
}

navegar_repositorio_ftp() {
    print_titulo "Navegador de Repositorio FTP"
    local os_dir="Linux"
    local ruta_os="${FTP_BASE_PATH}/${os_dir}"
    print_info "Ruta base: $ruta_os"
    local servicios
    mapfile -t servicios < <(ftp_listar_dir "$ruta_os")
    if [[ ${#servicios[@]} -eq 0 ]]; then
        print_error "No se encontraron servicios en $ruta_os"
        print_info "Estructura esperada: /http/Linux/Apache/"
        return 1
    fi
    echo ""
    local i=1
    for svc in "${servicios[@]}"; do
        echo "  [$i] $svc"
        (( i++ ))
    done
    echo ""
    local sel_svc
    while true; do
        echo -n "  Selecciona servicio [1-${#servicios[@]}]: "
        read -r sel_svc; sel_svc="${sel_svc//[^0-9]/}"
        [[ "$sel_svc" =~ ^[0-9]+$ ]] && (( sel_svc >= 1 && sel_svc <= ${#servicios[@]} )) && break
        print_error "Opcion invalida"
    done
    local servicio_elegido="${servicios[$((sel_svc-1))]}"
    local ruta_servicio="${ruta_os}/${servicio_elegido}"
    print_ok "Servicio: $servicio_elegido"
    local archivos
    mapfile -t archivos < <(ftp_listar_dir "$ruta_servicio" | grep -E '\.(deb|tar\.gz|rpm|zip|msi|exe)$')
    if [[ ${#archivos[@]} -eq 0 ]]; then
        print_error "No se encontraron instaladores en $ruta_servicio"
        return 1
    fi
    echo ""
    i=1
    for arch in "${archivos[@]}"; do
        echo "  [$i] $arch"
        (( i++ ))
    done
    echo ""
    local sel_arch
    while true; do
        echo -n "  Selecciona archivo [1-${#archivos[@]}]: "
        read -r sel_arch; sel_arch="${sel_arch//[^0-9]/}"
        [[ "$sel_arch" =~ ^[0-9]+$ ]] && (( sel_arch >= 1 && sel_arch <= ${#archivos[@]} )) && break
        print_error "Opcion invalida"
    done
    local archivo_elegido="${archivos[$((sel_arch-1))]}"
    FTP_ARCHIVO_SELECCIONADO="${ruta_servicio}/${archivo_elegido}"
    FTP_HASH_SELECCIONADO="${ruta_servicio}/${archivo_elegido}.sha256"
    print_ok "Archivo   : $archivo_elegido"
    print_ok "Ruta FTP  : $FTP_ARCHIVO_SELECCIONADO"
    return 0
}

descargar_verificar_instalar_ftp() {
    print_titulo "Descarga, Verificacion e Instalacion desde FTP"
    local archivo_remoto="$FTP_ARCHIVO_SELECCIONADO"
    local hash_remoto="$FTP_HASH_SELECCIONADO"
    local nombre_archivo
    nombre_archivo=$(basename "$archivo_remoto")
    local destino="/tmp/${nombre_archivo}"
    local destino_hash="/tmp/${nombre_archivo}.sha256"
    print_info "Descargando instalador..."
    ftp_descargar "$archivo_remoto" "$destino"
    if [[ ! -f "$destino" || ! -s "$destino" ]]; then
        print_error "Descarga fallida o archivo vacio"; return 1
    fi
    print_ok "Descargado: $destino ($(du -sh "$destino" | cut -f1))"
    print_info "Descargando archivo de hash SHA256..."
    ftp_descargar "$hash_remoto" "$destino_hash"
    print_info "Verificando integridad SHA256..."
    if [[ ! -f "$destino_hash" || ! -s "$destino_hash" ]]; then
        print_warn "No se encontro .sha256 en el repositorio FTP"
        print_warn "Continuando sin verificacion de integridad"
    else
        local hash_remoto_val hash_local
        hash_remoto_val=$(awk '{print $1}' "$destino_hash")
        hash_local=$(sha256sum "$destino" | awk '{print $1}')
        print_info "Hash remoto : $hash_remoto_val"
        print_info "Hash local  : $hash_local"
        if [[ "$hash_remoto_val" == "$hash_local" ]]; then
            print_ok "INTEGRIDAD VERIFICADA"
            registrar_resumen "Hash-$nombre_archivo" "SHA256" "OK"
        else
            print_error "INTEGRIDAD FALLIDA — archivo posiblemente corrupto"
            registrar_resumen "Hash-$nombre_archivo" "SHA256" "FALLO"
            echo -n "  Continuar igualmente? [s/N]: "
            read -r cont; cont="${cont,,}"
            [[ "$cont" != "s" ]] && { rm -f "$destino" "$destino_hash"; return 1; }
        fi
    fi
    print_info "Instalando $nombre_archivo ..."
    case "$nombre_archivo" in
        *.deb)
            command -v dpkg &>/dev/null && dpkg -i "$destino" && print_ok "Instalado con dpkg" || \
                { print_error "dpkg no disponible"; return 1; }
            ;;
        *.rpm)
            command -v rpm &>/dev/null && rpm -Uvh "$destino" && print_ok "Instalado con rpm" || \
                { print_error "rpm no disponible"; return 1; }
            ;;
        *.tar.gz)
            print_info "Extrayendo en /opt/ftp_install/"
            mkdir -p /opt/ftp_install
            tar xzf "$destino" -C /opt/ftp_install && print_ok "Extraido en /opt/ftp_install/"
            ;;
        *)
            print_warn "Extension no reconocida. Archivo en: $destino"
            ;;
    esac
    rm -f "$destino_hash"
    print_ok "Proceso FTP completado"
}

preparar_repositorio_ftp() {
    print_titulo "Preparar Repositorio FTP Local"
    local FTP_ROOT="/srv/ftp"
    local REPO_BASE="${FTP_ROOT}/general/http"
    local APACHE_VER="2.4.63"
    local NGINX_VER="1.27.5"
    local TOMCAT_VER="10.1.40"
    local DIRS=(
        "${REPO_BASE}/Linux/Apache"
        "${REPO_BASE}/Linux/Nginx"
        "${REPO_BASE}/Linux/Tomcat"
        "${REPO_BASE}/Windows/Apache"
        "${REPO_BASE}/Windows/Nginx"
        "${REPO_BASE}/Windows/Tomcat"
    )
    for d in "${DIRS[@]}"; do
        mkdir -p "$d" && print_ok "Creado: $d"
    done
    descargar_o_placeholder() {
        local url="$1" destino="$2"
        local nombre; nombre=$(basename "$destino")
        [[ -f "$destino" ]] && { print_info "$nombre ya existe"; return 0; }
        print_info "Descargando $nombre ..."
        if curl -L --silent --max-time 60 --fail -o "$destino" "$url" 2>/dev/null && [[ -s "$destino" ]]; then
            print_ok "$nombre descargado ($(du -sh "$destino" | cut -f1))"
        else
            echo "# Placeholder $nombre" > "$destino"
            echo "# URL: $url" >> "$destino"
            print_warn "Placeholder creado para $nombre"
        fi
    }
    descargar_o_placeholder \
        "https://downloads.apache.org/httpd/httpd-${APACHE_VER}.tar.gz" \
        "${REPO_BASE}/Linux/Apache/apache_${APACHE_VER}.tar.gz"
    descargar_o_placeholder \
        "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz" \
        "${REPO_BASE}/Linux/Nginx/nginx_${NGINX_VER}.tar.gz"
    local TOMCAT_RAMA="${TOMCAT_VER%%.*}"
    descargar_o_placeholder \
        "https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_RAMA}/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz" \
        "${REPO_BASE}/Linux/Tomcat/tomcat_${TOMCAT_VER}.tar.gz"
    for win_file in \
        "${REPO_BASE}/Windows/Apache/apache_${APACHE_VER}.zip" \
        "${REPO_BASE}/Windows/Nginx/nginx_${NGINX_VER}.zip" \
        "${REPO_BASE}/Windows/Tomcat/tomcat_${TOMCAT_VER}.zip"; do
        [[ ! -f "$win_file" ]] && echo "# Placeholder $(basename "$win_file")" > "$win_file"
    done
    print_titulo "Generando SHA256"
    for f in \
        "${REPO_BASE}/Linux/Apache/apache_${APACHE_VER}.tar.gz" \
        "${REPO_BASE}/Linux/Nginx/nginx_${NGINX_VER}.tar.gz" \
        "${REPO_BASE}/Linux/Tomcat/tomcat_${TOMCAT_VER}.tar.gz" \
        "${REPO_BASE}/Windows/Apache/apache_${APACHE_VER}.zip" \
        "${REPO_BASE}/Windows/Nginx/nginx_${NGINX_VER}.zip" \
        "${REPO_BASE}/Windows/Tomcat/tomcat_${TOMCAT_VER}.zip"; do
        [[ -f "$f" ]] || continue
        local nombre; nombre=$(basename "$f")
        sha256sum "$f" | awk -v n="$nombre" '{print $1"  "n}' > "${f}.sha256"
        print_ok "SHA256 generado para $nombre"
    done
    chown -R root:root "$REPO_BASE"
    find "$REPO_BASE" -type d -exec chmod 755 {} \;
    find "$REPO_BASE" -type f -exec chmod 644 {} \;
    print_ok "Permisos aplicados"

    # Configurar local_root por usuario para mostrar solo Linux en FileZilla
    print_titulo "Configurando directorio raiz FTP (solo Linux)"
    local LINUX_ROOT="${REPO_BASE}/Linux"
    local VSFTPD_USER_DIR="/etc/vsftpd/user_conf.d"
    mkdir -p "$VSFTPD_USER_DIR"
    local FTP_USER_NAME=""
    if [[ -f /etc/vsftpd/user_list ]]; then
        FTP_USER_NAME=$(grep -v "^#\|^$" /etc/vsftpd/user_list | head -1)
    fi
    if [[ -z "$FTP_USER_NAME" ]]; then
        echo -n "  Nombre del usuario FTP (ej: usuario1): "
        read -r FTP_USER_NAME
    fi
    if [[ -n "$FTP_USER_NAME" ]]; then
        echo "local_root=${LINUX_ROOT}" > "${VSFTPD_USER_DIR}/${FTP_USER_NAME}"
        print_ok "local_root configurado para '$FTP_USER_NAME': $LINUX_ROOT"
        # Limpiar duplicados y asegurar user_config_dir
        sed -i '/^user_config_dir/d' "$VSFTPD_CONF"
        echo "user_config_dir=${VSFTPD_USER_DIR}" >> "$VSFTPD_CONF"
        print_ok "user_config_dir configurado en vsftpd.conf"
        systemctl restart vsftpd 2>/dev/null && \
            print_ok "vsftpd reiniciado — FileZilla mostrara solo la carpeta Linux" || \
            print_warn "Reinicia vsftpd manualmente: systemctl restart vsftpd"
    else
        print_warn "No se configuro local_root — ingresa el usuario FTP manualmente"
    fi

    print_titulo "Estructura del repositorio"
    find "$REPO_BASE" | sed 's|[^/]*/|  |g'
    echo ""
    print_ok "Repositorio listo en ftp://${IP_SERVIDOR}/http/Linux/"
}

obtener_versiones_apache() {
    local base_url="https://downloads.apache.org/httpd/"
    print_info "Consultando versiones de Apache..." >&2
    local versiones
    versiones=$(curl -s --max-time 10 "$base_url" 2>/dev/null \
        | grep -oP 'httpd-\K2\.4\.[0-9]+(?=\.tar\.gz)' | sort -uV)
    if [[ -z "$versiones" ]]; then
        echo "2.4.62"; echo "2.4.63"; echo "2.4.66"; return
    fi
    echo "$versiones"
}

obtener_versiones_nginx() {
    local base_url="https://nginx.org/download/"
    print_info "Consultando versiones de Nginx..." >&2
    local versiones
    versiones=$(curl -s --max-time 10 "$base_url" 2>/dev/null \
        | grep -oP 'nginx-\K1\.[0-9]+\.[0-9]+(?=\.tar\.gz)' | sort -uV | tail -8)
    if [[ -z "$versiones" ]]; then
        echo "1.26.3"; echo "1.27.5"; echo "1.28.0"; return
    fi
    echo "$versiones"
}

obtener_versiones_tomcat() {
    local base_url="https://dlcdn.apache.org/tomcat/"
    print_info "Consultando versiones de Tomcat..." >&2
    local ramas
    ramas=$(curl -s --max-time 8 "$base_url" 2>/dev/null \
        | grep -oP 'tomcat-\K[0-9]+(?=/)' | sort -uV)
    if [[ -z "$ramas" ]]; then
        echo "9.0.102"; echo "10.1.40"; echo "11.0.7"; return
    fi
    while IFS= read -r rama; do
        local latest
        latest=$(curl -s --max-time 8 "${base_url}tomcat-${rama}/" 2>/dev/null \
            | grep -oP "v\K[0-9]+\.[0-9]+\.[0-9]+" | sort -V | tail -1)
        [[ -n "$latest" ]] && echo "$latest"
    done <<< "$ramas"
}

elegir_version() {
    local paquete="$1"; shift
    local versiones=("$@")
    if [[ ${#versiones[@]} -eq 0 ]]; then
        print_error "No se encontraron versiones para '$paquete'."; return 1
    fi
    echo ""
    echo "Versiones disponibles: $paquete"
    echo ""
    local i=1 total=${#versiones[@]}
    for ver in "${versiones[@]}"; do
        local etiqueta=""
        [[ $i -eq 1      ]] && etiqueta="  [LTS]"
        [[ $i -eq $total ]] && etiqueta="  [Latest]"
        echo "  [$i] $ver$etiqueta"
        (( i++ ))
    done
    echo ""
    while true; do
        echo -n "Elige una version [1-$total]: "
        read -r sel; sel="${sel//[^0-9]/}"
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= total )); then
            VERSION_ELEGIDA="${versiones[$((sel-1))]}"
            print_ok "Version elegida: $VERSION_ELEGIDA"; break
        fi
        print_error "Opcion invalida."
    done
}

pedir_puerto() {
    echo ""
    echo "Puerto HTTP para el servidor (sugerido: 8080, 8081, 8082):"
    while true; do
        echo -n "Puerto: "
        read -r PUERTO_ELEGIDO; PUERTO_ELEGIDO="${PUERTO_ELEGIDO//[^0-9]/}"
        if [[ "$PUERTO_ELEGIDO" =~ ^[0-9]+$ ]] && (( PUERTO_ELEGIDO >= 1 && PUERTO_ELEGIDO <= 65535 )); then
            print_ok "Puerto elegido: $PUERTO_ELEGIDO"; break
        fi
        print_error "Puerto invalido."
    done
}

configurar_firewall_http() {
    local puerto="$1"
    abrir_puerto_firewall "$puerto"
}

crear_index() {
    local servidor="$1" version="$2" puerto="$3" webroot="$4"
    mkdir -p "$webroot"
    cat > "$webroot/index.html" << EOF
<!DOCTYPE html>
<html><body>
<h1>$servidor $version</h1>
<p>Puerto: $puerto</p>
<p>Servidor: $(hostname)</p>
</body></html>
EOF
}

mostrar_url() {
    local puerto="$1"
    print_ok "URL: http://$IP_SERVIDOR:$puerto/"
}

instalar_apache() {
    print_titulo "Instalando Apache $VERSION_ELEGIDA"
    local url="https://downloads.apache.org/httpd/httpd-${VERSION_ELEGIDA}.tar.gz"
    local tarball="/tmp/httpd-${VERSION_ELEGIDA}.tar.gz"
    $PKG_INSTALL gcc make openssl-devel pcre-devel expat-devel &>/dev/null
    command -v curl &>/dev/null || $PKG_INSTALL curl &>/dev/null
    print_info "Descargando Apache $VERSION_ELEGIDA..."
    curl -L --progress-bar -o "$tarball" "$url" 2>&1
    gzip -t "$tarball" &>/dev/null || { print_error "Descarga invalida."; rm -f "$tarball"; return 1; }
    print_info "Compilando Apache..."
    rm -rf /tmp/httpd-src && mkdir /tmp/httpd-src
    tar xzf "$tarball" -C /tmp/httpd-src --strip-components=1 || { print_error "Fallo la extraccion."; return 1; }
    cd /tmp/httpd-src || return 1
    ./configure --prefix=/opt/apache \
        --enable-so --enable-ssl --enable-rewrite \
        --enable-headers --with-included-apr &>/dev/null
    make -j"$(nproc)" &>/dev/null
    make install &>/dev/null
    cd / || true
    rm -rf /tmp/httpd-src "$tarball"
    if [[ ! -f /opt/apache/bin/apachectl ]]; then
        print_error "Compilacion fallida."; return 1
    fi
    print_ok "Apache compilado en /opt/apache"
    sed -i "s/^Listen 80$/Listen $PUERTO_ELEGIDO/" /opt/apache/conf/httpd.conf
    sed -i "s/^ServerName .*/ServerName $IP_SERVIDOR:$PUERTO_ELEGIDO/" /opt/apache/conf/httpd.conf 2>/dev/null || \
        echo "ServerName $IP_SERVIDOR:$PUERTO_ELEGIDO" >> /opt/apache/conf/httpd.conf
    crear_index "Apache" "$VERSION_ELEGIDA" "$PUERTO_ELEGIDO" "$APACHE_WEBROOT"
    sed -i "s|^DocumentRoot.*|DocumentRoot \"$APACHE_WEBROOT\"|" /opt/apache/conf/httpd.conf
    cat > /etc/systemd/system/apache-web.service << EOF
[Unit]
Description=Apache HTTP Server $VERSION_ELEGIDA
After=network.target
[Service]
Type=forking
ExecStart=/opt/apache/bin/apachectl start
ExecStop=/opt/apache/bin/apachectl stop
ExecReload=/opt/apache/bin/apachectl graceful
PIDFile=/opt/apache/logs/httpd.pid
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable apache-web &>/dev/null
    systemctl start apache-web
    sleep 2
    configurar_firewall_http "$PUERTO_ELEGIDO"
    systemctl is-active --quiet apache-web && \
        { print_ok "Apache $VERSION_ELEGIDA activo en puerto $PUERTO_ELEGIDO"; mostrar_url "$PUERTO_ELEGIDO"; } || \
        print_error "Apache no arranco. Revisa: journalctl -u apache-web -n 20"
}

instalar_nginx() {
    print_titulo "Instalando Nginx $VERSION_ELEGIDA"
    local url="https://nginx.org/download/nginx-${VERSION_ELEGIDA}.tar.gz"
    local tarball="/tmp/nginx-${VERSION_ELEGIDA}.tar.gz"
    $PKG_INSTALL gcc make openssl-devel pcre-devel zlib-devel &>/dev/null
    print_info "Descargando Nginx $VERSION_ELEGIDA..."
    curl -L --progress-bar -o "$tarball" "$url" 2>&1
    gzip -t "$tarball" &>/dev/null || { print_error "Descarga invalida."; rm -f "$tarball"; return 1; }
    rm -rf /tmp/nginx-src && mkdir /tmp/nginx-src
    tar xzf "$tarball" -C /tmp/nginx-src --strip-components=1
    cd /tmp/nginx-src || return 1
    ./configure --prefix=/opt/nginx \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_rewrite_module &>/dev/null
    make -j"$(nproc)" &>/dev/null
    make install &>/dev/null
    cd / || true
    rm -rf /tmp/nginx-src "$tarball"
    if [[ ! -f /opt/nginx/sbin/nginx ]]; then
        print_error "Compilacion fallida."; return 1
    fi
    print_ok "Nginx compilado en /opt/nginx"
    crear_index "Nginx" "$VERSION_ELEGIDA" "$PUERTO_ELEGIDO" "$NGINX_WEBROOT"
    cat > /opt/nginx/conf/nginx.conf << EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    include mime.types;
    default_type application/octet-stream;
    server {
        listen $PUERTO_ELEGIDO;
        server_name $IP_SERVIDOR;
        root $NGINX_WEBROOT;
        index index.html;
        location / { try_files \$uri \$uri/ =404; }
    }
}
EOF
    cat > /etc/systemd/system/nginx-web.service << EOF
[Unit]
Description=Nginx HTTP Server $VERSION_ELEGIDA
After=network.target
[Service]
Type=forking
PIDFile=/opt/nginx/logs/nginx.pid
ExecStart=/opt/nginx/sbin/nginx
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nginx-web &>/dev/null
    systemctl start nginx-web
    sleep 2
    configurar_firewall_http "$PUERTO_ELEGIDO"
    systemctl is-active --quiet nginx-web && \
        { print_ok "Nginx $VERSION_ELEGIDA activo en puerto $PUERTO_ELEGIDO"; mostrar_url "$PUERTO_ELEGIDO"; } || \
        print_error "Nginx no arranco. Revisa: journalctl -u nginx-web -n 20"
}

instalar_tomcat() {
    print_titulo "Instalando Apache Tomcat $VERSION_ELEGIDA"
    local rama="${VERSION_ELEGIDA%%.*}"
    local url="https://dlcdn.apache.org/tomcat/tomcat-${rama}/v${VERSION_ELEGIDA}/bin/apache-tomcat-${VERSION_ELEGIDA}.tar.gz"
    local tarball="/tmp/apache-tomcat-${VERSION_ELEGIDA}.tar.gz"
    if ! command -v java &>/dev/null; then
        print_info "Instalando Java..."
        $PKG_INSTALL java-21-openjdk java-21-openjdk-headless &>/dev/null || \
        $PKG_INSTALL java-11-openjdk java-11-openjdk-headless &>/dev/null || \
            { print_error "No se pudo instalar Java."; return 1; }
    fi
    curl -L --progress-bar -o "$tarball" "$url" 2>&1
    gzip -t "$tarball" &>/dev/null || { print_error "Descarga invalida."; rm -f "$tarball"; return 1; }
    rm -rf /opt/tomcat && mkdir -p /opt/tomcat
    tar xzf "$tarball" -C /opt/tomcat --strip-components=1
    rm -f "$tarball"
    if (( PUERTO_ELEGIDO < 1024 )); then
        PUERTO_INTERNO=$(( PUERTO_ELEGIDO + 10000 ))
    else
        PUERTO_INTERNO=$PUERTO_ELEGIDO
    fi
    sed -i "s/port=\"8080\"/port=\"${PUERTO_INTERNO}\"/" /opt/tomcat/conf/server.xml
    sed -i 's/port="8009"/port="-1"/' /opt/tomcat/conf/server.xml
    id "tomcat" &>/dev/null || useradd -r -s /sbin/nologin -d /opt/tomcat -M tomcat
    mkdir -p "$TOMCAT_WEBROOT"
    crear_index "Apache Tomcat" "$VERSION_ELEGIDA" "$PUERTO_ELEGIDO" "$TOMCAT_WEBROOT"
    chown -R tomcat:tomcat /opt/tomcat
    chmod 750 /opt/tomcat /opt/tomcat/conf
    local java_home
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
    cat > /etc/systemd/system/tomcat.service << EOF
[Unit]
Description=Apache Tomcat $VERSION_ELEGIDA
After=network.target
[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=${java_home}"
Environment="CATALINA_HOME=/opt/tomcat"
Environment="CATALINA_BASE=/opt/tomcat"
Environment="CATALINA_PID=/opt/tomcat/temp/tomcat.pid"
Environment="CATALINA_OPTS=-Xms256M -Xmx512M"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    pkill -f java 2>/dev/null; sleep 2
    systemctl enable tomcat &>/dev/null
    systemctl start tomcat
    print_info "Esperando Tomcat (15 seg)..."
    sleep 15
    if (( PUERTO_ELEGIDO < 1024 )); then
        iptables -t nat -A PREROUTING -p tcp --dport "$PUERTO_ELEGIDO" -j REDIRECT --to-port "$PUERTO_INTERNO"
        iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport "$PUERTO_ELEGIDO" -j REDIRECT --to-port "$PUERTO_INTERNO"
    fi
    configurar_firewall_http "$PUERTO_ELEGIDO"
    systemctl is-active --quiet tomcat && \
        { print_ok "Tomcat $VERSION_ELEGIDA activo en puerto $PUERTO_ELEGIDO"; mostrar_url "$PUERTO_ELEGIDO"; } || \
        { print_error "Tomcat no arranco."; print_info "Revisa: tail -20 /opt/tomcat/logs/catalina.out"; return 1; }
}

verificar_HTTP() {
    echo ""
    echo "Estado de Servidores HTTP"
    echo ""
    echo -n "  Apache  : "
    if [[ -f /opt/apache/bin/apachectl ]]; then
        local ver p
        ver=$(/opt/apache/bin/apachectl -v 2>/dev/null | grep -oP 'Apache/\K[0-9.]+')
        systemctl is-active --quiet apache-web 2>/dev/null && \
            p=$(ss -tlnp 2>/dev/null | grep httpd | grep -oP ':\K[0-9]+' | head -1) && \
            echo "Activo | v${ver:-?} | Puerto: ${p:-?}" || echo "Detenido | v${ver:-?}"
    else echo "No instalado"; fi

    echo -n "  Nginx   : "
    if [[ -f /opt/nginx/sbin/nginx ]]; then
        local ver p
        ver=$(/opt/nginx/sbin/nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
        systemctl is-active --quiet nginx-web 2>/dev/null && \
            p=$(ss -tlnp 2>/dev/null | grep nginx | grep -oP ':\K[0-9]+' | head -1) && \
            echo "Activo | v${ver:-?} | Puerto: ${p:-?}" || echo "Detenido | v${ver:-?}"
    else echo "No instalado"; fi

    echo -n "  Tomcat  : "
    if [[ -f /opt/tomcat/bin/startup.sh ]]; then
        local ver p
        ver=$(/opt/tomcat/bin/version.sh 2>/dev/null | grep "Server version" | grep -oP 'Tomcat/\K[0-9.]+')
        systemctl is-active --quiet tomcat 2>/dev/null && \
            p=$(ss -tlnp 2>/dev/null | grep java | grep -oP '[:\*]\K[0-9]+' | grep -v "^8005$" | head -1) && \
            echo "Activo | v${ver:-?} | Puerto: ${p:-?}" || echo "Detenido | v${ver:-?}"
    else echo "No instalado"; fi

    echo -n "  vsftpd  : "
    rpm -q vsftpd &>/dev/null && \
        systemctl is-active vsftpd 2>/dev/null || echo "No instalado"
    echo ""
}

instalar_HTTP() {
    clear
    echo ""
    echo "Instalacion de Servidor HTTP"
    echo ""
    echo "  [1] Apache"
    echo "  [2] Nginx"
    echo "  [3] Apache Tomcat"
    echo ""
    local opcion
    echo -n "  Opcion: "
    read -r opcion; opcion="${opcion//[^0-9]/}"
    local versiones=()
    case $opcion in
        1)
            mapfile -t versiones < <(obtener_versiones_apache)
            elegir_version "Apache" "${versiones[@]}" || return 1
            pedir_puerto; instalar_apache ;;
        2)
            mapfile -t versiones < <(obtener_versiones_nginx)
            elegir_version "Nginx" "${versiones[@]}" || return 1
            pedir_puerto; instalar_nginx ;;
        3)
            mapfile -t versiones < <(obtener_versiones_tomcat)
            elegir_version "Apache Tomcat" "${versiones[@]}" || return 1
            pedir_puerto; instalar_tomcat ;;
    esac
}

instalacion_hibrida() {
    print_titulo "Instalacion Hibrida"
    echo "  [1] WEB  — descarga oficial / gestor de paquetes"
    echo "  [2] FTP  — repositorio privado"
    echo ""
    echo -n "  Opcion: "
    read -r origen; origen="${origen//[^0-9]/}"
    case "$origen" in
        1) instalar_HTTP ;;
        2)
            configurar_conexion_ftp
            navegar_repositorio_ftp || return 1
            descargar_verificar_instalar_ftp
            ;;
        *) print_error "Opcion invalida"; return 1 ;;
    esac
}

verificar_ssl_servicio() {
    local host="$1" puerto="$2" nombre="$3"
    echo -n "  $nombre (${host}:${puerto}) : "
    local result
    result=$(echo | timeout 5 openssl s_client \
        -connect "${host}:${puerto}" \
        -servername "$host" 2>/dev/null)
    if echo "$result" | grep -q "CONNECTED"; then
        local cn
        cn=$(echo "$result" | openssl x509 -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,/]+')
        echo -e "${verde}OK${nc} | CN=$cn"
        return 0
    else
        echo -e "${rojo}FALLO${nc} — no responde en puerto $puerto"
        return 1
    fi
}

mostrar_resumen() {
    print_titulo "Resumen de Verificacion SSL/TLS"
    # Usar siempre la IP de enp0s9
    local ip
    ip=$(ip addr show enp0s9 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    echo "  Dominio : $DOMINIO"
    echo "  IP      : $ip"
    echo ""
    local ok=0 fallo=0
    [[ -f /opt/apache/bin/apachectl ]] && \
        { verificar_ssl_servicio "$ip" 443  "Apache HTTPS" && (( ok++ )) || (( fallo++ )); }
    [[ -f /opt/nginx/sbin/nginx ]] && \
        { verificar_ssl_servicio "$ip" 443  "Nginx  HTTPS" && (( ok++ )) || (( fallo++ )); }
    [[ -f /opt/tomcat/bin/startup.sh ]] && \
        { verificar_ssl_servicio "$ip" 8443 "Tomcat HTTPS" && (( ok++ )) || (( fallo++ )); }
    if rpm -q vsftpd &>/dev/null; then
        echo -n "  vsftpd FTPS (:21) : "
        if systemctl is-active --quiet vsftpd && grep -q "ssl_enable=YES" "$VSFTPD_CONF" 2>/dev/null; then
            echo -e "${verde}OK${nc} | FTPS habilitado"
            (( ok++ ))
        else
            echo -e "${rojo}FALLO${nc} | vsftpd no activo o sin SSL"
            (( fallo++ ))
        fi
    fi
    echo ""
    echo "  Exitosos : $ok"
    echo "  Fallidos : $fallo"
    echo ""
    [[ -f "$RESUMEN_LOG" ]] && { echo "  Log: $RESUMEN_LOG"; echo ""; tail -20 "$RESUMEN_LOG" | sed 's/^/    /'; }
    echo ""
    print_info "Verificacion manual:"
    print_info "  curl -kv https://$ip/"
    print_info "  openssl s_client -connect $ip:443"
    print_info "  openssl s_client -connect $ip:8443"
    print_info "  curl -kv --ssl-reqd ftp://user:pass@$ip/"
}

menu_ssl() {
    clear
    echo ""
    echo "SSL/TLS — Cifrado de Canales"
    echo "Dominio: $DOMINIO"
    echo ""
    echo "  [1] Generar / Regenerar certificado SSL"
    echo "  [2] Activar HTTPS en Apache  (443)"
    echo "  [3] Activar HTTPS en Nginx   (443)"
    echo "  [4] Activar HTTPS en Tomcat  (8443)"
    echo "  [5] Activar FTPS  en vsftpd  (21+TLS)"
    echo "  [6] Activar SSL en TODOS los servicios"
    echo "  [0] Volver"
    echo ""
    echo -n "Opcion: "
}

ejecutar_menu_ssl() {
    local op
    while true; do
        menu_ssl
        read -r op; op="${op//[^0-9]/}"
        echo ""
        case "$op" in
            1) generar_certificado_ssl ;;
            2) echo -n "Activar SSL en Apache? [S/N]: "; read -r r; [[ "${r,,}" == "s" ]] && activar_ssl_apache ;;
            3) echo -n "Activar SSL en Nginx? [S/N]: ";  read -r r; [[ "${r,,}" == "s" ]] && activar_ssl_nginx ;;
            4) echo -n "Activar SSL en Tomcat? [S/N]: "; read -r r; [[ "${r,,}" == "s" ]] && activar_ssl_tomcat ;;
            5) echo -n "Activar FTPS en vsftpd? [S/N]: "; read -r r; [[ "${r,,}" == "s" ]] && activar_ssl_vsftpd ;;
            6)
                generar_certificado_ssl
                echo ""
                for svc in apache nginx tomcat vsftpd; do
                    echo -n "Activar SSL en $svc? [S/N]: "
                    read -r r
                    if [[ "${r,,}" == "s" ]]; then
                        case "$svc" in
                            apache) activar_ssl_apache  ;;
                            nginx)  activar_ssl_nginx   ;;
                            tomcat) activar_ssl_tomcat  ;;
                            vsftpd) activar_ssl_vsftpd  ;;
                        esac
                    fi
                    echo ""
                done
                ;;
            0) break ;;
            *) print_error "Opcion invalida." ;;
        esac
        echo ""
        echo -n "Presiona ENTER para continuar..."; read -r
    done
}

menu_ftp_cliente() {
    clear
    echo ""
    echo "Cliente FTP — Repositorio Privado"
    echo ""
    echo "  [1] Configurar conexion FTP"
    echo "  [2] Navegar y descargar desde repositorio"
    echo "  [3] Verificar hash de archivo local"
    echo "  [0] Volver"
    echo ""
    echo -n "Opcion: "
}

ejecutar_menu_ftp_cliente() {
    local op
    while true; do
        menu_ftp_cliente
        read -r op; op="${op//[^0-9]/}"
        echo ""
        case "$op" in
            1) configurar_conexion_ftp ;;
            2)
                if [[ -z "$FTP_IP" ]]; then
                    print_warn "Primero configura la conexion FTP (opcion 1)"
                else
                    navegar_repositorio_ftp && descargar_verificar_instalar_ftp
                fi
                ;;
            3)
                print_titulo "Verificar Hash Manualmente"
                echo -n "  Archivo local: "
                read -r arch_local
                echo -n "  Archivo .sha256: "
                read -r hash_file
                if [[ -f "$arch_local" && -f "$hash_file" ]]; then
                    local h_r h_l
                    h_r=$(awk '{print $1}' "$hash_file")
                    h_l=$(sha256sum "$arch_local" | awk '{print $1}')
                    print_info "Hash en archivo : $h_r"
                    print_info "Hash calculado  : $h_l"
                    [[ "$h_r" == "$h_l" ]] && print_ok "INTEGRIDAD OK" || print_error "INTEGRIDAD FALLIDA"
                else
                    print_error "Archivo no encontrado"
                fi
                ;;
            0) break ;;
            *) print_error "Opcion invalida." ;;
        esac
        echo ""
        echo -n "Presiona ENTER para continuar..."; read -r
    done
}

listar_versiones_disponibles() {
    print_titulo "Versiones disponibles en sitios oficiales"

    # Apache
    echo -e "  ${negrita}${amarillo}── Apache HTTPD ──${nc}"
    local vers_apache
    mapfile -t vers_apache < <(obtener_versiones_apache 2>/dev/null)
    if [[ ${#vers_apache[@]} -eq 0 ]]; then
        echo -e "     ${rojo}No se pudo consultar${nc}"
    else
        local total=${#vers_apache[@]}
        for i in "${!vers_apache[@]}"; do
            local etiqueta=""
            [[ $i -eq 0 ]]            && etiqueta="  ${cyan}[LTS]${nc}"
            [[ $i -eq $((total-1)) ]] && etiqueta="  ${cyan}[Latest]${nc}"
            echo -e "     ${verde}v${vers_apache[$i]}${nc}${etiqueta}"
        done
    fi
    echo ""

    # Nginx
    echo -e "  ${negrita}${amarillo}── Nginx ──${nc}"
    local vers_nginx
    mapfile -t vers_nginx < <(obtener_versiones_nginx 2>/dev/null)
    if [[ ${#vers_nginx[@]} -eq 0 ]]; then
        echo -e "     ${rojo}No se pudo consultar${nc}"
    else
        local total=${#vers_nginx[@]}
        for i in "${!vers_nginx[@]}"; do
            local etiqueta=""
            [[ $i -eq 0 ]]            && etiqueta="  ${cyan}[LTS]${nc}"
            [[ $i -eq $((total-1)) ]] && etiqueta="  ${cyan}[Latest]${nc}"
            echo -e "     ${verde}v${vers_nginx[$i]}${nc}${etiqueta}"
        done
    fi
    echo ""

    # Tomcat
    echo -e "  ${negrita}${amarillo}── Apache Tomcat ──${nc}"
    local vers_tomcat
    mapfile -t vers_tomcat < <(obtener_versiones_tomcat 2>/dev/null)
    if [[ ${#vers_tomcat[@]} -eq 0 ]]; then
        echo -e "     ${rojo}No se pudo consultar${nc}"
    else
        local total=${#vers_tomcat[@]}
        for i in "${!vers_tomcat[@]}"; do
            local etiqueta=""
            [[ $i -eq 0 ]]            && etiqueta="  ${cyan}[LTS]${nc}"
            [[ $i -eq $((total-1)) ]] && etiqueta="  ${cyan}[Latest]${nc}"
            echo -e "     ${verde}v${vers_tomcat[$i]}${nc}${etiqueta}"
        done
    fi
    echo ""
}

menu_principal() {
    clear
    echo ""
    echo "Practica 7 - Infraestructura SSL/TLS"
    echo "Sistema: $(uname -n)  |  Fecha: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    verificar_HTTP
    echo "  [1] Instalacion Hibrida (WEB o FTP)"
    echo "  [2] Preparar Repositorio FTP Local"
    echo "  [3] Cifrado SSL/TLS"
    echo "  [4] Cliente FTP — Repositorio Privado"
    echo "  [5] Verificacion y Resumen SSL"
    echo "  [6] Ver versiones en Repositorio FTP"
    echo "  [0] Salir"
    echo ""
    echo -n "Opcion: "
}

validar_root
detectar_entorno

while true; do
    menu_principal
    read -r op; op="${op//[^0-9]/}"
    echo ""
    case "$op" in
        1) instalacion_hibrida ;;
        2) preparar_repositorio_ftp ;;
        3) ejecutar_menu_ssl ;;
        4) ejecutar_menu_ftp_cliente ;;
        5) mostrar_resumen ;;
        6) listar_versiones_disponibles ;;
        0) echo "Hasta luego."; exit 0 ;;
        *) print_error "Opcion invalida." ;;
    esac
    echo ""
    echo -n "Presiona ENTER para continuar..."; read -r
done
