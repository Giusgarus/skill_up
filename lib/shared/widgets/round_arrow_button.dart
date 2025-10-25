import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Circular button that can show:
/// - a loader (when [loading] is true)
/// - a custom [child] widget
/// - an SVG icon from [svgAsset] (no need to pass [child])
///
/// Fully configurable via size, colors, elevation, and an optional tooltip.
class RoundArrowButton extends StatelessWidget {
  /// Tap callback. If null, the button is disabled.
  final VoidCallback? onPressed;

  /// When true, shows a CircularProgressIndicator instead of the icon/child.
  final bool loading;

  /// Custom widget to show inside the circle. Ignored if [loading] is true.
  /// If null and [svgAsset] is null, a default chevron icon is shown.
  final Widget? child;

  /// Optional SVG asset path to render as the button icon (e.g. 'assets/icons/send_icon.svg').
  /// Ignored if [loading] is true or [child] is provided.
  final String? svgAsset;

  /// Optional tint for the SVG (works best with monochrome SVGs).
  final Color? svgColor;

  /// Diameter of the circular button (width = height). Default: 74.
  final double size;

  /// Size for the default [Icon] or for the SVG (width & height). Default: 38 (Icon), 32 (SVG).
  final double iconSize;

  /// Background color of the button surface. Default: Colors.white.
  final Color? backgroundColor;

  /// Foreground color (ink ripple, default icon color). Default: Colors.black.
  final Color? foregroundColor;

  /// Elevation of the button. Default: 3.
  final double elevation;

  /// Optional tooltip shown on long-press / hover.
  final String? tooltip;

  /// Size of the loader. Default: 26.
  final double progressSize;

  const RoundArrowButton({
    super.key,
    required this.onPressed,
    this.loading = false,
    this.child,
    this.svgAsset,
    this.svgColor,
    this.size = 74,
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
      width: size,
      height: size,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          shape: const CircleBorder(),
          elevation: elevation,
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          padding: EdgeInsets.zero, // keep content centered and tight
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

    // Only wrap with Tooltip when provided
    return (tooltip == null) ? btn : Tooltip(message: tooltip!, child: btn);
  }

  /// Decide what to render inside when not loading.
  Widget _buildInner() {
    if (child != null) return child!;
    if (svgAsset != null) {
      return SvgPicture.asset(
        svgAsset!,
        width: iconSize,
        height: iconSize,
        // Apply tint only if provided. If your SVG has its own fills, this may not recolor it.
        colorFilter:
        (svgColor == null) ? null : ColorFilter.mode(svgColor!, BlendMode.srcIn),
      );
    }
    // Fallback to a default Material icon
    return Icon(Icons.chevron_right, size: iconSize);
  }
}