import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/material.dart' show Matrix4, MatrixUtils;
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/features/remote/feed_transform.dart';

void main() {
  group('feedQuarterFromRotationRaw', () {
    test('帧头 @839 旋位 → 显示四分之一圈映射', () {
      expect(feedQuarterFromRotationRaw(0), 0);
      expect(feedQuarterFromRotationRaw(1), 3, reason: '左转竖:图像逆时针 90°');
      expect(feedQuarterFromRotationRaw(2), 1, reason: '右转竖:图像顺时针 90°');
      expect(feedQuarterFromRotationRaw(3), 2, reason: '倒置:180°');
      expect(feedQuarterFromRotationRaw(9), 0, reason: '未知值不转');
    });
  });

  group('FeedTransform 几何', () {
    test('无画面 = 恒等变换,逆映射 null', () {
      final t = FeedTransform(
          imageSize: Size.zero, boxSize: const Size(800, 600));
      expect(t.hasImage, isFalse);
      expect(t.screenToNorm(const Offset(10, 10)), isNull);
      expect(t.imageRectToScreen(const Rect.fromLTWH(0, 0, 4, 4)), Rect.zero);
      expect(t.imageToScreen, Matrix4.identity());
    });

    test('contentSize:偶数圈横向拉伸,奇数圈宽高对调', () {
      final even = FeedTransform(
          imageSize: const Size(100, 50),
          boxSize: const Size(800, 600),
          deSqueeze: 1.5);
      expect(even.contentSize, const Size(150, 50));
      final odd = FeedTransform(
          imageSize: const Size(100, 50),
          boxSize: const Size(800, 600),
          quarter: 1,
          deSqueeze: 1.5);
      expect(odd.contentSize, const Size(50, 150), reason: '(h, ds·w)');
    });

    test('fitScale/displayRect:contain 取短板居中', () {
      // 32×24 在 800×600:同 4:3 → fitScale 25,整盒无 letterbox
      final t = FeedTransform(
          imageSize: const Size(32, 24), boxSize: const Size(800, 600));
      expect(t.fitScale, 25.0);
      expect(t.displayRect, const Rect.fromLTWH(0, 0, 800, 600));
      // 宽是短板:32×24 在 800×800
      final w = FeedTransform(
          imageSize: const Size(32, 24), boxSize: const Size(800, 800));
      expect(w.fitScale, 25.0);
      expect(w.displayRect, const Rect.fromLTWH(0, 100, 800, 600));
      // 变宽 2×:内容 64×24 → 宽成短板
      final ds = FeedTransform(
          imageSize: const Size(32, 24),
          boxSize: const Size(800, 800),
          deSqueeze: 2.0);
      expect(ds.displayRect, const Rect.fromLTWH(0, 250, 800, 300),
          reason: '64×24 contain 到 800 宽 → 高 300,上下各留 250');
    });

    test('imageToScreen:旋转/变宽计入,图像四角落 displayRect 四角', () {
      // quarter 1(顺时针 90°):图像上缘 → 屏幕右缘。
      // 32×24 内容转置后 24×32,在 800×600:fitScale = 600/32 = 18.75,
      // displayRect = (175, 0, 450, 600)。
      final t = FeedTransform(
          imageSize: const Size(32, 24),
          boxSize: const Size(800, 600),
          quarter: 1);
      expect(t.displayRect, const Rect.fromLTWH(175, 0, 450, 600));
      final m = t.imageToScreen;
      // 顺时针一圈换角:图像左上 (0,0) → 屏幕右上 (625, 0);图像
      // 左下 (0,24) → 屏幕左上 (175, 0)。rotateZ 的 cos(π/2) 非
      // 精确 0,角点对账用容差。
      Offset corner(Offset p) =>
          MatrixUtils.transformPoint(m, p);
      expect(corner(const Offset(0, 0)).dx, closeTo(625, 1e-9));
      expect(corner(const Offset(0, 0)).dy, closeTo(0, 1e-9));
      expect(corner(const Offset(0, 24)).dx, closeTo(175, 1e-9));
      expect(corner(const Offset(0, 24)).dy, closeTo(0, 1e-9));
      // 图像右上 (32,0) → 屏幕右下 (625, 600)。
      expect(corner(const Offset(32, 0)).dx, closeTo(625, 1e-9));
      expect(corner(const Offset(32, 0)).dy, closeTo(600, 1e-9));
      // 图像中心 → displayRect 中心。
      expect(corner(const Offset(16, 12)).dx, closeTo(400, 1e-9));
      expect(corner(const Offset(16, 12)).dy, closeTo(300, 1e-9));
    });

    test('imageToScreen:变宽拉伸横向,四角对账', () {
      // ds 2:内容 64×24 contain 到 800×600 = 整盒(64×24 恰为 4:1.5
      // 与盒同比例?不:800/600 ≠ 64/24,短板 = 高 600/24 = 25)。
      final t = FeedTransform(
          imageSize: const Size(32, 24),
          boxSize: const Size(800, 600),
          deSqueeze: 2.0);
      // 内容 64×24 → fitScale 25 → 1600×600:宽是短板?min(800/64=12.5,
      // 600/24=25) = 12.5 → 800×300,居中 (0, 150, 800, 300)。
      expect(t.displayRect, const Rect.fromLTWH(0, 150, 800, 300));
      final m = t.imageToScreen;
      expect(MatrixUtils.transformPoint(m, const Offset(0, 0)),
          const Offset(0, 150));
      expect(MatrixUtils.transformPoint(m, const Offset(32, 24)),
          const Offset(800, 450));
    });

    test('imageToScreen:缩放平移绕盒中心', () {
      final t = FeedTransform(
          imageSize: const Size(32, 24),
          boxSize: const Size(800, 600),
          zoom: 2.0,
          pan: const Offset(40, -20));
      // zoom=1 时中心 (400,300);zoom 2 绕盒中心 → 仍在 (400,300);
      // pan 平移 → (440, 280)。
      expect(MatrixUtils.transformPoint(t.imageToScreen, const Offset(16, 12)),
          const Offset(440, 280));
    });
  });

  group('FeedFit 适配模式(2026-10-12「不留黑边」)', () {
    test('widthFill:9:16 竖拍在偏宽盒恒满宽,两侧永无黑边', () {
      // 600×800 盒(横向偏宽):contain 高限 → 450×800 居中,两侧
      // 各 75 黑边 —— 用户竖拍报障场景。
      final c = FeedTransform(
          imageSize: const Size(9, 16), boxSize: const Size(600, 800));
      expect(c.fitScale, 50.0);
      expect(c.displayRect, const Rect.fromLTWH(75, 0, 450, 800));
      // widthFill 恒满宽:scale = 600/9 → 600×1066.7 居中,上下越出
      // (取景区 ClipRect 裁掉),两侧贴盒。
      final f = FeedTransform(
          imageSize: const Size(9, 16),
          boxSize: const Size(600, 800),
          fit: FeedFit.widthFill);
      expect(f.fitScale, closeTo(600 / 9, 1e-9));
      expect(f.displayRect.left, 0);
      expect(f.displayRect.width, 600);
      expect(f.displayRect.top, closeTo(-133.33, 0.01));
      expect(f.displayRect.height, closeTo(1066.67, 0.01));
    });

    test('heightFill:超宽内容在偏高盒恒满高,上下永无黑边', () {
      // 2:1 内容在 600×800 盒:contain 宽限 → 600×300 居中,上下各
      // 250 黑边 —— 横屏「取景上下黑边」场景。
      final c = FeedTransform(
          imageSize: const Size(2, 1), boxSize: const Size(600, 800));
      expect(c.fitScale, 300.0);
      expect(c.displayRect, const Rect.fromLTWH(0, 250, 600, 300));
      // heightFill 恒满高:scale = 800 → 1600×800 居中,左右越出被裁,
      // 上下贴盒。
      final f = FeedTransform(
          imageSize: const Size(2, 1),
          boxSize: const Size(600, 800),
          fit: FeedFit.heightFill);
      expect(f.fitScale, 800.0);
      expect(f.displayRect, const Rect.fromLTWH(-500, 0, 1600, 800));
    });

    test('常态等价:本就贴禁边的方向上 fill 与 contain 同果(零裁切)', () {
      // 2:1 宽内容在 600×300 盒:本就宽限 → widthFill 同 contain 整盒。
      final w = FeedTransform(
          imageSize: const Size(2, 1),
          boxSize: const Size(600, 300),
          fit: FeedFit.widthFill);
      expect(w.displayRect, const Rect.fromLTWH(0, 0, 600, 300));
      // 16:9 视频在横屏取景盒 1422×800(左缩 60 画面右移 + 右缩 118
      // 让柱,柱右缘 30 手调):
      // 本就高限 → heightFill 同 contain 满高,16:9 满高宽 1422.22 仅
      // 越盒 0.22(双侧各裁 0.11,不可见),余量黑边只落在左右两侧。
      final h = FeedTransform(
          imageSize: const Size(16, 9),
          boxSize: const Size(1422, 800),
          fit: FeedFit.heightFill);
      expect(h.fitScale, closeTo(800 / 9, 1e-9));
      expect(h.displayRect.top, 0);
      expect(h.displayRect.height, 800);
      expect(h.displayRect.left, closeTo(-0.11, 0.01));
      expect(h.displayRect.width, closeTo(1422.22, 0.01));
    });
  });

  group('逆映射', () {
    FeedTransform t({
      int quarter = 0,
      double deSqueeze = 1.0,
      double zoom = 1.0,
      Offset pan = Offset.zero,
    }) =>
        FeedTransform(
            imageSize: const Size(640, 480),
            boxSize: const Size(800, 600),
            quarter: quarter,
            deSqueeze: deSqueeze,
            zoom: zoom,
            pan: pan);

    test('screenToNorm:全参数往返(旋转/变宽/缩放/平移一次收口)', () {
      final cases = [
        t(),
        t(quarter: 1),
        t(quarter: 2),
        t(quarter: 3),
        t(deSqueeze: 1.33),
        t(quarter: 1, deSqueeze: 2.0),
        t(zoom: 3.5, pan: Offset(-120, 80)),
        t(quarter: 3, deSqueeze: 1.5, zoom: 2.0, pan: Offset(60, -40)),
      ];
      const samples = [
        Offset(0, 0),
        Offset(640, 0),
        Offset(0, 480),
        Offset(640, 480),
        Offset(320, 240),
        Offset(101.5, 377.25),
      ];
      for (final c in cases) {
        for (final p in samples) {
          final screen =
              MatrixUtils.transformPoint(c.imageToScreen, p);
          final back = c.screenToNorm(screen)!;
          // 逆矩阵有浮点误差,角点对账用容差
          expect(back.dx, closeTo(p.dx / 640, 1e-6),
              reason: 'quarter=${c.quarter} ds=${c.deSqueeze} '
                  'zoom=${c.zoom} pan=${c.pan} 图像点 $p');
          expect(back.dy, closeTo(p.dy / 480, 1e-6));
        }
      }
    });

    test('screenToNorm:画面外钳到边', () {
      final c = t();
      expect(c.screenToNorm(const Offset(-500, -500)), const Offset(0, 0));
      expect(
          c.screenToNorm(const Offset(9999, 9999)), const Offset(1, 1));
    });

    test('imageRectToScreen:中心与尺寸按 quarter 对调', () {
      // quarter 0:框 (288,192)-(352,288)(中心 320,240)→ 屏幕中心
      // (400,300),尺寸 64×96 × fitScale(800/640 = 1.25)= 80×120。
      final c = t();
      expect(
          c.imageRectToScreen(const Rect.fromLTWH(288, 192, 64, 96)),
          const Rect.fromLTWH(360, 240, 80, 120));
      // quarter 1:宽高对调 → 96·s × 64·s。640×480 内容转置 480×640
      // 在 800×600:fitScale = 600/640 = 0.9375,displayRect =
      // (175, 0, 450, 600);中心经 imageToScreen 算。
      final q = t(quarter: 1);
      final r = q.imageRectToScreen(const Rect.fromLTWH(288, 192, 64, 96));
      expect(r.center,
          MatrixUtils.transformPoint(q.imageToScreen, const Offset(320, 240)));
      expect(r.size, const Size(90, 60), reason: '宽高对调(96/64 × 0.9375)');
    });
  });
}
