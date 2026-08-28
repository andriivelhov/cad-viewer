cmake_minimum_required(VERSION 3.20)
project(CadViewer CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Ad-hoc by default; pass a real identity to produce a loadable extension:
#   cmake -S . -B build -DCODESIGN_IDENTITY="Apple Development: ..."
set(CODESIGN_IDENTITY "-" CACHE STRING "codesign identity for the app bundle")

find_package(OpenCASCADE REQUIRED)
message(STATUS "OpenCASCADE ${OpenCASCADE_VERSION} at ${OpenCASCADE_INSTALL_PREFIX}")

# Only the toolkits we actually use. Keeping this list tight is what lets us
# ship a trimmed static build later instead of 400 MB of dylibs.
set(OCCT_LIBS
  TKernel TKMath TKG2d TKG3d TKGeomBase TKGeomAlgo
  TKBRep TKTopAlgo TKPrim TKShHealing TKMesh TKBO TKBool TKGeomAlgo
  TKCDF TKLCAF TKCAF TKVCAF TKXCAF TKBinXCAF
  TKXSBase TKDE TKDECascade TKRWMesh
  TKDESTEP TKDEIGES TKDESTL TKDEOBJ TKDEGLTF TKDEVRML
)

add_library(cadcore STATIC core/src/CadDocument.cpp)
target_include_directories(cadcore PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/core/include
  ${OpenCASCADE_INCLUDE_DIR})
target_link_libraries(cadcore PUBLIC ${OCCT_LIBS})

add_executable(cadinspect core/tools/cadinspect.cpp)
target_link_libraries(cadinspect PRIVATE cadcore)

add_executable(makesamples core/tools/makesamples.cpp)
target_link_libraries(makesamples PRIVATE cadcore)

add_executable(makestress core/tools/makestress.cpp)
target_link_libraries(makestress PRIVATE cadcore)

# --- macOS viewer app -------------------------------------------------------

find_program(XCRUN xcrun REQUIRED)
set(METAL_SRC ${CMAKE_CURRENT_SOURCE_DIR}/app/Shaders.metal)
set(METAL_AIR ${CMAKE_CURRENT_BINARY_DIR}/Shaders.air)
set(METAL_LIB ${CMAKE_CURRENT_BINARY_DIR}/default.metallib)

# The Metal toolchain is a separate Xcode component. If it is missing we still
# build; CADView compiles the shader source at launch instead.
execute_process(COMMAND ${XCRUN} -sdk macosx metal --version
                RESULT_VARIABLE METAL_TOOLCHAIN_MISSING
                OUTPUT_QUIET ERROR_QUIET)
if(METAL_TOOLCHAIN_MISSING EQUAL 0)
  message(STATUS "Metal toolchain found: precompiling shaders")
  add_custom_command(
    OUTPUT ${METAL_LIB}
    COMMAND ${XCRUN} -sdk macosx metal -c ${METAL_SRC} -o ${METAL_AIR}
            -I ${CMAKE_CURRENT_SOURCE_DIR}/app
    COMMAND ${XCRUN} -sdk macosx metallib ${METAL_AIR} -o ${METAL_LIB}
    DEPENDS ${METAL_SRC} ${CMAKE_CURRENT_SOURCE_DIR}/app/ShaderTypes.h
    COMMENT "Compiling Metal shaders")
  add_custom_target(shaders DEPENDS ${METAL_LIB})
else()
  message(STATUS "Metal toolchain absent: shaders will compile at launch "
                 "(run: xcodebuild -downloadComponent MetalToolchain)")
  add_custom_target(shaders)
endif()

# Listing the metallib as a bundle resource makes it a real build dependency.
# A POST_BUILD copy only runs when the target relinks, which silently ships a
# stale shader library whenever only the .metal source changed.
set_source_files_properties(${METAL_LIB} PROPERTIES
  MACOSX_PACKAGE_LOCATION Resources GENERATED TRUE)
set_source_files_properties(${METAL_SRC} PROPERTIES
  MACOSX_PACKAGE_LOCATION Resources HEADER_FILE_ONLY TRUE)

add_executable(CADViewer MACOSX_BUNDLE
  app/main.mm app/CADView.mm ${METAL_SRC} ${METAL_LIB})
add_dependencies(CADViewer shaders)
target_include_directories(CADViewer PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/app)
target_link_libraries(CADViewer PRIVATE cadcore
  "-framework Cocoa" "-framework Metal" "-framework MetalKit"
  "-framework QuartzCore" "-framework UniformTypeIdentifiers"
  "-framework ImageIO" "-framework CoreGraphics")
target_compile_options(CADViewer PRIVATE -fobjc-arc)
target_link_options(CADViewer PRIVATE -Wl,-headerpad_max_install_names)

# Once the bundle has been signed and stapled macOS write-protects it, and the
# next plain build fails with "ld: can't write output file". Drop the signature
# before linking; every path that needs one re-signs afterwards.
add_custom_command(TARGET CADViewer PRE_BUILD
  COMMAND ${CMAKE_COMMAND} -E rm -rf
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/_CodeSignature
  VERBATIM)
# The icon is generated; regenerate with tools/make_icon.py.
set(APP_ICON ${CMAKE_CURRENT_SOURCE_DIR}/packaging/AppIcon.icns)
set_source_files_properties(${APP_ICON} PROPERTIES
  MACOSX_PACKAGE_LOCATION Resources)
target_sources(CADViewer PRIVATE ${APP_ICON})

set_target_properties(CADViewer PROPERTIES
  MACOSX_BUNDLE_BUNDLE_NAME "CAD Viewer"
  MACOSX_BUNDLE_GUI_IDENTIFIER "dev.cadviewer.app"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
  MACOSX_BUNDLE_EXECUTABLE_NAME "CADViewer"
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/app/Info.plist.in)

# --- QuickLook thumbnail extension ------------------------------------------
# An .appex is NOT a loadable bundle: it is a Mach-O executable entered at
# NSExtensionMain. Building it as a MODULE produces a bundle that PlugInKit
# silently refuses to register. The bundle layout is assembled by hand.

set(APPEX_DIR ${CMAKE_CURRENT_BINARY_DIR}/CADThumbnail.appex)

add_executable(CADThumbnail
  app/quicklook/ThumbnailProvider.mm app/CADView.mm)
add_dependencies(CADThumbnail shaders)
target_include_directories(CADThumbnail PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/app)
target_link_libraries(CADThumbnail PRIVATE cadcore
  "-framework Cocoa" "-framework Metal" "-framework MetalKit"
  "-framework QuartzCore" "-framework UniformTypeIdentifiers"
  "-framework ImageIO" "-framework CoreGraphics"
  "-framework QuickLookThumbnailing" "-framework Foundation")
target_compile_options(CADThumbnail PRIVATE -fobjc-arc)
target_link_options(CADThumbnail PRIVATE -e _NSExtensionMain
  -Wl,-headerpad_max_install_names)

add_custom_command(TARGET CADThumbnail POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory ${APPEX_DIR}/Contents/MacOS
  COMMAND ${CMAKE_COMMAND} -E make_directory ${APPEX_DIR}/Contents/Resources
  COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:CADThumbnail>
          ${APPEX_DIR}/Contents/MacOS/CADThumbnail
  COMMAND ${CMAKE_COMMAND} -E copy
          ${CMAKE_CURRENT_SOURCE_DIR}/app/quicklook/Info.plist
          ${APPEX_DIR}/Contents/Info.plist
  # Inside an appex, NSBundle.mainBundle is the appex, so it needs its own
  # copy of the shaders.
  COMMAND ${CMAKE_COMMAND} -E copy ${METAL_LIB}
          ${APPEX_DIR}/Contents/Resources/default.metallib
  COMMAND ${CMAKE_COMMAND} -E copy ${METAL_SRC}
          ${APPEX_DIR}/Contents/Resources/Shaders.metal
  COMMENT "Assembling CADThumbnail.appex"
  VERBATIM)

# --- QuickLook preview extension --------------------------------------------
# The interactive one: a QLPreviewingController hosting the real viewer, so the
# model can be orbited in Finder's preview pane.

set(PREVIEW_APPEX_DIR ${CMAKE_CURRENT_BINARY_DIR}/CADPreview.appex)

add_executable(CADPreview app/quicklook/PreviewProvider.mm app/CADView.mm)
add_dependencies(CADPreview shaders)
target_include_directories(CADPreview PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/app)
target_link_libraries(CADPreview PRIVATE cadcore
  "-framework Cocoa" "-framework Metal" "-framework MetalKit"
  "-framework QuartzCore" "-framework UniformTypeIdentifiers"
  "-framework ImageIO" "-framework CoreGraphics"
  "-framework QuickLookUI" "-framework Foundation")
target_compile_options(CADPreview PRIVATE -fobjc-arc)
target_link_options(CADPreview PRIVATE -e _NSExtensionMain
  -Wl,-headerpad_max_install_names)

add_custom_command(TARGET CADPreview POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory ${PREVIEW_APPEX_DIR}/Contents/MacOS
  COMMAND ${CMAKE_COMMAND} -E make_directory ${PREVIEW_APPEX_DIR}/Contents/Resources
  COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:CADPreview>
          ${PREVIEW_APPEX_DIR}/Contents/MacOS/CADPreview
  COMMAND ${CMAKE_COMMAND} -E copy
          ${CMAKE_CURRENT_SOURCE_DIR}/app/quicklook/PreviewInfo.plist
          ${PREVIEW_APPEX_DIR}/Contents/Info.plist
  COMMAND ${CMAKE_COMMAND} -E copy ${METAL_LIB}
          ${PREVIEW_APPEX_DIR}/Contents/Resources/default.metallib
  COMMAND ${CMAKE_COMMAND} -E copy ${METAL_SRC}
          ${PREVIEW_APPEX_DIR}/Contents/Resources/Shaders.metal
  COMMENT "Assembling CADPreview.appex"
  VERBATIM)

# Embedding must be a custom TARGET, not a POST_BUILD on CADViewer. POST_BUILD
# only runs when its target relinks, so editing only an extension source
# rebuilt the .appex and then silently shipped the previous one inside the app.
# A custom target is never "up to date", so this always runs.
add_custom_target(embed_extensions ALL
  # A signed and stapled bundle is write-protected, so copying into PlugIns
  # fails silently and leaves an empty .appex behind. Drop the signature first;
  # it is reapplied at the end of this target anyway.
  COMMAND ${CMAKE_COMMAND} -E rm -rf
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/_CodeSignature
  COMMAND ${CMAKE_COMMAND} -E make_directory
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/PlugIns
  COMMAND ${CMAKE_COMMAND} -E rm -rf
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/PlugIns/CADThumbnail.appex
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${APPEX_DIR}
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/PlugIns/CADThumbnail.appex
  COMMAND ${CMAKE_COMMAND} -E rm -rf
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/PlugIns/CADPreview.appex
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${PREVIEW_APPEX_DIR}
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/PlugIns/CADPreview.appex
  COMMAND codesign --force --sign "${CODESIGN_IDENTITY}" --timestamp=none
          --entitlements ${CMAKE_CURRENT_SOURCE_DIR}/app/quicklook/CADThumbnail.entitlements
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/PlugIns/CADThumbnail.appex
  COMMAND codesign --force --sign "${CODESIGN_IDENTITY}" --timestamp=none
          --entitlements ${CMAKE_CURRENT_SOURCE_DIR}/app/quicklook/CADPreview.entitlements
          $<TARGET_BUNDLE_CONTENT_DIR:CADViewer>/PlugIns/CADPreview.appex
  COMMAND codesign --force --sign "${CODESIGN_IDENTITY}" --timestamp=none
          $<TARGET_BUNDLE_DIR:CADViewer>
  DEPENDS CADViewer CADThumbnail CADPreview
  COMMENT "Embedding and signing the QuickLook extensions"
  VERBATIM)
