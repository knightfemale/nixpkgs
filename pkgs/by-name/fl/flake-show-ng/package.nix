{
  lib,
  rustPlatform,
  fetchFromGitHub,
  git,
  nixVersions,
  writableTmpDirAsHomeHook,
  nixPackage ? nixVersions.nix_2_34,
}:

rustPlatform.buildRustPackage {
  pname = "flake-show-ng";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "nix-config";
    repo = "flake-show-ng";
    rev = "e11f7ed2fe966079365b43ef3702120852e9a0f4";
    hash = "sha256-Z/Zex1iB7QHFxiOeIxwzR+pujmBFjJ14IH5w0muWC0w=";
  };

  cargoHash = "sha256-S5wbuGb8Z5LmT8El/1cFcZCWukYYrnhMxlmCJwQyXJw=";

  doCheck = true;

  nativeCheckInputs = [
    git
    nixPackage
    writableTmpDirAsHomeHook
  ];

  preCheck = ''
    export NIX_CONFIG="extra-experimental-features = nix-command flakes"
  '';

  meta = {
    description = "Show the complete tree of a flake's outputs.";
    homepage = "https://github.com/nix-config/flake-show-ng";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ knightfemale ];
    mainProgram = "fsn";
    platforms = lib.platforms.unix;
  };
}
