echo "--------------------- Bootstrap Started -------------------- 1/3"
echo "----Setting up local devices for tap network on the host --- 2/3"
sudo ip tuntap add dev tap0 mode tap user $(whoami)
sudo ip link set tap0 up
sudo ip addr add 192.168.100.1/24 dev tap0
echo "--------------Host Setup Complete, Running Qemu ------------ 3/3"
sudo qemu-system-riscv64 \
                                        -machine virt \
                                        -nographic \
                                    	-smp 2 \
                                        -kernel Image \
                                        -initrd initramfs-v43.cpio.gz \
                                        -append "rdinit=/init" \
                                        -m 128M \
                                        -device virtio-net-device,netdev=net0,mac=52:54:00:12:34:56 \
                                        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
                                        -drive file=config-storage.img,format=raw,if=none,id=disk0 \
                                        -device virtio-blk-device,drive=disk0,bootindex=1
