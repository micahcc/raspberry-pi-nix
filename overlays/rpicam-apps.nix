{ rpicam-apps-src, lib, pkgs, stdenv, }:

stdenv.mkDerivation {
  pname = "libcamera-apps";
  version = "v1.5.2";

  src = rpicam-apps-src;

  nativeBuildInputs = with pkgs; [ meson ninja pkg-config ];
  buildInputs = with pkgs; [
    libjpeg
    libtiff
    libcamera
    libepoxy
    boost
    libexif
    libpng
    ffmpeg
    libdrm
  ];
  mesonFlags = [
    "-Denable_qt=disabled"
    "-Denable_opencv=disabled"
    "-Denable_tflite=disabled"
    "-Denable_egl=disabled"
    "-Denable_hailo=disabled"
    "-Denable_drm=enabled"
  ];
  # Meson is no longer able to pick up Boost automatically.
  # https://github.com/NixOS/nixpkgs/issues/86131
  BOOST_INCLUDEDIR = "${lib.getDev pkgs.boost}/include";
  BOOST_LIBRARYDIR = "${lib.getLib pkgs.boost}/lib";

  meta = with lib; {
    description = "Userland tools interfacing with Raspberry Pi cameras";
    homepage = "https://github.com/raspberrypi/libcamera-apps";
    license = licenses.bsd2;
    platforms = [ "aarch64-linux" ];
  };
}
