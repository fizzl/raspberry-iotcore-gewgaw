SUMMARY = "Minimal AWS IoT Core MQTT client with out-of-band cert provisioning"
DESCRIPTION = "Installs a mosquitto-based mutual-TLS helper (aws-iot-mqtt), the \
AWS IoT connection config, the public Amazon Root CA, and a first-boot oneshot \
that self-tests the connection. The device certificate and private key are NOT \
baked into the image; they are pushed to the running target out-of-band (see \
provision-device.sh) into /etc/aws-iot/certs."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://aws-iot.conf \
    file://aws-iot-mqtt \
    file://aws-iot-provision.service \
    file://AmazonRootCA1.pem \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} = "aws-iot-provision.service"

# mosquitto provides mosquitto_pub / mosquitto_sub (the -clients package).
RDEPENDS:${PN} = "mosquitto-clients"

do_compile[noexec] = "1"
do_configure[noexec] = "1"

FILES:${PN} = " \
    ${sysconfdir}/aws-iot/aws-iot.conf \
    ${sysconfdir}/aws-iot/AmazonRootCA1.pem \
    ${sysconfdir}/aws-iot/certs \
    ${bindir}/aws-iot-mqtt \
    ${systemd_unitdir}/system/aws-iot-provision.service \
"

# Config may carry no secrets, but lock the cert directory down regardless.
do_install() {
    install -d ${D}${sysconfdir}/aws-iot
    install -m 0644 ${WORKDIR}/aws-iot.conf       ${D}${sysconfdir}/aws-iot/aws-iot.conf
    install -m 0644 ${WORKDIR}/AmazonRootCA1.pem  ${D}${sysconfdir}/aws-iot/AmazonRootCA1.pem

    # Provisioning drop-zone for the device cert + key (populated on the device).
    install -d -m 0700 ${D}${sysconfdir}/aws-iot/certs

    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/aws-iot-mqtt ${D}${bindir}/aws-iot-mqtt

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/aws-iot-provision.service \
        ${D}${systemd_unitdir}/system/aws-iot-provision.service
}
