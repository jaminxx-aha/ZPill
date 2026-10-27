cmake_minimum_required(VERSION 3.5.0)
project(rawdecoder)

# LibRaw 0.22.3(LICENSE.LGPL/CDDL 双许可,见 libraw/ 内 LICENSE 文件)静态编入;
set(LIBRAW_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/libraw)
include_directories(${LIBRAW_ROOT})

set(LIBRAW_SOURCES
  libraw/src/decoders/canon_600.cpp
  libraw/src/decoders/crx.cpp
  libraw/src/decoders/decoders_dcraw.cpp
  libraw/src/decoders/decoders_libraw.cpp
  libraw/src/decoders/decoders_libraw_dcrdefs.cpp
  libraw/src/decoders/dng.cpp
  libraw/src/decoders/fp_dng.cpp
  libraw/src/decoders/fuji_compressed.cpp
  libraw/src/decoders/generic.cpp
  libraw/src/decoders/kodak_decoders.cpp
  libraw/src/decoders/load_mfbacks.cpp
  libraw/src/decoders/olympus14.cpp
  libraw/src/decoders/pana8.cpp
  libraw/src/decoders/smal.cpp
  libraw/src/decoders/sonycc.cpp
  libraw/src/decoders/unpack.cpp
  libraw/src/decoders/unpack_thumb.cpp
  libraw/src/decompressors/losslessjpeg.cpp
  libraw/src/demosaic/aahd_demosaic.cpp
  libraw/src/demosaic/ahd_demosaic.cpp
  libraw/src/demosaic/dcb_demosaic.cpp
  libraw/src/demosaic/dht_demosaic.cpp
  libraw/src/demosaic/misc_demosaic.cpp
  libraw/src/demosaic/xtrans_demosaic.cpp
  libraw/src/integration/dngsdk_glue.cpp
  libraw/src/integration/rawspeed_glue.cpp
  libraw/src/libraw_c_api.cpp
  libraw/src/libraw_datastream.cpp
  libraw/src/metadata/adobepano.cpp
  libraw/src/metadata/canon.cpp
  libraw/src/metadata/ciff.cpp
  libraw/src/metadata/cr3_parser.cpp
  libraw/src/metadata/epson.cpp
  libraw/src/metadata/exif_gps.cpp
  libraw/src/metadata/fuji.cpp
  libraw/src/metadata/hasselblad_model.cpp
  libraw/src/metadata/identify.cpp
  libraw/src/metadata/identify_tools.cpp
  libraw/src/metadata/kodak.cpp
  libraw/src/metadata/leica.cpp
  libraw/src/metadata/makernotes.cpp
  libraw/src/metadata/mediumformat.cpp
  libraw/src/metadata/minolta.cpp
  libraw/src/metadata/misc_parsers.cpp
  libraw/src/metadata/nikon.cpp
  libraw/src/metadata/normalize_model.cpp
  libraw/src/metadata/olympus.cpp
  libraw/src/metadata/p1.cpp
  libraw/src/metadata/pentax.cpp
  libraw/src/metadata/samsung.cpp
  libraw/src/metadata/sony.cpp
  libraw/src/metadata/tiff.cpp
  libraw/src/postprocessing/aspect_ratio.cpp
  libraw/src/postprocessing/dcraw_process.cpp
  libraw/src/postprocessing/mem_image.cpp
  libraw/src/postprocessing/postprocessing_aux.cpp
  libraw/src/postprocessing/postprocessing_utils.cpp
  libraw/src/postprocessing/postprocessing_utils_dcrdefs.cpp
  libraw/src/preprocessing/ext_preprocess.cpp
  libraw/src/preprocessing/raw2image.cpp
  libraw/src/preprocessing/subtract_black.cpp
  libraw/src/tables/cameralist.cpp
  libraw/src/tables/colorconst.cpp
  libraw/src/tables/colordata.cpp
  libraw/src/tables/wblists.cpp
  libraw/src/utils/curves.cpp
  libraw/src/utils/decoder_info.cpp
  libraw/src/utils/init_close_utils.cpp
  libraw/src/utils/open.cpp
  libraw/src/utils/phaseone_processing.cpp
  libraw/src/utils/read_utils.cpp
  libraw/src/utils/thumb_utils.cpp
  libraw/src/utils/utils_dcraw.cpp
  libraw/src/utils/utils_libraw.cpp
  libraw/src/write/apply_profile.cpp
  libraw/src/write/file_write.cpp
  libraw/src/write/tiff_writer.cpp
  libraw/src/x3f/x3f_parse_process.cpp
  libraw/src/x3f/x3f_utils_patched.cpp
)

# fdk-aac 2.0.2(Fraunhofer FDK AAC,NOTICE 见 libfdkaac/ 内许可文件)静态
# 编入:本机音频编码器仅 Vendor.AAC 且创建即败、无软编,MP4 muxer 又只
# 收 AAC 音轨 —— 导出有声 = 自带软编 AAC 的唯一通路(2026-10-25 实锤)。
file(GLOB FDKAAC_SOURCES
  libfdkaac/libAACenc/src/*.cpp
  libfdkaac/libSBRenc/src/*.cpp
  libfdkaac/libMpegTPEnc/src/*.cpp
  libfdkaac/libPCMutils/src/*.cpp
  libfdkaac/libSACenc/src/*.cpp
  libfdkaac/libFDK/src/*.cpp
  libfdkaac/libSYS/src/*.cpp
)
set(FDKAAC_INCLUDES
  ${CMAKE_CURRENT_SOURCE_DIR}/libfdkaac/libAACenc/include
  ${CMAKE_CURRENT_SOURCE_DIR}/libfdkaac/libFDK/include
  ${CMAKE_CURRENT_SOURCE_DIR}/libfdkaac/libSYS/include
  ${CMAKE_CURRENT_SOURCE_DIR}/libfdkaac/libMpegTPEnc/include
  ${CMAKE_CURRENT_SOURCE_DIR}/libfdkaac/libSBRenc/include
  ${CMAKE_CURRENT_SOURCE_DIR}/libfdkaac/libPCMutils/include
  ${CMAKE_CURRENT_SOURCE_DIR}/libfdkaac/libSACenc/include
)
add_library(rawdecoder SHARED
  napi_init.cpp
  video_lut.cpp
  ${LIBRAW_SOURCES}
  ${FDKAAC_SOURCES}
)
target_include_directories(rawdecoder PRIVATE ${FDKAAC_INCLUDES})
target_compile_definitions(rawdecoder PRIVATE
  USE_ZLIB
  LIBRAW_MAX_ALLOC_MB_DEFAULT=512
)
target_link_libraries(
  rawdecoder
  PUBLIC libz.so
         libace_napi.z.so
         libnative_media_core.so
         libnative_media_codecbase.so
         libnative_media_vdec.so
         libnative_media_venc.so
         libnative_media_acodec.so
         libnative_media_aenc.so
         libnative_media_avdemuxer.so
         libnative_media_avmuxer.so
         libnative_media_avsource.so)
