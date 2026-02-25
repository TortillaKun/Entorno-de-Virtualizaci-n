#!/bin/bash

 instalar_ssh() {
 if rpm -q openssh-server &>/dev/null; then
 echo "SSH ya instalado"
else
 echo "Instalando SSH server"
 sudo urpmi --auto openssh-server
 echo "Instalacion Completa"
fi

 echo "Habilitando y prendiendo el servicio ssh"
 sudo systemctl enabled sshd
 sudo systemctl start sshd
 echo "Servicio ssh habilitado y ejecutando"

}

 verificar_ssh() {
 if rpm -q openssh-server &>/dev/null; then
 echo "SSH esta intalado"
else
 echo "SSH no esta instalado"
 return
fi

 if systemctl is-active --quiet sshd; then
 echo "El servicio SSH esta activo"
else
 echo "El servicio SSH no esta activo"
fi

 if systemctl is-enabled --quiet sshd; then
 echo "El servicio SSH esta habilitado"
else
 echo "El servicio SSH no esta habilitado"
fi

}

case "$1" in
 instalar)
 instalar_ssh
 ;;
 verificar)
 verificar_ssh
 ;;

 *)
  echo "Uso: $0 {Instalar|verificar}"
 ;;

esac

