import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Pill-shaped button (like an oval) instead of a circular one.
/// Keeps same behavior: shows loader, SVG, or child.
class RoundArrowButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool loading;
  final Widget? child;
  final String? svgAsset;
  final Color? svgColor;
  final double width; // 👈 ora usiamo width e height invece di size
  final double height;
  final double iconSize;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double elevation;
  final String? tooltip;
  final double progressSize;

  const RoundArrowButton({
    super.key,
    required this.onPressed,
    this.loading = false,
    this.child,
    this.svgAsset,
    this.svgColor,
    this.width = 88,   // 👈 larghezza “pillola”
    this.height = 54,  // 👈 altezza “pillola”
    this.iconSize = 32,
    this.backgroundColor = Colors.white,
    this.foregroundColor = Colors.black,
    this.elevation = 3,
    this.tooltip,
    this.progressSize = 26,
  });

  @override
  Widget build(BuildContext context) {
    final btn = SizedBox(
      width: width,
      height: height,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(height / 2), // 👈 pill shape
          ),
          elevation: elevation,
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          padding: EdgeInsets.zero,
          shadowColor: Colors.black.withOpacity(0.2),
        ),
        child: loading
            ? SizedBox(
          width: progressSize,
          height: progressSize,
          child: const CircularProgressIndicator(),
        )
            : _buildInner(),
      ),
    );

    return (tooltip == null) ? btn : Tooltip(message: tooltip!, child: btn);
  }

  Widget _buildInner() {
    if (child != null) return child!;
    if (svgAsset != null) {
      return SvgPicture.asset(
        svgAsset!,
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        colorFilter: (svgColor == null)
            ? null
            : ColorFilter.mode(svgColor!, BlendMode.srcIn),
      );
    }
    return Icon(Icons.chevron_right, size: iconSize);
  }
}