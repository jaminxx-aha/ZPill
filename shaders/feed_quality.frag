// 取景「高质量」画面处理链(fragment shader):
// Catmull-Rom 上采样(16 tap,锐利边缘、无双线性软)+ 细节增强
// (对同点双线性采样差值做轻锐化)+ 可选时域降噪(与前帧做运动
// 自适应混合:像素差大 = 运动现场,不混;差小 = 噪声区,半混)。
//
// 采样器:0 = 当前帧,1 = 前一帧(无前帧时上层传当前帧自身,uMotion
// 传 0)。采样坐标 uv 不是 fragCoord 直接除尺寸 —— 绘制矩形住在图像
// 坐标系,外层 Transform(contain/缩放/旋转/变宽)全折进 CTM,由
// Dart 侧算好两条边向量 + 原点回传(uEdgeX/uEdgeY/uOrigin),shader
// 里解 2×2 线性方程还原 uv。半像素对齐:texPos = uv/srcTexel − 0.5,
// 采样点 = (floor + tap + 0.5)·texel。
#include <flutter/runtime_effect.glsl>

uniform sampler2D curr_tex;
uniform sampler2D prev_tex;

uniform vec2 uEdgeX; // 图像 x 轴单位向量(层空间)
uniform vec2 uEdgeY; // 图像 y 轴单位向量(层空间)
uniform vec2 uOrigin; // 图像 (0,0) 在层空间
uniform vec2 uSrcSize; // 源帧像素尺寸
uniform float uMotion; // 时域混合强度(0 = 关)
uniform float uSharpen; // 细节增强量

out vec4 fragColor;

// Catmull-Rom 核(a = 0.5):|x| ≤ 1 主瓣,1 < |x| < 2 副瓣。
float crWeight(float x) {
  x = abs(x);
  float x2 = x * x;
  float x3 = x2 * x;
  if (x <= 1.0) {
    return 1.5 * x3 - 2.5 * x2 + 1.0;
  } else if (x < 2.0) {
    return -0.5 * x3 + 2.5 * x2 - 4.0 * x + 2.0;
  }
  return 0.0;
}

vec3 catmullRom(vec2 uv, vec2 texel) {
  vec2 texPos = uv / texel - 0.5;
  vec2 frac2 = fract(texPos);
  vec2 base = (floor(texPos) + 0.5) * texel;
  vec3 sum = vec3(0.0);
  float wsum = 0.0;
  for (int j = -1; j <= 2; j++) {
    float wy = crWeight(float(j) - frac2.y);
    for (int i = -1; i <= 2; i++) {
      float wx = crWeight(float(i) - frac2.x);
      float w = wx * wy;
      sum += texture(curr_tex, base + vec2(float(i), float(j)) * texel).rgb * w;
      wsum += w;
    }
  }
  return sum / wsum;
}

void main() {
  // CTM 逆映射:frag − origin = u·edgeX + v·edgeY
  vec2 f = FlutterFragCoord() - uOrigin;
  float det = uEdgeX.x * uEdgeY.y - uEdgeX.y * uEdgeY.x;
  vec2 uv = vec2(
      (f.x * uEdgeY.y - f.y * uEdgeY.x) / det,
      (uEdgeX.x * f.y - uEdgeX.y * f.x) / det);
  vec2 texel = 1.0 / uSrcSize;

  vec3 c = catmullRom(uv, texel);

  if (uSharpen > 0.0) {
    vec3 b = texture(curr_tex, uv).rgb;
    c = c + (c - b) * uSharpen;
  }

  if (uMotion > 0.0) {
    vec3 p = texture(prev_tex, uv).rgb;
    // 与上采样结果的差当运动幅度:大差(≥1/6)= 真运动不混,
    // 小差 = 噪声,半幅混合(时域平均掉随机噪声)。
    float d = max(max(abs(c.r - p.r), abs(c.g - p.g)), abs(c.b - p.b));
    float w = uMotion * clamp(1.0 - d * 6.0, 0.0, 1.0);
    c = mix(c, (c + p) * 0.5, w);
  }

  fragColor = vec4(c, 1.0);
}
