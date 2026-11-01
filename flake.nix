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
      # imports and inputsFrom below mirror each other, except the toolchain
      # version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        zig."0.17"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = with config.devShells; [
              base
              zig
            ];

            # Project-specific tools.
            packages = with pkgs; [
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
            ];
          };
        };
    };
}
