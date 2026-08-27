ARG BASE_VERSION
ARG TARGETARCH

FROM homeassistant/${TARGETARCH}-addon-silabs-multiprotocol:${BASE_VERSION} AS base-amd64
FROM homeassistant/aarch64-addon-silabs-multiprotocol:${BASE_VERSION} AS base-arm64
FROM base-${TARGETARCH} AS final
#FROM homeassistant/${TARGETARCH}-addon-silabs-multiprotocol:${BASE_VERSION}

ENV S6_VERBOSITY=3 \
    DEVICE="/dev/ttyUSB0" \
    BAUDRATE="460800" \
    CPCD_TRACE="false" \
    CPCP_DISABLE_ENCRYPTION="true" \
    FLOW_CONTROL="true" \
    NETWORK_DEVICES=0 \
    OTBR_ENABLE=1 \
    BACKBONE_IF="eth0" \
    OTBR_LOG_LEVEL="notice" \
    OTB_FIREWALL=1 \
    OTBR_REST_LISTEN_PORT="8081" \
    OTBR_WEB_PORT="8086" \
    NETWORK_DEVICE="" \
    EZSP_LISTEN_PORT="20108"\
    AUTOFLASH_FIRMWARE=0 \
    FIRMWARE=""

RUN rm -rf /etc/s6-overlay/s6-rc.d/banner && \
    rm -rf /etc/s6-overlay/scripts/banner.sh && \
    rm -rf /etc/s6-overlay/s6-rc.d/universal-silabs-flasher/dependencies.d && \
    rm -rf /etc/s6-overlay/s6-rc.d/otbr-agent-rest-discovery && \
    rm -rf /etc/s6-overlay/scripts/otbr-agent-rest-discovery.sh && \
    rm -rf /etc/s6-overlay/s6-rc.d/user/contents.d/otbr-agent-rest-discovery && \
    rm -rf /etc/s6-overlay/s6-rc.d/cpcd-config && \
    rm -rf /etc/s6-overlay/s6-rc.d/cpcd/dependencies.d && \
    rm -rf /usr/bin/bashio && \
    rm -rf *.gbl && \
    rm -rf firmware && \
    rm -rf /home/firmware && \
    rm -rf /root/*.gbl

COPY rootfs /

WORKDIR /

VOLUME /data

ENTRYPOINT ["/init"]
