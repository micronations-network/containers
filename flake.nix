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

      config = pkgs.writeText "nsd.conf" ''
        server:
          zonesdir: "/state/zones"
          database: ""
          hide-version: yes
          identity: ""
          username: somebody
          pidfile: ""
          xfrdfile: "/state/xfrd.state"
          verbosity: 2

        remote-control:
          control-enable: yes
          control-interface: /tmp/control

        zone:
          name: m
          zonefile: "m.zone"

      '';

      startupScript = pkgs.writeShellScript "start" ''
        chown somebody:somebody /state
        mkdir -p /state/zones
        chown somebody:somebody /state/zones

        $@
      '';

      hydraJob = pkgs.lib.hydraJob;
    in
    {

      defaultPackage.x86_64-linux = pkgs.linkFarmFromDrvs "m-tld-config" (
        builtins.attrValues self.packages.x86_64-linux
      );

      hydraJobs.aggregate.x86_64-linux = pkgs.releaseTools.aggregate {
        name = "micronet-dns";

        constituents = with self.packages.x86_64-linux; [
          m-tld-primary
          m-tld-update-script
        ];
      };

      hydraJobs.update-script.x86_64-linux = pkgs.runCommand "update-script" { script = self.packages.x86_64-linux.m-tld-update-script; } ''
        mkdir -p $out/nix-support
        cp $script/bin/update-m-tld.sh $out/update-m-tld.sh
        echo "file script $out/update-m-tld.sh" >> $out/nix-support/hydra-build-products
      '';

      hydraJobs.primary-container.x86_64-linux = pkgs.runCommand "primary-container" { container = self.packages.x86_64-linux.m-tld-primary; } ''
        mkdir -p $out/nix-support
        cp $container $out/m-tld-primary.tar.gz
        echo "file container $out/m-tld-primary.tar.gz" >> $out/nix-support/hydra-build-products
      '';

      packages.x86_64-linux.m-tld-primary = pkgs.dockerTools.buildImage {
        name = primary-image-name;

        contents = with pkgs; [ coreutils nsd ] ++ nonRootShadowSetup { uid = 999; user = "somebody"; };

        runAsRoot = ''
          mkdir -p /state/zones
          mkdir -p /tmp
          chown somebody:somebody /tmp

          /bin/nsd-checkconf ${config}
        '';

        config = {
          EntryPoint = [ startupScript ];
          Cmd = [ "/bin/nsd" "-d" "-p" "5353" "-c" "${config}" ];
          WorkDir = "/state";
          ExposedPorts = {
            "5353/udp" = {};
            "5353/tcp" = {};
          };
        };
      };

      packages.x86_64-linux.m-tld-update-script = let
        container-name = "m-tld-named";
        dns-publish = "53";
      in
      pkgs.writeScript "update-m-tld.sh" ''
        #! /usr/bin/env bash

        set -euo pipefail
        set -x

        if [[ $# -ne 1 ]]; then
          echo >&2 "First argument should be the zone directory"
          exit 1
        fi

        ZONE_DIR=$1

        for cmd in jq curl sed cut docker find; do
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
          curl --fail 'https://hydra.pingiun.com/job/micronet/containers/m-tld-primary.x86_64-linux/latest/download-by-type/file/container' > "$tmpfile"
          docker load < "$tmpfile"
          docker stop ${container-name} && docker rm ${container-name} || true
          docker run --detach --publish ${dns-publish}:5353/udp --publish ${dns-publish}:5353/tcp --volume "$ZONE_DIR:/state" --name ${container-name} ${primary-image-name}:$new_version
          docker image prune -f
          rm $tmpfile
        }

        function main () {
          mkdir -p $ZONE_DIR/zones

          curl 'https://raw.githubusercontent.com/micronations-network/registry/main/m.zone' > $ZONE_DIR/zones/m.zone

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
          docker exec ${container-name} /bin/nsd-checkzone m /state/zones/m.zone
          docker exec ${container-name} /bin/nsd-control -c ${config} reload
        }

        main
      '';

    };
}
