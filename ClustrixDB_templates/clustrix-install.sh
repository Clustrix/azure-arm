#!/bin/bash

# The MIT License (MIT)
#
# Copyright (c) 2015 Microsoft Azure
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

#debug
set -x

# Script parameters and their defaults
VERSION="latest"
CLUSTER_NAME="clx-cluster"
IS_LAST_NODE=0
NUM_NODES=1
IP_PREFIX="10.0.0.0"
CLUSTER='false'
CLX_LICENSE=''
SQLPASS='clustrix'
LOGGING_KEY="c75b83f3-fa3a-4e35-8945-e2b19d15bae9"
IP_LIST="" 
# clustrix mount path 
data_path='/mnt/resource'
log_path='/mnt/resource/log'



########################################################
# This script will install clusrixDB
########################################################
help()
{
    echo "This script installs ClustrixDB on a Centos virtual machine image"
    echo "Available parameters:"
    echo "-n Cluster name"
    echo "-v ClustrixDB version"
    echo "-c Number of instances"
    echo "-p Private IP address prefix"
    echo "-f form a cluster after install"
    echo "-k ClustrixDB license key"
    echo "-s SQL root user password"
    echo "-l (Indicator of the last node)"
    echo "-h Help"
}
log()
{
    # If you want to enable this logging, uncomment the line below and specify your logging key 
    curl -X POST -H "content-type:text/plain" --data-binary "$(date) | ${HOSTNAME} | $1" https://logs-01.loggly.com/inputs/${LOGGING_KEY}/tag/clx-install,${HOSTNAME}
    echo "$1"
}

log "Begin execution of clustrix installation script extension on ${HOSTNAME}"

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi


# Parse script parameters
while getopts :n:v:c:i:p:f:k:s:lh optname; do
  log "Option $optname set with value ${OPTARG}"
  
  case $optname in
    n)  # Cluster name
        CLUSTER_NAME=${OPTARG}
        ;;
    v)  # Version to be installed
        VERSION=${OPTARG}
        ;;
    c) # Number of instances
        NUM_NODES=${OPTARG}
        ;;                    
    p) # Private IP address prefix
        IP_PREFIX=${OPTARG}
        ;;
    f) # form new cluster 
        CLUSTER=${OPTARG}
        ;;  
    k) # CLX license key
        CLX_LICENSE=${OPTARG}
        ;;
    s) # SQL root password
        SQLPASS=${OPTARG}
        ;;  
    l)  # Indicator of the last node
        IS_LAST_NODE=1
        ;;      
    h)  # Helpful hints
        help
        exit 2
        ;;
    \?) #unrecognized option - show help
        echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
        help
        exit 2
        ;;
  esac
done

setup_storage()
{   
    #data disks 
    # find un-configured storage device(s) to setup the data volume:
    log "data path is: $data_path."
    log "log path is: $log_path"
    umount $data_path
    device='/dev/sdb'

    # Clustrix log partition size: either 15% of total space or 50GB whichever is smaller
    totsize=$((`blockdev --getsize64 $device`))
    totsize=$(($totsize/1024/1024/1024))
    logsize1="$(echo "scale=4; $totsize*0.15" | bc)"
    logsize1=${logsize1%.*}
    logsize=$(($logsize1<50?$logsize1:50))
    dataSize=$(($totsize-$logsize))

    mkdir -p $data_path
    log "Starting storage setup, single disk: $device"
    device=$(echo $device | tr -d ' ') 
    (echo o; echo n; echo p; echo 1; echo ; echo +"$dataSize"G; echo n; echo p; echo 2; echo; echo; echo w) | fdisk -c -u $device
    mkfs -t ext4 $device"1"
    e2label $device"1" CLUSTRIX-DATA
    echo "LABEL=CLUSTRIX-DATA   $data_path  ext4    defaults,noatime,nodiratime 0 2" >> /etc/fstab
    mount -L CLUSTRIX-DATA $data_path
    mkfs -t ext4 $device"2"
    e2label $device"2" CLUSTRIX-LOG
    mkdir -p $log_path
    echo "LABEL=CLUSTRIX-LOG    $log_path   ext4    defaults,noatime,nodiratime 0 2" >> /etc/fstab
    mount -L CLUSTRIX-LOG $log_path
    log "Storage setup successful"

    # Create symlink from /data/clustrix to /mnt/resource  
    mkdir /data
    cd /data
    ln -s $data_path clustrix
} 

tweek_os() 
{
    #update OS 
    yum -y install yum-plugin-security
    yum -y update-minimal --security

    #install utils
    yum -y install wget screen telnet

    #turn off iptables 
    chkconfig iptables off
    /etc/init.d/iptables stop
}

install_clx()
{
    log "installing CLXnode" 

    # install specified version of clxdb (unattended) 
    if [[ $VERSION = 'latest' ]]; 
    then
        export CLXSRC="http://files.clustrix.com/releases"
        export SRCVERSION=`curl -s $CLXSRC/LATEST`
    else
        export CLXSRC="http://files.clustrix.com/releases/software"
        export SRCVERSION="clustrix-$VERSION"
    fi

    curl $CLXSRC/$SRCVERSION.tar.bz2 -s | tar xvj 
    cd $SRCVERSION; ./clxnode_install.py --data-path=$data_path --log-path=$log_path  --ui-log-path=$log_path/clustrix_ui --yes

    # Post install steps 
    export PATH=$PATH:/opt/clustrix/bin
    echo 'export PATH=$PATH:/opt/clustrix/bin' >> ~clustrix/.bash_profile
    echo 'export PATH=$PATH:/opt/clustrix/bin' >> ~root/.bash_profile

    log "setup script completed successfully on ${HOSTNAME}."
}
 
setup_cluster() 
{
    log "starting cluster setup on ${HOSTNAME}" 
    CLX_LICENSE=$(echo $CLX_LICENSE | base64 -d)
    mysql -e "SET PASSWORD FOR 'root'@'%' = PASSWORD(\"$SQLPASS\")"
    mysql -e "set global license = '$CLX_LICENSE'"
    mysql -e "INSERT INTO clustrix_ui.clustrix_ui_systemproperty (name) VALUES (\"install_wizard_completed\")"
    mysql -e "set global cluster_name = \"$CLUSTER_NAME\""
 
	get_seq_ips $IP_PREFIX $NUM_NODES
	mysql -e "alter cluster add $IP_LIST COORDINATE"
    log "Completed cluster setup on ${HOSTNAME}"    
}

get_seq_ips()
{
    start="$1"
    num=$2

    octet1=$(echo $start | awk -F'.' '{print $1}')
    octet2=$(echo $start | awk -F'.' '{print $2}')
    octet3=$(echo $start | awk -F'.' '{print $3}')
    octet4=$(echo $start | awk -F'.' '{print $4}')

    IP_LIST="'$start'"
    for ((i=1; i<$num; i++ )); do
        let newOctet4="($octet4+$i) % 255"
        let newOctet3="$octet3+(($octet4+$i)/255)"
        IP_LIST="$IP_LIST, '$octet1.$octet2.$newOctet3.$newOctet4'"
    done
}

logfile=/var/log/install.$$.log
exec > $logfile 2>&1
whoami
setup_storage 
tweek_os
install_clx
if [ "$IS_LAST_NODE" -eq 1 ] && [ "$CLUSTER" = true ]; then
    log "starting cluster setup"
    setup_cluster
fi
log "All Done !"
