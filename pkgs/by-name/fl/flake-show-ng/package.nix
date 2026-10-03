{
  lib,
  rustPlatform,
  fetchFromGitHub,
  git,
  nixVersions,
}:

rustPlatform.buildRustPackage {
  pname = "flake-show-ng";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "nix-config";
    repo = "flake-show-ng";
    rev = "797e31d9689bb6f1e60171d9cd06e79ff3f30289";
    hash = "sha256-0rAhKXoYBd7neewenN1+7R8RVgwc2DUe4RUxhAhOuws=";
  };

  cargoHash = "sha256-S5wbuGb8Z5LmT8El/1cFcZCWukYYrnhMxlmCJwQyXJw=";

  nativeCheckInputs = [
    git
    nixVersions.nix_2_34
  ];

  preCheck = ''
    export NIX_CONFIG="experimental-features = nix-command flakes"
    export HOME=$TMPDIR
    export FSN_IT=1
  '';

  checkFlags = [ "--nocapture" ];

  meta = {
    description = "Show the complete tree of a flake's outputs.";
    homepage = "https://github.com/nix-config/flake-show-ng";
    license = lib.licenses.mit;
    mainProgram = "fsn";
    platforms = lib.platforms.unix;
  };
}
