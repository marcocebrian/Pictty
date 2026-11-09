// swift-tools-version:6.0
import PackageDescription

// Release builds: full optimisation (-O), whole-module and cross-module optimisation so the
// engine's small hot functions inline across PicttyCore and Pictty, no runtime exclusivity checks,
// code scheduled for Apple silicon (M1 and later), and dead code stripped at link time.
// Bounds and overflow checks stay on (-O, not -Ounchecked): the heavy lifting is in
// ImageIO, vImage and Core Animation, so removing them would buy nothing measurable.
let optimised: [SwiftSetting] = [
    .unsafeFlags(["-O", "-wmo", "-cross-module-optimization", "-enforce-exclusivity=unchecked",
                  "-target-cpu", "apple-m1"],
                 .when(configuration: .release)),
]

// Sparkle, for the download only: build.sh sets PICTTY_SPARKLE, and the updater's code is compiled
// in. It is not linked: build.sh puts the framework in the app and Pictty loads it on its own, long
// after launch. Plain `swift build`, `swift test` and the Mac App Store build have no updater.
let sparkle: [SwiftSetting] = (Context.environment["PICTTY_SPARKLE"] ?? "").isEmpty ? [] : [.define("PICTTY_SPARKLE")]

let package = Package(
    name: "Pictty",
    platforms: [.macOS(.v15)],
    targets: [
        // LibRaw 0.22.3 (CDDL 1.0), compiled in: it reads a RAW's sensor mosaic (see Sources/LibRaw/README.md).
        // Its own build's sources and settings: thread-safe, deflate DNGs through the system's zlib.
        .target(
            name: "LibRaw",
            path: "Sources/LibRaw",
            exclude: ["README.md", "COPYRIGHT", "LICENSE.CDDL", "LICENSE.LGPL"],
            sources: [
                "src/libraw_c_api.cpp",
                "src/libraw_datastream.cpp",
                "src/decoders/canon_600.cpp",
                "src/decoders/crx.cpp",
                "src/decoders/pana8.cpp",
                "src/decoders/decoders_dcraw.cpp",
                "src/decoders/sonycc.cpp",
                "src/decompressors/losslessjpeg.cpp",
                "src/decoders/decoders_libraw_dcrdefs.cpp",
                "src/decoders/olympus14.cpp",
                "src/decoders/decoders_libraw.cpp",
                "src/decoders/dng.cpp",
                "src/decoders/fp_dng.cpp",
                "src/decoders/fuji_compressed.cpp",
                "src/decoders/generic.cpp",
                "src/decoders/kodak_decoders.cpp",
                "src/decoders/load_mfbacks.cpp",
                "src/decoders/smal.cpp",
                "src/decoders/unpack_thumb.cpp",
                "src/decoders/unpack.cpp",
                "src/demosaic/aahd_demosaic.cpp",
                "src/demosaic/ahd_demosaic.cpp",
                "src/demosaic/dcb_demosaic.cpp",
                "src/demosaic/dht_demosaic.cpp",
                "src/demosaic/misc_demosaic.cpp",
                "src/demosaic/xtrans_demosaic.cpp",
                "src/integration/dngsdk_glue.cpp",
                "src/integration/rawspeed_glue.cpp",
                "src/metadata/adobepano.cpp",
                "src/metadata/canon.cpp",
                "src/metadata/ciff.cpp",
                "src/metadata/cr3_parser.cpp",
                "src/metadata/epson.cpp",
                "src/metadata/exif_gps.cpp",
                "src/metadata/fuji.cpp",
                "src/metadata/identify_tools.cpp",
                "src/metadata/identify.cpp",
                "src/metadata/kodak.cpp",
                "src/metadata/leica.cpp",
                "src/metadata/makernotes.cpp",
                "src/metadata/mediumformat.cpp",
                "src/metadata/minolta.cpp",
                "src/metadata/misc_parsers.cpp",
                "src/metadata/nikon.cpp",
                "src/metadata/normalize_model.cpp",
                "src/metadata/olympus.cpp",
                "src/metadata/hasselblad_model.cpp",
                "src/metadata/p1.cpp",
                "src/metadata/pentax.cpp",
                "src/metadata/samsung.cpp",
                "src/metadata/sony.cpp",
                "src/metadata/tiff.cpp",
                "src/postprocessing/aspect_ratio.cpp",
                "src/postprocessing/dcraw_process.cpp",
                "src/postprocessing/mem_image.cpp",
                "src/postprocessing/postprocessing_aux.cpp",
                "src/postprocessing/postprocessing_utils_dcrdefs.cpp",
                "src/postprocessing/postprocessing_utils.cpp",
                "src/preprocessing/ext_preprocess.cpp",
                "src/preprocessing/raw2image.cpp",
                "src/preprocessing/subtract_black.cpp",
                "src/tables/cameralist.cpp",
                "src/tables/colorconst.cpp",
                "src/tables/colordata.cpp",
                "src/tables/wblists.cpp",
                "src/utils/curves.cpp",
                "src/utils/decoder_info.cpp",
                "src/utils/init_close_utils.cpp",
                "src/utils/open.cpp",
                "src/utils/phaseone_processing.cpp",
                "src/utils/read_utils.cpp",
                "src/utils/thumb_utils.cpp",
                "src/utils/utils_dcraw.cpp",
                "src/utils/utils_libraw.cpp",
                "src/write/apply_profile.cpp",
                "src/write/file_write.cpp",
                "src/write/tiff_writer.cpp",
                "src/x3f/x3f_parse_process.cpp",
                "src/x3f/x3f_utils_patched.cpp",
            ],
            publicHeadersPath: "libraw",
            cxxSettings: [.headerSearchPath("."), .define("USE_ZLIB"), .unsafeFlags(["-w"])],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Pictty's few calls into LibRaw.
        .target(name: "CLibRaw", dependencies: ["LibRaw"]),
        .target(name: "PicttyCore", dependencies: ["CLibRaw"], swiftSettings: optimised),
        .executableTarget(
            name: "Pictty",
            dependencies: ["PicttyCore"],
            swiftSettings: optimised + sparkle,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))]
        ),
        .testTarget(name: "PicttyCoreTests", dependencies: ["PicttyCore"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
