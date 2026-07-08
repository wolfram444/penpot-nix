{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.penpot;
in
{
  options.services.penpot = {
    enable = mkEnableOption "Penpot collaborative design platform";

    port = mkOption {
      type = types.port;
      default = 9001;
      description = "Port for the HTTP proxy frontend (Nginx).";
    };

    domain = mkOption {
      type = types.str;
      description = "Domain name for Penpot.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in the firewall for the Nginx proxy.";
    };

    backendPort = mkOption {
      type = types.port;
      default = 6060;
      description = "Port to internally run the backend API service on.";
    };

    exporterPort = mkOption {
      type = types.port;
      default = 6061;
      description = "Port to internally run the exporter service on.";
    };

    secretKeyFile = mkOption {
      type = types.path;
      description = ''
        Path to a securely provisioned file containing Penpot's PENPOT_SECRET_KEY.
        It serves as a master key from which other keys for subsystems are derived.
        Recommended to use a 512-bit base64 encoded string.
      '';
    };

    secretKeyFileEX = mkOption {
      type = types.path;
      description = ''
        Path to a securely provisioned file containing Penpot's PENPOT_SECRET_KEY for penpot_exporter.
      '';
    };

    flags = mkOption {
      type = types.str;
      default = "disable-email-verification enable-smtp enable-prepl-server disable-secure-session-cookies enable-login-with-oidc enable-oidc-registration disable-login-with-password disable-registration";
      description = ''
        PENPOT_FLAGS,
      '';
    };

    db = {
      enablePostgres = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the bundled PostgreSQL database service automatically.";
      };
      enableRedis = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the bundled Redis database service automatically.";
      };
      postgresUri = mkOption {
        type = types.str;
        default = "postgresql://penpot:penpot@localhost/penpot";
        description = "PostgreSQL DB URI. Ignored if `enablePostgres` automatically overrides it via default unix sockets.";
      };
      redisUri = mkOption {
        type = types.str;
        default = "redis://127.0.0.1:6379/0";
        description = "Redis URI.";
      };
    };
  };

  config = mkIf cfg.enable {

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

    # 1. Provide default configuration for Valkey & Postgres if instructed
    services.postgresql = mkIf cfg.db.enablePostgres {
      enable = true;
      ensureDatabases = [ "penpot" ];
      ensureUsers = [
        {
          name = "penpot";
          ensureDBOwnership = true;
        }
      ];
    };

    services.redis.servers.penpot = mkIf cfg.db.enableRedis {
      enable = true;
      port = 6379;
    };

    # 2. Systemd Backend Daemon
    systemd.services.penpot-backend = {
      description = "Penpot Backend API Daemon";
      after = [
        "network.target"
      ]
      ++ (if cfg.db.enablePostgres then [ "postgresql.service" ] else [ ])
      ++ (if cfg.db.enableRedis then [ "redis-penpot.service" ] else [ ]);
      wantedBy = [ "multi-user.target" ];

      environment = {

        PENPOT_FLAGS = cfg.flags;

        PENPOT_PUBLIC_URI = "https://${cfg.domain}";
        PENPOT_HTTP_SERVER_PORT = toString cfg.backendPort;
        PENPOT_HTTP_SERVER_MAX_BODY_SIZE = "31457280";
        PENPOT_HTTP_SERVER_MAX_MULTIPART_BODY_SIZE = "367001600";

        PENPOT_DATABASE_URI = "postgresql://localhost/penpot?socketFactory=org.newsclub.net.unix.AFUNIXSocketFactory$FactoryArg&socketFactoryArg=/run/postgresql/.s.PGSQL.${toString config.services.postgresql.port}&sslMode=disable";
        PENPOT_DATABASE_USERNAME = "penpot";
        PENPOT_DATABASE_PASSWORD = "penpot";

        PENPOT_REDIS_URI = cfg.db.redisUri;
        PENPOT_OBJECTS_STORAGE_BACKEND = "fs";
        PENPOT_OBJECTS_STORAGE_FS_DIRECTORY = "/var/lib/penpot/assets";

        PENPOT_TELEMETRY_ENABLED = "true";
        PENPOT_TELEMETRY_REFERER = "nixos-module";

        # Auth
        PENPOT_OIDC_CLIENT_ID = "pepnpot";
        PENPOT_OIDC_CLIENT_SECRET = "fs4OIMGPhtWAbt5iwvbIVLCbvtirVs5m";
        PENPOT_OIDC_BASE_URI = "https://auth.funksiyachi.uz/realms/TestOpensearch/";
      };

      serviceConfig = {
        ExecStart = ''
          ${pkgs.penpot-backend}/bin/penpot-backend
        '';
        EnvironmentFile = [ cfg.secretKeyFile ];
        User = "penpot";
        Group = "penpot";
        StateDirectory = "penpot";
        WorkingDirectory = "/var/lib/penpot";
        Restart = "always";
      };
    };

    # 3. Systemd Exporter Daemon
    systemd.services.penpot-exporter = {
      description = "Penpot Exporter Daemon";
      after = [
        "network.target"
        "penpot-backend.service"
      ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PENPOT_PUBLIC_URI = "https://${cfg.domain}";
        PENPOT_REDIS_URI = cfg.db.redisUri;
        PENPOT_HTTP_SERVER_PORT = toString cfg.exporterPort;
      };

      serviceConfig = {
        ExecStart = ''
          ${pkgs.penpot-exporter}/bin/penpot-exporter
        '';
        EnvironmentFile = [ cfg.secretKeyFileEX ];
        User = "penpot";
        Group = "penpot";
        Restart = "always";
      };
    };

    systemd.services.penpot-frontend-config = {
      description = "Generate Penpot frontend config.js with runtime flags";
      after = [ "network.target" ];
      before = [ "nginx.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "penpot";
        Group = "penpot";
      };

      script = ''
        set -eu
        rm -rf /var/lib/penpot/frontend
        mkdir -p /var/lib/penpot/frontend
        cp -r ${pkgs.penpot-frontend}/share/penpot/frontend/. /var/lib/penpot/frontend/
        chmod -R u+w /var/lib/penpot/frontend

        cat > /var/lib/penpot/frontend/js/config.js <<EOF
        var penpotFlags = "${cfg.flags}";
        var penpotPublicURI = "https://${cfg.domain}";
        var penpotOIDCClientID = "pepnpot";
        EOF
      '';
    };

    users.users.penpot = {
      isSystemUser = true;
      group = "penpot";
      description = "Penpot application user";
    };
    users.groups.penpot = { };

    # 4. Expose the static Frontend + API routing strictly through Nginx!
    systemd.services.nginx = {
      after = [ "penpot-frontend-config.service" ];
      requires = [ "penpot-frontend-config.service" ];
    };

    services.nginx = {
      enable = true;
      virtualHosts."${cfg.domain}" = {

        forceSSL = true;
        enableACME = true;

        locations."/" = {
          root = "/var/lib/penpot/frontend";
          tryFiles = "$uri /index.html$is_args$args /index.html =404";
          extraConfig = ''
            add_header X-Frame-Options SAMEORIGIN always;
            add_header Cache-Control "no-store, no-cache, max-age=0" always;
          '';
        };

        locations."~* \\.(js|css|jpg|png|svg|gif|ttf|woff|woff2|wasm|map)$" = {
          root = "/var/lib/penpot/frontend";
          extraConfig = ''
            add_header Cache-Control "public, max-age=604800" always; # 7 days
          '';
        };

        # Proxies
        locations."/api" = {
          proxyPass = "http://127.0.0.1:${toString cfg.backendPort}/api";
          extraConfig = "proxy_buffering off;";
        };

        locations."/ws/notifications" = {
          proxyPass = "http://127.0.0.1:${toString cfg.backendPort}/ws/notifications";
          proxyWebsockets = true;
        };

        locations."/assets" = {
          proxyPass = "http://127.0.0.1:${toString cfg.backendPort}/assets";
        };

        locations."/internal/assets/" = {
          alias = "/var/lib/penpot/assets/";
          extraConfig = "internal;";
        };

        locations."/api/export" = {
          proxyPass = "http://127.0.0.1:${toString cfg.exporterPort}";
        };
      };
    };

  };
}
