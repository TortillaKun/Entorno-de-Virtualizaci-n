#!/bin/bash
# htppfun.sh - Funciones para instalacion de servidores HTTP
# Practica 6 - Mageia Linux

print_info()      { echo "[INFO] $1"; }
print_completado(){ echo "[OK] $1"; }
print_error()     { echo "[ERROR] $1"; }
print_titulo()    { echo ""; echo ">> $1"; }

readonly PUERTOS_RESERVADOS=(22 21 23 25 53 443 3306 5432 6379 27017)
readonly APACHE_WEBROOT="/var/www/html/apache"
readonly NGINX_WEBROOT="/var/www/html/nginx"
readonly TOMCAT_WEBROOT="/opt/tomcat/webapps/ROOT"

VERSION_ELEGIDA=""
PUERTO_ELEGIDO=""
PUERTO_INTERNO=""   # Puerto real donde escucha Tomcat (puede ser diferente al elegido)
PKG_MANAGER=""
PKG_INSTALL=""
INTERFAZ_RED=""
IP_SERVIDOR=""
AUTHBIND_CMD=""

detectar_entorno() {
    if command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"; PKG_INSTALL="dnf install -y"
    elif command -v urpmi &>/dev/null; then
        PKG_MANAGER="urpmi"; PKG_INSTALL="urpmi --auto"
    else
        print_error "No se detecto dnf ni urpmi."; exit 1
    fi
    print_completado "Gestor de paquetes: $PKG_MANAGER"
    INTERFAZ_RED="enp0s9"
    IP_SERVIDOR=$(ip addr show "$INTERFAZ_RED" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    print_completado "Interfaz: $INTERFAZ_RED ($IP_SERVIDOR)"
}

validar_root() {
    [[ $EUID -ne 0 ]] && { echo "[ERROR] Ejecuta como root."; exit 1; }
}

http_propio_en_puerto() {
    local puerto="$1"
    if [[ -f /opt/apache/bin/apachectl ]] && systemctl is-active --quiet apache-web 2>/dev/null; then
        local p; p=$(ss -tlnp 2>/dev/null | grep httpd | grep -oP ':\K[0-9]+' | head -1)
        [[ "$p" == "$puerto" ]] && echo "Apache:apache-web" && return
    fi
    if [[ -f /opt/nginx/sbin/nginx ]] && systemctl is-active --quiet nginx-web 2>/dev/null; then
        local p; p=$(ss -tlnp 2>/dev/null | grep nginx | grep -oP ':\K[0-9]+' | head -1)
        [[ "$p" == "$puerto" ]] && echo "Nginx:nginx-web" && return
    fi
    if [[ -f /opt/tomcat/bin/startup.sh ]] && systemctl is-active --quiet tomcat 2>/dev/null; then
        # Tomcat puede estar en puerto interno diferente, revisar la regla NAT
        local nat_puerto
        nat_puerto=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "redir ports" | grep "dpt:${puerto}" | head -1 | grep -oP 'dpt:\K[0-9]+')
        [[ -n "$nat_puerto" ]] && echo "Apache Tomcat:tomcat" && return
        local p; p=$(ss -tlnp 2>/dev/null | grep java | grep -oP '[:\*]\K[0-9]+' | grep -v "^8005$" | head -1)
        [[ "$p" == "$puerto" ]] && echo "Apache Tomcat:tomcat" && return
    fi
    echo ""
}

servicio_en_puerto() {
    local puerto="$1"
    local proc
    proc=$(ss -tlnp 2>/dev/null | grep ":${puerto} " | grep -oP 'users:\(\("\K[^"]+' | head -1)
    case "$proc" in
        *httpd*|*apache*) echo "apache-web" ;;
        *nginx*)          echo "nginx-web"  ;;
        *java*)           echo "tomcat"     ;;
        *)                echo "otro"       ;;
    esac
}

validar_puerto() {
    local puerto="$1"; shift
    local reservados=("$@")
    if ! [[ "$puerto" =~ ^[0-9]+$ ]]; then
        print_error "El puerto debe ser un numero."; return 1
    fi
    if (( puerto < 1 || puerto > 65535 )); then
        print_error "Puerto fuera de rango (1-65535)."; return 1
    fi
    for r in "${reservados[@]}"; do
        (( puerto == r )) && { print_error "Puerto $puerto reservado para otro servicio critico."; return 1; }
    done
    return 0
}

verificar_y_liberar_puerto() {
    local puerto="$1"
    if ! ss -tlnp 2>/dev/null | grep -q ":${puerto} "; then
        # Verificar tambien si hay una regla NAT para este puerto (Tomcat)
        if ! iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:${puerto}"; then
            return 0
        fi
    fi

    local http_info
    http_info=$(http_propio_en_puerto "$puerto")

    if [[ -n "$http_info" ]]; then
        local nombre svc
        nombre="${http_info%%:*}"
        svc="${http_info##*:}"
        print_error "Puerto $puerto ya esta en uso por: $nombre"
        echo -n "Deseas desconectar $nombre del puerto $puerto y asignarlo al nuevo servidor? [s/N]: "
        read -r resp; resp="${resp,,}"
        if [[ "$resp" == "s" || "$resp" == "si" ]]; then
            systemctl stop "$svc" 2>/dev/null
            pkill -f java 2>/dev/null
            # Limpiar reglas NAT del puerto
            iptables -t nat -D PREROUTING -p tcp --dport "$puerto" -j REDIRECT --to-port "$((puerto+10000))" 2>/dev/null
            iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport "$puerto" -j REDIRECT --to-port "$((puerto+10000))" 2>/dev/null
            sleep 2
            print_completado "$nombre detenido. Puerto $puerto liberado."
            return 0
        else
            print_info "Elige un puerto diferente."; return 1
        fi
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${puerto} "; then
        local svc
        svc=$(servicio_en_puerto "$puerto")
        print_error "Puerto $puerto ocupado por proceso del sistema: $svc"
        echo -n "Deseas detener '$svc' y liberar el puerto? [s/N]: "
        read -r resp; resp="${resp,,}"
        if [[ "$resp" == "s" || "$resp" == "si" ]]; then
            systemctl stop "$svc" 2>/dev/null
            sleep 2
            if ss -tlnp 2>/dev/null | grep -q ":${puerto} "; then
                print_error "El puerto $puerto sigue ocupado."; return 1
            fi
            print_completado "Puerto $puerto liberado."
        else
            print_info "Elige un puerto diferente."; return 1
        fi
    fi
    return 0
}

obtener_versiones_apache() {
    local base_url="https://downloads.apache.org/httpd/"
    print_info "Consultando versiones de Apache..." >&2
    local versiones
    versiones=$(curl -s --max-time 10 "$base_url" 2>/dev/null \
        | grep -oP 'httpd-\K2\.4\.[0-9]+(?=\.tar\.gz)' | sort -uV)
    if [[ -z "$versiones" ]]; then
        print_info "Sin acceso. Usando versiones de referencia." >&2
        echo "2.4.62"; echo "2.4.63"; echo "2.4.66"; return
    fi
    echo "$versiones"
}

obtener_versiones_nginx() {
    local base_url="https://nginx.org/download/"
    print_info "Consultando versiones de Nginx..." >&2
    local versiones
    versiones=$(curl -s --max-time 10 "$base_url" 2>/dev/null \
        | grep -oP 'nginx-\K1\.[0-9]+\.[0-9]+(?=\.tar\.gz)' \
        | sort -uV | tail -8)
    if [[ -z "$versiones" ]]; then
        print_info "Sin acceso. Usando versiones de referencia." >&2
        echo "1.26.3"; echo "1.27.5"; echo "1.28.0"; echo "1.29.0"; return
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
        print_info "Sin acceso. Usando versiones de referencia." >&2
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
    clear
    local paquete="$1"; shift
    local versiones=("$@")
    if [[ ${#versiones[@]} -eq 0 ]]; then
        print_error "No se encontraron versiones para '$paquete'."; return 1
    fi
    echo ""
    echo "=== Versiones disponibles: $paquete ==="
    echo ""
    local i=1 total=${#versiones[@]}
    for ver in "${versiones[@]}"; do
        local etiqueta=""
        [[ $i -eq 1      ]] && etiqueta="  [LTS / Estable]"
        [[ $i -eq $total ]] && etiqueta="  [Latest / Desarrollo]"
        echo "  [$i] $ver$etiqueta"
        (( i++ ))
    done
    echo ""
    while true; do
        echo -n "Elige una version [1-$total]: "
        read -r sel; sel="${sel//[^0-9]/}"
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= total )); then
            VERSION_ELEGIDA="${versiones[$((sel-1))]}"
            print_completado "Version elegida: $VERSION_ELEGIDA"; break
        fi
        print_error "Opcion invalida."
    done
}

pedir_puerto() {
    clear
    echo ""
    echo "=== Configuracion de Puerto ==="
    echo ""
    print_info "Por defecto: 80  |  Otros: 8080, 8888"
    print_info "Bloqueados: ${PUERTOS_RESERVADOS[*]}"
    echo ""
    while true; do
        echo -n "Ingresa el puerto [Enter = 80]: "
        read -r input
        [[ -z "$input" ]] && input="80"
        input="${input//[^0-9]/}"
        [[ -z "$input" ]] && { print_error "Ingresa un numero."; continue; }
        validar_puerto "$input" "${PUERTOS_RESERVADOS[@]}" || continue
        verificar_y_liberar_puerto "$input" || continue
        PUERTO_ELEGIDO="$input"
        print_completado "Puerto $PUERTO_ELEGIDO aceptado."; sleep 1; break
    done
}

configurar_firewall() {
    local puerto="$1"
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null
        firewall-cmd --reload &>/dev/null
        print_completado "Firewall: puerto $puerto abierto."
    elif command -v iptables &>/dev/null; then
        iptables -A INPUT -p tcp --dport "$puerto" -j ACCEPT
        print_completado "iptables: puerto $puerto abierto."
    else
        print_info "Sin firewall activo."
    fi
}

# Redireccion NAT para Tomcat: puerto_elegido -> puerto_interno
configurar_nat_tomcat() {
    local puerto_pub="$1" puerto_priv="$2"
    # Limpiar reglas anteriores para este puerto
    iptables -t nat -D PREROUTING -p tcp --dport "$puerto_pub" -j REDIRECT --to-port "$puerto_priv" 2>/dev/null
    iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport "$puerto_pub" -j REDIRECT --to-port "$puerto_priv" 2>/dev/null
    # Agregar nuevas reglas
    iptables -t nat -A PREROUTING -p tcp --dport "$puerto_pub" -j REDIRECT --to-port "$puerto_priv"
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport "$puerto_pub" -j REDIRECT --to-port "$puerto_priv"
    print_completado "NAT: puerto $puerto_pub -> $puerto_priv (Tomcat interno)."
}

mostrar_url() {
    local puerto="$1"
    echo ""
    print_info "Prueba local  : curl -I http://localhost:${puerto}"
    print_info "Prueba red    : curl -I http://${IP_SERVIDOR}:${puerto}"
    print_info "Navegador     : http://${IP_SERVIDOR}:${puerto}"
}

crear_index() {
    local servicio="$1" version="$2" puerto="$3" destino="$4"
    mkdir -p "$destino"
    cat > "${destino}/index.html" << EOF
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>$servicio</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 60px; background: #fff; color: #222; }
    h2   { border-bottom: 1px solid #ccc; padding-bottom: 8px; }
    p    { font-size: 1.1em; margin: 8px 0; }
  </style>
</head>
<body>
  <h2>Servidor Web - Practica 6</h2>
  <p>Servidor : $servicio</p>
  <p>Version  : $version</p>
  <p>Puerto   : $puerto</p>
  <br>
  <p>Lo logre profe Herman!</p>
</body>
</html>
EOF
    print_completado "index.html creado en $destino"
}

instalar_apache() {
    print_titulo "Instalando Apache $VERSION_ELEGIDA desde binario..."

    print_info "Instalando dependencias..."
    $PKG_INSTALL gcc make pcre-devel openssl-devel expat-devel \
                 libxml2-devel apr-devel apr-util-devel zlib-devel curl &>/dev/null
    print_completado "Dependencias instaladas."

    local tarball="/tmp/httpd-${VERSION_ELEGIDA}.tar.gz"
    local url="https://downloads.apache.org/httpd/httpd-${VERSION_ELEGIDA}.tar.gz"
    local url_archive="https://archive.apache.org/dist/httpd/httpd-${VERSION_ELEGIDA}.tar.gz"

    print_info "Descargando Apache $VERSION_ELEGIDA..."
    curl -L --progress-bar -o "$tarball" "$url" 2>&1
    if ! gzip -t "$tarball" &>/dev/null; then
        print_info "Intentando mirror alternativo..."
        rm -f "$tarball"
        curl -L --progress-bar -o "$tarball" "$url_archive" 2>&1
        if ! gzip -t "$tarball" &>/dev/null; then
            print_error "No se pudo descargar Apache $VERSION_ELEGIDA. Intenta otra version."
            rm -f "$tarball"; return 1
        fi
    fi
    print_completado "Descarga verificada."

    print_info "Compilando Apache (esto puede tardar 3-5 minutos)..."
    rm -rf /tmp/httpd_src && mkdir -p /tmp/httpd_src
    tar xzf "$tarball" -C /tmp/httpd_src --strip-components=1 || { print_error "Fallo la extraccion."; rm -f "$tarball"; return 1; }
    rm -f "$tarball"

    cd /tmp/httpd_src || return 1
    ./configure \
        --prefix=/opt/apache \
        --enable-so --enable-ssl --enable-rewrite \
        --enable-headers --enable-proxy \
        --with-mpm=prefork --enable-log-config \
        &>/dev/null || { print_error "Fallo configure."; return 1; }
    make -j"$(nproc)" &>/dev/null || { print_error "Fallo la compilacion."; return 1; }
    make install &>/dev/null || { print_error "Fallo make install."; return 1; }
    cd / && rm -rf /tmp/httpd_src
    print_completado "Apache $VERSION_ELEGIDA instalado en /opt/apache"

    if ! id "apache_web" &>/dev/null; then
        useradd -r -s /sbin/nologin -M apache_web
        print_completado "Usuario apache_web creado."
    fi

    mkdir -p /opt/apache/logs /opt/apache/run
    chmod 755 /opt/apache/logs /opt/apache/run

    local conf="/opt/apache/conf/httpd.conf"
    cp "$conf" "${conf}.bak"
    sed -i "s/^User daemon/User apache_web/"   "$conf"
    sed -i "s/^Group daemon/Group apache_web/" "$conf"
    sed -i "s/^Listen 80$/Listen ${PUERTO_ELEGIDO}/" "$conf"
    sed -i "s/^#ServerName.*/ServerName localhost/" "$conf"
    sed -i "s|^DocumentRoot \".*\"|DocumentRoot \"${APACHE_WEBROOT}\"|" "$conf"
    sed -i "s|<Directory \".*htdocs\">|<Directory \"${APACHE_WEBROOT}\">|" "$conf"
    sed -i 's/#LoadModule headers_module/LoadModule headers_module/' "$conf"
    cat >> "$conf" << 'SECEOF'

ServerTokens Prod
ServerSignature Off
TraceEnable Off
<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
</IfModule>
SECEOF
    print_completado "httpd.conf configurado (puerto $PUERTO_ELEGIDO)."

    mkdir -p "$APACHE_WEBROOT"
    crear_index "Apache" "$VERSION_ELEGIDA" "$PUERTO_ELEGIDO" "$APACHE_WEBROOT"
    chown -R apache_web:apache_web "$APACHE_WEBROOT"
    chmod 750 "$APACHE_WEBROOT"
    print_completado "Permisos webroot: apache_web (chmod 750)."

    cat > /etc/systemd/system/apache-web.service << EOF
[Unit]
Description=Apache HTTP Server ${VERSION_ELEGIDA}
After=network.target

[Service]
Type=forking
PIDFile=/opt/apache/logs/httpd.pid
ExecStart=/opt/apache/bin/apachectl -k start
ExecReload=/opt/apache/bin/apachectl -k graceful
ExecStop=/opt/apache/bin/apachectl -k stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl stop apache-web 2>/dev/null; sleep 1
    systemctl enable apache-web &>/dev/null
    systemctl start apache-web
    sleep 3

    configurar_firewall "$PUERTO_ELEGIDO"

    if systemctl is-active --quiet apache-web; then
        print_completado "Apache $VERSION_ELEGIDA activo en puerto $PUERTO_ELEGIDO"
        mostrar_url "$PUERTO_ELEGIDO"
    else
        print_error "Apache no arranco. Revisa: journalctl -u apache-web -n 20 --no-pager"
        return 1
    fi
}

instalar_nginx() {
    print_titulo "Instalando Nginx $VERSION_ELEGIDA desde binario..."

    print_info "Instalando dependencias..."
    $PKG_INSTALL gcc make pcre-devel openssl-devel zlib-devel curl &>/dev/null
    print_completado "Dependencias instaladas."

    local tarball="/tmp/nginx-${VERSION_ELEGIDA}.tar.gz"
    local url="https://nginx.org/download/nginx-${VERSION_ELEGIDA}.tar.gz"

    print_info "Descargando Nginx $VERSION_ELEGIDA..."
    curl -L --progress-bar -o "$tarball" "$url" 2>&1
    if ! gzip -t "$tarball" &>/dev/null; then
        print_error "Descarga invalida o version no disponible. Intenta otra version."
        rm -f "$tarball"; return 1
    fi
    print_completado "Descarga verificada."

    if ! id "www-nginx" &>/dev/null; then
        useradd -r -s /sbin/nologin -M www-nginx
        print_completado "Usuario www-nginx creado."
    fi

    print_info "Compilando Nginx (esto puede tardar 2-3 minutos)..."
    rm -rf /tmp/nginx_src && mkdir -p /tmp/nginx_src
    tar xzf "$tarball" -C /tmp/nginx_src --strip-components=1 || { print_error "Fallo la extraccion."; rm -f "$tarball"; return 1; }
    rm -f "$tarball"

    cd /tmp/nginx_src || return 1
    ./configure \
        --prefix=/opt/nginx \
        --user=www-nginx --group=www-nginx \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_gzip_static_module \
        --with-pcre \
        &>/dev/null || { print_error "Fallo configure."; return 1; }
    make -j"$(nproc)" &>/dev/null || { print_error "Fallo la compilacion."; return 1; }
    make install &>/dev/null || { print_error "Fallo make install."; return 1; }
    cd / && rm -rf /tmp/nginx_src
    print_completado "Nginx $VERSION_ELEGIDA instalado en /opt/nginx"

    mkdir -p /opt/nginx/logs
    chown www-nginx:www-nginx /opt/nginx/logs
    chmod 755 /opt/nginx/logs

    cat > /opt/nginx/conf/nginx.conf << NGINXEOF
user www-nginx;
worker_processes auto;
pid /opt/nginx/logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include      /opt/nginx/conf/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff"    always;
    add_header X-XSS-Protection       "1; mode=block" always;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen      ${PUERTO_ELEGIDO};
        server_name localhost;
        root        ${NGINX_WEBROOT};
        index       index.html;

        if (\$request_method !~ ^(GET|POST|HEAD|OPTIONS)$) {
            return 405;
        }

        location / {
            try_files \$uri \$uri/ =404;
            autoindex off;
        }

        access_log /opt/nginx/logs/access.log;
        error_log  /opt/nginx/logs/error.log;
    }
}
NGINXEOF
    print_completado "nginx.conf configurado con puerto $PUERTO_ELEGIDO"
    /opt/nginx/sbin/nginx -t 2>/dev/null || { print_error "Error de sintaxis."; /opt/nginx/sbin/nginx -t; return 1; }

    mkdir -p "$NGINX_WEBROOT"
    crear_index "Nginx" "$VERSION_ELEGIDA" "$PUERTO_ELEGIDO" "$NGINX_WEBROOT"
    chown -R www-nginx:www-nginx "$NGINX_WEBROOT"
    chmod 750 "$NGINX_WEBROOT"
    print_completado "Permisos webroot: www-nginx (chmod 750)."

    cat > /etc/systemd/system/nginx-web.service << EOF
[Unit]
Description=Nginx HTTP Server ${VERSION_ELEGIDA}
After=network.target

[Service]
Type=forking
PIDFile=/opt/nginx/logs/nginx.pid
ExecStart=/opt/nginx/sbin/nginx
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl stop nginx-web 2>/dev/null; sleep 1
    systemctl enable nginx-web &>/dev/null
    systemctl start nginx-web
    sleep 2

    configurar_firewall "$PUERTO_ELEGIDO"

    if systemctl is-active --quiet nginx-web; then
        print_completado "Nginx $VERSION_ELEGIDA activo en puerto $PUERTO_ELEGIDO"
        mostrar_url "$PUERTO_ELEGIDO"
    else
        print_error "Nginx no arranco. Revisa: journalctl -u nginx-web -n 20 --no-pager"
        return 1
    fi
}

instalar_tomcat() {
    print_titulo "Instalando Apache Tomcat $VERSION_ELEGIDA..."

    local rama="${VERSION_ELEGIDA%%.*}"
    local url="https://dlcdn.apache.org/tomcat/tomcat-${rama}/v${VERSION_ELEGIDA}/bin/apache-tomcat-${VERSION_ELEGIDA}.tar.gz"
    local tarball="/tmp/apache-tomcat-${VERSION_ELEGIDA}.tar.gz"

    if ! command -v java &>/dev/null; then
        print_info "Java no encontrado. Instalando OpenJDK..."
        $PKG_INSTALL java-21-openjdk java-21-openjdk-headless &>/dev/null || \
        $PKG_INSTALL java-11-openjdk java-11-openjdk-headless &>/dev/null || \
            { print_error "No se pudo instalar Java."; return 1; }
        print_completado "Java instalado."
    else
        print_completado "Java: $(java -version 2>&1 | head -1)"
    fi

    command -v curl &>/dev/null || $PKG_INSTALL curl &>/dev/null

    print_info "Descargando Tomcat $VERSION_ELEGIDA..."
    curl -L --progress-bar -o "$tarball" "$url" 2>&1
    if ! gzip -t "$tarball" &>/dev/null; then
        print_error "Descarga invalida. Intenta otra version."
        rm -f "$tarball"; return 1
    fi
    print_completado "Descarga verificada."

    print_info "Extrayendo en /opt/tomcat..."
    rm -rf /opt/tomcat && mkdir -p /opt/tomcat
    tar xzf "$tarball" -C /opt/tomcat --strip-components=1 || { print_error "Fallo la extraccion."; rm -f "$tarball"; return 1; }
    rm -f "$tarball"
    print_completado "Tomcat extraido en /opt/tomcat"

    # Si el puerto elegido es < 1024, Tomcat escucha en puerto+10000
    # e iptables redirige el trafico
    if (( PUERTO_ELEGIDO < 1024 )); then
        PUERTO_INTERNO=$(( PUERTO_ELEGIDO + 10000 ))
        print_info "Puerto $PUERTO_ELEGIDO < 1024. Tomcat usara internamente el puerto $PUERTO_INTERNO."
        print_info "Se configurara NAT con iptables para redirigir $PUERTO_ELEGIDO -> $PUERTO_INTERNO."
    else
        PUERTO_INTERNO=$PUERTO_ELEGIDO
    fi

    cp /opt/tomcat/conf/server.xml /opt/tomcat/conf/server.xml.bak
    sed -i "s/port=\"8080\"/port=\"${PUERTO_INTERNO}\"/" /opt/tomcat/conf/server.xml
    sed -i 's/port="8009"/port="-1"/' /opt/tomcat/conf/server.xml
    print_completado "Puerto interno configurado -> $PUERTO_INTERNO (AJP deshabilitado)."

    if ! id "tomcat" &>/dev/null; then
        useradd -r -s /sbin/nologin -d /opt/tomcat -M tomcat
        print_completado "Usuario tomcat creado."
    fi

    mkdir -p "$TOMCAT_WEBROOT"
    crear_index "Apache Tomcat" "$VERSION_ELEGIDA" "$PUERTO_ELEGIDO" "$TOMCAT_WEBROOT"
    chown -R tomcat:tomcat /opt/tomcat
    chmod 750 /opt/tomcat /opt/tomcat/conf
    print_completado "Permisos: tomcat (chmod 750)."

    local java_home
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

    cat > /etc/systemd/system/tomcat.service << SVCEOF
[Unit]
Description=Apache Tomcat ${VERSION_ELEGIDA}
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
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl stop tomcat 2>/dev/null
    pkill -f java 2>/dev/null; sleep 2
    systemctl enable tomcat &>/dev/null
    systemctl start tomcat
    print_info "Esperando que Tomcat inicie (15 seg)..."
    sleep 15

    if ! systemctl is-active --quiet tomcat; then
        print_error "Tomcat no arranco."
        print_info  "Revisa: cat /opt/tomcat/logs/catalina.out | tail -20"
        return 1
    fi

    # Configurar NAT si puerto < 1024
    if (( PUERTO_ELEGIDO < 1024 )); then
        configurar_nat_tomcat "$PUERTO_ELEGIDO" "$PUERTO_INTERNO"
    fi

    configurar_firewall "$PUERTO_ELEGIDO"

    print_completado "Tomcat $VERSION_ELEGIDA activo en puerto $PUERTO_ELEGIDO"
    mostrar_url "$PUERTO_ELEGIDO"
}

verificar_HTTP() {
    echo ""
    echo "=== Estado de Servidores HTTP ==="
    echo ""

    echo -n "  Apache  : "
    if [[ -f /opt/apache/bin/apachectl ]]; then
        local ver; ver=$(/opt/apache/bin/apachectl -v 2>/dev/null | grep -oP 'Apache/\K[0-9.]+')
        if systemctl is-active --quiet apache-web 2>/dev/null; then
            local p; p=$(ss -tlnp 2>/dev/null | grep httpd | grep -oP ':\K[0-9]+' | head -1)
            echo "Activo | Version: ${ver:-?} | Puerto: ${p:-?}"
        else
            echo "Detenido | Version: ${ver:-?}"
        fi
    else
        echo "No instalado"
    fi

    echo -n "  Nginx   : "
    if [[ -f /opt/nginx/sbin/nginx ]]; then
        local ver; ver=$(/opt/nginx/sbin/nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
        if systemctl is-active --quiet nginx-web 2>/dev/null; then
            local p; p=$(ss -tlnp 2>/dev/null | grep nginx | grep -oP ':\K[0-9]+' | head -1)
            echo "Activo | Version: ${ver:-?} | Puerto: ${p:-?}"
        else
            echo "Detenido | Version: ${ver:-?}"
        fi
    else
        echo "No instalado"
    fi

    echo -n "  Tomcat  : "
    if [[ -f /opt/tomcat/bin/startup.sh ]]; then
        local ver; ver=$(/opt/tomcat/bin/version.sh 2>/dev/null | grep "Server version" | grep -oP 'Tomcat/\K[0-9.]+')
        if systemctl is-active --quiet tomcat 2>/dev/null; then
            # Mostrar el puerto publico (de la regla NAT si existe, o el interno)
            local p_nat p_int p_show
            p_int=$(ss -tlnp 2>/dev/null | grep java | grep -oP '[:\*]\K[0-9]+' | grep -v "^8005$" | head -1)
            p_nat=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "redir ports ${p_int}" | grep -oP 'dpt:\K[0-9]+' | head -1)
            p_show="${p_nat:-$p_int}"
            echo "Activo | Version: ${ver:-?} | Puerto: ${p_show:-?}"
        else
            echo "Detenido | Version: ${ver:-?}"
        fi
    else
        echo "No instalado"
    fi
    echo ""
}

instalar_HTTP() {
    clear
    echo ""
    echo "=== Instalacion de Servidor HTTP ==="
    echo ""
    echo "  [1] Apache"
    echo "  [2] Nginx"
    echo "  [3] Apache Tomcat"
    echo ""

    local opcion
    while true; do
        echo -n "Selecciona un servidor [1-3]: "
        read -r opcion; opcion="${opcion//[^0-9]/}"
        [[ "$opcion" =~ ^[123]$ ]] && break
        print_error "Opcion invalida."
    done

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