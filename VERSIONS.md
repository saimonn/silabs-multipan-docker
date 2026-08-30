# Reference versions

Pin set used by this image (see README "Why this exists"):

| Component                        | Version         | Notes                                          |
| -------------------------------- | --------------- | ---------------------------------------------- |
| cpcd                             | v4.9.1          | CPC protocol 6, built with encryption disabled (compatible with v5 RCP) |
| zigbeed                          | Gecko SDK 4.4.6 | SLC build, EZSP over TCP                       |
| ot-br-posix                      | Gecko SDK 4.4.6 | Silicon Labs fork, native build, REST + Web    |
| base image                       | debian:bookworm |                                                |
| s6-overlay                       | v3.2.0.0        | init system                                    |

Known-good dongle firmware: NabuCasa SkyConnect RCP **v5** images
(`RCPMultiPAN_v5.x.x_rcp-uart-hw-802154_460800.gbl`), SONOFF
ZBDongle-E/P etc. shipping protocol v5 RCP.