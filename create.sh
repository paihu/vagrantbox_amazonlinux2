#!/bin/bash

VM=amznlinux2
# 仮想マシンがすでにあった場合は削除
(VBoxManage list vms | grep "\"${VM}\"")
if [ $? == 0 ]; then
  VBoxManage controlvm ${VM} poweroff
  sleep 1;
  VBoxManage unregistervm ${VM} --delete
fi

# latest指定して帰ってきたのが最新のURL
URL=$(curl -kL https://cdn.amazonlinux.com/os-images/latest/ -I | grep location | cut -d":" -f 2,3 | tr '\n\r' ' ' | xargs )

# Virtualbox用は末尾にvirtualbox/つける。 href="hoge.vdi"なのでそれを探す
FILE=$(curl -kL ${URL}virtualbox/ | grep vdi | cut -d"=" -f 2 | cut -d'"' -f 2)

# SHASUMをダウンロード
curl -kLO ${URL}virtualbox/SHA256SUMS

if [ -f "${FILE}" ]; then
  diff SHA256SUMS <(shasum -a 256 ${FILE})
  if [ $? != 0 ]; then
    rm ${FILE}
  fi
fi

if [ ! -f "${FILE}" ]; then
  curl -kLO ${URL}virtualbox/${FILE}
fi
diff SHA256SUMS <(shasum -a 256 ${FILE})
if [ ! $? == 0 ];then
  echo "error: image file mismatch" >/dev/stderr
  exit 1
fi

# seed.isoの作成
if [ ! -f "seed.iso" ];then

echo "local-hostname: amznlinux2" > meta-data

cat <<__EOT__ > user-data
#cloud-config
users:
  - name: vagrant
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    ssh_pwauth: True
    ssh_authorized_keys:
      - `ssh-keygen -y -f ~/.vagrant.d/insecure_private_key`
chpasswd:
  list: |
    root: vagrant
    vagrant: vagrant
  expire: False
__EOT__

docker run --rm -itv $(pwd):/data debian sh -c 'apt-get update && apt-get install -y genisoimage && cd /data && pwd && ls &&  genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data'
fi

# VirtualBox Guest Addion の入手
VBOXVER=$(VBoxManage --version | cut -d'r' -f 1)
if [ ! -f VBoxGuestAdditions_${VBOXVER}.iso ]; then
  curl -kLO "https://download.virtualbox.org/virtualbox/${VBOXVER}/VBoxGuestAdditions_${VBOXVER}.iso"
fi
# VM の作成

# 仮想マシンを作成
VBoxManage createvm --name "$VM" --ostype "RedHat_64" --register
# 仮想ストレージアレイを追加
VBoxManage storagectl "$VM" --name "SATA Controller" --add "sata" --controller "IntelAHCI"
# 仮想ディスクとISOをアタッチ
VBoxManage storageattach "$VM" --storagectl "SATA Controller" \
  --port 0 --device 0 --type hdd --medium ${FILE}
VBoxManage storageattach "$VM" --storagectl "SATA Controller" \
  --port 1 --device 0 --type dvddrive --medium seed.iso
# ポートフォワードとメモリを調整
VBoxManage modifyvm "$VM" --natpf1 "ssh,tcp,127.0.0.1,2222,,22" --memory 1024 --vram 8
# オーディオの無効化
VBoxManage modifyvm "$VM" --audio none
# 仮想マシンを起動
VBoxManage startvm "$VM" --type headless
sleep 10;

# VirtualBox Additions Install

function ssh_command() {
 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 -l vagrant 127.0.0.1 -i ~/.vagrant.d/insecure_private_key $*
}

ssh_command sudo eject
VBoxManage storageattach "$VM" --storagectl "SATA Controller" \
  --port 1 --device 0 --type dvddrive --medium VBoxGuestAdditions_${VBOXVER}.iso
ssh_command sudo ln -s /etc/system-release /etc/redhat-release
ssh_command sudo yum -y install perl gcc kernel-devel-\`uname -r\`
ssh_command sudo mount -r /dev/cdrom /mnt
ssh_command sudo /mnt/VBoxLinuxAdditions.run --nox11
ssh_command sudo umount /mnt
ssh_command sudo eject
VBoxManage storageattach "$VM" --storagectl "SATA Controller" \
  --port 1 --device 0 --type dvddrive --medium none
ssh_command sudo rm -rf /var/cache/yum
ssh_command sudo dd if=/dev/zero of=/EMPTY bs=1M
ssh_command sudo rm -f /EMPTY


# package.box作成
if [ -f package.box ];then
  rm package.box
fi
vagrant package --base ${VM}
vagrant box add --name amazonlinux2 package.box
