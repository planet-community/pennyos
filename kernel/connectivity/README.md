# Vendor connectivity stack (WMT / BTIF / BT), ported to mainline 6.4

The Cosmo's Wi-Fi/BT/GPS/FM live in the MT6771's built-in "consys". There is no
mainline driver; this is MediaTek's vendor stack built out-of-tree. Background and
measurements: `research/wifi-scoping.md`.

- `pennyos-conn.patch` - everything we changed or added on top of the pristine
  vendor sources (compat header, shim module, Kbuild files, API ports, the two
  hardware-facing changes).
- Vendor base: `planet-community/android_kernel_planetcom_mt6771`, commit
  `5ba79b000e56509dae238a647114ebbe1e32e3a2`, directories
  `drivers/misc/mediatek/{connectivity/{common,bt,wlan},btif}` (+ `include`,
  `base/power/include`, `emi` as `vendor-include/` for reference headers).
- The working tree lives in the Docker volume `cosmo-conn` at `/c/conn` (a git repo
  whose first commit is the vendor import). Build:
  `docker run --rm -v cosmo-kernel-src:/src:ro -v cosmo-conn:/c cosmo-kbuild bash /c/conn/build.sh`
  -> `pennyos_shim.ko`, `btif.ko`, `wmt_drv.ko`, `bt_drv.ko` (load in that order).
- Device tree: `devicetree/pennyos-consys.dtsi`.
- Userspace: `tools/wmt/penny-wmtd.c` replaces Android's `wmt_loader` + `wmt_launcher`.
- Firmware (proprietary, copied from the phone's vendor partition into
  `collected/vendor-conn/firmware`, not in git): `ROMv4_be_patch_1_{0,1}_hdr.bin`,
  `WMT_SOC.cfg`, `WIFI_RAM_CODE_6759` -> `/lib/firmware` on the device.
