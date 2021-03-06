#!/bin/bash
set -x
set -e

export DIR="/root"

export REPORT_FILE="/root/report.txt"


set +e
umount /mnt/newimage/{proc,dev,sys,}
sleep 1
losetup -d /dev/loop1
losetup -d /dev/loop0
set -e



if [ "${1}_" == "clean_" ] ; then
  exit 0
fi



echo "usage: ./build_guest_node_image.sh 2>&1 | tee build.log"

if [ ! -e waggle_first_boot.sh  ] ; then
  echo "waggle_first_boot.sh not found. Execute script from script location."
  exit 1
fi

SCRIPT_DIR=`pwd`


hash partprobe &> /dev/null
if [ $? -eq 1 ]; then
    apt-get install -y parted
fi


ODROID_MODEL=$(head -n 1 /media/boot/boot.ini | cut -d '-' -f 1)
MODEL=""
if [ "${ODROID_MODEL}_"  == "ODROIDXU_" ] ; then
  echo "Detected device: ${ODROID_MODEL}"
  if [ -e /media/boot/exynos5422-odroidxu3.dtb ] ; then
    export MODEL="odroid-xu3"
  else
    export MODEL="odroid-xu"
    echo "Did not find the XU3/4-specific file /media/boot/exynos5422-odroidxu3.dtb."
    exit 1
  fi
elif [ "${ODROID_MODEL}_"  == "ODROIDC_" ] ; then
  echo "Detected device: ${ODROID_MODEL}"
  export MODEL="odroid-c1"
else
  echo "Could not detect ODROID model. (${ODROID_MODEL})"
  exit 1
fi


set -e
set -x

export DATE=`date +"%Y%m%d"` ; echo "DATE: ${DATE}"
export NEW_IMAGE_PREFIX="${DIR}/waggle-guestnode-${MODEL}-${DATE}" ; echo "NEW_IMAGE_PREFIX: ${NEW_IMAGE_PREFIX}"
export NEW_IMAGE="${NEW_IMAGE_PREFIX}.img" ; echo "NEW_IMAGE: ${NEW_IMAGE}"

export NEW_IMAGE_B="${NEW_IMAGE_PREFIX}_B.img" ; echo "NEW_IMAGE_B: ${NEW_IMAGE_B}"



cd ${DIR}

export IMAGE="ubuntu-14.04lts-server-odroid-xu3-20150725.img"
if [ ! -e ${IMAGE}.xz ] ; then
  wget http://www.mcs.anl.gov/research/projects/waggle/downloads/${IMAGE}.xz
fi


if [ ! -e ${IMAGE} ] ; then
  unxz --keep ${IMAGE}.xz
fi

rm -f ${NEW_IMAGE}

cp ${IMAGE} ${NEW_IMAGE}


# get partition start position
#fdisk -lu ${IMAGE}
export START_BLOCK=$(fdisk -lu ${NEW_IMAGE} | grep "${NEW_IMAGE}2" | awk '{print $2}') ; echo "START_BLOCK: ${START_BLOCK}"

export START_POS=$(echo "${START_BLOCK}*512" | bc) ; echo "START_POS: ${START_POS}"

# create loop device for disk and for root partition
losetup /dev/loop0 ${NEW_IMAGE}
losetup -o ${START_POS} /dev/loop1 /dev/loop0


export IMAGEDIR="/mnt/newimage/"

mkdir -p ${IMAGEDIR}
mount /dev/loop1 ${IMAGEDIR}
mount -o bind /proc ${IMAGEDIR}/proc
mount -o bind /dev ${IMAGEDIR}/dev
mount -o bind /sys ${IMAGEDIR}/sys



###                              ###
###  Script for chroot execution ###
###                              ###

cat <<EOF > ${IMAGEDIR}/root/build_gn_image.sh
#!/bin/bash
set -x
set -e

###locale
locale-gen "en_US.UTF-8"
dpkg-reconfigure locales

### timezone 
echo "Etc/UTC" > /etc/timezone 
dpkg-reconfigure --frontend noninteractive tzdata

apt-get update
#apt-get upgrade -y
apt-get --no-install-recommends install -y network-manager
apt-get autoclean
apt-get autoremove -y

apt-get install -y git

mkdir -p /usr/lib/waggle/
cd /usr/lib/waggle/
git clone --recursive https://github.com/waggle-sensor/guestnodes.git





### create report
echo "image created: " > ${REPORT_FILE}
date >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
uname -a >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
cat /etc/os-release >> ${REPORT_FILE}
dpkg -l >> ${REPORT_FILE}


### mark image for first boot 
touch /root/first_boot

ln -s /usr/lib/waggle/guestnodes/scripts/waggle_first_boot.sh /etc/init.d/waggle_first_boot.sh

#chown root:root /etc/init.d/waggle_first_boot.sh
update-rc.d waggle_first_boot.sh defaults

rm -f /etc/network/interfaces.d/*
rm -f /etc/udev/rules.d/70-persistent-net.rules 


EOF



chmod +x ${IMAGEDIR}/root/build_gn_image.sh

#
# CHROOT HERE
#

chroot ${IMAGEDIR} /bin/bash /root/build_gn_image.sh

# 
# After changeroot
#

rm -f ${REPORT_FILE}
cp ${IMAGEDIR}${REPORT_FILE} ${NEW_IMAGE}.report.txt



#set static IP
cat <<EOF >  ${IMAGEDIR}/etc/network/interfaces
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

auto lo eth0
iface lo inet loopback

iface eth0 inet static
      address 10.31.81.51
      netmask 255.255.255.0
      #gateway 10.31.81.10

EOF





export OLD_PARTITION_SIZE_KB=$(df -BK --output=size /dev/loop1 | tail -n 1 | grep -o "[0-9]\+") ; echo "OLD_PARTITION_SIZE_KB: ${OLD_PARTITION_SIZE_KB}"

umount /mnt/newimage/{proc,dev,sys,}



export ESTIMATED_FS_SIZE_BLOCKS=$(resize2fs -P /dev/loop1 | grep -o "[0-9]*") ; echo "ESTIMATED_FS_SIZE_BLOCKS: ${ESTIMATED_FS_SIZE_BLOCKS}"

export BLOCK_SIZE=`blockdev --getbsz /dev/loop1`; echo "BLOCK_SIZE: ${BLOCK_SIZE}"

export ESTIMATED_FS_SIZE_KB=$(echo "${ESTIMATED_FS_SIZE_BLOCKS}*${BLOCK_SIZE}/1024" | bc) ; echo "ESTIMATED_FS_SIZE_KB: ${ESTIMATED_FS_SIZE_KB}"



# add 500MB
export NEW_PARTITION_SIZE_KB=$(echo "${ESTIMATED_FS_SIZE_KB} + (1024)*500" | bc) ; echo "NEW_PARTITION_SIZE_KB: ${NEW_PARTITION_SIZE_KB}"

# add 100MB
export NEW_FS_SIZE_KB=$(echo "${ESTIMATED_FS_SIZE_KB} + (1024)*100" | bc) ; echo "NEW_FS_SIZE_KB: ${NEW_FS_SIZE_KB}"


# verify partition:
e2fsck -f -y /dev/loop1



export SECTOR_SIZE=`fdisk -lu ${NEW_IMAGE} | grep "Sector size" | grep -o ": [0-9]*" | grep -o "[0-9]*"` ; echo "SECTOR_SIZE: ${SECTOR_SIZE}"

export FRONT_SIZE_KB=`echo "${SECTOR_SIZE} * ${START_BLOCK} / 1024" | bc` ; echo "FRONT_SIZE_KB: ${FRONT_SIZE_KB}"


if [ "${NEW_PARTITION_SIZE_KB}" -lt "${OLD_PARTITION_SIZE_KB}" ] ; then 

  echo "NEW_PARTITION_SIZE_KB is smaller than OLD_PARTITION_SIZE_KB"

  # shrink filesystem (that does not shrink the partition!)
  resize2fs -p /dev/loop1 ${NEW_FS_SIZE_KB}K


  partprobe  /dev/loop1

  sleep 3

  ### fdisk (shrink partition)
  # fdisk: (d)elete partition 2 ; (c)reate new partiton 2 ; specify start posirion and size of new partiton
  set +e
  echo -e "d\n2\nn\np\n2\n${START_BLOCK}\n+${NEW_PARTITION_SIZE_KB}K\nw\n" | fdisk ${NEW_IMAGE}
  set -e


  partprobe /dev/loop1

  #set +e
  #resize2fs /dev/loop1
  #set -e

  # does not show the new size
  #fdisk -lu ${NEW_IMAGE}

  # shows the new size (-b for bytes)
  #partx --show /dev/loop1 (fails)

  sleep 3

  e2fsck -n -f /dev/loop1

  #e2fsck_ok=1
  #set +e
  #while [ ${e2fsck_ok} != "0" ] ; do
  #  e2fsck -f /dev/loop1
  #  e2fsck_ok=$?
  #  sleep 2
  #done
  #set -e

else
  echo "NEW_PARTITION_SIZE_KB is NOT smaller than OLD_PARTITION_SIZE_KB"
fi

losetup -d /dev/loop1
losetup -d /dev/loop0



# add size of boot partition
COMBINED_SIZE_KB=`echo "${NEW_PARTITION_SIZE_KB} + ${FRONT_SIZE_KB}" | bc` ; echo "COMBINED_SIZE_KB: ${COMBINED_SIZE_KB}"
COMBINED_SIZE_BYTES=`echo "(${NEW_PARTITION_SIZE_KB} + ${FRONT_SIZE_KB}) * 1024" | bc` ; echo "COMBINED_SIZE_KB: ${COMBINED_SIZE_KB}"

# from kb to mb
export BLOCKS_TO_WRITE=`echo "${COMBINED_SIZE_KB}/1024" | bc` ; echo "BLOCKS_TO_WRITE: ${BLOCKS_TO_WRITE}"



# does not work: count=${BLOCKS_TO_WRITE}
pv -per --width 80 --size ${COMBINED_SIZE_BYTES} -f ${NEW_IMAGE} | dd bs=1M iflag=fullblock count=${BLOCKS_TO_WRITE} | xz -1 --stdout - > ${NEW_IMAGE}.xz_part


mv ${NEW_IMAGE}.xz_part ${NEW_IMAGE}.xz




if [ -e ${DIR}/waggle-id_rsa ] ; then
  md5sum $(basename ${NEW_IMAGE}.xz) > ${NEW_IMAGE}.xz.md5sum 
  scp -o "StrictHostKeyChecking no" -v -i ${DIR}/waggle-id_rsa ${NEW_IMAGE}.xz ${NEW_IMAGE}.xz.md5sum waggle@terra.mcs.anl.gov:/mcs/www.mcs.anl.gov/research/projects/waggle/downloads/unstable
  
  if [ -e ${NEW_IMAGE_B}.xz ] ; then
    # upload second image with different UUID's
    md5sum $(basename ${NEW_IMAGE_B}.xz) > ${NEW_IMAGE_B}.xz.md5sum
    scp -o "StrictHostKeyChecking no" -v -i ${DIR}/waggle-id_rsa ${NEW_IMAGE_B}.xz ${NEW_IMAGE_B}.xz.md5sum waggle@terra.mcs.anl.gov:/mcs/www.mcs.anl.gov/research/projects/waggle/downloads/unstable
  fi
  
  
  if [ -e ${NEW_IMAGE}.report.txt ] ; then 
    scp -o "StrictHostKeyChecking no" -v -i ${DIR}/waggle-id_rsa ${NEW_IMAGE}.report.txt waggle@terra.mcs.anl.gov:/mcs/www.mcs.anl.gov/research/projects/waggle/downloads/unstable
  fi
  
  if [ -e ${NEW_IMAGE}.build_log.txt ] ; then 
    scp -o "StrictHostKeyChecking no" -v -i ${DIR}/waggle-id_rsa ${NEW_IMAGE}.build_log.txt waggle@terra.mcs.anl.gov:/mcs/www.mcs.anl.gov/research/projects/waggle/downloads/unstable
  fi
  
fi
