
### Desired test-bed:
1. QEMU-RISCV64 
2. Linux Kernel (MUSL-Compilled)
3. Busybox for userspace (MUSL-Compilled)

### So how do we get there

For context I am on an x86 Arch Linux installation. 

#### Attempt 1

Attempt 1 architecture 
QEMU-RISCV64 -> OpenSBI(First Stage Bootloader) -> U-Boot -> Linux Kernel -> Busybox & Filesystem

My initial approach was following the bootlin guide which consisted of:
1. Compilling buildroot cross compiling toolchain with MUSL C Library on the HOST system
2. relocating buildroot directories in the system and reconfiguring symlinks
3. Adding this to bashrc, path and including it in the host system entirely
4. Compiling u-boot from source with the cross compiler
5. Compiling OpenSBI from source with the u-boot payload using the Cross-Compiler
6. ... 

After step 5 this attempt ended due to an error in qemu running the custom u-boot/opensbi bios due to overlapping memory segments

### Attempt 1.5

Initially I thought this might be due to the MUSL compilation, or the fact that the guide I was following was over 5 years old, so I repeated this with a compilled GNU-RISCV64-MUSL compiler and a GNU-RISCV64-GCC Compiler, same issue. 

(Time spend 10+ HRS)

Then at some point I discovered 2 things, the overlapping memory segments is a current open issue in the qemu and opensbi git forums (Gitlab and Github respectively). I found a patch for it which involved manually patching my install on qemu, then recompiling opensbi and specifying a memory entrypoint {FW_TEXT_START} (instead of just downgrading versions or similar because it has 1000 dependencies, and related qemu-* packages). And that there are some silently failing errors in my build toolchain, only visible verbosely compiling or examining logs.

I did this and received the same issues, specifying qemu memory start location and sbi, to no avail.

(Time spend 15+ HRS)

### Attempt 2

At this point I did some more research, and wanted to find a cross compiling toolchain I could build statically, so that paths and host system mattered less, and I wanted to find an alternative to building my own OpenSBI & U-Boot, I found that I can run qemu with a linux kernel with no bios (Great) - this just boots a flavor of openSBI called qemu-openSBI, I also found a MUSL cross compiling toolchain that was statically built (Great).

I used this static CC toolchain to build the linux kernel successfully (again, great). 
Now it was time to build busybox, however busybox for risc-v statically compiled required some linux headers which I was unable to point it to the pathing for (again pathing issues).

So now I made the discovery, alpine linux is a low RISC-V compatible linux distribution which natively uses the MUSL library, no need for a seperate toolchain, great, but how do I use this? 

Docker. 

After many iterations this is the final Dockerfile for cross compiling busybox. 

```dockerfile
# Stage 1: Build BusyBox for RISC-V
FROM --platform=linux/riscv64 alpine:latest AS builder

# Install build tools (no cache)
RUN echo "Build date: $(date)" > /dev/null && \
    apk update && \
    apk add --no-cache \
    build-base \
    linux-headers \
    wget \
    cpio \
    gzip

WORKDIR /usr/src

# Download and extract BusyBox
ARG BUSYBOX_VERSION=1.36.1
RUN wget https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2 && \
    tar -xvf busybox-${BUSYBOX_VERSION}.tar.bz2

WORKDIR /usr/src/busybox-${BUSYBOX_VERSION}

# Configure and build with static linking
RUN make defconfig && \
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config && \
    make -j$(nproc) && \
    make install CONFIG_PREFIX=/busybox-install

# Stage 2: Create initramfs
FROM --platform=linux/riscv64 alpine:latest AS initramfs
WORKDIR /initramfs_staging

# 1. First copy the BusyBox binary
COPY --from=builder /busybox-install/bin/busybox bin/busybox

# 2. Create directory structure
RUN mkdir -p dev etc proc sys tmp usr/bin usr/sbin sbin

# 3. Create device placeholders (real devices will be created at boot)
RUN touch dev/console dev/null && \
    chmod 660 dev/console dev/null

# 4. Install BusyBox symlinks
RUN bin/busybox --install -s ./bin && \
    ln -s /bin/busybox /usr/bin/busybox && \
    ln -s /bin/busybox /sbin/busybox

# 5. Create init script
RUN echo '#!/bin/busybox sh' > init && \
    echo 'mount -t proc proc /proc' >> init && \
    echo 'mount -t sysfs sysfs /sys' >> init && \
    echo 'mount -t devtmpfs devtmpfs /dev' >> init && \
    echo 'echo "Initramfs booted successfully!"' >> init && \
    echo "setsid sh -c 'exec sh </dev/tty1 >/dev/tty1 2>&1'" >> init && \
    chmod +x init

# 6. Verification step
RUN ls -l bin/busybox && \
    /initramfs_staging/bin/busybox --list | head -5

# 7. Create final cpio archive
RUN find . -print0 | cpio --null -ov --format=newc | gzip > /initramfs.cpio.gz

# Final stage (optional)
FROM scratch
COPY --from=initramfs /initramfs.cpio.gz /
```

There are a couple of unexpected things though, due to safety permissions I had trouble creating the /dev/console and /dev/null special files with the desired permission (600), and no matter what I changed in the dockerfile i could not get busybox install to generate the correctly pathed symlinks in /bin/. No matter what the symlinks always we're prefixed with my root working directory in Docker (initramfs_staging).

After many iterations and rebuilds of initramfs I decided to forget about busybox install and unpack the initramfs.cpio.gz and recursively update the symlinks in the /bin/ with a shell script. 
```Bash
#!/bin/bash

# Define the old and new target paths
old_target="/initramfs_staging/bin/busybox"
new_target="/bin/busybox"  

# Find all symbolic links within the current directory (extracted initramfs)
find . -type l -print0 | while IFS= read -r -d $'\0' link_path; do
  # Get the target of the current symlink
  target=$(readlink "$link_path")

  # Check if the target matches the old target
  if [[ "$target" == "$old_target" ]]; then
    echo "Updating symlink: '$link_path' -> '$new_target'"
    # Create the new symlink
    rm "$link_path"  # Remove the old symlink
    ln -s "$new_target" "$link_path"
  fi
done

echo "Symlink update process completed."
```

Now that this was working I ran into my next problem while booting the qemu virtual machine, we boot successfully, however I keep receiving this error: sh: can't access tty; job control turned off", every standard method of assigning a tty was not working. After consulting documentation I learned that it was because the shell we are using to run the init is not the session leader. The reason is somewhat obscure: kernel starts process with PID=1 (in this case, shell) with SID=0 and PGID=0, not with SID=1 and PGID=1. After updating the init script to assume control of the session now we can assign a tty session. 

Great, everythings working... except nftables and iptables which is the whole point... 

At this point I learned that I need to enable configs in my make menuconfig when im building the kernel for netfilter, and I need to build kernel modules as well....

Back to step 1, now we re cross compile the kernel, build kernel modules. 

ok we've done that, now its time to built the userspact utilities for nftables and iptables. After what seemed like hundreds of iterations I landed on this final config, disabling some features like clusterip. 

```Dockerfile
FROM --platform=linux/riscv64 alpine:latest AS builder

# Install build tools
RUN echo "Build date: $(date)" > /dev/null && \
    apk update && \
    apk add --no-cache \
    build-base \
    linux-headers \
    wget \
    cpio \
    gzip \
    gmp-dev \
    libcap-ng-dev \
    pkgconf \
    readline-dev \
    libedit-dev \
    musl-dev 

ENV CFLAGS="-march=rv64gc -mabi=lp64d -Os"
ENV CXXFLAGS="${CFLAGS}"
ENV PREFIX=/usr




WORKDIR /build

RUN mkdir -p /output/install

# --- Build libmnl (Minimalistic Netlink library) ---
WORKDIR /build/libmnl
RUN wget https://www.netfilter.org/projects/libmnl/files/libmnl-1.0.5.tar.bz2 \
    && tar -xjvf libmnl-1.0.5.tar.bz2 \
    && cd libmnl-1.0.5 \
    && ./configure --prefix=${PREFIX} --enable-static --disable-shared \
    && make -j$(nproc) \
    && make install DESTDIR=/output/install \
    && rm -f /output/install/${PREFIX}/lib/*.la


# --- Build libnftnl (Netfilter Netlink library) ---
WORKDIR /build/libnftnl
ENV LDFLAGS="-L/output/install/${PREFIX}/lib"
ENV CPPFLAGS="-I/output/install/${PREFIX}/include"
ENV LIBMNL_CFLAGS="-I/output/install/${PREFIX}/include"
ENV LIBMNL_LIBS="-L/output/install/${PREFIX}/lib -lmnl"
ENV PKG_CONFIG_PATH="/output/install/${PREFIX}/lib/pkgconfig"

RUN wget https://www.netfilter.org/projects/libnftnl/files/libnftnl-1.2.9.tar.xz \
    && tar -xJvf libnftnl-1.2.9.tar.xz \
    && find /output/install -name libmnl.pc \
    && cd libnftnl-1.2.9 \
    && ./configure --prefix=${PREFIX} --enable-static --disable-shared \
    && make -j$(nproc) \
    && make install DESTDIR=/output/install



# --- Build iptables (xtables) ---
WORKDIR /build/iptables
ENV LDFLAGS="-L/output/install/${PREFIX}/lib"
ENV CPPFLAGS="-I/output/install/${PREFIX}/include"
RUN wget https://www.netfilter.org/projects/iptables/files/iptables-1.8.11.tar.xz \
    && tar -xJvf iptables-1.8.11.tar.xz \
    && cd iptables-1.8.11 \
    && sed -i '/linux\/if_ether.h/d' extensions/libxt_mac.c \
    && rm -f extensions/libipt_CLUSTERIP.c \
    && rm -f extensions/libipt_CLUSTERIP.h \
    && sed -i '/linux\/if_ether.h/d' extensions/libipt_realm.c \
    && ./configure --prefix=${PREFIX} --enable-static --disable-shared --disable-clusterip \
    && make -j$(nproc) \
    && make install DESTDIR=/output/install

# --- Build nftables (nft utility) ---
WORKDIR /build/nftables
ENV LDFLAGS="-L/output/install/${PREFIX}/lib -L/usr/lib"
ENV CPPFLAGS="-I/output/install/${PREFIX}/include -I/usr/include"
RUN wget https://netfilter.org/projects/nftables/files/nftables-1.1.3.tar.xz \
    && tar -xJvf nftables-1.1.3.tar.xz \
    && cd nftables-1.1.3 \
    && ./configure --prefix=${PREFIX} --enable-static --disable-shared \
    && make -j$(nproc) \
    && make install DESTDIR=/output/install
    
# Add this after your nftables build, still in the builder stage
WORKDIR /output
RUN mkdir -p /output/lib && \
    cp /lib/ld-musl-riscv64.so.1 /output/lib/ && \
    cp /lib/libc.musl-riscv64.so.1 /output/lib/ && \
    # Create a tarball with everything you need
    tar -czf /output/riscv-netfilter.tar.gz \
        -C /output/install . \
        -C /output lib/

# Optional: Create a minimal stage to extract just what you need
FROM scratch AS export
COPY --from=builder /output/riscv-netfilter.tar.gz /
COPY --from=builder /output/install /install
COPY --from=builder /lib/ld-musl-riscv64.so.1 /lib/
COPY --from=builder /lib/libc.musl-riscv64.so.1 /lib/
COPY --from=builder /usr/lib/libedit.so.0 /export/
COPY --from=builder /usr/lib/libgmp.so.10 /export/
COPY --from=builder /usr/lib/libncursesw.so.6 /export/
```

After unpacking and repacking my initramfs.cpio.gz hundreds of times with 
```Bash
 find . -print0 | cpio --null -ov --format=newc | gzip > ../initramfs.cpio.gz
```

I learned that the statically build binaries were not completely static, file {name} shows a dynamic file, and LDD {name} shows a statically built binary. Trial and error lead me to including 4 shared objects which got the full stack working. 

this is the run script 
```Bash
sudo qemu-system-riscv64 \
                                          -machine virt \
                                          -nographic \
                                          -kernel Image \
                                          -initrd initramfs-v32.cpio.gz \
                                          -append "rdinit=/init ip=dhcp" \
                                          -m 512M \
                                          -device virtio-net-device,netdev=net0,mac=52:54:00:12:34:56 \
                                          -netdev user,id=net0,hostfwd=tcp::8090-:8090 \
                                          -drive file=config-storage.img,format=raw,if=none,id=disk0 \
                                          -device virtio-blk-device,drive=disk0,bootindex=1
```


Instead of -netdev user, use:
-netdev bridge,id=net0,br=virbr0

Here are the docker build and copy out commands: 
``` Bash
sudo docker buildx build --platform=linux/riscv64 --no-cache --progress=plain -t busybox-riscv-initramfs . --load && sudo docker create --platform=linux/riscv64 --name temp_initramfs busybox-riscv-initramfs --target builder && sudo docker cp temp_initramfs:/app/initramfs.cpio.gz ./initramfs.cpio.g && sudo docker rm temp_initramfs

```
























