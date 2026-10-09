{
  lib,
  config,
  callPackage,
  stdenv,
  fetchFromGitHub,
  cmake,
  boost,
  nlohmann_json,
  onnxruntime,
  opencv,
  zlib,
  isBeta ? false,
  cudaSupport ? config.cudaSupport,
  cudaPackages ? { },
}:

let
  fastdeploy = callPackage ./fastdeploy-ppocr.nix { };
  sources = lib.importJSON ./pin.json;
  # v6 builds the MaaUtils submodule; nixpkgs' fetchSubmodules does not populate
  # submodule working trees here, so fetch it explicitly and overlay it in postPatch.
  #
  # WARNING: this rev is a snapshot of MAA's src/MaaUtils submodule gitlink. MAA
  # releases advance this pointer, so when bumping the MAA version you MUST
  # re-check / update this rev to match; otherwise the new MAA build would use an
  # old, mismatched MaaUtils.
  maaUtilsSrc = fetchFromGitHub {
    owner = "MaaXYZ";
    repo = "MaaUtils";
    rev = "0c2556cfcff85eab8c2fa4529d71e37c310a3b78";
    hash = "sha256-bNi3IqSgavG7dbL3VQKvwTCiT7tyCWcKl0/y+/pvW3w=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "maa-assistant-arknights" + lib.optionalString isBeta "-beta";
  version = if isBeta then sources.beta.version else sources.stable.version;

  src = fetchFromGitHub {
    owner = "MaaAssistantArknights";
    repo = "MaaAssistantArknights";
    rev = "v${finalAttrs.version}";
    hash = if isBeta then sources.beta.hash else sources.stable.hash;
    # v6 requires the src/MaaUtils submodule (included via the root CMakeLists).
    # We do NOT use fetchSubmodules here: its submodule working tree is empty
    # after the fetch, so the MaaUtils content is populated by the explicit
    # maaUtilsSrc fetch + cp -a overlay in postPatch (the only authoritative
    # source). Keeping fetchSubmodules off avoids the risk of the overlay
    # colliding with a non-empty submodule tree in the future.
  };

  nativeBuildInputs = [
    cmake
    fastdeploy.cmake
  ]
  ++ lib.optionals cudaSupport [ cudaPackages.cuda_nvcc ];

  buildInputs = [
    fastdeploy
    boost
    onnxruntime
    opencv
    zlib
  ]
  # nlohmann_json is only required by the beta BlackFlow module; it is header-only
  # and harmless on stable, but keep it out of stable builds.
  ++ lib.optionals isBeta [ nlohmann_json ]
  ++ lib.optionals cudaSupport (
    with cudaPackages;
    [
      cccl # cub/cub.cuh
      libcublas # cublas_v2.h
      libcurand # curand.h
      libcusparse # cusparse.h
      libcufft # cufft.h
      cudnn # cudnn.h
      cuda_cudart
    ]
  );

  cmakeBuildType = "None";

  cmakeFlags = [
    (lib.cmakeBool "BUILD_SHARED_LIBS" true)
    # MaaUtils' LINUX && WITH_RPATH_LIBRARY path copies the LLVM/libc++ runtime
    # libs (chained build uses libstdc++), which breaks with the gcc wrapper.
    (lib.cmakeBool "WITH_RPATH_LIBRARY" false)
    (lib.cmakeBool "INSTALL_FLATTEN" false)
    (lib.cmakeBool "INSTALL_PYTHON" true)
    (lib.cmakeBool "INSTALL_RESOURCE" true)
    # MAA's MaaUtils cmake/version.cmake does `add_compile_definitions(MAA_VERSION="${MAA_HASH_VERSION}")`,
    # so the C++ MAA_VERSION macro is fed by MAA_HASH_VERSION, NOT MAA_VERSION. Passing -DMAA_VERSION is
    # a dead cache var that leaves the macro at its Conf.h fallback ("DEBUG_VERSION").
    (lib.cmakeFeature "MAA_HASH_VERSION" "v${finalAttrs.version}")
  ];

  passthru.updateScript = ./update.sh;

  postPatch = ''
    # Ensure the source tree (including the overlaid, store-read-only MaaUtils
    # files) is writable for the patches below.
    chmod -R u+w .

    # Populate the MaaUtils submodule (its working tree is empty after the fetch).
    cp -a ${maaUtilsSrc}/. src/MaaUtils/
    chmod -R u+w src/MaaUtils

    # MaaUtils vendors its dependency management via maadeps.cmake, which is not
        # present in the upstream MaaUtils submodule (it 404s). nixpkgs fetches all
        # of its dependencies itself, so provide a no-op stub.
        mkdir -p src/MaaUtils/MaaDeps
        cat > src/MaaUtils/MaaDeps/maadeps.cmake <<'EOF'
    function(maadeps_install)
    endfunction()
    function(detect_maadeps_triplet OUT)
      set(''${OUT} "x" PARENT_SCOPE)
    endfunction()
    EOF

        # nixpkgs boost (1.89) defaults <boost/process.hpp> to the v2 API, but MaaUtils
        # uses the legacy v1 API (boost::process::child ipstream opstream ...). Include
        # the v1 headers and re-export them into the boost::process namespace.
        cat > src/MaaUtils/include/MaaUtils/IOStream/BoostIO.hpp <<'EOF'
    #pragma once

    #define BOOST_PROCESS_USE_STD_FS 1

    #include <boost/asio.hpp>
    #include <boost/process/v1.hpp>
    namespace boost
    {
    namespace process
    {
    using namespace v1;
    }
    }
    #ifdef _WIN32
    #include <boost/process/extend.hpp>
    #include <boost/process/windows.hpp>
    #endif
    EOF

        # MaaCore was written against a libstdc++ with more generous transitive
        # includes. With gcc 15's libstdc++ the standard headers no longer include
        # each other, so force-include a compat header of common std headers.
        cat > MaaStdCxxCompat.h <<'EOF'
    #pragma once
    #include <algorithm>
    #include <array>
    #include <atomic>
    #include <chrono>
    #include <cmath>
    #include <cstddef>
    #include <cstdint>
    #include <deque>
    #include <filesystem>
    #include <fstream>
    #include <functional>
    #include <iostream>
    #include <list>
    #include <map>
    #include <memory>
    #include <mutex>
    #include <numeric>
    #include <optional>
    #include <queue>
    #include <set>
    #include <sstream>
    #include <string>
    #include <string_view>
    #include <thread>
    #include <tuple>
    #include <type_traits>
    #include <unordered_map>
    #include <unordered_set>
    #include <utility>
    #include <variant>
    #include <vector>
    EOF
        sed -i '/^project(MAA)/a\    add_compile_options(-include ''${CMAKE_SOURCE_DIR}/MaaStdCxxCompat.h)' CMakeLists.txt

        # nixpkgs boost does not ship the (header-only) Boost.System CMake component
        # config (it has no libboost_system and no boost_system cmake dir). Boost.System
        # is header-only since 1.69, so map Boost::system to Boost::headers and drop the
        # "system" component from the find_package request.
        grep -rl 'Boost::system' --include='*.cmake' --include='CMakeLists.txt' . 2>/dev/null | while read -r f; do
          sed -i 's/Boost::system/Boost::headers/g' "$f"
        done
        sed -i 's/REQUIRED CONFIG COMPONENTS system regex/REQUIRED CONFIG COMPONENTS regex/' src/MaaUtils/MaaUtils.cmake

        # MaaCore links against more OpenCV modules than the upstream three-component
        # find_package declares (features2d/xfeatures2d for SIFT/SURF, calib3d, videoio).
        # nixpkgs' opencv splits its modules (no opencv_world), so OpenCV_LIBS only
        # carries the declared components. Without declaring the additional modules they
        # are missing from libMaaCore.so's DT_NEEDED and SIFT/SURF symbols stay undefined
        # at runtime. Explicitly list them to link those shared libs in.
        sed -i 's|find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs)|find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs features2d xfeatures2d calib3d videoio)|' src/MaaUtils/MaaUtils.cmake

        # MaaUtils enables -Wall;-Werror;-Wextra;-Wpedantic on non-MSVC; disable -Werror
        # so warnings don't fail the build.
        grep -rl '\-Werror' --include='*.cmake' --include='CMakeLists.txt' . 2>/dev/null | while read -r f; do
          sed -i 's/-Werror//g; s/;;/;/g' "$f"
        done
  '';

  postInstall = ''
    mkdir -p $out/share/${finalAttrs.pname}
    mv $out/{Python,resource} $out/share/${finalAttrs.pname}
  '';

  meta = {
    description = "Arknights assistant";
    homepage = "https://github.com/MaaAssistantArknights/MaaAssistantArknights";
    license = lib.licenses.agpl3Only;
    maintainers = with lib.maintainers; [
      Cryolitia
      knightfemale
    ];
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
