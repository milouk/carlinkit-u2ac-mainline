#!/bin/sh
# load order from modules.dep
M=/tmp/rt/lib/modules/7.2.10
echo /tmp/rt/fw > /sys/module/firmware_class/parameters/path
wifi(){
  insmod $M/kernel/drivers/mmc/core/mmc_core.ko
  insmod $M/kernel/drivers/mmc/host/sdhci.ko
  insmod $M/kernel/drivers/mmc/host/sdhci-pltfm.ko
  insmod $M/kernel/drivers/mmc/host/cqhci.ko
  insmod $M/kernel/drivers/mmc/host/sdhci-esdhc-imx.ko
  insmod $M/kernel/net/wireless/cfg80211.ko
  insmod $M/kernel/drivers/net/wireless/broadcom/brcm80211/brcmutil/brcmutil.ko
  insmod $M/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko
  insmod $M/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/wcc/brcmfmac-wcc.ko
}
bt(){
  insmod $M/kernel/lib/crc/crc-ccitt.ko
  insmod $M/kernel/lib/crc/crc16.ko
  insmod $M/kernel/crypto/crypto.ko
  insmod $M/kernel/crypto/crypto_algapi.ko
  insmod $M/kernel/crypto/kpp.ko
  insmod $M/kernel/crypto/ecc.ko
  insmod $M/kernel/crypto/ecdh_generic.ko
  insmod $M/kernel/lib/crypto/libcryptoutils.ko
  insmod $M/kernel/lib/crypto/libaes.ko
  insmod $M/kernel/net/bluetooth/bluetooth.ko
  insmod $M/kernel/drivers/bluetooth/btrtl.ko
  insmod $M/kernel/drivers/bluetooth/btbcm.ko
  insmod $M/kernel/drivers/bluetooth/hci_uart.ko
}
"$@"
