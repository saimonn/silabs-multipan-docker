# syntax=docker/dockerfile:1
#
# From-scratch Silicon Labs multi-PAN daemon image (cpcd + zigbeed + ot-br-posix).
#
# No dependency on the deprecated Home Assistant "silabs-multiprotocol" addon
# base image. Everything is compiled from source in this Dockerfile.
#
# The image is built NATIVELY for each target architecture:
#   * x86_64  -> podman build -t multipan .
#   * aarch64 -> built in the GitHub Actions workflow (buildx + QEMU, the
#                heavy stages run natively per-architecture; only the SLC
#                project generation runs once on the amd64 build platform).
#
# Software (a fully compatible set for a CPC protocol v5 multiprotocol dongle):
#   * cpcd        v4.9.1        (CPC protocol 6, built with encryption disabled)
#   * zigbeed     Gecko SDK v4.4.6
#   * ot-br-posix Gecko SDK v4.4.6 (Silicon Labs fork of openthread 4.4)
#
ARG BUILD_FROM=debian:bookworm
ARG CPCD_VERSION=v4.9.1
ARG GECKO_SDK_VERSION=v4.4.6

# -----------------------------------------------------------------------------
# Stage 1: cpcd - Co-Processor Communication Daemon
# -----------------------------------------------------------------------------
FROM ${BUILD_FROM} AS cpcd-builder

ARG CPCD_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libmbedtls-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Encryption is disabled: the v4.9.1 daemon then speaks CPC protocol v5 with
# the RCP on the dongle. bindings/encryption are not needed for a local UART.
RUN git clone --depth 1 --branch "${CPCD_VERSION}" \
        https://github.com/SiliconLabs/cpc-daemon.git /usr/src/cpc-daemon \
    && cmake -S /usr/src/cpc-daemon -B /usr/src/cpc-daemon/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_ENCRYPTION=FALSE \
    && cmake --build /usr/src/cpc-daemon/build --parallel "$(nproc)" \
    && cmake --install /usr/src/cpc-daemon/build

# -----------------------------------------------------------------------------
# Stage 2a: zigbeed project generation (SLC, build platform only)
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${BUILD_FROM} AS zigbeed-slc

ARG GECKO_SDK_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        patch \
        python3 \
        python3-jinja2 \
        python3-pip \
        unzip \
        wget \
    && rm -rf /var/lib/apt/lists/*

# SLC CLI requires Java >= 21 (class file 65.0), which debian:bookworm does
# not ship; grab a Temurin JRE 21 (build-time tool only, does not affect the
# produced binaries).
RUN set -eux \
    && case "$(uname -m)" in \
        x86_64)  JRE_ASSET="OpenJDK21U-jre_x64_linux_hotspot_21.0.9_10.tar.gz" ;; \
        aarch64) JRE_ASSET="OpenJDK21U-jre_aarch64_linux_hotspot_21.0.9_10.tar.gz" ;; \
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
    && wget -q -O /tmp/jre21.tar.gz \
        "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.9%2B10/${JRE_ASSET}" \
    && mkdir -p /opt/jdk21 \
    && tar -xzf /tmp/jre21.tar.gz -C /opt/jdk21 --strip-components=1 \
    && rm -f /tmp/jre21.tar.gz

# SLC CLI (Silicon Labs Configurator) generates the zigbeed build projects.
# The SLC Linux distribution ships an x86-64-only native launcher, so this
# stage must run on the BUILD platform (amd64 on GitHub Actions). Project
# generation is pure templating + file copying: the two outputs below are
# architecture-neutral except for the prebuilt Zigbee stack library directory
# they reference (protocol/zigbee/build/gcc/{x86-64,arm64v8}).
RUN wget -q -O /tmp/slc_cli_linux.zip \
        "https://www.silabs.com/documents/login/software/slc_cli_linux.zip" \
    && unzip -q /tmp/slc_cli_linux.zip -d /usr/src/slc_cli \
    && rm -f /tmp/slc_cli_linux.zip

ENV PATH="/opt/jdk21/bin:/usr/src/slc_cli/slc_cli:${PATH}"

# Optional offline bootstrap cache (see README "Build caching"): drop the SDK
# zip here to skip the 1.3 GB download on rebuilds.
COPY build-cache/ /tmp/build-cache/
COPY patches/ /usr/src/patches/

RUN set -eux \
    && [ -s /tmp/build-cache/gecko-sdk.zip ] \
        || wget -q -O /tmp/build-cache/gecko-sdk.zip \
            "https://github.com/SiliconLabs/gecko_sdk/releases/download/${GECKO_SDK_VERSION}/gecko-sdk.zip" \
    && mkdir -p /usr/src/gecko_sdk \
    && unzip -q /tmp/build-cache/gecko-sdk.zip -d /usr/src/gecko_sdk \
    && rm -f /tmp/build-cache/gecko-sdk.zip

# Patch the SDK and generate an x86-64 and an arm64 zigbeed project. The
# generated zigbeed.project.mak bakes in the SDK path used here, so the later
# build stage must mount the SDK at /usr/src/gecko_sdk as well.
RUN set -eux \
    && cd /usr/src/gecko_sdk \
    && patch -p1 -f < /usr/src/patches/gecko-sdk/0001-Use-TCP-socket-instead-of-serial-port-SDK.patch \
    && slc signature trust --sdk=/usr/src/gecko_sdk \
    && for SL_CONFIG in zigbee_x86_64 zigbee_arm64; do \
        case "${SL_CONFIG}" in \
            zigbee_x86_64) SL_DIR="x86_64" ;; \
            zigbee_arm64)  SL_DIR="arm64" ;; \
        esac; \
        slc generate --sdk=/usr/src/gecko_sdk \
            --with="${SL_CONFIG}" \
            --project-file=/usr/src/gecko_sdk/protocol/zigbee/app/zigbeed/zigbeed.slcp \
            --export-destination=/usr/src/zigbeed/${SL_DIR} \
            --copy-proj-sources; \
        cd /usr/src/zigbeed/${SL_DIR}; \
        patch -p1 -f < /usr/src/patches/zigbeed-app/0001-Use-TCP-socket-instead-of-serial-port-main-app.patch; \
        printf '\n# Extra host-Linux support the SLC generated project does not include by\n# default (zigbeed links against libcpc, shipped by the cpcd-builder stage).\n#  * loglevel must be dynamic: app.c calls otLoggingSetLevel()\n#  * the r23 support library is missing the dynamic-commissioning stubs\nC_DEFS += -DOPENTHREAD_CONFIG_LOG_LEVEL_DYNAMIC_ENABLE=1\nC_SOURCE_FILES += $(SDK_PATH)/protocol/zigbee/stack/stubs/sl_zigbee_dynamic_commissioning_stubs.c\n' \
            >> zigbeed.project.mak; \
        cd /usr/src/gecko_sdk; \
    done

# -----------------------------------------------------------------------------
# Stage 2b: zigbeed native compile (per target architecture)
# -----------------------------------------------------------------------------
FROM --platform=$TARGETPLATFORM ${BUILD_FROM} AS zigbeed-builder

ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# CPC library + headers zigbeed links against (from stage 1); the patched Gecko
# SDK and the generated projects (from stage 2a, whose project.mak references
# the SDK at /usr/src/gecko_sdk). ldconfig makes /usr/local/lib visible to both
# the linker and the runtime loader.
COPY --from=cpcd-builder /usr/local/ /usr/local/
COPY --from=zigbeed-slc /usr/src/gecko_sdk /usr/src/gecko_sdk
COPY --from=zigbeed-slc /usr/src/zigbeed /usr/src/zigbeed
RUN ldconfig

RUN set -eux \
    && case "${TARGETARCH}" in \
        amd64) SL_DIR="x86_64" ;; \
        arm64) SL_DIR="arm64" ;; \
        *)     echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && cd /usr/src/zigbeed/${SL_DIR} \
    && make -f zigbeed.Makefile \
        C_FLAGS="-std=gnu99 -DEMBER_MULTICAST_TABLE_SIZE=16" \
        LD_FLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib -lcpc -lpthread -lrt -lm" \
        debug \
    && install -D -m 0755 /usr/src/zigbeed/${SL_DIR}/build/debug/zigbeed /usr/local/bin/zigbeed

# -----------------------------------------------------------------------------
# Stage 3: ot-br - OpenThread Border Router
# -----------------------------------------------------------------------------
FROM ${BUILD_FROM} AS otbr-builder

ENV \
    DOCKER=1 \
    BORDER_ROUTING=1 \
    BACKBONE_ROUTER=1 \
    WEB_GUI=1

# script/bootstrap performs its own apt installs, but cannot pull npm/nodejs
# in without triggering a systemd install; pre-install those here.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 \
        lsb-release \
        netcat-openbsd \
        netcat-traditional \
        nodejs \
        npm \
        patch \
        python3 \
        python3-aiohttp \
        python3-cryptography \
        python3-pip \
        python3-yarl \
        sudo \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Reuse the Gecko SDK trees extracted during the zigbeed stage.
COPY --from=zigbeed-builder /usr/src/gecko_sdk/util/third_party/ot-br-posix /usr/src/ot-br-posix
COPY --from=zigbeed-builder /usr/src/gecko_sdk/util/third_party/openthread /usr/src/openthread
COPY --from=zigbeed-builder /usr/src/gecko_sdk/protocol/openthread/platform-abstraction/posix /usr/src/silabs-vendor-interface
COPY --from=cpcd-builder /usr/local/ /usr/local/
COPY patches/ /usr/src/patches/

# Build OTBR natively. The Silicon Labs RCP vendor bus is wired to CPC via
# cpc_interface.cpp. The OTBR REST "delete dataset" patch is applied.
RUN set -eux \
    && mkdir -p /usr/src/ot-br-posix/third_party/openthread \
    && ln -s /usr/src/openthread /usr/src/ot-br-posix/third_party/openthread/repo \
    && ln -s /usr/src/silabs-vendor-interface/openthread-core-silabs-posix-config.h \
        /usr/src/openthread/src/posix/platform/openthread-core-silabs-posix-config.h \
    && cd /usr/src/ot-br-posix \
    && patch -p1 -f < /usr/src/patches/otbr/0001-PATCH-rest-Support-deleting-the-dataset.patch \
    && chmod +x script/* \
    && ./script/bootstrap \
    && echo "88 openthread" >> /etc/iproute2/rt_tables \
    && ./script/cmake-build \
        -DBUILD_TESTING=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_MODULE_PATH=/usr/src/silabs-vendor-interface \
        -DOTBR_FEATURE_FLAGS=ON \
        -DOTBR_DNSSD_DISCOVERY_PROXY=ON \
        -DOTBR_SRP_ADVERTISING_PROXY=ON \
        -DOTBR_INFRA_IF_NAME=eth0 \
        -DOTBR_MDNS=mDNSResponder \
        -DOTBR_VERSION= \
        -DOT_PACKAGE_VERSION= \
        -DOTBR_DBUS=OFF \
        -DOT_MULTIPAN_RCP=ON \
        -DOT_POSIX_RCP_VENDOR_BUS=ON \
        -DOT_POSIX_CONFIG_RCP_VENDOR_DEPS_PACKAGE=/usr/src/silabs-vendor-interface/posix_vendor_rcp.cmake \
        -DOT_POSIX_CONFIG_RCP_VENDOR_INTERFACE=/usr/src/silabs-vendor-interface/cpc_interface.cpp \
        -DOT_PLATFORM_CONFIG=openthread-core-silabs-posix-config.h \
        -DOT_LINK_RAW=1 \
        -DOTBR_WEB=ON \
        -DOTBR_BORDER_ROUTING=ON \
        -DOTBR_REST=ON \
        -DOTBR_BACKBONE_ROUTER=ON \
        -DOTBR_VENDOR_NAME="silabs-multipan-docker" \
        -DOTBR_PRODUCT_NAME="Silicon Labs Multiprotocol" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    && cd build/otbr \
    && ninja \
    && ninja install

# -----------------------------------------------------------------------------
# Stage 4: runtime image
# -----------------------------------------------------------------------------
FROM ${BUILD_FROM} AS runtime

ARG S6_OVERLAY_VERSION=v3.2.0.0
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 \
        ipset \
        iptables \
        libavahi-client3 \
        libavahi-common3 \
        libjsoncpp25 \
        libmbedtls14 \
        libncurses6 \
        libnetfilter-queue1 \
        libreadline8 \
        netcat-openbsd \
        procps \
        socat \
        tzdata \
        wget \
        xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && echo "88 openthread" >> /etc/iproute2/rt_tables \
    && touch /accept_silabs_msla

# s6-overlay v3 init system
RUN set -eux \
    && if [ -z "${TARGETARCH}" ]; then \
        case "$(uname -m)" in \
          x86_64)  TARGETARCH="amd64" ;; \
          aarch64) TARGETARCH="arm64" ;; \
        esac; \
    fi \
    && case "${TARGETARCH}" in \
        amd64) S6_ARCH="x86_64" ;; \
        arm64) S6_ARCH="aarch64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && wget -q -O /tmp/s6-noarch.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
    && wget -q -O /tmp/s6-bin.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
    && tar -C / -Jxpf /tmp/s6-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-bin.tar.xz \
    && ln -s /command/with-contenv /usr/bin/with-contenv \
    && rm -f /tmp/s6-*.tar.xz

COPY --from=cpcd-builder /usr/local/bin/cpcd /usr/local/bin/
COPY --from=cpcd-builder /usr/local/lib/ /usr/local/lib/
COPY --from=zigbeed-builder /usr/local/bin/zigbeed /usr/local/bin/
COPY --from=otbr-builder /usr/sbin/otbr-agent /usr/sbin/otbr-agent
COPY --from=otbr-builder /usr/sbin/otbr-web /usr/sbin/otbr-web
COPY --from=otbr-builder /usr/sbin/mdnsd /usr/sbin/mdnsd
COPY --from=otbr-builder /usr/share/otbr-web/ /usr/share/otbr-web/

COPY rootfs/ /

RUN ldconfig \
    && mkdir -p /dev/shm /data

ENV \
    S6_VERBOSITY=3 \
    DEVICE="/dev/ttyUSB0" \
    BAUDRATE="460800" \
    FLOW_CONTROL="true" \
    CPCD_TRACE="false" \
    CPCP_DISABLE_ENCRYPTION="true" \
    OTBR_ENABLE=1 \
    BACKBONE_IF="eth0" \
    OTBR_LOG_LEVEL="notice" \
    OTBR_FIREWALL=1 \
    OTBR_REST_LISTEN_PORT="8081" \
    OTBR_WEB_PORT="8086" \
    EZSP_LISTEN_PORT="9999" \
    S6_STAGE2_HOOK=/etc/s6-overlay/scripts/enable-check.sh

VOLUME ["/data"]

# 9999 : Zigbee (EZSP over TCP, used by Home Assistant ZHA)
# 8081 : OpenThread Border Router REST API  (Home Assistant OTBR integration)
# 8086 : OpenThread Web GUI
EXPOSE 9999 8081 8086

HEALTHCHECK --interval=10s --start-period=120s CMD [ "$(s6-svstat -u /run/service/zigbeed)" = "true" ]

ENTRYPOINT ["/init"]