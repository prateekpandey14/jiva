#!/bin/bash

# Get Docker image for Jiva
JI=$(sudo docker images | grep openebs/jiva | awk '{print $1":"$2}')
echo "Run CI tests on $JI"

# Prepare environment to run Jiva containers
mkdir /tmp/vol1
mkdir /tmp/vol2
sudo docker network create --subnet=172.18.0.0/16 stg-net

# Start Jiva controller and replicas in detached mode
sudo docker run -d --net stg-net --ip 172.18.0.2 -P --expose 3260 --expose 9501 --expose 9502-9504 $JI launch controller --frontend gotgt --frontendIP 172.18.0.2 store1
sudo docker run -d -it --net stg-net --ip 172.18.0.3 -P --expose 9502-9504 -v /tmp/vol1:/vol1 $JI launch replica --frontendIP 172.18.0.2 --listen 172.18.0.3:9502 --size 2g /vol1
sudo docker run -d -it --net stg-net --ip 172.18.0.4 -P --expose 9502-9504 -v /tmp/vol2:/vol2 $JI launch replica --frontendIP 172.18.0.2 --listen 172.18.0.4:9502 --size 2g /vol2

# Display running containers
sudo docker ps 

# Create a local mountpoint
sudo mkdir -p /mnt/store

# Cleanup existing iSCSI sessions
sudo iscsiadm -m node -u
sudo iscsiadm -m node -o delete

# Discover Jiva iSCSI target and Login 
sudo iscsiadm -m discovery -t st -p 172.18.0.2:3260
sudo iscsiadm -m node -l

# Wait for iSCSI device node (scsi device) to be created 
sleep 1
sudo fdisk -l
x=$(iscsiadm -m session -P 3 |grep -i "Attached scsi disk" | awk '{print $4}')
echo $x

i=0
while x==""; do
        sleep 4
        x=$(iscsiadm -m session -P 3 |grep -i "Attached scsi disk" | awk '{print $4}')
        i=i+1
        if i==5; then
                break
        else
                continue
        fi
done

# Start tests once (i)SCSI device is detected
if [ "$x"!="" ]; then
        # Format disk as ext2 FS
        sudo mkfs.ext2 -F /dev/$x

        # Mount FS onto local mountpoint
        sudo mount /dev/$x /mnt/store

        # TEST#1: Perform simple data-integrity check on Jiva Vol
        sudo dd if=/dev/urandom of=file1 bs=4k count=10000
        hash1=$(sudo md5sum file1 | awk '{print $1}')
        sudo cp file1 /mnt/store
        hash2=$(sudo md5sum /mnt/store/file1 | awk '{print $1}')
        if [ $hash1 == $hash2 ]; then echo "DI Test: PASSED"
        else 
            echo "DI Test: FAILED"; exit 1
        fi

        # TEST#2: Perform a random I/O workload test on Jiva Vol
        sudo mkdir -p /mnt/store/data
        sudo chown 777 /mnt/store/data
        sudo docker run -v /mnt/store/data:/datadir1 openebs/tests-vdbench:latest
        if [ $? -eq 0 ]; then echo "VDbench Test: PASSED"
        else
            echo "VDbench Test: FAILED";exit 1
        fi

        # TEST#3: Run the libiscsi compliance suite on Jiva Vol
        sudo mkdir /mnt/logs 
        sudo docker run -v /mnt/logs:/mnt/logs --net host openebs/tests-libiscsi /bin/bash -c "./testiscsi.sh --ctrl-svc-ip 172.18.0.2"
        tp=$(grep "PASSED" $(find /mnt/logs -name SUMMARY.log) | wc -l)
        tf=$(grep "FAILED" $(find /mnt/logs -name SUMMARY.log) | wc -l)
        if [ $tp -ge 146 ] && [ $tf -le 29 ]; then
            echo "iSCSI Compliance test: PASSED"
        else 
            echo "iSCSI Compliance test: FAILED"; exit 1
        fi
else 
        echo "Unable to detect iSCSI device, login failed"; exit 1
fi 

