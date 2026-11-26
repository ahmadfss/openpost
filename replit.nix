{ pkgs }: {
  # Runtime packages only. ffmpeg/ffprobe are required to verify videos and make posters.
  # sqlite is used for consistent .backup snapshots and restore checks. curl
  # (with --aws-sigv4) talks to R2; the deploy image has no python3, so the
  # scripts in scripts/amhar must not need it. The OpenPost and Litestream
  # binaries are downloaded by scripts/amhar, not built here.
  deps = [
    pkgs.ffmpeg
    pkgs.sqlite
    pkgs.cacert
    pkgs.curl
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.bash
    # nginx fronts OpenPost only to inject the Amhar auth-page artwork.
    # See scripts/amhar/signin-bg-overlay.sh. Not used to build the monorepo.
    pkgs.nginx
  ];
}
