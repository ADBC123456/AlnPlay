import 'dart:io';

import 'package:flutter/material.dart';

import '../services/image_cache_service.dart';

/// Durable TMDB artwork; non-TMDB server images retain their existing loader.
class CachedImage extends StatefulWidget {
  const CachedImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
    this.loadingBuilder,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
  });
  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageLoadingBuilder? loadingBuilder;
  final AlignmentGeometry alignment;
  final FilterQuality filterQuality;

  @override
  State<CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<CachedImage> {
  late Future<File?> _file;

  @override
  void initState() {
    super.initState();
    _file = ImageCacheService.instance.fetch(widget.url);
  }

  @override
  void didUpdateWidget(covariant CachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _file = ImageCacheService.instance.fetch(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ImageCacheService.supports(widget.url)) {
      return Image.network(
        widget.url,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: widget.errorBuilder,
        loadingBuilder: widget.loadingBuilder,
        alignment: widget.alignment,
        filterQuality: widget.filterQuality,
      );
    }
    return FutureBuilder<File?>(
      key: ValueKey(widget.url),
      future: _file,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          final file = snapshot.data;
          if (file != null) {
            return Image.file(
              file,
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              errorBuilder: widget.errorBuilder,
              alignment: widget.alignment,
              filterQuality: widget.filterQuality,
            );
          }
          return widget.errorBuilder?.call(
                context,
                const FileSystemException('Artwork unavailable'),
                StackTrace.current,
              ) ??
              SizedBox(width: widget.width, height: widget.height);
        }
        final placeholder = SizedBox(
          width: widget.width,
          height: widget.height,
        );
        return widget.loadingBuilder?.call(
              context,
              placeholder,
              const ImageChunkEvent(
                cumulativeBytesLoaded: 0,
                expectedTotalBytes: null,
              ),
            ) ??
            placeholder;
      },
    );
  }
}
