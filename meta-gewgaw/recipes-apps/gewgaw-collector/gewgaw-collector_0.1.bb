SUMMARY = "gewgaw onboard collector + opportunistic submit daemons"
DESCRIPTION = "Records nearby 2.4 GHz Wi-Fi APs and BLE devices into a local \
SQLite presence database (gewgaw-collector) and opportunistically uploads new \
observations to AWS IoT Core over known/open Wi-Fi (gewgaw-submit), including a \
first-connect boot beacon. See scan_and_submit_daemons_design.md. \
NOTE: the collector does real Wi-Fi + BLE scanning into the SQLite presence \
model (phase 2) and hosts the single-radio arbiter at GEWGAW_SOCK (phase 3); \
gewgaw-submit does the real steady-state upload (candidate selection, \
wpa_supplicant association, 204 connectivity check, batched publish via \
aws-iot-mqtt) (phase 4) and the boot beacon (record a boot event, get online \
with a larger budget, confirm NTP, flush events to .../status then sightings) \
(phase 5). Candidate APs are scored by a per-BSSID net_health blacklist with \
exponential-backoff cooldowns so the brief upload window isn't wasted on \
dead/captive hotspots (phase 6, §9)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://gewgaw-collector \
    file://gewgaw-submit \
    file://gewgaw.conf \
    file://networks.conf.sample \
    file://schema.sql \
    file://gewgaw-collector.service \
    file://gewgaw-submit.service \
    file://gewgaw-submit.timer \
    file://gewgaw-boot.service \
    file://80-gewgaw-wlan0.network \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_AUTO_ENABLE = "enable"
# The submit .service is triggered by its .timer and by gewgaw-boot.service, so
# it is installed but not enabled on its own.
SYSTEMD_SERVICE:${PN} = "gewgaw-collector.service gewgaw-submit.timer gewgaw-boot.service"

# python3 + sqlite3 for the daemons; iw/wpa-supplicant/bluez5/iproute2 for
# capture and the opportunistic uplink; aws-iot-mqtt for the actual publish.
RDEPENDS:${PN} = "python3-core python3-json python3-io python3-sqlite3 iw wpa-supplicant bluez5 iproute2 aws-iot-mqtt"

# Pure-data recipe — nothing to compile or configure.
do_compile[noexec] = "1"
do_configure[noexec] = "1"

FILES:${PN} = " \
    ${bindir}/gewgaw-collector \
    ${bindir}/gewgaw-submit \
    ${sysconfdir}/gewgaw/gewgaw.conf \
    ${sysconfdir}/gewgaw/networks.conf.sample \
    ${datadir}/gewgaw/schema.sql \
    ${sysconfdir}/systemd/network/80-gewgaw-wlan0.network \
    ${systemd_unitdir}/system/gewgaw-collector.service \
    ${systemd_unitdir}/system/gewgaw-submit.service \
    ${systemd_unitdir}/system/gewgaw-submit.timer \
    ${systemd_unitdir}/system/gewgaw-boot.service \
"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/gewgaw-collector ${D}${bindir}/gewgaw-collector
    install -m 0755 ${WORKDIR}/gewgaw-submit    ${D}${bindir}/gewgaw-submit

    install -d ${D}${sysconfdir}/gewgaw
    install -m 0644 ${WORKDIR}/gewgaw.conf           ${D}${sysconfdir}/gewgaw/gewgaw.conf
    install -m 0644 ${WORKDIR}/networks.conf.sample  ${D}${sysconfdir}/gewgaw/networks.conf.sample

    install -d ${D}${datadir}/gewgaw
    install -m 0644 ${WORKDIR}/schema.sql ${D}${datadir}/gewgaw/schema.sql

    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/80-gewgaw-wlan0.network \
        ${D}${sysconfdir}/systemd/network/80-gewgaw-wlan0.network

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/gewgaw-collector.service ${D}${systemd_unitdir}/system/gewgaw-collector.service
    install -m 0644 ${WORKDIR}/gewgaw-submit.service    ${D}${systemd_unitdir}/system/gewgaw-submit.service
    install -m 0644 ${WORKDIR}/gewgaw-submit.timer      ${D}${systemd_unitdir}/system/gewgaw-submit.timer
    install -m 0644 ${WORKDIR}/gewgaw-boot.service      ${D}${systemd_unitdir}/system/gewgaw-boot.service
}
