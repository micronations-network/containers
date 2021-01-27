{
  description = "Docker images for the micronet DNS";

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs {
        # It only makes sense to build on linux
        system = "x86_64-linux";
      };
      nonRootShadowSetup = { user, uid, gid ? uid }: with pkgs; [
        (
        writeTextDir "etc/shadow" ''
          root:!x:::::::
          ${user}:!:::::::
        ''
        )
        (
        writeTextDir "etc/passwd" ''
          root:x:0:0::/root:${runtimeShell}
          ${user}:x:${toString uid}:${toString gid}::/home/${user}:
        ''
        )
        (
        writeTextDir "etc/group" ''
          root:x:0:
          ${user}:x:${toString gid}:
        ''
        )
        (
        writeTextDir "etc/gshadow" ''
          root:x::
          ${user}:x::
        ''
        )
      ];

      primary-image-name = "m-tld-primary";
      primary-image-data-name = "m-tld-primary-data";

      config = pkgs.writeText "named.conf" ''
        options {
          listen-on port 5353 { any; };
          listen-on-v6 port 5353 { any; };
          allow-query { any; };
          version "[hidden]";
          recursion no;
          edns-udp-size 4096;
          directory "/state";
          dnssec-validation yes;
          disable-empty-zone ".";
        };

        controls { };

        zone "m" {
          type primary;
          file "m.zone";
          allow-transfer { any; };
          notify yes;
        };
      '';

      startupScript = pkgs.writeShellScript "start" ''
        chown somebody:somebody .

        exec /bin/gosu somebody $@
      '';
    in
    {

      defaultPackage.x86_64-linux = with self.packages.x86_64-linux; pkgs.linkFarmFromDrvs "m-tld-config" [
        m-tld-primary
        m-tld-update-script
      ];

      hydraJobs.m-tld-primary.x86_64-linux = self.packages.x86_64-linux.m-tld-primary;
      hydraJobs.m-tld-update-script.x86_64-linux = self.packages.x86_64-linux.m-tld-update-script;

      packages.x86_64-linux.m-tld-primary = pkgs.dockerTools.buildImage {
        name = primary-image-name;

        contents = with pkgs; [ coreutils gosu bind ] ++ nonRootShadowSetup { uid = 999; user = "somebody"; };

        runAsRoot = ''
          mkdir -p /state
          mkdir -p /var/run/named

          chown somebody:somebody /var/run/named

          /bin/named-checkconf ${config}
        '';

        config = {
          EntryPoint = [ startupScript ];
          Cmd = [ "/bin/named" "-c" "${config}" "-fg" ];
          WorkDir = "/state";
          ExposedPorts = {
            "5353/udp" = {};
          };
        };
      };

      packages.x86_64-linux.m-tld-update-script = let
        container-name = "m-tld-named";
        dns-publish = "127.0.0.1:5353";
      in
      pkgs.writeScript "update-m-tld.sh" ''
        #! /usr/bin/env bash

        set -euo pipefail
        set -x

        if [[ $# -ne 1 ]]; then
          echo >&2 "First argument should be the zone directory"
          exit 1
        fi

        zone_dir=$1

        for cmd in jq curl sed cut docker; do
          if ! command -v $cmd &> /dev/null; then
              echo "$cmd should be installed"
              exit 1
          fi
        done

        function getLatest () {
          set -e
          curl --fail -L -H 'Accept: application/json' 'https://hydra.pingiun.com/job/micronet/containers/m-tld-primary.x86_64-linux/latest-finished'
        }


        function updateContainer () {
          set -e
          local latest_finished=$1
          local store_path=$(echo "$latest_finished" | jq -r '.buildoutputs.out.path')
          local new_version=$(echo "$store_path" | sed 's|/nix/store/||' | cut -d '-' -f 1)
          local tmpfile=$(mktemp)
          NIX_REMOTE=https://hydra.pingiun.com/ nix cat-store "$store_path" > "$tmpfile"
          docker load < "$tmpfile"
          docker stop ${container-name} && docker rm ${container-name} || true
          docker run --detach --publish ${dns-publish}:5353/udp --volume "$zone_dir:/state" --name ${container-name} ${primary-image-name}:$new_version
          docker image prune -f
        }

        function main () {
          mkdir -p $zone_dir

          curl 'https://raw.githubusercontent.com/micronations-network/registry/main/m.zone' > $zone_dir/m.zone

          set +e
          old_version=$(docker inspect m-tld-named --format '{{.Config.Image}}' | cut -d ':' -f 2)
          retval=$?
          set -e
          if (( retval > 0 )); then
            updateContainer $(getLatest)
            exit 0
          fi

          local latest_finished=$(getLatest)
          local store_path=$(echo "$latest_finished" | jq -r '.buildoutputs.out.path')
          local new_version=$(echo "$store_path" | sed 's|/nix/store/||' | cut -d '-' -f 1)
          if [[ "$old_version" != "$new_version" ]]; then
            updateContainer "$latest_finished"
            exit 0
          fi
        }

        main
      '';

    };
}
