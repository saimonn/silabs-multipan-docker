# Silabs multiprotocol for HA docker installation

This container is a **standalone** version of the [Silicon Labs multiprotocol addon for HAOS](https://skyconnect.home-assistant.io/procedures/enable-multiprotocol/). without the HAOS stuff.

![](https://img.shields.io/github/license/b2un0/silabs-multipan-docker.svg)
![](https://img.shields.io/github/stars/b2un0/silabs-multipan-docker)
![](https://img.shields.io/docker/v/b2un0/silabs-multipan-docker)
![](https://img.shields.io/docker/pulls/b2un0/silabs-multipan-docker.svg)
![](https://img.shields.io/docker/image-size/b2un0/silabs-multipan-docker.svg)

> [!WARNING]
> This project is deprecated due to discontinued multiprotocol support for Home Assistant SkyConnect (ZBT-1).
> 
> See https://www.home-assistant.io/connectzbt1

# ❗ Attention ❗

I do not provide any support for the software running in this container.

I have only provided a `standalone` version of the Silabs multiprotocol container which can run **without** `HAOS`

## Credits

Based on the work by [@nervousapps](https://github.com/nervousapps/haDOCKERaddons/tree/master/silabs-multiprotocol/dockerCustom)
and [m33ts4k0z](https://github.com/m33ts4k0z/silabs-multipan-docker)

## Versions

see [VERSIONS.md](VERSIONS.md)

## Changelog

see [CHANGELOG.md](CHANGELOG.md)

## Docs

see [DOCS.md](DOCS.md)

## Base

see [BASE.md](BASE.md)

## ❗ requirements ❗ read carefully ❗

1. the container must run in `host` network mode
2. working `IPv6` in your LAN
3. the container must run with `--privileged` flag
4. the name of your network interface (try `ifconfig` or `ip a`) to set `BACKBONE_IF` correctly
5. the path of your Device like `/dev/tty???` (`/dev/serial/by-id/` will not work out of the box)
6. **Zigbee channel and Thread channel must be configured to the same**
7. Port `8081` is not in use because the OTBR API use is (can't be changed)

## environment variables

take a look at the [Dockerfile](Dockerfile) file for more information

## getting started

⚠️ change `DEVICE` and `BACKBONE_IF` to your environment ⚠️

### as docker run

```bash
docker run --name multipan \
            --detach \
            --privileged \
            --network host \
            --restart unless-stopped \
            --volume ~/multipan/:/data \
            --env DEVICE="/dev/ttyUSB0" \
            --env BACKBONE_IF="eth0" \
            b2un0/silabs-multipan-docker:latest
```

### as docker compose

1. download the [docker-compose.yml](docker-compose.yml) or copy the service to your existing one
2. change the config in `environment` if necessary
3. run `docker compose up -d`

## Setup OpenThread Border Router

open in your browser `http://HOST:8086` and configure your OTBR

## Home Assistant

### OTBR

add a new Device Integration `Open Thread Border Router` and use as Host `http://HOST:8081` as Endpoint.

### ZHA

1. Add the Zigbee Home Automation (`ZHA`) integration
2. Choose `EZSP` as Radio type
3. As serial path, enter `tcp://host_ip:20108` or `socket://host_ip:20108`
4. Port speed `460800`
5. flow control `hardware`

## Setup Zigbee2MQTT

To use this with `Zigbee2MQTT` change the `configuration.yaml` file of Zigbee2MQTT to this configuration:

```yaml
serial:
  port: tcp://host_ip:20108
  adapter: ezsp
  baudrate: 460800
```

Restart `Zigbee2MQTT`.
It might take a couple of tries for `Zigbee2MQTT` to connect the first time, but it will work without issues afterward.

## Matter

you also need the [python-matter-server](https://github.com/home-assistant-libs/python-matter-server) if you want to use Matter enabled devices with Home Assistant.

### Firmware Update

1. download the newer firmware from https://github.com/NabuCasa/silabs-firmware/tree/main/RCPMultiPAN/beta
2. place them into your local directory `~/multipan/firmware/` (if your `/data` Volume mounted to `~/multipan/`)
3. change the environment variable `FIRMWARE` to the new Filename (without path)
4. change the environment variable `AUTOFLASH_FIRMWARE` to `1`
5. redeploy your container

## Docker Base Images

| arch    | url                                                                       |
|---------|---------------------------------------------------------------------------|
| aarch64 | https://hub.docker.com/r/homeassistant/aarch64-addon-silabs-multiprotocol |
| amd64   | https://hub.docker.com/r/homeassistant/amd64-addon-silabs-multiprotocol   |
| armv7   | https://hub.docker.com/r/homeassistant/arm-addon-silabs-multiprotocol     |
| i386    | not exists (not supported by HA)                                          |
