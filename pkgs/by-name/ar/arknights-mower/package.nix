{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  makeBinaryWrapper,
  bash,
  python3,
  stdenvNoCC,
}:
let
  appDependencies =
    ps: with ps; [
      evalidate
      flask
      flask-cors
      flask-sock
      pytz
      tzlocal
      pydantic
      pyyaml
      yamlcore
      numpy
      pandas
      scipy
      scikit-image
      scikit-learn
      networkx
      requests
      beautifulsoup4
      lxml
      jinja2
      htmllistparse
      colorlog
      cryptography
      opencv-python
      onnxruntime
      rapidocr-onnxruntime
      jieba
      langchain
      langchain-openai
      langgraph
    ];

  pythonEnv = python3.withPackages appDependencies;

  version = "4.1.5";
  src = fetchFromGitHub {
    owner = "ArkMowers";
    repo = "arknights-mower";
    tag = "v${version}";
    hash = "sha256-MEPT7SPmRxFNrZems18mCKU0t4nC44QnVuOtxNGaSCs=";
  };

  uiDist = buildNpmPackage {
    pname = "arknights-mower-ui";
    inherit version;

    src = src + "/ui";

    npmDepsHash = "sha256-VMSN7NH8cknVRkpDExadivAaSv2svXBaGbeJCj7sFeM=";

    npmBuildScript = "build";

    installPhase = ''
      mkdir -p $out
      cp -r dist $out
    '';
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "arknights-mower";
  inherit version;

  strictDeps = true;
  __structuredAttrs = true;

  inherit src;

  nativeBuildInputs = [ makeBinaryWrapper ];

  patches = [
    ./email-templates.patch
    ./only-web.patch
    ./server-ui.patch
  ];

  # MaaCore spawns adb via `execlp("sh", ...)` (PosixIO), which resolves sh from PATH.
  # The systemd unit's default PATH lacks /bin, so suffix bash's bin (provides sh) to
  # keep those subprocesses (and any MAA adb commands) executable.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/arknights-mower $out/bin
    cp -r . $out/share/arknights-mower
    cp -r ${uiDist}/dist $out/share/arknights-mower/ui/dist

    makeBinaryWrapper ${lib.getExe pythonEnv} $out/bin/mower \
      --add-flag "$out/share/arknights-mower/webserver.py" \
      --unset NIX_PYTHONPATH \
      --unset PYTHONPATH \
      --prefix PATH : ${lib.makeBinPath [ bash ]}

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    ${lib.getExe pythonEnv} -c "import arknights_mower; print(arknights_mower.__version__)"
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "Arknights mower helper";
    homepage = "https://github.com/ArkMowers/arknights-mower";
    changelog = "https://github.com/ArkMowers/arknights-mower/releases/tag/v${version}";
    mainProgram = "mower";
    maintainers = with lib.maintainers; [ knightfemale ];
    platforms = platforms.linux;
    license = licenses.mit;
  };
})
