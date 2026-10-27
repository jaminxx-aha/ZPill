/**
 * ohos 视频 LUT 导出(rawdecoder.so 内,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/video_lut_export.dart(`nikonpill/video_lut`):
 * 本地视频 + 3D LUT(Float32 N³×4 RGBA 红最快)→ 烘焙 MP4 临时档。
 * iOS = AVVideoComposition 内嵌 CIColorCube;Android = Media3
 * Transformer SingleColorLut;ohos 无带颜色钩子的转码 API(AVTranscoder
 * 只有 rotation)→ **全 buffer 模式管线**:
 *
 *   OH_AVSource/OH_AVDemuxer(选轨)→ OH_VideoDecoder(buffer,NV12)
 *   → CPU 行并行 3D-LUT 上色(BT.709 limited 域进出,八角三线性)
 *   → OH_VideoEncoder(buffer,NV12,H.264)
 *   → OH_AVMuxer(MPEG_4);音频轨 AAC 逐样直通拷贝不重编。
 *
 * - 进度:napi 侧 g_lutProgress 0-100,ArkTS 每 250ms 轮询后经通道
 *   onProgress 反向调用 Dart(契约同 iOS/Android);
 * - 取消:g_lutCancel 原子位,逐帧检查,中断即 reject("cancelled");
 * - 同一时刻仅一个导出在途(g_lutBusy)。
 *
 * 坑位备查:napi promise 参数序 (env,&deferred,&promise);buffer 模式
 * 解码输出带 stride(取自输出 format),处理时读旧 stride 写紧凑
 * encoder stride;width/height 与 MIME 从源轨 format 拷贝;ROTATION
 * 原样带到 muxer 轨。
 */
#include "napi/native_api.h"

#include "aacenc_lib.h"

#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/avcodec_audio_channel_layout.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_audioencoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include <multimedia/player_framework/native_avsource.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

std::atomic<bool> g_lutBusy{false};
std::atomic<bool> g_lutCancel{false};
std::atomic<int> g_lutProgress{0};

constexpr int32_t kMaxVideoDimension = 8192;
constexpr int64_t kMaxVideoPixels = 64LL * 1024 * 1024;
constexpr int32_t kMaxTrackCount = 256;
constexpr int32_t kMaxAudioChannels = 8;
constexpr int32_t kMinAudioSampleRate = 8000;
constexpr int32_t kMaxAudioSampleRate = 384000;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

/** 线程安全索引/缓冲队列(codec 回调线程 ↔ 导出线程)。 */
struct BufQueue {
    std::mutex m;
    std::condition_variable cv;
    std::vector<std::pair<uint32_t, OH_AVBuffer *>> items;
    int64_t waitMs = 0;

    void Push(uint32_t index, OH_AVBuffer *buffer) {
        {
            std::lock_guard<std::mutex> lk(m);
            items.push_back({index, buffer});
        }
        cv.notify_one();
    }

    /** 非阻塞取:空即 false(主循环泵送模型专用,勿阻塞)。 */
    bool TryPop(uint32_t &index, OH_AVBuffer *&buffer) {
        std::lock_guard<std::mutex> lk(m);
        if (items.empty()) {
            return false;
        }
        index = items.front().first;
        buffer = items.front().second;
        items.erase(items.begin());
        return true;
    }
};

/** clamp 0-255。 */
inline uint8_t Clamp8(float v) {
    return static_cast<uint8_t>(std::min(255.0f, std::max(0.0f, v + 0.5f)));
}

/** 面包屑(诊断):追加进沙盒 cache 固定文件,崩溃后重启可读上屏。 */
void Breadcrumb(const std::string &tag) {
    FILE *f = fopen("/data/storage/el2/base/haps/entry/cache/lut_bc.txt", "a");
    if (f != nullptr) {
        const auto now = std::chrono::steady_clock::now().time_since_epoch();
        fprintf(f, "%lldms %s\n",
                static_cast<long long>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(now)
                        .count()),
                tag.c_str());
        fclose(f);
    }
}

/** 三线性采样:红最快布局 idx = ((b*N + g)*N + r)*4。 */
void SampleCube(const std::vector<float> &cube, int n, float r, float g,
                float b, float out[3]) {
    const float maxIdx = static_cast<float>(n - 1);
    r = std::min(maxIdx, std::max(0.0f, r * maxIdx));
    g = std::min(maxIdx, std::max(0.0f, g * maxIdx));
    b = std::min(maxIdx, std::max(0.0f, b * maxIdx));
    const int r0 = static_cast<int>(r);
    const int g0 = static_cast<int>(g);
    const int b0 = static_cast<int>(b);
    const int r1 = std::min(r0 + 1, n - 1);
    const int g1 = std::min(g0 + 1, n - 1);
    const int b1 = std::min(b0 + 1, n - 1);
    const float fr = r - r0;
    const float fg = g - g0;
    const float fb = b - b0;
    const float c000[3] = {cube[((b0 * n + g0) * n + r0) * 4],
                           cube[((b0 * n + g0) * n + r0) * 4 + 1],
                           cube[((b0 * n + g0) * n + r0) * 4 + 2]};
    const float c100[3] = {cube[((b0 * n + g0) * n + r1) * 4],
                           cube[((b0 * n + g0) * n + r1) * 4 + 1],
                           cube[((b0 * n + g0) * n + r1) * 4 + 2]};
    const float c010[3] = {cube[((b0 * n + g1) * n + r0) * 4],
                           cube[((b0 * n + g1) * n + r0) * 4 + 1],
                           cube[((b0 * n + g1) * n + r0) * 4 + 2]};
    const float c110[3] = {cube[((b0 * n + g1) * n + r1) * 4],
                           cube[((b0 * n + g1) * n + r1) * 4 + 1],
                           cube[((b0 * n + g1) * n + r1) * 4 + 2]};
    const float c001[3] = {cube[((b1 * n + g0) * n + r0) * 4],
                           cube[((b1 * n + g0) * n + r0) * 4 + 1],
                           cube[((b1 * n + g0) * n + r0) * 4 + 2]};
    const float c101[3] = {cube[((b1 * n + g0) * n + r1) * 4],
                           cube[((b1 * n + g0) * n + r1) * 4 + 1],
                           cube[((b1 * n + g0) * n + r1) * 4 + 2]};
    const float c011[3] = {cube[((b1 * n + g1) * n + r0) * 4],
                           cube[((b1 * n + g1) * n + r0) * 4 + 1],
                           cube[((b1 * n + g1) * n + r0) * 4 + 2]};
    const float c111[3] = {cube[((b1 * n + g1) * n + r1) * 4],
                           cube[((b1 * n + g1) * n + r1) * 4 + 1],
                           cube[((b1 * n + g1) * n + r1) * 4 + 2]};
    for (int ch = 0; ch < 3; ch++) {
        const float c00 = c000[ch] + (c100[ch] - c000[ch]) * fr;
        const float c10 = c010[ch] + (c110[ch] - c010[ch]) * fr;
        const float c01 = c001[ch] + (c101[ch] - c001[ch]) * fr;
        const float c11 = c011[ch] + (c111[ch] - c011[ch]) * fr;
        const float c0 = c00 + (c10 - c00) * fg;
        const float c1 = c01 + (c11 - c01) * fg;
        out[ch] = c0 + (c1 - c0) * fb;
    }
}

/**
 * 帧上色:读解码面(P010 10-bit 或 NV12 8-bit,按 stride 探测)→
 * BT.709 limited → RGB → 线性域 3D-LUT(trilinear)→ RGB → 写 8-bit
 * NV12(紧凑 stride = width,编码器输入)。行并行。
 *
 * **应用域定案(2026-10-25 Mac CI 镜像实证)**:iOS CIColorCube 在
 * CoreImage 工作空间(≈ γ1.76 纯幂律对)套 cube,不是 gamma 直套——
 * G×0.5 cube 的数据域斜率实测 0.677(= 0.5^(1/1.775)),G×0.25 实测
 * 0.450;R/B 恒等斜率 0.999。此处以 γ=1.76 幂律对查表线性化,与 CI
 * 的残差 <1%(两档 cube 斜率偏差 0.002/0.005)。
 *
 * **NV12 索引定案(2026-10-24 SEGV 实锤)**:UV 平面每行 = width 字节
 * (每 2×2 块一对 U+V 各 1 字节),按 luma 列逐点写 2 字节会越界 2 倍
 * (UV 尾行冲出 buffer ~3.8KB → SIGSEGV)。色度必须 x/2 配对:偶列写
 * uvOut[x]、uvOut[x+1]。10-bit 输入 = P010(stride=2×width,本机解码器
 * fmt 恒报 NV12 不可信):word>>8 = 10-bit 值÷4 = 8-bit 等效,直接落
 * 8-bit limited 域(Y∈[16,235] C∈[16,240])与 8-bit 路共公式;UV 平面
 * 起点在 stride×对齐高(2160 实测 2176,见 decPlaneHeight)。
 */
void ApplyLutFrame(const uint8_t *ySrc, int yStride, const uint8_t *uvSrc,
                   int uvStride, bool tenBit, uint8_t *yDst, int dstStride,
                   uint8_t *uvDst, int dstUvStride, int w, int h,
                   const std::vector<float> &cube, int n) {
    // 幂律对查表:数据域 [0,1] ↔ 线性域。查表必须线性插值——线性域
    // 上再量化一格 = 数据域暗部一大步(encTab[0]→[1] = 0→0.043 实测
    // identity 均值 G −7.7%),插值后 roundtrip 残差 ~1e-4。
    // γ=1.97:Mac CI 镜像双探针标定(×0.5→斜率 0.7037→γ1.973,
    // ×0.25→0.4939→γ1.965,纯幂律自洽;Python 直测 raw 帧)。
    constexpr float kGamma = 1.97f;
    const float kInvGamma = 1.0f / kGamma;
    float linTab[257];
    float encTab[257];
    for (int i = 0; i <= 256; i++) {
        linTab[i] = std::pow(i / 255.0f, kGamma);
        encTab[i] = std::pow(i / 255.0f, kInvGamma);
    }
    auto tableLerp = [](const float *tab, float v) {
        v = std::min(1.0f, std::max(0.0f, v)) * 255.0f;
        const int i = static_cast<int>(v);
        if (i >= 255) {
            return tab[255];
        }
        return tab[i] + (tab[i + 1] - tab[i]) * (v - i);
    };
    auto toLin = [&](float v) { return tableLerp(linTab, v); };
    auto toData = [&](float v) { return tableLerp(encTab, v); };
    const unsigned threads =
        std::min(8u, std::max(1u, std::thread::hardware_concurrency()));
    std::atomic<int> row{0};
    auto worker = [&]() {
        for (;;) {
            const int y = row.fetch_add(1);
            if (y >= h) {
                return;
            }
            const uint8_t *yRow = ySrc + static_cast<size_t>(y) * yStride;
            const uint8_t *uvRow =
                uvSrc + static_cast<size_t>(y / 2) * uvStride;
            uint8_t *yOut = yDst + static_cast<size_t>(y) * dstStride;
            uint8_t *uvOut = uvDst + static_cast<size_t>(y / 2) * dstUvStride;
            for (int x = 0; x + 1 < w; x += 2) {
                // 2×2 块:一对色度供两个 luma 像素
                float ys[2] = {0.0f, 0.0f};
                float cb = 0.0f;
                float cr = 0.0f;
                if (tenBit) {
                    // P010(高 10 位有效):word>>8 = 10-bit 值÷4 = 8-bit
                    // 等效值,直接落 8-bit limited 域与下方共用公式
                    //(旧式 (word>>6−64)/876 把 [0,1] 的 luma 配进 8-bit
                    // 系数公式,白场塌到 0.005,全黑)
                    const auto yp0 =
                        reinterpret_cast<const uint16_t *>(yRow +
                                                           (size_t)x * 2);
                    const auto up =
                        reinterpret_cast<const uint16_t *>(uvRow +
                                                           (size_t)x * 2);
                    ys[0] = static_cast<float>((*yp0 >> 8) - 16);
                    ys[1] = static_cast<float>((*(yp0 + 1) >> 8) - 16);
                    cb = static_cast<float>((*up >> 8)) - 128.0f;
                    cr = static_cast<float>((*(up + 1) >> 8)) - 128.0f;
                } else {
                    ys[0] = static_cast<float>(yRow[x] - 16);
                    ys[1] = static_cast<float>(yRow[x + 1] - 16);
                    cb = static_cast<float>(uvRow[x]) - 128.0f;
                    cr = static_cast<float>(uvRow[x + 1]) - 128.0f;
                }
                float rMean = 0.0f;
                float gMean = 0.0f;
                float bMean = 0.0f;
                for (int dx = 0; dx < 2; dx++) {
                    // BT.709 limited → RGB 0-1(0.2132 配 Cb、0.5329 配
                    // Cr——此前两者交叉,identity 的 G 都系统性漂移)
                    float r = (1.1644f * ys[dx] + 1.7927f * cr) / 255.0f;
                    float g =
                        (1.1644f * ys[dx] - 0.2132f * cb - 0.5329f * cr) /
                        255.0f;
                    float b = (1.1644f * ys[dx] + 2.1124f * cb) / 255.0f;
                    float out[3];
                    // 线性域套 cube(CI 语义):数据域 → γ1.76 幂律线性
                    // → trilinear → 幂律回数据域
                    float lin[3] = {toLin(r), toLin(g), toLin(b)};
                    SampleCube(cube, n, lin[0], lin[1], lin[2], out);
                    out[0] = toData(out[0]);
                    out[1] = toData(out[1]);
                    out[2] = toData(out[2]);
                    // RGB 0-1 → BT.709 limited Y/UV(与读端同矩阵互逆;
                    // 旧系数 65.481/128.553/24.966 是 BT.601 的 219×
                    // {.299,.587,.114},配 709 读端 = 往返系统性暗化偏色)
                    yOut[x + dx] = Clamp8(
                        16.0f + 46.559f * out[0] + 156.629f * out[1] +
                        15.812f * out[2]);
                    rMean += out[0];
                    gMean += out[1];
                    bMean += out[2];
                }
                rMean *= 0.5f;
                gMean *= 0.5f;
                bMean *= 0.5f;
                uvOut[x] = Clamp8(128.0f - 25.664f * rMean - 86.334f * gMean +
                                  112.0f * bMean);
                uvOut[x + 1] = Clamp8(128.0f + 112.0f * rMean -
                                      101.732f * gMean - 10.270f * bMean);
            }
        }
    };
    std::vector<std::thread> pool;
    for (unsigned i = 1; i < threads; i++) {
        pool.emplace_back(worker);
    }
    worker();
    for (auto &t : pool) {
        t.join();
    }
}

// ---------------------------------------------------------------------------
// 管线
// ---------------------------------------------------------------------------

/** codec 回调队列载体。 */
struct Pipeline {
    BufQueue decIn;
    BufQueue decOut;
    BufQueue encIn;
    BufQueue encOut;
    const void *decoder = nullptr; // 回调归属判别用
    const void *encoder = nullptr;
};

void OnDecNeedInput(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer,
                    void *userData) {
    static_cast<Pipeline *>(userData)->decIn.Push(index, buffer);
}
void OnDecNewOutput(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer,
                    void *userData) {
    static_cast<Pipeline *>(userData)->decOut.Push(index, buffer);
}
void OnEncNeedInput(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer,
                    void *userData) {
    static_cast<Pipeline *>(userData)->encIn.Push(index, buffer);
}
void OnEncNewOutput(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer,
                    void *userData) {
    static_cast<Pipeline *>(userData)->encOut.Push(index, buffer);
}
void OnCodecStreamChanged(OH_AVCodec *codec, OH_AVFormat *format,
                          void *userData) {
    auto *p = static_cast<Pipeline *>(userData);
    if (format == nullptr) {
        return;
    }
    std::string dump = "stream_changed";
    dump += p->encoder == codec ? " enc" : " dec";
    // 抽关键项进面包屑(编码器输入格式 = stride/像素格式定案点)
    int32_t stride = 0;
    int32_t pixFmt = -1;
    int32_t w = 0;
    int32_t h = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_STRIDE, &stride);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, &pixFmt);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &w);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &h);
    dump += " s=" + std::to_string(stride) + " fmt=" + std::to_string(pixFmt) +
            " " + std::to_string(w) + "x" + std::to_string(h);
    Breadcrumb(dump.c_str());
}
void OnCodecError(OH_AVCodec *, int32_t code, void *userData) {
    // 错误经主循环的队列枯竭/返回码收口,这里只留痕。
    (void)code;
    (void)userData;
}

struct RunResult {
    bool ok = false;
    std::string error;
};

/** 主体:解封装 → 硬解 → LUT → 硬编 → 混流(音频直通)。 */
RunResult RunLutExport(const std::string &path, const std::string &outPath,
                       const std::vector<float> &cube, int cubeN) {
    RunResult result;
    const int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        result.error = "open_src";
        return result;
    }
    const int outFd = open(outPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (outFd < 0) {
        close(fd);
        result.error = "open_out";
        return result;
    }

    Breadcrumb("start");
    OH_AVSource *source = nullptr;
    OH_AVDemuxer *demuxer = nullptr;
    OH_AVCodec *decoder = nullptr;
    OH_AVCodec *encoder = nullptr;
    OH_AVMuxer *muxer = nullptr;
    Pipeline pipeline;
    auto fail = [&](const std::string &stage) {
        result.error = stage;
        if (muxer != nullptr) {
            OH_AVMuxer_Destroy(muxer);
            muxer = nullptr;
        }
        if (encoder != nullptr) {
            OH_VideoEncoder_Destroy(encoder);
            encoder = nullptr;
        }
        if (decoder != nullptr) {
            OH_VideoDecoder_Destroy(decoder);
            decoder = nullptr;
        }
        if (demuxer != nullptr) {
            OH_AVDemuxer_Destroy(demuxer);
            demuxer = nullptr;
        }
        if (source != nullptr) {
            OH_AVSource_Destroy(source);
            source = nullptr;
        }
        close(fd);
        close(outFd);
        return result;
    };

    int64_t fileSize = 0;
    struct stat st{};
    if (fstat(fd, &st) == 0) {
        fileSize = st.st_size;
    }
    source = OH_AVSource_CreateWithFD(fd, 0, fileSize);
    if (source == nullptr) {
        return fail("create_source");
    }
    Breadcrumb("source_ok");
    demuxer = OH_AVDemuxer_CreateWithSource(source);
    if (demuxer == nullptr) {
        return fail("create_demuxer");
    }
    OH_AVFormat *srcFmt = OH_AVSource_GetSourceFormat(source);
    int64_t durationUs = 0;
    if (srcFmt != nullptr) {
        OH_AVFormat_GetLongValue(srcFmt, OH_MD_KEY_DURATION, &durationUs);
        OH_AVFormat_Destroy(srcFmt);
    }
    int32_t trackCount = 0;
    OH_AVFormat *srcFmt2 = OH_AVSource_GetSourceFormat(source);
    if (srcFmt2 != nullptr) {
        OH_AVFormat_GetIntValue(srcFmt2, OH_MD_KEY_TRACK_COUNT, &trackCount);
        OH_AVFormat_Destroy(srcFmt2);
    }
    if (trackCount <= 0 || trackCount > kMaxTrackCount) {
        return fail("track_count");
    }
    if (durationUs < 0) {
        durationUs = 0;
    }

    Breadcrumb("demuxer_ok");
    // 选轨:按 mime 前缀分(勿按 track 序号猜)。
    int32_t vTrack = -1;
    int32_t aTrack = -1;
    int32_t vWidth = 0;
    int32_t vHeight = 0;
    int64_t vBitrate = 8'000'000;
    float vFps = 30.0f;
    float vRotation = 0.0f;
    std::string vMime;
    int32_t aChannels = 2;
    int32_t aSampleRate = 48000;
    int64_t aBitrate = 128000;
    std::string aMime;
    int32_t aSrcFmt = SAMPLE_S16LE;
    for (int32_t i = 0; i < trackCount; i++) {
        OH_AVFormat *tf = OH_AVSource_GetTrackFormat(source, i);
        if (tf == nullptr) {
            continue;
        }
        const char *mime = nullptr;
        OH_AVFormat_GetStringValue(tf, OH_MD_KEY_CODEC_MIME, &mime);
        if (mime != nullptr && vTrack < 0 && strncmp(mime, "video/", 6) == 0) {
            vTrack = i;
            vMime = mime;
            OH_AVFormat_GetIntValue(tf, OH_MD_KEY_WIDTH, &vWidth);
            OH_AVFormat_GetIntValue(tf, OH_MD_KEY_HEIGHT, &vHeight);
            OH_AVFormat_GetLongValue(tf, OH_MD_KEY_BITRATE, &vBitrate);
            double fpsD = 0;
            if (OH_AVFormat_GetDoubleValue(tf, OH_MD_KEY_FRAME_RATE, &fpsD)) {
                vFps = static_cast<float>(fpsD);
            } else if (OH_AVFormat_GetFloatValue(tf, OH_MD_KEY_FRAME_RATE,
                                                 &vFps)) {
                // 兼容:个别轨以 float 存
            }
            OH_AVFormat_GetFloatValue(tf, OH_MD_KEY_ROTATION, &vRotation);
        } else if (mime != nullptr && aTrack < 0 &&
                   strncmp(mime, "audio/", 6) == 0) {
            aTrack = i;
            aMime = mime;
            OH_AVFormat_GetIntValue(tf, OH_MD_KEY_AUD_CHANNEL_COUNT, &aChannels);
            OH_AVFormat_GetIntValue(tf, OH_MD_KEY_AUD_SAMPLE_RATE, &aSampleRate);
            OH_AVFormat_GetLongValue(tf, OH_MD_KEY_BITRATE, &aBitrate);
            // PCM 位宽:轨 format 缺该键时按 Zf 实况默认 S24LE(面包屑留痕)
            if (!OH_AVFormat_GetIntValue(tf, OH_MD_KEY_AUDIO_SAMPLE_FORMAT,
                                        &aSrcFmt)) {
                aSrcFmt = SAMPLE_S24LE;
            }
        }
        OH_AVFormat_Destroy(tf);
    }
    if (vTrack < 0 || vWidth <= 0 || vHeight <= 0 ||
        vWidth > kMaxVideoDimension || vHeight > kMaxVideoDimension ||
        static_cast<int64_t>(vWidth) * vHeight > kMaxVideoPixels) {
        return fail("no_video_track");
    }
    if (!std::isfinite(vFps) || vFps < 1.0f || vFps > 240.0f) {
        vFps = 30.0f;
    }
    if (!std::isfinite(vRotation) || vRotation < -3600.0f ||
        vRotation > 3600.0f) {
        vRotation = 0.0f;
    }
    vBitrate = std::min<int64_t>(200'000'000,
                                 std::max<int64_t>(1'000'000, vBitrate));
    aBitrate = std::min<int64_t>(512'000,
                                 std::max<int64_t>(32'000, aBitrate));
    if (aChannels < 1 || aChannels > kMaxAudioChannels) {
        aChannels = 2;
    }
    if (aSampleRate < kMinAudioSampleRate ||
        aSampleRate > kMaxAudioSampleRate) {
        aSampleRate = 48000;
    }
    // 选轨后才能 ReadSample(demuxer 不选轨读样必败)
    OH_AVDemuxer_SelectTrackByID(demuxer, static_cast<uint32_t>(vTrack));
    if (aTrack >= 0) {
        OH_AVDemuxer_SelectTrackByID(demuxer, static_cast<uint32_t>(aTrack));
    }
    const double estimatedFrames = durationUs * vFps / 1000000.0;
    const int64_t estFrames =
        estimatedFrames >= static_cast<double>(INT64_MAX)
            ? INT64_MAX
            : static_cast<int64_t>(std::max(0.0, estimatedFrames));
    const int64_t sourcePixels =
        static_cast<int64_t>(vWidth) * static_cast<int64_t>(vHeight);
    const int64_t sourceFrameBytes = sourcePixels * 3 / 2;

    // 解码器(buffer 模式,NV12 出)。
    Breadcrumb(("tracks v=" + std::to_string(vWidth) + "x" + std::to_string(vHeight) + " mime=" + vMime + " fps=" + std::to_string(vFps) +
                (aTrack >= 0 ? " a=" + aMime + " fmt=" + std::to_string(aSrcFmt) + " rate=" + std::to_string(aSampleRate) : ""))
                   .c_str());
    decoder = OH_VideoDecoder_CreateByMime(vMime.c_str());
    if (decoder == nullptr) {
        return fail("create_decoder");
    }
    pipeline.decoder = decoder;
    OH_AVCodecCallback decCb = {OnCodecError, OnCodecStreamChanged,
                                OnDecNeedInput, OnDecNewOutput};
    OH_VideoDecoder_RegisterCallback(decoder, decCb, &pipeline);
    OH_AVFormat *decFmt = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(decFmt, OH_MD_KEY_WIDTH, vWidth);
    OH_AVFormat_SetIntValue(decFmt, OH_MD_KEY_HEIGHT, vHeight);
    OH_AVFormat_SetIntValue(decFmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    // 4K 关键帧可超默认容量:读样直写解码输入 buffer,容量不足即越界
    OH_AVFormat_SetIntValue(
        decFmt, OH_MD_KEY_MAX_INPUT_SIZE,
        static_cast<int32_t>(std::max<int64_t>(4 << 20, sourceFrameBytes)));
    if (OH_VideoDecoder_Configure(decoder, decFmt) != AV_ERR_OK) {
        OH_AVFormat_Destroy(decFmt);
        return fail("config_decoder");
    }
    OH_AVFormat_Destroy(decFmt);
    Breadcrumb("decoder_configured");
    if (OH_VideoDecoder_Start(decoder) != AV_ERR_OK) {
        return fail("start_decoder");
    }

    // 混流器:视频轨(H.264)+ 音频轨直通。
    Breadcrumb("decoder_started");
    muxer = OH_AVMuxer_Create(outFd, AV_OUTPUT_FORMAT_MPEG_4);
    if (muxer == nullptr) {
        return fail("create_muxer");
    }
    OH_AVFormat *mvFmt = OH_AVFormat_Create();
    OH_AVFormat_SetStringValue(mvFmt, OH_MD_KEY_CODEC_MIME,
                               OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    OH_AVFormat_SetIntValue(mvFmt, OH_MD_KEY_WIDTH, vWidth);
    OH_AVFormat_SetIntValue(mvFmt, OH_MD_KEY_HEIGHT, vHeight);
    OH_AVFormat_SetLongValue(mvFmt, OH_MD_KEY_BITRATE, vBitrate);
    OH_AVFormat_SetFloatValue(mvFmt, OH_MD_KEY_FRAME_RATE, vFps);
    if (vRotation != 0.0f) {
        OH_AVFormat_SetFloatValue(mvFmt, OH_MD_KEY_ROTATION, vRotation);
    }
    int32_t mvIdx = -1;
    if (OH_AVMuxer_AddTrack(muxer, &mvIdx, mvFmt) != AV_ERR_OK) {
        OH_AVFormat_Destroy(mvFmt);
        return fail("muxer_add_video");
    }
    OH_AVFormat_Destroy(mvFmt);

    // 音轨准备:AAC 源直通;PCM 源(Zf lpcm)经 fdk-aac 软编 AAC ——
    // 本机音频编码器仅 Vendor.AAC 且创建即败、无软编候选,MP4 muxer
    // 又只收 AAC 轨(flc/opus/pcm 轨全拒,2026-10-25 实锤)= 自带软编
    // 是唯一有声通路。读样仍须与视频交错(demuxer 读游标共享)。
    HANDLE_AACENCODER audEnc = nullptr; // fdk 编码器(非 OH codec)
    OH_AVBuffer *aBuf = nullptr;        // demuxer 音频读样缓冲
    OH_AVBuffer *muxBuf = nullptr;      // AAC 帧混流复用缓冲
    std::vector<uint8_t> audPcm;        // S16LE 转换落点
    bool audDemuxEos = false;
    int64_t aacOutFrames = 0;           // 已混流 AAC 帧(1024 样本/帧)
    int audEmptyReads = 0;              // 连续空音频读(demuxer 隐式 EOS 防御)
    int encCalls = 0;                   // fdk 调用计数(诊断)
    bool audDiagDone = false;
    int32_t maIdx = -1;
    if (aTrack >= 0) {
        aBuf = OH_AVBuffer_Create(1 << 20);
        muxBuf = OH_AVBuffer_Create(1 << 16);
        if (aBuf == nullptr || muxBuf == nullptr) {
            return fail("audio_buffer");
        }
        const bool aacSource = aMime.rfind("audio/mp4a-latm", 0) == 0;
        if (!aacSource) {
            if (aSrcFmt != SAMPLE_S16LE && aSrcFmt != SAMPLE_S24LE &&
                aSrcFmt != SAMPLE_S32LE) {
                return fail("audio_format");
            }
            if (aacEncOpen(&audEnc, 0, aChannels) != AACENC_OK) {
                return fail("fdk_open");
            }
            aacEncoder_SetParam(audEnc, AACENC_AOT, 2); // AAC-LC
            aacEncoder_SetParam(audEnc, AACENC_SAMPLERATE, aSampleRate);
            aacEncoder_SetParam(audEnc, AACENC_CHANNELMODE,
                                aChannels == 2 ? MODE_2 : MODE_1);
            aacEncoder_SetParam(audEnc, AACENC_BITRATE, 192000);
            aacEncoder_SetParam(audEnc, AACENC_TRANSMUX, TT_MP4_RAW);
            aacEncoder_SetParam(audEnc, AACENC_SIGNALING_MODE,
                                1); // 兼容式 implicit signaling
            aacEncoder_SetParam(audEnc, AACENC_AFTERBURNER, 1);
            // fdk 无显式 init:参数就绪后首 Encode 惰性初始化
        }
        OH_AVFormat *maFmt = OH_AVFormat_Create();
        OH_AVFormat_SetStringValue(maFmt, OH_MD_KEY_CODEC_MIME,
                                   OH_AVCODEC_MIMETYPE_AUDIO_AAC);
        OH_AVFormat_SetIntValue(maFmt, OH_MD_KEY_AUD_CHANNEL_COUNT, aChannels);
        OH_AVFormat_SetIntValue(maFmt, OH_MD_KEY_AUD_SAMPLE_RATE, aSampleRate);
        OH_AVFormat_SetLongValue(maFmt, OH_MD_KEY_BITRATE,
                                 aacSource ? aBitrate : 192000);
        if (OH_AVMuxer_AddTrack(muxer, &maIdx, maFmt) != AV_ERR_OK) {
            OH_AVFormat_Destroy(maFmt);
            maIdx = -1;
            Breadcrumb("muxer_add_audio_failed");
        } else {
            Breadcrumb(("aud maIdx=" + std::to_string(maIdx)).c_str());
        }
        OH_AVFormat_Destroy(maFmt);
    }
    Breadcrumb("muxer_started");
    if (OH_AVMuxer_Start(muxer) != AV_ERR_OK) {
        return fail("muxer_start");
    }

    const int audSrcBytes = aSrcFmt == SAMPLE_S24LE
                                ? 3
                                : (aSrcFmt == SAMPLE_S32LE ? 4 : 2);
    const int audBytesPerFrame = aChannels * audSrcBytes;

    // 编码器(buffer 模式,NV12 入)。
    encoder = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (encoder == nullptr) {
        return fail("create_encoder");
    }
    pipeline.encoder = encoder;
    OH_AVCodecCallback encCb = {OnCodecError, OnCodecStreamChanged,
                                OnEncNeedInput, OnEncNewOutput};
    OH_VideoEncoder_RegisterCallback(encoder, encCb, &pipeline);
    OH_AVFormat *encFmt = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(encFmt, OH_MD_KEY_WIDTH, vWidth);
    OH_AVFormat_SetIntValue(encFmt, OH_MD_KEY_HEIGHT, vHeight);
    OH_AVFormat_SetIntValue(encFmt, OH_MD_KEY_PIXEL_FORMAT,
                            AV_PIXEL_FORMAT_NV12);
    // 码率显式封顶(编码器对源码率目标不敏感,实测 121-138MB/3s 的旧
    // 账):上限 w×h×fps/10,下限 10Mbps 兜底(1080p24 按公式只有
    // 5Mbps,压缩伪影满脸)
    const int64_t targetBr =
        std::min<int64_t>(vBitrate,
                          std::max<int64_t>(static_cast<int64_t>(vWidth) *
                                                vHeight * vFps / 10,
                                            10000000));
    OH_AVFormat_SetLongValue(encFmt, OH_MD_KEY_BITRATE,
                             targetBr > 1000000 ? targetBr : 8000000);
    // 码率模式必须显式给:缺省落 SQR(3) 而 OMX AVC 编码器不支持
    //(unknown BitRateMode 3 → 配置残废,输入 buffer 不回收死锁实锤)
    OH_AVFormat_SetIntValue(encFmt, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE,
                            0 /* BITRATE_MODE_CBR */);
    OH_AVFormat_SetFloatValue(encFmt, OH_MD_KEY_FRAME_RATE, vFps);
    // I_FRAME_INTERVAL 二分排查:[701] not support 嫌疑参数(2000ms)
    // OH_AVFormat_SetIntValue(encFmt, OH_MD_KEY_I_FRAME_INTERVAL, 2000);
    if (OH_VideoEncoder_Configure(encoder, encFmt) != AV_ERR_OK) {
        OH_AVFormat_Destroy(encFmt);
        return fail("config_encoder");
    }
    OH_AVFormat_Destroy(encFmt);
    Breadcrumb("encoder_configured");
    if (OH_VideoEncoder_Start(encoder) != AV_ERR_OK) {
        return fail("start_encoder");
    }

    // 主循环 = 全非阻塞泵:四路队列(解入/解出/编入/编出)统一泵送,
    // 帧在等编码器空位时可暂存(stash)—— 任何一路阻塞泵都会死锁
    // (编码器输出不排空 → 编入不回收 → 永等,2026-10-24 真机实锤)。
    const size_t frameBytes = static_cast<size_t>(sourceFrameBytes);
    struct StashedFrame {
        uint32_t decIdx;
        OH_AVBuffer *buf;
        int64_t pts;
    };
    std::vector<StashedFrame> stash;
    int64_t processedFrames = 0;
    bool demuxEos = false;
    bool decInEosSent = false;
    bool decOutEos = false;
    bool encEosSent = false;
    bool encEos = false;
    int decoderStride = vWidth; // 输出 format 修正(stream changed 时)
    // 平面高:解码器按对齐高度排布(3840x2160 实测 2176),UV 平面起点
    // 在 stride×平面高;按编码高 vHeight 算会整图色度上移 16 行——顶部
    // 32 行读进 luma 填充区(零色度 = 绿条),全图色度错配偏色。
    int decPlaneHeight = vHeight;
    bool decoderFmtChecked = false;
    bool tenBit = false;
    RunResult inner;
    auto lastProgress = std::chrono::steady_clock::now();
    const auto progressDeadline = std::chrono::seconds(45);
    while (true) {
        if (g_lutCancel.load()) {
            inner.error = "cancelled";
            break;
        }
        // 喂解码器输入
        if (!demuxEos) {
            uint32_t inIdx = 0;
            OH_AVBuffer *inBuf = nullptr;
            if (pipeline.decIn.TryPop(inIdx, inBuf)) {
                const OH_AVErrCode rr = OH_AVDemuxer_ReadSampleBuffer(
                    demuxer, static_cast<uint32_t>(vTrack), inBuf);
                if (rr != AV_ERR_OK) {
                    inner.error = "demux_read";
                    break;
                }
                OH_AVCodecBufferAttr attr{};
                OH_AVBuffer_GetBufferAttr(inBuf, &attr);
                if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                    demuxEos = true;
                }
                OH_AVBuffer_SetBufferAttr(inBuf, &attr);
                OH_VideoDecoder_PushInputBuffer(decoder, inIdx);
                if (demuxEos) {
                    decInEosSent = true;
                }
            }
        } else if (!decInEosSent) {
            uint32_t inIdx = 0;
            OH_AVBuffer *inBuf = nullptr;
            if (pipeline.decIn.TryPop(inIdx, inBuf)) {
                OH_AVCodecBufferAttr attr{};
                attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
                OH_AVBuffer_SetBufferAttr(inBuf, &attr);
                OH_VideoDecoder_PushInputBuffer(decoder, inIdx);
                decInEosSent = true;
            }
        }
        // 音轨 tick:与视频交错读(demuxer 共享读游标)。AAC 源直通;
        // PCM 源 S24→S16 转 fdk 软编。**每个 tick 连续读到 EOS 或攒满
        //(1MB)**——视频帧处理太快,单包/tick 会让泵在音频读完前退出
        //(2s 1080p24 实锤恒断在 33 包 = 音轨 69%,2026-10-25)。
        while (aBuf != nullptr && maIdx >= 0 && !audDemuxEos &&
               audPcm.size() < (1u << 20)) {
            const OH_AVErrCode rr = OH_AVDemuxer_ReadSampleBuffer(
                demuxer, static_cast<uint32_t>(aTrack), aBuf);
            OH_AVCodecBufferAttr attr{};
            if (rr == AV_ERR_OK) {
                OH_AVBuffer_GetBufferAttr(aBuf, &attr);
            }
            if (rr != AV_ERR_OK ||
                (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                audDemuxEos = true;
                audEmptyReads = 0;
                break;
            } else if (attr.size < 0 ||
                       attr.size > OH_AVBuffer_GetCapacity(aBuf)) {
                inner.error = "aud_buf_size";
                break;
            } else if (attr.size == 0) {
                // 空样本:略过
            } else if (audEnc == nullptr) {
                // AAC 直通:整样混流
                OH_AVMuxer_WriteSampleBuffer(
                    muxer, static_cast<uint32_t>(maIdx), aBuf);
            } else {
                audEmptyReads = 0;
                if (!audDiagDone) {
                    // 首包诊断:demuxer 交出的音频字节布局实锤
                    const uint8_t *raw = static_cast<const uint8_t *>(
                        OH_AVBuffer_GetAddr(aBuf));
                    std::string hex;
                    char tmp[8];
                    for (int i = 0; i < 16 && i < attr.size; i++) {
                        snprintf(tmp, sizeof(tmp), "%02x", raw[i]);
                        hex += tmp;
                    }
                    Breadcrumb(("aud p0 size=" + std::to_string(attr.size) +
                                " hex=" + hex)
                                   .c_str());
                    audDiagDone = true;
                }
                // PCM → S16LE(fdk 规范输入)
                const uint8_t *s =
                    static_cast<const uint8_t *>(OH_AVBuffer_GetAddr(aBuf));
                for (int32_t i = 0; i + audBytesPerFrame <= attr.size;
                     i += audBytesPerFrame) {
                    for (int ch = 0; ch < aChannels; ch++) {
                        int16_t v = 0;
                        if (audSrcBytes == 3) {
                            // S24LE 取高 16 位:LE 字节 [lo,mid,hi] →
                            // mid | hi<<8(此前 mid/hi 互逆 = 10 倍响度削顶)
                            v = static_cast<int16_t>(s[1] | (s[2] << 8));
                            s += 3;
                        } else if (audSrcBytes == 4) {
                            v = static_cast<int16_t>(s[2] | (s[3] << 8));
                            s += 4;
                        } else {
                            v = static_cast<int16_t>(s[0] | (s[1] << 8));
                            s += 2;
                        }
                        audPcm.push_back(static_cast<uint8_t>(v & 0xFF));
                        audPcm.push_back(
                            static_cast<uint8_t>((v >> 8) & 0xFF));
                    }
                }
                // 喂 fdk:按 numInBytesConsumed 推进,残量留到下个 tick
                uint8_t outBuf[8192];
                int outIdent = OUT_BITSTREAM_DATA;
                int outElem = 1;
                void *outPtrs[] = {static_cast<void *>(outBuf)};
                int outSize = static_cast<int>(sizeof(outBuf));
                AACENC_BufDesc outDesc{};
                outDesc.numBufs = 1;
                outDesc.bufs = outPtrs;
                outDesc.bufferIdentifiers = &outIdent;
                outDesc.bufSizes = &outSize;
                outDesc.bufElSizes = &outElem;
                size_t off = 0;
                while (off < audPcm.size() && inner.error.empty()) {
                    void *inBufs[] = {
                        static_cast<void *>(audPcm.data() + off)};
                    int inSize =
                        static_cast<int>(audPcm.size() - off);
                    int inIdent = IN_AUDIO_DATA;
                    int inElem = 1;
                    AACENC_BufDesc inDesc{};
                    inDesc.numBufs = 1;
                    inDesc.bufs = inBufs;
                    inDesc.bufferIdentifiers = &inIdent;
                    inDesc.bufSizes = &inSize;
                    inDesc.bufElSizes = &inElem;
                    AACENC_InArgs inArgs{};
                    inArgs.numInSamples = inSize / 2; // S16 交错样本数
                    AACENC_OutArgs outArgs{};
                    const AACENC_ERROR e = aacEncEncode(
                        audEnc, &inDesc, &outDesc, &inArgs, &outArgs);
                    if (encCalls < 3) {
                        Breadcrumb(("enc call" + std::to_string(encCalls) +
                                    " e=" + std::to_string(static_cast<int>(e)) +
                                    " in=" + std::to_string(inSize) +
                                    " consumed=" +
                                    std::to_string(outArgs.numInSamples) +
                                    " out=" +
                                    std::to_string(outArgs.numOutBytes))
                                       .c_str());
                    }
                    encCalls++;
                    if (e != AACENC_OK) {
                        inner.error = "fdk_encode";
                        break;
                    }
                    if (outArgs.numOutBytes > 0) {
                        if (outArgs.numOutBytes >
                                static_cast<int>(sizeof(outBuf)) ||
                            outArgs.numOutBytes >
                                OH_AVBuffer_GetCapacity(muxBuf)) {
                            inner.error = "fdk_output_size";
                            break;
                        }
                        memcpy(OH_AVBuffer_GetAddr(muxBuf), outBuf,
                               outArgs.numOutBytes);
                        OH_AVCodecBufferAttr wa{};
                        wa.size = outArgs.numOutBytes;
                        wa.pts = aacOutFrames * 1024LL * 1000000LL /
                                 aSampleRate;
                        OH_AVBuffer_SetBufferAttr(muxBuf, &wa);
                        const OH_AVErrCode wr = OH_AVMuxer_WriteSampleBuffer(
                            muxer, static_cast<uint32_t>(maIdx), muxBuf);
                        if (aacOutFrames == 0 || wr != AV_ERR_OK) {
                            Breadcrumb(("aud write f" +
                                        std::to_string(aacOutFrames) +
                                        " n=" + std::to_string(outArgs.numOutBytes) +
                                        " err=" + std::to_string(static_cast<int>(wr)))
                                           .c_str());
                        }
                        aacOutFrames++;
                    }
                    if (outArgs.numInSamples < 0) {
                        inner.error = "fdk_consumed";
                        break;
                    }
                    const int64_t consumedBytes =
                        static_cast<int64_t>(outArgs.numInSamples) *
                        2; // S16 交错:样本×2B
                    if (consumedBytes >
                        static_cast<int64_t>(audPcm.size() - off)) {
                        inner.error = "fdk_consumed";
                        break;
                    }
                    off += consumedBytes;
                    if (consumedBytes == 0 && outArgs.numOutBytes == 0) {
                        break; // fdk 内部攒帧中,余量下轮续喂
                    }
                }
                if (!audPcm.empty()) {
                    if (off > audPcm.size()) {
                        inner.error = "fdk_consumed";
                        break;
                    }
                    audPcm.erase(audPcm.begin(),
                                 audPcm.begin() +
                                     static_cast<long>(off));
                }
            }
        }
        // 排空解码输出:能进编码器的就地处理,进不了的上暂存架
        uint32_t decIdx = 0;
        OH_AVBuffer *decBuf = nullptr;
        while (pipeline.decOut.TryPop(decIdx, decBuf)) {
            OH_AVCodecBufferAttr attr{};
            OH_AVBuffer_GetBufferAttr(decBuf, &attr);
            if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                decOutEos = true;
                OH_VideoDecoder_FreeOutputBuffer(decoder, decIdx);
                break;
            }
            if (attr.size <= 0) {
                OH_VideoDecoder_FreeOutputBuffer(decoder, decIdx);
                continue;
            }
            if (!decoderFmtChecked) {
                decoderFmtChecked = true;
                OH_AVFormat *of =
                    OH_VideoDecoder_GetOutputDescription(decoder);
                if (of != nullptr) {
                    int32_t stride = 0;
                    int32_t planeH = 0;
                    if (OH_AVFormat_GetIntValue(of, OH_MD_KEY_VIDEO_STRIDE,
                                                &stride) &&
                        stride > 0) {
                        decoderStride = stride;
                    }
                    if (OH_AVFormat_GetIntValue(of, OH_MD_KEY_HEIGHT,
                                                &planeH) &&
                        planeH > vHeight) {
                        decPlaneHeight = planeH;
                    }
                    // 10-bit 判据回归 stride:本机解码器 10-bit 输出走
                    // P010(stride=2×width,1080p 实测 3840),而 fmt 恒报
                    // NV12(2)不可信(以查询为准的旧判据实测翻车);4K
                    // 8-bit 时 stride=width 自然可分。
                    tenBit = decoderStride >= 2 * vWidth;
                    OH_AVFormat_Destroy(of);
                    if (stride > kMaxVideoDimension * 2 ||
                        planeH > kMaxVideoDimension * 2 ||
                        decoderStride < vWidth || decPlaneHeight < vHeight) {
                        inner.error = "decoder_format";
                        OH_VideoDecoder_FreeOutputBuffer(decoder, decIdx);
                        break;
                    }
                }
                Breadcrumb(("frame0 s=" + std::to_string(decoderStride) +
                            " h=" + std::to_string(decPlaneHeight) +
                            " tenBit=" + (tenBit ? "1" : "0"))
                               .c_str());
            }
            // 容量防御:读端(解码 stride 布局)与写端(紧凑 NV12)
            const int64_t needRead =
                static_cast<int64_t>(decoderStride) * decPlaneHeight * 3 / 2;
            const int64_t needWrite =
                static_cast<int64_t>(vWidth) * vHeight * 3 / 2;
            if (OH_AVBuffer_GetCapacity(decBuf) < needRead) {
                inner.error = "dec_buf_small";
                OH_VideoDecoder_FreeOutputBuffer(decoder, decIdx);
                break;
            }
            uint32_t encIdx = 0;
            OH_AVBuffer *encBuf = nullptr;
            if (pipeline.encIn.TryPop(encIdx, encBuf)) {
                if (OH_AVBuffer_GetCapacity(encBuf) < needWrite) {
                    inner.error = "enc_buf_small";
                    OH_VideoDecoder_FreeOutputBuffer(decoder, decIdx);
                    break;
                }
                const uint8_t *base = OH_AVBuffer_GetAddr(decBuf);
                uint8_t *dst = OH_AVBuffer_GetAddr(encBuf);
                const uint8_t *uvSrc =
                    base + static_cast<size_t>(decoderStride) * decPlaneHeight;
                ApplyLutFrame(base, decoderStride, uvSrc, decoderStride,
                              tenBit, dst, vWidth,
                              dst + static_cast<size_t>(vWidth) * vHeight,
                              vWidth, vWidth, vHeight, cube, cubeN);
                OH_AVCodecBufferAttr outAttr{};
                outAttr.pts = attr.pts;
                outAttr.size = static_cast<int32_t>(frameBytes);
                // GOP 交编码器自理(I_FRAME_INTERVAL 已设):逐帧强插
                // SYNC_FRAME = 全 I 帧,码率爆炸(136MB/3s 实锤)
                outAttr.flags = 0;
                OH_AVBuffer_SetBufferAttr(encBuf, &outAttr);
                OH_VideoEncoder_PushInputBuffer(encoder, encIdx);
                processedFrames++;
                g_lutProgress.store(static_cast<int>(
                    processedFrames * 70 / std::max<int64_t>(estFrames, 1)));
                lastProgress = std::chrono::steady_clock::now();
                OH_VideoDecoder_FreeOutputBuffer(decoder, decIdx);
            } else {
                // 编码器无空位:帧上暂存架(解码输出池有限,自然背压)
                stash.push_back({decIdx, decBuf, attr.pts});
                break;
            }
        }
        if (!inner.error.empty()) {
            break;
        }
        // 暂存架回灌(编码器空位到位即处理)
        while (!stash.empty() && inner.error.empty()) {
            uint32_t encIdx = 0;
            OH_AVBuffer *encBuf = nullptr;
            if (!pipeline.encIn.TryPop(encIdx, encBuf)) {
                break;
            }
            auto &sf = stash.front();
            const int64_t needRead =
                static_cast<int64_t>(decoderStride) * decPlaneHeight * 3 / 2;
            const int64_t needWrite =
                sourceFrameBytes;
            if (OH_AVBuffer_GetCapacity(sf.buf) < needRead) {
                inner.error = "dec_buf_small";
                OH_VideoDecoder_FreeOutputBuffer(decoder, sf.decIdx);
                break;
            }
            if (OH_AVBuffer_GetCapacity(encBuf) < needWrite) {
                inner.error = "enc_buf_small";
                OH_VideoDecoder_FreeOutputBuffer(decoder, sf.decIdx);
                break;
            }
            const uint8_t *base = OH_AVBuffer_GetAddr(sf.buf);
            uint8_t *dst = OH_AVBuffer_GetAddr(encBuf);
            const uint8_t *uvSrc =
                base + static_cast<size_t>(decoderStride) * decPlaneHeight;
            ApplyLutFrame(base, decoderStride, uvSrc, decoderStride, tenBit,
                          dst, vWidth,
                          dst + static_cast<size_t>(vWidth) * vHeight, vWidth,
                          vWidth, vHeight, cube, cubeN);
            OH_AVCodecBufferAttr outAttr{};
            outAttr.pts = sf.pts;
            outAttr.size = static_cast<int32_t>(frameBytes);
            // GOP 同直通路径交编码器自理;逐帧 SYNC_FRAME = 全 I 帧码率
            // 爆炸(136MB/3s 实锤),暂存架回灌更不可强插
            outAttr.flags = 0;
            OH_AVBuffer_SetBufferAttr(encBuf, &outAttr);
            OH_VideoEncoder_PushInputBuffer(encoder, encIdx);
            processedFrames++;
            g_lutProgress.store(static_cast<int>(processedFrames * 70 /
                                                std::max<int64_t>(estFrames, 1)));
            lastProgress = std::chrono::steady_clock::now();
            OH_VideoDecoder_FreeOutputBuffer(decoder, sf.decIdx);
            stash.erase(stash.begin());
        }
        if (!inner.error.empty()) {
            break;
        }
        // 解码 EOS 已出且暂存架清空:给编码器发 EOS —— 不发则编码器
        // 永不收尾(2026-10-24 实锤:全帧处理完仍在等,看门狗误杀)
        if (decOutEos && !encEosSent && stash.empty()) {
            uint32_t encIdx = 0;
            OH_AVBuffer *encBuf = nullptr;
            if (pipeline.encIn.TryPop(encIdx, encBuf)) {
                OH_AVCodecBufferAttr attr{};
                attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
                OH_AVBuffer_SetBufferAttr(encBuf, &attr);
                OH_VideoEncoder_PushInputBuffer(encoder, encIdx);
                encEosSent = true;
            }
        }
        // 排空编码输出 → muxer
        uint32_t eoIdx = 0;
        OH_AVBuffer *eoBuf = nullptr;
        while (pipeline.encOut.TryPop(eoIdx, eoBuf)) {
            OH_AVCodecBufferAttr attr{};
            OH_AVBuffer_GetBufferAttr(eoBuf, &attr);
            if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                encEos = true;
                OH_VideoEncoder_FreeOutputBuffer(encoder, eoIdx);
            } else if (attr.size > 0) {
                OH_AVMuxer_WriteSampleBuffer(muxer,
                                             static_cast<uint32_t>(mvIdx),
                                             eoBuf);
                OH_VideoEncoder_FreeOutputBuffer(encoder, eoIdx);
                lastProgress = std::chrono::steady_clock::now();
            } else {
                OH_VideoEncoder_FreeOutputBuffer(encoder, eoIdx);
            }
        }
        // 全链收口:解/编 EOS 齐 + 暂存架清空 → fdk 排空尾帧 → 结束
        if (decInEosSent && decOutEos && encEos && stash.empty()) {
            if (audEnc != nullptr && maIdx >= 0) {
                const auto flushDeadline =
                    std::chrono::steady_clock::now() + std::chrono::seconds(5);
                uint8_t outBuf[8192];
                int outIdent = OUT_BITSTREAM_DATA;
                int outElem = 1;
                void *outPtrs[] = {static_cast<void *>(outBuf)};
                int outSize = static_cast<int>(sizeof(outBuf));
                AACENC_BufDesc outDesc{};
                outDesc.numBufs = 1;
                outDesc.bufs = outPtrs;
                outDesc.bufferIdentifiers = &outIdent;
                outDesc.bufSizes = &outSize;
                outDesc.bufElSizes = &outElem;
                while (!g_lutCancel.load() && inner.error.empty()) {
                    AACENC_InArgs emptyArgs{};
                    AACENC_OutArgs outArgs{};
                    const AACENC_ERROR e = aacEncEncode(
                        audEnc, nullptr, &outDesc, &emptyArgs, &outArgs);
                    if (e != AACENC_OK) {
                        inner.error = "fdk_flush";
                        break;
                    }
                    if (outArgs.numOutBytes > 0) {
                        memcpy(OH_AVBuffer_GetAddr(muxBuf), outBuf,
                               outArgs.numOutBytes);
                        OH_AVCodecBufferAttr wa{};
                        wa.size = outArgs.numOutBytes;
                        wa.pts = aacOutFrames * 1024LL * 1000000LL /
                                 aSampleRate;
                        OH_AVBuffer_SetBufferAttr(muxBuf, &wa);
                        const OH_AVErrCode wr = OH_AVMuxer_WriteSampleBuffer(
                            muxer, static_cast<uint32_t>(maIdx), muxBuf);
                        if (aacOutFrames == 0 || wr != AV_ERR_OK) {
                            Breadcrumb(("aud write f" +
                                        std::to_string(aacOutFrames) +
                                        " n=" + std::to_string(outArgs.numOutBytes) +
                                        " err=" + std::to_string(static_cast<int>(wr)))
                                           .c_str());
                        }
                        aacOutFrames++;
                    }
                    if (outArgs.numOutBytes == 0) {
                        break; // 排空完成
                    }
                    if (std::chrono::steady_clock::now() > flushDeadline) {
                        inner.error = "fdk_flush_stall";
                        break;
                    }
                }
            }
            if (inner.error.empty()) {
                result.ok = true;
            }
            break;
        }
        // 停滞看门狗:45s 无进展 = 管线死锁兜底
        if (std::chrono::steady_clock::now() - lastProgress >
            progressDeadline) {
            inner.error = "stall";
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    if (muxer != nullptr) {
        OH_AVMuxer_Stop(muxer);
        OH_AVMuxer_Destroy(muxer);
        muxer = nullptr;
    }
    if (audEnc != nullptr) {
        aacEncClose(&audEnc);
        audEnc = nullptr;
    }
    if (aBuf != nullptr) {
        OH_AVBuffer_Destroy(aBuf);
        aBuf = nullptr;
    }
    if (muxBuf != nullptr) {
        OH_AVBuffer_Destroy(muxBuf);
        muxBuf = nullptr;
    }
    if (encoder != nullptr) {
        OH_VideoEncoder_Stop(encoder);
        OH_VideoEncoder_Destroy(encoder);
        encoder = nullptr;
    }
    if (decoder != nullptr) {
        OH_VideoDecoder_Stop(decoder);
        OH_VideoDecoder_Destroy(decoder);
        decoder = nullptr;
    }
    if (demuxer != nullptr) {
        OH_AVDemuxer_Destroy(demuxer);
        demuxer = nullptr;
    }
    if (source != nullptr) {
        OH_AVSource_Destroy(source);
        source = nullptr;
    }
    close(fd);
    close(outFd);
    if (!result.ok) {
        result.error = inner.error.empty()
                           ? (result.error.empty() ? "unknown" : result.error)
                           : inner.error;
    }
    return result;
}

// ---------------------------------------------------------------------------
// napi 入口
// ---------------------------------------------------------------------------

struct LutJob {
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    std::string path;
    std::string outPath;
    std::vector<float> cube;
    int cubeN = 0;
    bool ok = false;
    std::string error;
    std::string out;
};

void ExecuteLut(napi_env env, void *data) {
    auto *job = static_cast<LutJob *>(data);
    const RunResult r = RunLutExport(job->path, job->outPath, job->cube,
                                     job->cubeN);
    job->ok = r.ok;
    job->error = r.error;
    job->out = job->outPath;
}

void CompleteLut(napi_env env, napi_status status, void *data) {
    auto *job = static_cast<LutJob *>(data);
    if (job->ok) {
        napi_value out;
        napi_create_string_utf8(env, job->out.c_str(), job->out.size(), &out);
        napi_resolve_deferred(env, job->deferred, out);
    } else {
        napi_value msg;
        napi_create_string_utf8(env, job->error.c_str(), job->error.size(),
                                &msg);
        napi_value err;
        napi_create_error(env, nullptr, msg, &err);
        napi_reject_deferred(env, job->deferred, err);
    }
    napi_delete_async_work(env, job->work);
    g_lutBusy.store(false);
    g_lutProgress.store(0);
    delete job;
}

napi_value LutExportVideo(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_error(env, "bad_args", "lutExportVideo 需要 4 参");
        return nullptr;
    }
    bool expected = false;
    if (!g_lutBusy.compare_exchange_strong(expected, true)) {
        napi_throw_error(env, "busy", "已有 LUT 导出在途");
        return nullptr;
    }
    auto *job = new LutJob();
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    job->path.resize(len);
    napi_get_value_string_utf8(env, argv[0], &job->path[0], len + 1, &len);
    len = 0;
    napi_get_value_string_utf8(env, argv[1], nullptr, 0, &len);
    job->outPath.resize(len);
    napi_get_value_string_utf8(env, argv[1], &job->outPath[0], len + 1,
                               &len);
    int32_t cubeSize = 0;
    napi_get_value_int32(env, argv[3], &cubeSize);
    bool isArr = false;
    napi_is_typedarray(env, argv[2], &isArr);
    if (!isArr) {
        g_lutBusy.store(false);
        delete job;
        napi_throw_error(env, "bad_args", "cube 须 Float32Array");
        return nullptr;
    }
    napi_typedarray_type type = napi_int8_array;
    size_t length = 0;
    void *data = nullptr;
    napi_value arrBuf;
    size_t off = 0;
    napi_get_typedarray_info(env, argv[2], &type, &length, &data, &arrBuf,
                             &off);
    if (type != napi_float32_array || cubeSize < 2) {
        g_lutBusy.store(false);
        delete job;
        napi_throw_error(env, "bad_cube", "cube 须 Float32 N³×4");
        return nullptr;
    }
    // ohos napi 的 typedarray length 实测回**字节量**(规格应元素数):
    // 17³×4 Float32Array 报 78608。以 Dart 侧 size 为准,两种语义都收。
    const long expectedElems = static_cast<long>(cubeSize) * cubeSize *
                               cubeSize * 4;
    if (length != static_cast<size_t>(expectedElems) &&
        length != static_cast<size_t>(expectedElems) * 4) {
        g_lutBusy.store(false);
        delete job;
        napi_throw_error(env, "bad_cube",
                         ("cube 长度不符 expected " +
                          std::to_string(expectedElems) + " got " +
                          std::to_string(length))
                             .c_str());
        return nullptr;
    }
    const size_t elems = length == static_cast<size_t>(expectedElems)
                             ? length
                             : length / 4;
    const auto *floats = static_cast<const float *>(data);
    job->cube.assign(floats, floats + elems);
    job->cubeN = cubeSize;
    g_lutCancel.store(false);
    g_lutProgress.store(0);

    napi_value pname;
    napi_create_string_utf8(env, "lut-export", NAPI_AUTO_LENGTH, &pname);
    napi_value promise;
    if (napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
        napi_create_async_work(env, nullptr, pname, ExecuteLut, CompleteLut,
                               job, &job->work) != napi_ok) {
        g_lutBusy.store(false);
        delete job;
        napi_throw_error(env, "setup_failed", "异步工作创建失败");
        return nullptr;
    }
    napi_queue_async_work(env, job->work);
    return promise;
}

napi_value LutProgress(napi_env env, napi_callback_info info) {
    napi_value out;
    napi_create_int32(env, g_lutProgress.load(), &out);
    return out;
}

napi_value LutCancel(napi_env env, napi_callback_info info) {
    g_lutCancel.store(true);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

} // namespace

/** 供 napi_init.cpp 的模块 Init 挂载(外部链接,匿名空间外)。 */
void RegisterVideoLut(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"lutExportVideo", nullptr, LutExportVideo, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"lutProgress", nullptr, LutProgress, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"lutCancel", nullptr, LutCancel, nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]),
                           desc);
}
