/**
 * LibRaw NEF/NRW 真解码 napi 模块(rawdecoder.so)。
 *
 * 契约(napi):`decodeToRgba(path: string, halfSize: boolean)`
 * → Promise<{width: number, height: number, data: Uint8Array(RGBA8888)}>。
 * 解码 = LibRaw 全管线(open→unpack→dcraw_process:相机白平衡/sRGB
 * /8bit/自动亮度,halfSize 走 superpixel 半尺寸免 demosaic 提速),
 * 调用方(RawDecodePlugin.ets)拿 RGBA 后 createPixelMap →
 * ImagePacker 出 JPEG,与 HIF 路同一压缩出口。
 *
 * - 重活全在 napi 异步工作线程(libuv 池),JS 线程零阻塞;
 * - 同一时刻仅一个解码在途(C++ 侧原子闸兜底:通道本身单飞,这里是
 *   防御,双开直接 throw busy);
 * - 失败经 Promise reject(String 错误码:阶段:LIBRAW 错误值)。
 *
 * LibRaw 0.22.3(LICENSE.LGPL/CDDL 双许可)静态编入本 .so,源码见
 * libraw/ 子目录(显式清单见 CMakeLists.txt)。
 */
#include "napi/native_api.h"

#include "libraw/libraw.h"

#include <atomic>
#include <chrono>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <vector>

/** video_lut.cpp 提供(全局链接,勿放匿名空间)。 */
void RegisterVideoLut(napi_env env, napi_value exports);

namespace {

/** 在途闸:通道虽单飞,防御并发调用(双开即 throw busy)。 */
std::atomic<bool> g_busy{false};

/** 手机端硬边界:相机 RAW 再大也不应让解析器拿到进程级内存耗尽。 */
constexpr unsigned kMaxRawMemoryMb = 512;
constexpr uint64_t kMaxSourcePixels = 256ULL * 1024ULL * 1024ULL;
constexpr uint64_t kMaxOutputPixels = 32ULL * 1024ULL * 1024ULL;

/** 解码载荷:入参与出产,execute(工作线程)/complete(JS 线程)接力。 */
struct DecodeJob {
    std::string path;
    bool halfSize = true;
    bool ok = false;
    std::string error;
    int width = 0;
    int height = 0;
    std::string ms; // 分段耗时(调试用):open/unpack/process
    std::vector<uint8_t> rgba;
};

/** 异步工作外壳:载荷 + deferred/work 句柄。 */
struct Carrier {
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    DecodeJob job;
};

/** LibRaw 真解码:文件 → RGBA8888。返回 false 时 err 带阶段+错误码。 */
bool DecodeToRgba(const std::string &path, bool halfSize,
                  std::vector<uint8_t> &out, int &width, int &height,
                  std::string &err, std::string &ms) {
    using clock = std::chrono::steady_clock;
    const auto t0 = clock::now();
    auto lap = [&t0, &ms](const char *tag) {
        const auto now = clock::now();
        ms += std::string(tag) + "=" +
              std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(
                                 now - t0)
                                 .count()) +
              "ms ";
    };
    try {
        LibRaw r;
        r.imgdata.rawparams.max_raw_memory_mb = kMaxRawMemoryMb;
        // 显影参数:相机白平衡 + sRGB + 8bit + 自动亮度;halfSize 走
        // superpixel(2×2 合一,免 demosaic,~1/4 像素量,长边减半仍罩
        // 2560 观看档)。
        r.imgdata.params.use_camera_wb = 1;
        r.imgdata.params.output_bps = 8;
        r.imgdata.params.output_color = 1; // sRGB
        r.imgdata.params.no_auto_bright = 0;
        if (halfSize) {
            r.imgdata.params.half_size = 1;
        }
        int ret = r.open_file(path.c_str());
        if (ret != LIBRAW_SUCCESS) {
            err = "open:" + std::to_string(ret);
            return false;
        }
        const uint64_t sourcePixels =
            static_cast<uint64_t>(r.imgdata.sizes.raw_width) *
            static_cast<uint64_t>(r.imgdata.sizes.raw_height);
        if (sourcePixels == 0 || sourcePixels > kMaxSourcePixels) {
            err = "open:size-limit";
            return false;
        }
        lap("open");
        ret = r.unpack();
        if (ret != LIBRAW_SUCCESS) {
            err = "unpack:" + std::to_string(ret);
            return false;
        }
        lap("unpack");
        ret = r.dcraw_process();
        if (ret != LIBRAW_SUCCESS) {
            err = "process:" + std::to_string(ret);
            return false;
        }
        lap("process");

        int outWidth = 0;
        int outHeight = 0;
        int outColors = 0;
        int outBits = 0;
        r.get_mem_image_format(&outWidth, &outHeight, &outColors, &outBits);
        if (outWidth <= 0 || outHeight <= 0 || outColors != 3 ||
            outBits != 8) {
            err = "output:format";
            return false;
        }
        const uint64_t outputPixels =
            static_cast<uint64_t>(outWidth) *
            static_cast<uint64_t>(outHeight);
        const uint64_t maxSizeTPixels =
            static_cast<uint64_t>(std::numeric_limits<size_t>::max() / 4);
        if (outputPixels == 0 || outputPixels > kMaxOutputPixels ||
            outputPixels > maxSizeTPixels) {
            err = "output:size-limit";
            return false;
        }

        int memErr = 0;
        std::unique_ptr<libraw_processed_image_t,
                        decltype(&libraw_dcraw_clear_mem)>
            img(r.dcraw_make_mem_image(&memErr), &libraw_dcraw_clear_mem);
        if (!img) {
            err = "mem_image:" + std::to_string(memErr);
            return false;
        }
        const uint64_t expectedRgbBytes = outputPixels * 3ULL;
        if (img->type != LIBRAW_IMAGE_BITMAP || img->colors != 3 ||
            img->bits != 8 || img->width != outWidth ||
            img->height != outHeight ||
            static_cast<uint64_t>(img->data_size) != expectedRgbBytes) {
            err = "output:data";
            return false;
        }

        width = outWidth;
        height = outHeight;
        out.resize(static_cast<size_t>(outputPixels) * 4);
        const uint8_t *src = img->data; // RGB888 打平
        for (size_t i = 0; i < outputPixels; i++) {
            out[i * 4] = src[i * 3];
            out[i * 4 + 1] = src[i * 3 + 1];
            out[i * 4 + 2] = src[i * 3 + 2];
            out[i * 4 + 3] = 255;
        }
        lap("mem");
        return true;
    } catch (const std::bad_alloc &) {
        err = "exception:alloc";
        return false;
    } catch (const std::exception &) {
        err = "exception:std";
        return false;
    } catch (...) {
        err = "exception:unknown";
        return false;
    }
}

/** 工作线程:纯解码,不碰 napi。 */
void ExecuteDecode(napi_env env, void *data) {
    auto *carrier = static_cast<Carrier *>(data);
    carrier->job.ok =
        DecodeToRgba(carrier->job.path, carrier->job.halfSize,
                     carrier->job.rgba, carrier->job.width, carrier->job.height,
                     carrier->job.error, carrier->job.ms);
}

/** JS 线程收口:成功建 {width,height,data} resolve,失败 reject。 */
void CompleteDecode(napi_env env, napi_status status, void *data) {
    auto *carrier = static_cast<Carrier *>(data);
    if (carrier->job.ok) {
        napi_value obj;
        napi_create_object(env, &obj);
        napi_value w;
        napi_create_int32(env, carrier->job.width, &w);
        napi_value h;
        napi_create_int32(env, carrier->job.height, &h);
        const size_t bytes = carrier->job.rgba.size();
        void *copy = nullptr;
        napi_value dataArr;
        napi_create_arraybuffer(env, bytes, &copy, &dataArr);
        if (copy != nullptr && bytes > 0) {
            memcpy(copy, carrier->job.rgba.data(), bytes);
        }
        napi_create_typedarray(env, napi_uint8_array, bytes, dataArr, 0,
                               &dataArr);
        napi_set_named_property(env, obj, "width", w);
        napi_set_named_property(env, obj, "height", h);
        napi_set_named_property(env, obj, "data", dataArr);
        napi_value ms;
        napi_create_string_utf8(env, carrier->job.ms.c_str(),
                                carrier->job.ms.size(), &ms);
        napi_set_named_property(env, obj, "ms", ms);
        napi_resolve_deferred(env, carrier->deferred, obj);
    } else {
        napi_value msg;
        napi_create_string_utf8(env, carrier->job.error.c_str(),
                                carrier->job.error.size(), &msg);
        napi_value err;
        napi_create_error(env, nullptr, msg, &err);
        napi_reject_deferred(env, carrier->deferred, err);
    }
    napi_delete_async_work(env, carrier->work);
    g_busy.store(false);
    delete carrier;
}

/** 入口:decodeToRgba(path: string, halfSize: boolean) → Promise。 */
napi_value DecodeToRgba(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, "bad_args", "decodeToRgba 需要 (path, halfSize)");
        return nullptr;
    }
    char pathBuf[4096];
    size_t pathLen = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &pathLen);
    if (pathLen >= sizeof(pathBuf)) {
        napi_throw_error(env, "bad_args", "path 过长");
        return nullptr;
    }
    napi_get_value_string_utf8(env, argv[0], pathBuf, sizeof(pathBuf),
                               &pathLen);
    bool halfSize = false;
    napi_get_value_bool(env, argv[1], &halfSize);

    bool expected = false;
    if (!g_busy.compare_exchange_strong(expected, true)) {
        napi_throw_error(env, "busy", "已有解码在途");
        return nullptr;
    }

    auto *carrier = new Carrier();
    carrier->job.path = std::string(pathBuf, pathLen);
    carrier->job.halfSize = halfSize;

    napi_value pname;
    napi_create_string_utf8(env, "libraw-decode", NAPI_AUTO_LENGTH, &pname);
    napi_value resource;
    napi_create_object(env, &resource);
    napi_value promise;
    if (napi_create_promise(env, &carrier->deferred, &promise) != napi_ok ||
        napi_create_async_work(env, nullptr, pname, ExecuteDecode,
                               CompleteDecode, carrier, &carrier->work) !=
            napi_ok) {
        g_busy.store(false);
        delete carrier;
        napi_throw_error(env, "setup_failed", "异步工作创建失败");
        return nullptr;
    }
    napi_queue_async_work(env, carrier->work);
    return promise;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"decodeToRgba", nullptr, DecodeToRgba, nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    napi_define_properties(env, exports,
                           sizeof(desc) / sizeof(desc[0]), desc);
    RegisterVideoLut(env, exports);
    return exports;
}

napi_module g_rawdecoderModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "rawdecoder",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterRawDecoderModule(void) {
    napi_module_register(&g_rawdecoderModule);
}

} // namespace
