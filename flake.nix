{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version. Both versions build; the default is the current
      # stable, and `zig-old` is the previous one for the CI compatibility
      # lane and for local checks.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.16"
        zig."0.17"
      ];

      perSystem =
        { pkgs, config, ... }:
        let
          project =
            with pkgs;
            [
              # `just bench-compare` and `just oracle` (bench/README.md):
              # simdutf is the C++ arm and the oracle, built with the shell's
              # c++ and found with pkg-config; go and the rust toolchain build
              # their arms; goperf is golang.org/x/perf, which supplies
              # benchstat; util-linux supplies taskset, which pins every arm to
              # one core; time is GNU time, for each arm's peak RSS; curl
              # fetches the corpus.
              simdutf
              pkg-config
              go
              cargo
              rustc
              goperf
              util-linux
              time
              curl
            ]
            ++ [ config.packages."ziglint-0-16" ];
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-17"
            ];
            packages = project;
          };

          devShells.zig-old = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-16"
            ];
            packages = project;
          };
        };
    };
}
