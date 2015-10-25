#!/bin/bash

set -e

[ -n "$DEBUG" ] && set -x

# Create the kvm node (required --privileged)
if [ ! -e /dev/kvm ]; then
  set +e
  mknod /dev/kvm c 10 $(grep '\<kvm\>' /proc/misc | cut -f 1 -d' ')
  set -e
fi

# If we were given arguments, override the default configuration
if [ $# -gt 0 ]; then
  exec /usr/bin/kvm $@
  exit $?
fi

# mountpoint check
if [ ! -d /data ]; then
  if [ "${ISO:0:1}" != "/" ] || [ -z "$IMAGE" ]; then
    echo "/data not mounted: using -v to mount it"
    exit 1
  fi
fi

if [ -n "$ISO" ]; then
  echo "[iso]"
  if [ "${ISO:0:1}" != "/" ] && [ "${ISO:0:10}" != "gluster://" ]; then
    basename=$(basename $ISO)
    if [ ! -f "/data/${basename}" ] || [ "$ISO_DOWNLOAD" != "0" ]; then
      wget -O- "$ISO" > /data/${basename}
    fi
    ISO=/data/${basename}
  fi
  FLAGS_ISO="-drive file=${ISO},media=cdrom,index=2"
  if [ "${ISO:0:10}" != "gluster://" ] && [ ! -f "$ISO" ]; then
    echo "ISO file not found: $ISO"
    exit 1
  fi
  echo "parameter: ${FLAGS_ISO}"
fi

if [ -n "$ISO2" ]; then
  echo "[iso2]"
  if [ "${ISO2:0:1}" != "/" ] && [ "${ISO2:0:10}" != "gluster://" ]; then
    basename=$(basename $ISO2)
    if [ ! -f "/data/${basename}" ] || [ "$ISO_DOWNLOAD" != "0" ]; then
      wget -O- "$ISO2" > /data/${basename}
    fi
    ISO=/data/${basename}
  fi
  FLAGS_ISO2="-drive file=${ISO2},media=cdrom,index=3"
  if [ "${ISO2:0:10}" != "gluster://" ] && [ ! -f "$ISO2" ]; then
    echo "ISO2 file not found: $ISO2"
    exit 1
  fi
  echo "parameter: ${FLAGS_ISO2}"
fi

echo "[disk image]"
if [ "$IMAGE_CREATE" == "1" ]; then
  qemu-img create -f qcow2 ${IMAGE} ${IMAGE_SIZE}
elif [ "${IMAGE:0:10}" != "gluster://" ] && [ ! -f "$IMAGE" ]; then
  echo "IMAGE not found: ${IMAGE}"; exit 1;
fi
FLAGS_DISK_IMAGE="-drive file=${IMAGE},if=virtio,cache=none,format=${IMAGE_FORMAT},index=1"
echo "parameter: ${FLAGS_DISK_IMAGE}"

echo "[network]"
if [ "$NETWORK" == "bridge" ]; then
  NETWORK_BRIDGE="${NETWORK_BRIDGE:-docker0}"
  hexchars="0123456789ABCDEF"
  NETWORK_MAC="${NETWORK_MAC:-$(echo 00:F0$(for i in {1..8} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done | sed -e 's/\(..\)/:\1/g'))}"
  echo allow $NETWORK_BRIDGE > /etc/qemu/bridge.conf
  FLAGS_NETWORK="-netdev bridge,br=${NETWORK_BRIDGE},id=net0 -device virtio-net,netdev=net0,mac=${NETWORK_MAC}"
elif [ "$NETWORK" == "tap" ]; then
  IFACE=eth0
  TAP_IFACE=tap0
  IP=`ip addr show dev $IFACE | grep "inet " | awk '{print $2}' | cut -f1 -d/`
  NAMESERVER=`grep nameserver /etc/resolv.conf | cut -f2 -d ' '`
  NAMESERVERS=`echo ${NAMESERVER[*]} | sed "s/ /,/"`
  NETWORK_IP="${NETWORK_IP:-$(echo 172.$((RANDOM%(31-16+1)+16)).$((RANDOM%256)).$((RANDOM%(254-2+1)+2)))}"
  NETWORK_SUB=`echo $NETWORK_IP | cut -f1,2,3 -d\.`
  NETWORK_GW="${NETWORK_GW:-$(echo ${NETWORK_SUB}.1)}"
  tunctl -t $TAP_IFACE
  dnsmasq --user=root \
    --dhcp-range=$NETWORK_IP,$NETWORK_IP \
    --dhcp-option=option:router,$NETWORK_GW \
    --dhcp-option=option:dns-server,$NAMESERVERS
  ifconfig $TAP_IFACE $NETWORK_GW up
  iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
  iptables -I FORWARD 1 -i $TAP_IFACE -j ACCEPT
  iptables -I FORWARD 1 -o $TAP_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
  if [ "$VNC" == "tcp" ]; then
    vncport=5900+$VNC_ID
    iptables -t nat -A PREROUTING -p tcp -d $IP ! --dport $vncport -j DNAT --to-destination $NETWORK_IP
    iptables -t nat -A PREROUTING -p udp -d $IP -j DNAT --to-destination $NETWORK_IP
    iptables -t nat -A PREROUTING -p icmp -d $IP -j DNAT --to-destination $NETWORK_IP
  else
    iptables -t nat -A PREROUTING -d $IP -j DNAT --to-destination $NETWORK_IP
  fi
  FLAGS_NETWORK="-net nic,model=virtio -net tap,ifname=tap0,script=no"
elif [ "$NETWORK" == "macvtap" ]; then
  NETWORK_IF="${NETWORK_IF:-eth0}"
  NETWORK_BRIDGE="${NETWORK_BRIDGE:-vtap0}"
  hexchars="0123456789ABCDEF"
  NETWORK_MAC="${NETWORK_MAC:-$(echo 00:F0$(for i in {1..8} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done | sed -e 's/\(..\)/:\1/g'))}"
  set +e
  ip link add link $NETWORK_IF name $NETWORK_BRIDGE address $NETWORK_MAC type macvtap mode bridge
  if [[ $? -ne 0 ]]; then
    echo "Warning! Bridge interface already exists"
  fi
  set -e
  FLAGS_NETWORK="-netdev tap,fd=3,id=net0,vhost=on -net nic,vlan=0,netdev=net0,macaddr=$NETWORK_MAC,model=virtio"
  exec 3<> /dev/tap`cat /sys/class/net/$NETWORK_BRIDGE/ifindex`
else
  NETWORK="user"
  REDIR=""
  if [ ! -z "$PORTS" ]; then
    OIFS=$IFS
    IFS=","
    for port in $PORTS; do
      REDIR+="-redir tcp:${port}::${port} "
    done
    IFS=$OIFS
  fi
  FLAGS_NETWORK="-net nic,model=virtio -net user ${REDIR}"
fi
echo "Using ${NETWORK}"
echo "parameter: ${FLAGS_NETWORK}"

echo "[Remote Access]"
if [ "$VNC" == "tcp" ]; then
  FLAGS_REMOTE_ACCESS="-vnc ${VNC_IP}:${VNC_ID}"
elif [ "$VNC" == "reverse" ]; then
  FLAGS_REMOTE_ACCESS="-vnc ${VNC_IP}:${VNC_PORT},reverse"
elif [ "$VNC" == "sock" ]; then
  FLAGS_REMOTE_ACCESS="-vnc unix:${VNC_SOCK}"
else
  FLAGS_REMOTE_ACCESS=""
fi
echo "parameter: ${FLAGS_REMOTE_ACCESS}"

set -x
exec /usr/bin/kvm ${FLAGS_REMOTE_ACCESS} \
  -k en-us -m ${RAM} -smp ${SMP} -cpu qemu64 -usb -usbdevice tablet -no-shutdown \
  -name ${HOSTNAME} \
  ${FLAGS_DISK_IMAGE} \
  ${FLAGS_ISO} \
  ${FLAGS_ISO2} \
  ${FLAGS_NETWORK}
