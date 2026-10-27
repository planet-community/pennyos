# devicetree/

Our additions to the upstream board file `mt6771-planet-cosmocom.dts` (in the
`affenull2345/linux` `mt6771` branch). `./tools/kbuild.sh dts-sync` copies the `.dtsi`
files into the kernel tree and `#include`s them at the end of the board DTS, in a fixed
order; `./tools/kbuild.sh patch` applies the `.patch` files to the board DTS itself.

| File | What it adds |
|---|---|
| `pennyos-debug.dtsi` | pstore/ramoops laid out like the vendor kernel's, so Android can read the last log back (`tools/read-lastboot.sh`) |
| `pennyos-panel-ssd2092.dtsi` | the Solomon SSD2092 main panel (`kernel/drivers/panel-planet-ssd2092.c`) |
| `pennyos-touch-ssd20xx.dtsi` | its touch controller (`kernel/drivers/ssd20xx.c`) |
| `pennyos-power-key.dtsi` | keeps the PMIC's hold-the-power-key hardware reset working |
| `pennyos-lid-keys.dtsi` | the lid Hall sensor as a switch |
| `pennyos-consys.dtsi` | the built-in Wi-Fi/Bluetooth subsystem for the vendor driver (`kernel/connectivity/`) |
| `pennyos-sound.dtsi` | the sound card (`kernel/drivers/cosmo-sound.c`) |
| `mt6771-mtk-lk-compat.dtsi` | **generated** by `tools/gen-lk-compat-dtsi.py`: the labels and nodes the bootloader's `dtbo` overlay needs ([lk-dtb-requirements](../research/lk-dtb-requirements.md)) |
| `debug-usb-peripheral.patch` | USB fixed in device mode, so the serial and Ethernet gadget always come up |

Map devices by I2C controller **base address**, not bus index
(see [the hardware inventory](../docs/cosmo-communicator-hardware-inventory.md) §0b).
The vendor's own device tree, captured from Android by `tools/android-recon.sh`, is the
reference for pins, addresses and power sequencing.
