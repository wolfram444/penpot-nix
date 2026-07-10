{
  stdenv,
  nodejs,
  pnpm,
  clojure,
  zulu25,
  cacert,
  git,
  rsync,
  penpot-src,
  penpot-render-wasm,
  autoPatchelfHook,
  zlib,
  jq,
  curl,
  patchelf,
}:

let
  version = penpot-src.rev;

  # Build the frontend in a Fixed Output Derivation with network access.
  # The frontend build is complex: pnpm + clojure + cargo/wasm (via emscripten)
  frontend-dist = stdenv.mkDerivation {
    pname = "penpot-frontend-dist";
    inherit version;
    src = penpot-src;

    nativeBuildInputs = [
      nodejs
      pnpm
      clojure
      zulu25
      cacert
      git
      rsync
      jq
      curl
      patchelf
      autoPatchelfHook
    ];

    buildInputs = [
      stdenv.cc.cc.lib
      zlib
    ];

    dontFixup = true;

    buildPhase = ''
      export HOME=$(pwd)
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      export NODE_ENV=production
      export VERSION=${version}
      export COREPACK_ENABLE_STRICT=0
      export COREPACK_ENABLE_AUTO_PIN=0

      # Strip packageManager fields so nixpkgs pnpm works
      # Using jq to avoid leaving trailing commas which breaks JSON parsing
      find . -name "package.json" -exec sh -c 'jq "del(.packageManager)" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;

      cd frontend

      # Copy render-wasm artifacts in so frontend doesn't need to build them
      mkdir -p resources/public/js/worker
      mkdir -p src/app/render_wasm/api

      cp ${penpot-render-wasm}/public/js/render-wasm.js resources/public/js/
      cp ${penpot-render-wasm}/public/js/render-wasm.wasm resources/public/js/
      cp ${penpot-render-wasm}/public/js/worker/render.js resources/public/js/worker/
      cp ${penpot-render-wasm}/api/shared.js src/app/render_wasm/api/

      # Remove render-wasm from scripts/build so it doesn't try to build it natively again!
      sed -i '/pushd \.\.\/render-wasm;/,+2d' scripts/build

      patchShebangs scripts/build
      patchShebangs ../mcp/scripts/setup

      sed -i '/corepack enable/d; /corepack install/d' scripts/build
      sed -i '/corepack enable/d; /corepack install/d' ../mcp/scripts/setup

      # Prevent postinstall scripts from compiling dart-sass binary until AFTER we explicitly patch it with glibc paths!
      sed -i 's/pnpm install;/pnpm install --ignore-scripts;\nfind node_modules -type f -name dart -exec patchelf --set-interpreter "$(cat $NIX_CC\/nix-support\/dynamic-linker)" {} + || true;\nfind node_modules -type f -name esbuild -exec patchelf --set-interpreter "$(cat $NIX_CC\/nix-support\/dynamic-linker)" {} + || true;\npnpm rebuild;/g' scripts/build

      ./scripts/build ${version}
    '';

    installPhase = ''
      mkdir -p $out
      cp -r target/dist/* $out/
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-Q1JF8yh0ZB9VHYPU/eQlhiK1Z5Ewhe2wqFwFMY/GhDM=";
  };

in
stdenv.mkDerivation {
  pname = "penpot-frontend";
  inherit version;

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/share/penpot/frontend
    cp -r ${frontend-dist}/* $out/share/penpot/frontend/
    chmod -R +w $out/share/penpot/frontend/

    # Inject the WebAssembly execution threads that the frontend build wiped during `rm -rf resources/public/`
    mkdir -p $out/share/penpot/frontend/js/worker
    cp ${penpot-render-wasm}/public/js/render-wasm.js $out/share/penpot/frontend/js/
    cp ${penpot-render-wasm}/public/js/render-wasm.wasm $out/share/penpot/frontend/js/
    cp ${penpot-render-wasm}/public/js/worker/render.js $out/share/penpot/frontend/js/worker/

    # Inject the static JVM environment configurations
    cp ${penpot-src}/docker/images/files/config.js $out/share/penpot/frontend/js/config.js
  '';
}
