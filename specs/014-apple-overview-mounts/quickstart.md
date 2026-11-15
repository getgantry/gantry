<!-- STE deviation: commands and paths stay verbatim. -->
# Quickstart: Apple Container Mounts in Overview

1. Run the tests:

   ```sh
   swift test --package-path Packages/DockerKit --scratch-path /Volumes/SanDisk2Tb/builds/gantry/apple-overview-mounts/DockerKit --filter AppleContainerMounts
   swift test --package-path Packages/AppCore --scratch-path /Volumes/SanDisk2Tb/builds/gantry/apple-overview-mounts/AppCore --filter AppleMountsConsumer
   ```

   Expected: all pass.

2. Live data check (optional): create a container with a read-only bind and a named volume
   with the `container` CLI, then run `container inspect` and compare with R1 in research.md.

3. GUI live check (when the screen is free): start the Debug build, select the container,
   and read the Overview tab with `scripts/gantry-ctl`. Expected: `ro` for the read-only bind,
   the volume name for the volume.
