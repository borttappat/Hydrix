# cpond - from VM
{ pkgs }:
pkgs.stdenv.mkDerivation {
        pname = "cpond";
        version = "unstable";
        src = pkgs.fetchFromGitHub {
          owner = "ayuzur";
          repo = "cpond";
          rev = "main";
          hash = "sha256-feRGJ2CIa82eEiGG65WwFlh6dhhIvhW70FJMObWvi1Q=";
        };
        buildInputs = [ pkgs.ncurses ];
        # TODO: Add build instructions
        installPhase = ''
          mkdir -p $out/bin
          cp cpond $out/bin/
        '';
      }
