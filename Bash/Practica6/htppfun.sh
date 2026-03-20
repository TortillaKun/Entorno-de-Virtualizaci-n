#!/bin/bash
# htppfun.sh - Funciones para instalacion de servidores HTTP
# Practica 6 - Mageia Linux (Server, sin GUI)

print_info()      { echo "[INFO] $1"; }
print_completado(){ echo "[OK]   $1"; }
print_error()     { echo "[ERROR] $1"; }
print_titulo()    { echo ""; echo ">> $1"; echo ""; }

readonly PUERTOS_RESERVADOS=(22 21 23 25 53 443 3306 5432 6379 27017)
readonly APACHE_WEBROOT="/var/www/html/apache"
readonly NGINX_WEBROOT="/var/www/html/nginx"
readonly TOMCAT_WEBROOT="/opt/tomcat/webapps/ROOT"

VERSION_ELEGIDA=""
PUERTO_ELEGIDO=""
PUERTO_INTERNO=""
PKG_MANAGER=""
PKG_INSTALL=""
IP_SERVIDOR=""

# ─────────────────────────────────────────────────────────────────
# Obtiene la IP real del servidor probando interfaces en orden.
# enp0s9 es la interfaz SSH tipica en Mageia con VirtualBox (NIC4).
# ─────────────────────────────────────────────────────────────────
obtener_ip_servidor() {
    local ip=""
    for iface in enp0s9 enp0s8 enp0s3 eth1 eth0; do
        ip=$(ip addr show "$iface" 2>/dev/null \
             | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
        [[ -n "$ip" ]] && echo "$ip" && return
    done
    # Cualquier interfaz UP que no sea loopback
    ip=$(ip addr 2>/dev/null \
         | awk '/state UP/{up=1} up && /inet / && !/127\.0\.0\./{print $2; exit}' \
         | cut -d/ -f1)
    [[ -n "$ip" ]] && echo "$ip" && return
    hostname -I 2>/dev/null | awk '{print $1}'
}

detectar_entorno() {
    if command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"; PKG_INSTALL="dnf install -y"
    elif command -v urpmi &>/dev/null; then
        PKG_MANAGER="urpmi"; PKG_INSTALL="urpmi --auto"
    else
        print_error "No se detecto dnf ni urpmi."; exit 1
    fi
    print_completado "Gestor de paquetes: $PKG_MANAGER"

    IP_SERVIDOR=$(obtener_ip_servidor)
    if [[ -z "$IP_SERVIDOR" ]]; then
        print_error "No se pudo determinar la IP del servidor."
        IP_SERVIDOR="<SIN-IP>"
    fi
    print_completado "IP del servidor   : $IP_SERVIDOR"
}

validar_root() {
    [[ $EUID -ne 0 ]] && { echo "[ERROR] Ejecuta como root."; exit 1; }
}

# ─────────────────────────────────────────────────────────────────
# Helpers: puerto activo de cada servidor (lectura en tiempo real)
# ─────────────────────────────────────────────────────────────────
puerto_activo_apache() {
    ss -tlnp 2>/dev/null \
        | grep -E '"httpd"|"apache"' \
        | grep -oP ':\K[0-9]+' | head -1
}

puerto_activo_nginx() {
    ss -tlnp 2>/dev/null \
        | grep '"nginx"' \
        | grep -oP ':\K[0-9]+' | head -1
}

puerto_activo_tomcat() {
    local p_int p_pub
    p_int=$(ss -tlnp 2>/dev/null \
            | grep '"java"' \
            | grep -oP ':\K[0-9]+' \
            | grep -v '^8005$' | grep -v '^8443$' | head -1)
    [[ -z "$p_int" ]] && return
    # Ver si hay regla NAT que apunte a p_int -> puerto publico
    p_pub=$(iptables -t nat -L PREROUTING -n 2>/dev/null \
            | awk -v p="$p_int" \
              '$0 ~ "redir ports " p {match($0,/dpt:([0-9]+)/,a); if(a[1]) print a[1]}' \
            | head -1)
    echo "${p_pub:-$p_int}"
}

http_propio_en_puerto() {
    local puerto="$1"
    if [[ -f /opt/apache/bin/apachectl ]] && systemctl is-active --quiet apache-web 2>/dev/null; then
        [[ "$(puerto_activo_apache)" == "$puerto" ]] && echo "Apache:apache-web" && return
    fi
    if [[ -f /opt/nginx/sbin/nginx ]] && systemctl is-active --quiet nginx-web 2>/dev/null; then
        [[ "$(puerto_activo_nginx)" == "$puerto" ]] && echo "Nginx:nginx-web" && return
    fi
    if [[ -f /opt/tomcat/bin/startup.sh ]] && systemctl is-active --quiet tomcat 2>/dev/null; then
        [[ "$(puerto_activo_tomcat)" == "$puerto" ]] && echo "Apache Tomcat:tomcat" && return
    fi
    echo ""
}

servicio_en_puerto() {
    local puerto="$1"
    local proc
    proc=$(ss -tlnp 2>/dev/null \
           | grep ":${puerto} " \
           | grep -oP 'users:\(\("\K[^"]+' | head -1)
    case "$proc" in
        *httpd*|*apache*) echo "apache-web" ;;
        *nginx*)          echo "nginx-web"  ;;
        *java*)           echo "tomcat"     ;;
        *)                echo "${proc:-desconocido}" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────
# Validaciones de puerto
# ─────────────────────────────────────────────────────────────────
validar_puerto() {
    local puerto="$1"; shift
    local reservados=("$@")
    [[ ! "$puerto" =~ ^[0-9]+$ ]]     && { print_error "El puerto debe ser un numero."; return 1; }
    (( puerto < 1 || puerto > 65535 )) && { print_error "Puerto fuera de rango (1-65535)."; return 1; }
    for r in "${reservados[@]}"; do
        (( puerto == r )) && { print_error "Puerto $puerto reservado."; return 1; }
    done
    return 0
}

verificar_y_liberar_puerto() {
    local puerto="$1"
    local ocupado=0
    ss -tlnp 2>/dev/null | grep -q ":${puerto} "                          && ocupado=1
    iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:${puerto}" && ocupado=1
    [[ $ocupado -eq 0 ]] && return 0

    local http_info; http_info=$(http_propio_en_puerto "$puerto")
    if [[ -n "$http_info" ]]; then
        local nombre="${http_info%%:*}" svc="${http_info##*:}"
        print_error "Puerto $puerto en uso por: $nombre"
        echo -n "Deseas detener $nombre y ceder el puerto? [s/N]: "
        read -r resp; resp="${resp,,}"
        if [[ "$resp" == "s" || "$resp" == "si" ]]; then
            systemctl stop "$svc" 2>/dev/null
            pkill -f java 2>/dev/null
            iptables -t nat -D PREROUTING -p tcp --dport "$puerto" \
                -j REDIRECT --to-port "$((puerto+10000))" 2>/dev/null
            iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport "$puerto" \
                -j REDIRECT --to-port "$((puerto+10000))" 2>/dev/null
            sleep 2
            print_completado "$nombre detenido. Puerto $puerto liberado."
            return 0
        else
            print_info "Elige un puerto diferente."; return 1
        fi
    fi

    local svc; svc=$(servicio_en_puerto "$puerto")
    print_error "Puerto $puerto ocupado por: $svc"
    echo -n "Deseas detener ese proceso? [s/N]: "
    read -r resp; resp="${resp,,}"
    if [[ "$resp" == "s" || "$resp" == "si" ]]; then
        systemctl stop "$svc" 2>/dev/null; sleep 2
        ss -tlnp 2>/dev/null | grep -q ":${puerto} " \
            && { print_error "Puerto sigue ocupado."; return 1; }
        print_completado "Puerto $puerto liberado."
    else
        print_info "Elige un puerto diferente."; return 1
    fi
}

# ─────────────────────────────────────────────────────────────────
# Consulta de versiones online
# ─────────────────────────────────────────────────────────────────
obtener_versiones_apache() {
    print_info "Consultando versiones de Apache..." >&2
    local v
    v=$(curl -s --max-time 10 "https://downloads.apache.org/httpd/" 2>/dev/null \
        | grep -oP 'httpd-\K2\.4\.[0-9]+(?=\.tar\.gz)' | sort -uV)
    if [[ -z "$v" ]]; then
        print_info "Sin acceso. Usando versiones de referencia." >&2
        echo "2.4.62"; echo "2.4.63"; echo "2.4.66"; return
    fi
    echo "$v"
}

obtener_versiones_nginx() {
    print_info "Consultando versiones de Nginx..." >&2
    local v
    v=$(curl -s --max-time 10 "https://nginx.org/download/" 2>/dev/null \
        | grep -oP 'nginx-\K1\.[0-9]+\.[0-9]+(?=\.tar\.gz)' | sort -uV | tail -8)
    if [[ -z "$v" ]]; then
        print_info "Sin acceso. Usando versiones de referencia." >&2
        echo "1.26.3"; echo "1.27.5"; echo "1.28.0"; return
    fi
    echo "$v"
}

obtener_versiones_tomcat() {
    print_info "Consultando versiones de Tomcat..." >&2
    local base="https://dlcdn.apache.org/tomcat/"
    local ramas
    ramas=$(curl -s --max-time 8 "$base" 2>/dev/null \
            | grep -oP 'tomcat-\K[0-9]+(?=/)' | sort -uV)
    if [[ -z "$ramas" ]]; then
        print_info "Sin acceso. Usando versiones de referencia." >&2
        echo "9.0.102"; echo "10.1.40"; echo "11.0.7"; return
    fi
    while IFS= read -r rama; do
        local latest
        latest=$(curl -s --max-time 8 "${base}tomcat-${rama}/" 2>/dev/null \
                 | grep -oP "v\K[0-9]+\.[0-9]+\.[0-9]+" | sort -V | tail -1)
        [[ -n "$latest" ]] && echo "$latest"
    done <<< "$ramas"
}

elegir_version() {
    clear
    local paquete="$1"; shift
    local versiones=("$@")
    [[ ${#versiones[@]} -eq 0 ]] && { print_error "Sin versiones para '$paquete'."; return 1; }
    echo ""
    echo "=== Versiones disponibles: $paquete ==="
    echo ""
    local i=1 total=${#versiones[@]}
    for ver in "${versiones[@]}"; do
        local etiqueta=""
        [[ $i -eq 1      ]] && etiqueta="  [LTS / Estable]"
        [[ $i -eq $total ]] && etiqueta="  [Latest]"
        printf "  [%d] %s%s\n" "$i" "$ver" "$etiqueta"
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
    print_info "Predeterminado: 80  |  Alternativos: 8080, 8888"
    print_info "Reservados (bloqueados): ${PUERTOS_RESERVADOS[*]}"
    echo ""
    while true; do
        echo -n "Ingresa el puerto [Enter = 80]: "
        read -r input
        [[ -z "$input" ]] && input="80"
        input="${input//[^0-9]/}"
        [[ -z "$input" ]] && { print_error "Ingresa un numero valido."; continue; }
        validar_puerto "$input" "${PUERTOS_RESERVADOS[@]}" || continue
        verificar_y_liberar_puerto "$input"               || continue
        PUERTO_ELEGIDO="$input"
        print_completado "Puerto $PUERTO_ELEGIDO aceptado."; sleep 1; break
    done
}

configurar_firewall() {
    local puerto="$1"
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null
        firewall-cmd --reload &>/dev/null
        print_completado "Firewall: puerto $puerto abierto (firewalld)."
    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "$puerto" -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport "$puerto" -j ACCEPT
        print_completado "Firewall: puerto $puerto abierto (iptables)."
    else
        print_info "Sin firewall activo detectado."
    fi
}

configurar_nat_tomcat() {
    local pub="$1" priv="$2"
    iptables -t nat -D PREROUTING -p tcp --dport "$pub" -j REDIRECT --to-port "$priv" 2>/dev/null
    iptables -t nat -D OUTPUT     -p tcp -d 127.0.0.1 --dport "$pub" -j REDIRECT --to-port "$priv" 2>/dev/null
    iptables -t nat -A PREROUTING -p tcp --dport "$pub" -j REDIRECT --to-port "$priv"
    iptables -t nat -A OUTPUT     -p tcp -d 127.0.0.1 --dport "$pub" -j REDIRECT --to-port "$priv"
    print_completado "NAT configurado: $pub -> $priv"
}

# ─────────────────────────────────────────────────────────────────
# Muestra URL usando IP en tiempo real
# ─────────────────────────────────────────────────────────────────
mostrar_url() {
    local puerto="$1"
    local ip; ip=$(obtener_ip_servidor)
    [[ -z "$ip" ]] && ip="<TU-IP>"
    echo ""
    echo "  ┌──────────────────────────────────────────────────┐"
    printf "  │  URL: http://%-36s│\n" "${ip}:${puerto}"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""
    print_info "Prueba local : curl -I http://localhost:${puerto}"
    print_info "Prueba red   : curl -I http://${ip}:${puerto}"
    echo ""
}

crear_index() {
    local servicio="$1" version="$2" puerto="$3" destino="$4"
    local ip; ip=$(obtener_ip_servidor)
    [[ -z "$ip" ]] && ip="<SIN-IP>"
    mkdir -p "$destino"
    cat > "${destino}/index.html" << EOF
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>$servicio - Practica 6</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 60px; background: #f5f5f5; color: #222; }
    .card { background: #fff; border-radius: 8px; padding: 30px; max-width: 520px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.12); }
    h2   { border-bottom: 2px solid #0066cc; padding-bottom: 10px; color: #0066cc; }
    p    { font-size: 1.1em; margin: 8px 0; }
    .url { background: #e8f0fe; padding: 10px 14px; border-radius: 4px;
           font-family: monospace; font-size: 1.05em; margin-top: 15px; word-break: break-all; }
  </style>
</head>
<body>
  <div class="card">
    <h2>Servidor Web &mdash; Practica 6</h2>
    <p><b>Servidor :</b> $servicio</p>
    <p><b>Version  :</b> $version</p>
    <p><b>Puerto   :</b> $puerto</p>
    <p><b>IP       :</b> $ip</p>
    <div class="url">http://${ip}:${puerto}</div>
    <br>
    <p>&#10003; &nbsp;Lo logre profe Herman!</p>
  </div>
</body>
</html>
EOF
    print_completado "index.html creado en $destino"
}

# ─────────────────────────────────────────────────────────────────
# Estado en tiempo real — lee directamente ss y systemctl
# Nunca usa variables globales de instalacion anterior
# ─────────────────────────────────────────────────────────────────
verificar_HTTP() {
    local ip; ip=$(obtener_ip_servidor)
    [[ -z "$ip" ]] && ip="<SIN-IP>"

    echo ""
    echo "=== Estado de Servidores HTTP ==="
    echo ""

    # ── Apache ──────────────────────────────────────────────────
    echo -n "  Apache  : "
    if [[ -f /opt/apache/bin/apachectl ]]; then
        local ver; ver=$(/opt/apache/bin/apachectl -v 2>/dev/null | grep -oP 'Apache/\K[0-9.]+')
        if systemctl is-active --quiet apache-web 2>/dev/null; then
            local p; p=$(puerto_activo_apache)
            echo "Activo  | v${ver:-?} | :${p:-?} | http://${ip}:${p:-?}"
        else
            echo "Detenido | v${ver:-?}"
        fi
    else
        echo "No instalado"
    fi

    # ── Nginx ────────────────────────────────────────────────────
    echo -n "  Nginx   : "
    if [[ -f /opt/nginx/sbin/nginx ]]; then
        local ver; ver=$(/opt/nginx/sbin/nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
        if systemctl is-active --quiet nginx-web 2>/dev/null; then
            local p; p=$(puerto_activo_nginx)
            echo "Activo  | v${ver:-?} | :${p:-?} | http://${ip}:${p:-?}"
        else
            echo "Detenido | v${ver:-?}"
        fi
    else
        echo "No instalado"
    fi

    # ── Tomcat ───────────────────────────────────────────────────
    echo -n "  Tomcat  : "
    if [[ -f /opt/tomcat/bin/startup.sh ]]; then
        local ver; ver=$(/opt/tomcat/bin/version.sh 2>/dev/null \
                         | grep "Server version" | grep -oP 'Tomcat/\K[0-9.]+')
        if systemctl is-active --quiet tomcat 2>/dev/null; then
            local p; p=$(puerto_activo_tomcat)
            echo "Activo  | v${ver:-?} | :${p:-?} | http://${ip}:${p:-?}"
        else
            echo "Detenido | v${ver:-?}"
        fi
    else
        echo "No instalado"
    fi

    echo ""
}

# ─────────────────────────────────────────────────────────────────
# Instalacion de servidores
# ─────────────────────────────────────────────────────────────────
instalar_apache() {
    print_titulo "Instalando Apache $VERSION_ELEGIDA desde fuente..."

    print_info "Instalando dependencias..."
    $PKG_INSTALL gcc make pcre-devel openssl-devel expat-devel \
                 libxml2-devel apr-devel apr-util-devel zlib-devel curl &>/dev/null
    print_completado "Dependencias listas."

    local tarball="/tmp/httpd-${VERSION_ELEGIDA}.tar.gz"
    print_info "Descargando Apache $VERSION_ELEGIDA..."
    curl -L --progress-bar -o "$tarball" \
        "https://downloads.apache.org/httpd/httpd-${VERSION_ELEGIDA}.tar.gz" 2>&1
    if ! gzip -t "$tarball" &>/dev/null; then
        print_info "Probando mirror archive.apache.org..."
        rm -f "$tarball"
        curl -L --progress-bar -o "$tarball" \
            "https://archive.apache.org/dist/httpd/httpd-${VERSION_ELEGIDA}.tar.gz" 2>&1
        gzip -t "$tarball" &>/dev/null \
            || { print_error "Descarga fallida. Prueba otra version."; rm -f "$tarball"; return 1; }
    fi
    print_completado "Descarga verificada."

    print_info "Compilando Apache (3-5 min)..."
    rm -rf /tmp/httpd_src && mkdir -p /tmp/httpd_src
    tar xzf "$tarball" -C /tmp/httpd_src --strip-components=1 \
        || { print_error "Fallo la extraccion."; rm -f "$tarball"; return 1; }
    rm -f "$tarball"
    cd /tmp/httpd_src || return 1
    ./configure --prefix=/opt/apache \
        --enable-so --enable-ssl --enable-rewrite \
        --enable-headers --enable-proxy \
        --with-mpm=prefork --enable-log-config &>/dev/null \
        || { print_error "Fallo configure."; return 1; }
    make -j"$(nproc)" &>/dev/null || { print_error "Fallo make."; return 1; }
    make install       &>/dev/null || { print_error "Fallo make install."; return 1; }
    cd / && rm -rf /tmp/httpd_src
    print_completado "Apache instalado en /opt/apache"

    id "apache_web" &>/dev/null || useradd -r -s /sbin/nologin -M apache_web
    mkdir -p /opt/apache/logs /opt/apache/run
    chmod 755 /opt/apache/logs /opt/apache/run

    local conf="/opt/apache/conf/httpd.conf"
    cp "$conf" "${conf}.bak"
    sed -i "s/^User daemon/User apache_web/"                              "$conf"
    sed -i "s/^Group daemon/Group apache_web/"                            "$conf"
    sed -i "s/^Listen 80$/Listen ${PUERTO_ELEGIDO}/"                      "$conf"
    sed -i "s/^#ServerName.*/ServerName localhost/"                       "$conf"
    sed -i "s|^DocumentRoot \".*\"|DocumentRoot \"${APACHE_WEBROOT}\"|"   "$conf"
    sed -i "s|<Directory \".*htdocs\">|<Directory \"${APACHE_WEBROOT}\">|" "$conf"
    sed -i 's/#LoadModule headers_module/LoadModule headers_module/'       "$conf"
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
    print_completado "Webroot: $APACHE_WEBROOT (apache_web, 750)"

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
    systemctl start apache-web; sleep 3
    configurar_firewall "$PUERTO_ELEGIDO"

    if systemctl is-active --quiet apache-web; then
        print_completado "Apache $VERSION_ELEGIDA activo."
        mostrar_url "$PUERTO_ELEGIDO"
    else
        print_error "Apache no arranco."
        print_info  "Revisa: journalctl -u apache-web -n 30 --no-pager"
        return 1
    fi
}

instalar_nginx() {
    print_titulo "Instalando Nginx $VERSION_ELEGIDA desde fuente..."

    print_info "Instalando dependencias..."
    $PKG_INSTALL gcc make pcre-devel openssl-devel zlib-devel curl &>/dev/null
    print_completado "Dependencias listas."

    local tarball="/tmp/nginx-${VERSION_ELEGIDA}.tar.gz"
    print_info "Descargando Nginx $VERSION_ELEGIDA..."
    curl -L --progress-bar -o "$tarball" \
        "https://nginx.org/download/nginx-${VERSION_ELEGIDA}.tar.gz" 2>&1
    gzip -t "$tarball" &>/dev/null \
        || { print_error "Descarga invalida."; rm -f "$tarball"; return 1; }
    print_completado "Descarga verificada."

    id "www-nginx" &>/dev/null || useradd -r -s /sbin/nologin -M www-nginx

    print_info "Compilando Nginx (2-3 min)..."
    rm -rf /tmp/nginx_src && mkdir -p /tmp/nginx_src
    tar xzf "$tarball" -C /tmp/nginx_src --strip-components=1 \
        || { print_error "Fallo la extraccion."; rm -f "$tarball"; return 1; }
    rm -f "$tarball"
    cd /tmp/nginx_src || return 1
    ./configure --prefix=/opt/nginx \
        --user=www-nginx --group=www-nginx \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_gzip_static_module \
        --with-pcre &>/dev/null \
        || { print_error "Fallo configure."; return 1; }
    make -j"$(nproc)" &>/dev/null || { print_error "Fallo make."; return 1; }
    make install       &>/dev/null || { print_error "Fallo make install."; return 1; }
    cd / && rm -rf /tmp/nginx_src
    print_completado "Nginx instalado en /opt/nginx"

    mkdir -p /opt/nginx/logs
    chown www-nginx:www-nginx /opt/nginx/logs
    chmod 755 /opt/nginx/logs

    cat > /opt/nginx/conf/nginx.conf << NGINXEOF
user www-nginx;
worker_processes auto;
pid /opt/nginx/logs/nginx.pid;

events { worker_connections 1024; }

http {
    include      /opt/nginx/conf/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    add_header X-Frame-Options        "SAMEORIGIN"    always;
    add_header X-Content-Type-Options "nosniff"       always;
    add_header X-XSS-Protection       "1; mode=block" always;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen      ${PUERTO_ELEGIDO};
        server_name localhost;
        root        ${NGINX_WEBROOT};
        index       index.html;

        if (\$request_method !~ ^(GET|POST|HEAD|OPTIONS)$) { return 405; }

        location / {
            try_files \$uri \$uri/ =404;
            autoindex off;
        }

        access_log /opt/nginx/logs/access.log;
        error_log  /opt/nginx/logs/error.log;
    }
}
NGINXEOF

    /opt/nginx/sbin/nginx -t 2>/dev/null \
        || { print_error "Error en nginx.conf:"; /opt/nginx/sbin/nginx -t; return 1; }
    print_completado "nginx.conf configurado (puerto $PUERTO_ELEGIDO)."

    mkdir -p "$NGINX_WEBROOT"
    crear_index "Nginx" "$VERSION_ELEGIDA" "$PUERTO_ELEGIDO" "$NGINX_WEBROOT"
    chown -R www-nginx:www-nginx "$NGINX_WEBROOT"
    chmod 750 "$NGINX_WEBROOT"
    print_completado "Webroot: $NGINX_WEBROOT (www-nginx, 750)"

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
    systemctl start nginx-web; sleep 2
    configurar_firewall "$PUERTO_ELEGIDO"

    if systemctl is-active --quiet nginx-web; then
        print_completado "Nginx $VERSION_ELEGIDA activo."
        mostrar_url "$PUERTO_ELEGIDO"
    else
        print_error "Nginx no arranco."
        print_info  "Revisa: journalctl -u nginx-web -n 30 --no-pager"
        return 1
    fi
}

instalar_tomcat() {
    print_titulo "Instalando Apache Tomcat $VERSION_ELEGIDA..."

    local rama="${VERSION_ELEGIDA%%.*}"
    local url="https://dlcdn.apache.org/tomcat/tomcat-${rama}/v${VERSION_ELEGIDA}/bin/apache-tomcat-${VERSION_ELEGIDA}.tar.gz"
    local tarball="/tmp/apache-tomcat-${VERSION_ELEGIDA}.tar.gz"

    if ! command -v java &>/dev/null; then
        print_info "Instalando Java..."
        $PKG_INSTALL java-21-openjdk java-21-openjdk-headless &>/dev/null \
            || $PKG_INSTALL java-11-openjdk java-11-openjdk-headless &>/dev/null \
            || { print_error "No se pudo instalar Java."; return 1; }
        print_completado "Java instalado."
    else
        print_completado "Java: $(java -version 2>&1 | head -1)"
    fi

    command -v curl &>/dev/null || $PKG_INSTALL curl &>/dev/null

    print_info "Descargando Tomcat $VERSION_ELEGIDA..."
    curl -L --progress-bar -o "$tarball" "$url" 2>&1
    gzip -t "$tarball" &>/dev/null \
        || { print_error "Descarga invalida."; rm -f "$tarball"; return 1; }
    print_completado "Descarga verificada."

    print_info "Extrayendo en /opt/tomcat..."
    rm -rf /opt/tomcat && mkdir -p /opt/tomcat
    tar xzf "$tarball" -C /opt/tomcat --strip-components=1 \
        || { print_error "Fallo la extraccion."; rm -f "$tarball"; return 1; }
    rm -f "$tarball"
    print_completado "Tomcat extraido en /opt/tomcat"

    if (( PUERTO_ELEGIDO < 1024 )); then
        PUERTO_INTERNO=$(( PUERTO_ELEGIDO + 10000 ))
        print_info "Puerto $PUERTO_ELEGIDO < 1024: Tomcat usara internamente $PUERTO_INTERNO"
        print_info "NAT iptables: $PUERTO_ELEGIDO -> $PUERTO_INTERNO"
    else
        PUERTO_INTERNO=$PUERTO_ELEGIDO
    fi

    cp /opt/tomcat/conf/server.xml /opt/tomcat/conf/server.xml.bak
    sed -i "s/port=\"8080\"/port=\"${PUERTO_INTERNO}\"/" /opt/tomcat/conf/server.xml
    sed -i 's/port="8009"/port="-1"/'                   /opt/tomcat/conf/server.xml
    print_completado "server.xml: puerto=$PUERTO_INTERNO, AJP deshabilitado."

    id "tomcat" &>/dev/null || useradd -r -s /sbin/nologin -d /opt/tomcat -M tomcat

    mkdir -p "$TOMCAT_WEBROOT"
    crear_index "Apache Tomcat" "$VERSION_ELEGIDA" "$PUERTO_ELEGIDO" "$TOMCAT_WEBROOT"
    chown -R tomcat:tomcat /opt/tomcat
    chmod 750 /opt/tomcat /opt/tomcat/conf
    print_completado "Permisos: tomcat:tomcat, chmod 750."

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
        print_info  "Log: tail -30 /opt/tomcat/logs/catalina.out"
        return 1
    fi

    (( PUERTO_ELEGIDO < 1024 )) && configurar_nat_tomcat "$PUERTO_ELEGIDO" "$PUERTO_INTERNO"
    configurar_firewall "$PUERTO_ELEGIDO"

    print_completado "Tomcat $VERSION_ELEGIDA activo."
    mostrar_url "$PUERTO_ELEGIDO"
}

# ─────────────────────────────────────────────────────────────────
# Menu de instalacion
# ─────────────────────────────────────────────────────────────────
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
        echo -n "Selecciona [1-3]: "
        read -r opcion; opcion="${opcion//[^0-9]/}"
        [[ "$opcion" =~ ^[123]$ ]] && break
        print_error "Opcion invalida."
    done

    local versiones=()
    case $opcion in
        1) mapfile -t versiones < <(obtener_versiones_apache)
           elegir_version "Apache"        "${versiones[@]}" || return 1
           pedir_puerto; instalar_apache ;;
        2) mapfile -t versiones < <(obtener_versiones_nginx)
           elegir_version "Nginx"         "${versiones[@]}" || return 1
           pedir_puerto; instalar_nginx  ;;
        3) mapfile -t versiones < <(obtener_versiones_tomcat)
           elegir_version "Apache Tomcat" "${versiones[@]}" || return 1
           pedir_puerto; instalar_tomcat ;;
    esac
}