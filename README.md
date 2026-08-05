# EdgePi E87N ImmortalWrt source builder

This public fork builds reproducible ImmortalWrt firmware for the EdgePi E87N
(`mediatek/filogic`, `edgepi,e87n`). It replaces the inherited x86 ImageBuilder
workflow with a full-source build pipeline.

The immutable upstream revisions used by the build are recorded in
[`versions.env`](versions.env). The intended output is an E87N sysupgrade image
that updates only the kernel and rootfs; it must never include boot0, boot1,
U-Boot environment, factory, or FIP data.

## Repository safety

This is a public repository. The supplied firmware, router-specific information,
backups, private runtime captures, generated images, and build working trees are
ignored. Do not override these protections with forced staging. Run the safety
check before committing:

```sh
bash tests/test-repository-safety.sh
```

## Build status

The repository is being converted incrementally to the E87N source-build
pipeline. Follow the committed E87N build and recovery documentation as those
components are added.
