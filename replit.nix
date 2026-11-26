{ pkgs }: {
  # Runtime packages only. ffmpeg/ffprobe are required to verify videos and make posters.
  # sqlite is used for consistent .backup snapshots. The OpenPost and Litestream
  # binaries are downloaded by scripts/amhar, not built here.
  deps = [
    pkgs.ffmpeg
    pkgs.sqlite
    pkgs.cacert
    pkgs.curl
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.bash
  ];
}
