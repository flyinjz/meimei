cmake_minimum_required(VERSION 3.24)
project(i2s LANGUAGES CXX)

# i2s for Windows (and later Linux): the interface in Qt Quick, the logic in
# the shared Swift core (Core/), called through its C header (Core/include).
# Build the core first (see the build script), then:
#   cmake -S Windows -B .build-windows -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build .build-w

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickShapes)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MEDIA REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil libswresample taglib)
qt_standard_project_setup(REQUIRES 6.8)

set(REPO "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(I2S_CORE_DIR "${REPO}/.build-core/out/Products/Release-windows-x86_64" CACHE PATH "Folder with I2SCore.dll and I2SCore.lib")
set(I2S_SWIFT_RUNTIME "$ENV{LOCALAPPDATA}/Programs/Swift/Runtimes/6.4.2/usr/bin" CACHE PATH "The Swift runtime's DLLs")
add_library(I2SCore SHARED IMPORTED)
set_target_properties(I2SCore PROPERTIES
    IMPORTED_LOCATION "${I2S_CORE_DIR}/I2SCore.dll"
    IMPORTED_IMPLIB "${I2S_CORE_DIR}/I2SCore.lib"
    INTERFACE_INCLUDE_DIRECTORIES "${REPO}/Core/include")

qt_add_executable(i2s WIN32
    main.cpp
    CoreBridge.h CoreBridge.cpp
    Platform.h Platform.cpp
    Typography.h Typography.cpp
    Glyph.h Glyph.cpp
    AudioEngine.h AudioEngine.cpp
    MediaSession.h MediaSession.cpp
    SelfTest.h SelfTest.cpp
    Library.h Library.cpp
    Player.h Player.cpp
    Artwork.h Artwork.cpp
)

# Every QML file in this folder; the file name is the type name.
file(GLOB QML_FILES RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS "*.qml")
set_source_files_properties(Skin.qml AppMenu.qml Customize.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(i2s
    URI I2S
    VERSION 1.0
    QML_FILES ${QML_FILES}
)

# Fonts are read straight from the repository's font folder in development.
target_compile_definitions(i2s PRIVATE I2S_FONT_DIR="${REPO}/Assets/Fonts" UNICODE _UNICODE)
target_include_directories(i2s PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(i2s PRIVATE Qt6::Core Qt6::Gui Qt6::Quick Qt6::QuickShapes PkgConfig::MEDIA I2SCore
    dwmapi psapi wer runtimeobject ole32 uuid)

# The core and the Swift runtime sit next to the app.
file(GLOB SWIFT_RUNTIME_DLLS "${I2S_SWIFT_RUNTIME}/*.dll")
add_custom_command(TARGET i2s POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${I2S_CORE_DIR}/I2SCore.dll" ${SWIFT_RUNTIME_DLLS} $<TARGET_FILE_DIR:i2s>
    VERBATIM)
