echo "TAREA 1 SCRIPT "
echo "Hostname"
hostname
echo "IP"
ip -4 addr show | grep inet | grep -v 127.0.0.1
echo"espacio En disco "
df -h
