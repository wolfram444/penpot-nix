{
  stdenv,
  nodejs,
  pnpm,
  clojure,
  zulu25,
  git,
  cacert,
  penpot-src,
  makeWrapper,
  playwright-driver,
}:

let
  version = "2.6.0-develop";

  # Build the exporter in a Fixed Output Derivation with network access.
  exporter-dist = stdenv.mkDerivation {
    pname = "penpot-exporter-dist";
    inherit version;
    src = penpot-src;

    nativeBuildInputs = [
      nodejs
      pnpm
      clojure
      zulu25
      git
      cacert
    ];
    dontFixup = true;

    buildPhase = ''
      export HOME=$(pwd)
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      export NODE_ENV=production

      cd exporter

      # Strip packageManager field so nixpkgs pnpm doesn't try to version-switch
      sed -i '/"packageManager"/d' package.json


      pnpm install
      pnpm run build

      cp pnpm-lock.yaml target/
      cp package.json target/
      touch target/pnpm-workspace.yaml

      sed -i -re "s/\%version\%/${version}/g" ./target/app.js

      # Install production node_modules in the target dir (needed at runtime)
      cd target
      pnpm install --prod
      cd ..
    '';

    installPhase = ''
      mkdir -p $out
      cp -r target/* $out/
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-fSCdsqap7uwjg42H1FAUebKS1Smoxjbp/4+LfZZ85vk=";
  };

in
stdenv.mkDerivation {
  pname = "penpot-exporter";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [
    makeWrapper
    nodejs
  ];

  installPhase = ''
    mkdir -p $out/lib/penpot/exporter $out/bin

    cp -r ${exporter-dist}/* $out/lib/penpot/exporter/

    makeWrapper ${nodejs}/bin/node $out/bin/penpot-exporter \
      --add-flags "$out/lib/penpot/exporter/app.js" \
      --set NODE_ENV "production" \
      --set PLAYWRIGHT_BROWSERS_PATH "${playwright-driver.browsers}"
  '';
}
