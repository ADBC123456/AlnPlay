import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'edge dispersion samples the backdrop and leaves the center clear',
    (tester) async {
      await tester.runAsync(() async {
        const width = 300;
        const height = 64;
        final program = await ui.FragmentProgram.fromAsset(
          'shaders/liquid_glass.frag',
        );

        Future<ui.Image> source({bool solid = false, bool ramp = false}) async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawColor(const Color(0xFF808080), BlendMode.src);
          if (ramp) {
            for (var x = 0; x < width; x++) {
              final level = (x * 16).clamp(0, 255);
              canvas.drawRect(
                Rect.fromLTWH(x.toDouble(), 0, 1, height.toDouble()),
                Paint()..color = Color.fromARGB(255, level, level, level),
              );
            }
          } else if (!solid) {
            for (var x = -height; x < width; x += 16) {
              canvas.drawPath(
                Path()
                  ..moveTo(x.toDouble(), 0)
                  ..lineTo(x + 8, 0)
                  ..lineTo(x + height + 8, height.toDouble())
                  ..lineTo(x + height.toDouble(), height.toDouble())
                  ..close(),
                Paint()..color = Colors.white,
              );
            }
          }
          final picture = recorder.endRecording();
          final image = await picture.toImage(width, height);
          picture.dispose();
          return image;
        }

        Future<Uint8List> render(ui.Image input, double dispersion) async {
          final shader = program.fragmentShader()
            ..setFloat(0, width.toDouble())
            ..setFloat(1, height.toDouble())
            ..setFloat(2, width.toDouble())
            ..setFloat(3, height.toDouble())
            ..setFloat(4, dispersion)
            ..setFloat(5, 12)
            ..setFloat(6, 0)
            ..setFloat(7, 0)
            ..setFloat(8, width.toDouble())
            ..setFloat(9, height.toDouble())
            ..setImageSampler(0, input);
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, width * 1.0, height * 1.0),
            Paint()..shader = shader,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(width, height);
          final pixels = (await image.toByteData())!.buffer.asUint8List();
          image.dispose();
          picture.dispose();
          shader.dispose();
          return pixels;
        }

        final stripes = await source();
        final neutral = await render(stripes, 0);
        final chromatic = await render(stripes, 1.2);
        stripes.dispose();
        var changedEdgePixels = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 40; x < width - 40; x++) {
            final i = (y * width + x) * 4;
            expect(neutral[i], neutral[i + 1]);
            expect(neutral[i + 1], neutral[i + 2]);
            if (y >= 12 && y < height - 12) {
              expect(chromatic.sublist(i, i + 4), neutral.sublist(i, i + 4));
            } else if (chromatic[i] != chromatic[i + 2]) {
              changedEdgePixels++;
            }
            expect(
              chromatic[i + 3],
              255,
              reason: 'No transparent sampling seams',
            );
          }
        }
        expect(changedEdgePixels, greaterThan(100));

        final ramp = await source(ramp: true);
        final separated = await render(ramp, 1);
        ramp.dispose();
        final totals = [0, 0, 0];
        for (var y = 24; y < 40; y++) {
          for (var x = 0; x < 10; x++) {
            final lip = (y * width + x) * 4;
            expect(
              separated[lip + 2],
              greaterThanOrEqualTo(separated[lip + 1]),
            );
            expect(separated[lip + 1], greaterThanOrEqualTo(separated[lip]));
            for (var channel = 0; channel < 3; channel++) {
              totals[channel] += separated[lip + channel];
            }
          }
        }
        // Individual subpixel shifts may round to the same 8-bit value.
        expect(totals[2], greaterThan(totals[1]), reason: 'Blue bends most');
        expect(totals[1], greaterThan(totals[0]), reason: 'Red bends least');

        final solid = await source(solid: true);
        final flat = await render(solid, 1.2);
        solid.dispose();
        for (var i = 0; i < flat.length; i += 4) {
          expect(flat.sublist(i, i + 4), [128, 128, 128, 255]);
        }
      });
    },
  );
}
