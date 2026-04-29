SUMMARY = "First-boot root partition and filesystem resize to fill SD card"
DESCRIPTION = "Installs a systemd oneshot service that runs once on first boot \
to extend the root partition (mmcblk0p2) to fill remaining SD card space and \
then online-resizes the ext4 filesystem to match. A stamp file prevents the \
service from running again on subsequent boots."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://grow-rootfs.sh \
    file://grow-rootfs.service \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} = "grow-rootfs.service"

# util-linux provides sfdisk and partx; e2fsprogs-resize2fs provides resize2fs.
RDEPENDS:${PN} = "util-linux e2fsprogs-resize2fs"

do_compile[noexec] = "1"
do_configure[noexec] = "1"

FILES:${PN} = " \
    ${sbindir}/grow-rootfs.sh \
    ${systemd_unitdir}/system/grow-rootfs.service \
"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/grow-rootfs.sh ${D}${sbindir}/grow-rootfs.sh

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/grow-rootfs.service \
        ${D}${systemd_unitdir}/system/grow-rootfs.service
}
