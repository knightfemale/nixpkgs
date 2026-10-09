{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  hatchling,
  wheel,
  pytestCheckHook,
}:

buildPythonPackage (finalAttrs: {
  pname = "evalidate";
  version = "2.1.4";
  src = fetchFromGitHub {
    owner = "yaroslaff";
    repo = "evalidate";
    tag = "v${finalAttrs.version}";
    hash = "sha256-IzqvsA07FjtPyAuhZ7qMFjk99XMIk2Ug8t7ZDGityuk=";
  };

  pyproject = true;
  
  build-system = [
    hatchling
    wheel
  ];

  pythonImportsCheck = [ "evalidate" ];

  nativeCheckInputs = [ pytestCheckHook ];

  meta = {
    homepage = "https://github.com/yaroslaff/evalidate";
    description = "Safe and fast evaluation of untrusted user-supplied python expressions";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ knightfemale ];
  };
})
