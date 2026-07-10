{
  lib,
  stdenv,
  clojure,
  zulu25,
  makeWrapper,
  git,
  cacert,
  babashka,
  curl,
  penpot-src,
  imagemagick,
  nodejs,
  python3,
  woff2,
  fontforge,
  junixsocket-common,
  junixsocket-native-common,
}:

let
  version = penpot-src.rev;

  # Build the backend jar in a Fixed Output Derivation.
  # This has network access so Aether can resolve the full POM tree.
  # The output hash guarantees reproducibility.
  backend-dist = stdenv.mkDerivation {
    pname = "penpot-backend-dist";
    inherit version;
    src = penpot-src;

    nativeBuildInputs = [
      clojure
      zulu25
      git
      cacert
      babashka
      curl
    ];
    dontFixup = true;

    buildPhase = ''
      export HOME=$(pwd)
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt

      cd backend

      # patchShebangs is needed because /usr/bin/env doesn't exist in the Nix sandbox
      patchShebangs scripts/build
      patchShebangs scripts/prefetch-templates.clj

      ./scripts/build ${version}
    '';

    installPhase = ''
      mkdir -p $out
      cp -r target/dist/* $out/

      # Strip nix store references from output scripts to maintain FOD purity.
      # Replace patched shebangs (e.g. /nix/store/...-bash/bin/bash) with /usr/bin/env equivalents.
      find $out -type f -name "*.sh" -exec sed -i '1s|^#!.*/bin/bash|#!/usr/bin/env bash|' {} +
      find $out -type f -name "*.py" -exec sed -i '1s|^#!.*/bin/python3\?|#!/usr/bin/env python3|' {} +
      find $out -type f -name "*.clj" -exec sed -i '1s|^#!.*/bin/bb|#!/usr/bin/env bb|' {} +
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-aPLDJEvrDGL8M8afdCXSPMozg9RNaI3u4kcsv9GADLI=";
  };

in
stdenv.mkDerivation {
  pname = "penpot-backend";
  inherit version;

  # No source needed — we just package the pre-built dist
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/lib $out/bin $out/share/penpot/backend

    cp -r ${backend-dist}/* $out/share/penpot/backend/

    # Create a wrapper that mirrors run.sh from the penpot distribution
    makeWrapper ${zulu25}/bin/java $out/bin/penpot-backend \
      --prefix PATH : ${
        lib.makeBinPath [
          imagemagick
          nodejs
          python3
          woff2
          fontforge
        ]
      } \
      --chdir "$out/share/penpot/backend" \
      --add-flags "-cp \"${
        lib.join ":" [
          "$out/share/penpot/backend/penpot.jar"
          "${junixsocket-common}/share/java/*"
          "${junixsocket-native-common}/share/java/*"
        ]
      }\"" \
      --add-flags "-Dim4java.useV7=true" \
      --add-flags "-Djava.util.logging.manager=org.apache.logging.log4j.jul.LogManager" \
      --add-flags "-Dlog4j2.configurationFile=log4j2.xml" \
      --add-flags "-XX:-OmitStackTraceInFastThrow" \
      --add-flags "--sun-misc-unsafe-memory-access=allow" \
      --add-flags "--enable-native-access=ALL-UNNAMED" \
      --add-flags "--enable-preview" \
      --add-flags "clojure.main" \
      --add-flags "-m app.main"
  '';
}
