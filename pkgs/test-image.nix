# Workload image for VM tests: busybox with an httpd entrypoint, so one
# image covers both "pod runs" and "service answers" assertions without any
# registry access.
{
  dockerTools,
  busybox,
  writeTextDir,
}:
dockerTools.streamLayeredImage {
  name = "kubenyx.local/test";
  tag = "1";
  contents = [
    busybox
    (writeTextDir "www/index.html" "kubenyx-ok")
  ];
  config.Cmd = [
    "/bin/busybox"
    "httpd"
    "-f"
    "-p"
    "8080"
    "-h"
    "/www"
  ];
}
