# The pod sandbox image, built from the pause binary that nixpkgs'
# kubernetes derivation already compiles (its `pause` output). Imported into
# containerd at boot so starting a pod never touches a registry. The name is
# registry-qualified (contains a dot) so containerd stores it verbatim —
# unqualified names get docker.io-prefixed on import and then miss the
# sandbox_image lookup (the exact bug nixpkgs fixed in Nov 2025).
{
  dockerTools,
  kubernetes,
}:
dockerTools.streamLayeredImage {
  name = "kubenyx.local/pause";
  tag = "1";
  config.Entrypoint = [ "${kubernetes.pause}/bin/pause" ];
}
