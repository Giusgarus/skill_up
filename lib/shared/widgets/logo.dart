import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// App logo rendered from an SVG asset.
/// If your asset is already white, you can omit the [colorFilter].
class AppLogo extends StatelessWidget {
  final double height;
  const AppLogo({super.key, this.height = 200});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/brand/skillup_whitelogo.svg',
      height: height,
      fit: BoxFit.contain,
      // Force white in case the SVG isn't already white:
      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
      // semanticsLabel: 'SkillUp logo', // accessibility (optional)
    );
  }
}